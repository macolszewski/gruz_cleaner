import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
HELPER = Path(__file__).resolve().parents[2] / "Sources/CleanerKit/Helpers/claude_mem_reindex.py"
spec = importlib.util.spec_from_file_location("claude_mem_reindex", HELPER)
reindex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reindex)


class Collection:
    def __init__(self):
        self.docs = {}

    def add(self, ids, documents, metadatas):
        self.docs.update(zip(ids, zip(documents, metadatas)))

    def count(self):
        return len(self.docs)

    def get(self, limit, offset, include):
        return {"ids": sorted(self.docs)[offset:offset + limit]}


class Client:
    def __init__(self, collection):
        self.collection = collection

    def create_collection(self, name):
        assert name == "cm__claude-mem"
        return self.collection


def fixture(path):
    with closing(sqlite3.connect(path)) as db:
        db.executescript("""
        CREATE TABLE sdk_sessions(id INTEGER PRIMARY KEY, memory_session_id TEXT UNIQUE, project TEXT, platform_source TEXT);
        CREATE TABLE observations(id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT, narrative TEXT, title TEXT, subtitle TEXT, facts TEXT, concepts TEXT, files_read TEXT, files_modified TEXT, created_at_epoch INTEGER, merged_into_project TEXT);
        CREATE TABLE session_summaries(id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT, request TEXT, notes TEXT, created_at_epoch INTEGER);
        CREATE TABLE user_prompts(id INTEGER PRIMARY KEY, session_db_id INTEGER, prompt_text TEXT, created_at_epoch INTEGER);
        INSERT INTO sdk_sessions VALUES(1,'m1','alpha','codex'),(2,'m2','summary-only','claude'),(3,'m3','prompt-only','claude');
        INSERT INTO observations VALUES(1,'m1','alpha','Retained narrative','Title','Subtitle','["fact"]','["testing"]','["file.swift"]','[]',1000,'merged');
        INSERT INTO observations VALUES(2,'m1','alpha',NULL,'Title only',NULL,'[]',NULL,NULL,NULL,2000,NULL);
        INSERT INTO session_summaries VALUES(7,'m2','summary-only','Summary request','notes',1000);
        INSERT INTO user_prompts VALUES(8,3,'Retained prompt',1000);
        """)
        db.commit()


class ReindexTests(unittest.TestCase):
    def test_document_contract(self):
        row = dict(id=42, created_at_epoch=1000, project="example", memory_session_id="m", title="Heading", facts='["fact", 2]', concepts='["concept"]', merged_into_project="destination")
        docs = reindex.documents("observations", row)
        self.assertEqual([doc[0] for doc in docs], ["obs_42_fact_0"])
        self.assertEqual(docs[0][2]["sqlite_id"], 42)
        self.assertEqual(docs[0][2]["merged_into_project"], "destination")
        self.assertEqual(docs[0][2]["platform_source"], "claude")

    def test_list_fields_match_upstream_parsers(self):
        # Expected values follow claude-mem's parseStringListField and parseFileList (commit 356b7c0),
        # written out by hand rather than produced by the helper.
        cases = [
            ('["fact"]', ["fact"]),
            ('"fact"', ["fact"]),
            ("plain, with a comma", ["plain, with a comma"]),
            ('["a", 2, "  ", "b"]', ["a", "b"]),
            ('{"k": 1}', ['{"k": 1}']),
            ('"   "', []),
            ("", []),
            (None, []),
        ]
        for raw, expected in cases:
            self.assertEqual(reindex.string_list(raw), expected, raw)
        self.assertEqual(reindex.file_list('["a.swift", "b.swift"]'), ["a.swift", "b.swift"])
        self.assertEqual(reindex.file_list("a.swift, b.swift"), ["a.swift, b.swift"])
        self.assertEqual(reindex.file_list('"a.swift"'), ["a.swift"])
        self.assertEqual(reindex.file_list("null"), ["null"])

    def test_fact_stored_as_json_string_is_indexed(self):
        row = dict(id=5, created_at_epoch=1000, title="Untitled", facts='"The only fact"')
        docs = reindex.documents("observations", row)
        self.assertEqual([(doc[0], doc[1]) for doc in docs], [("obs_5_fact_0", "The only fact")])

    def test_title_only_and_empty_observations(self):
        self.assertEqual(reindex.documents("observations", dict(id=1, created_at_epoch=1000, title="Title"))[0][0], "obs_1_title")
        self.assertEqual(reindex.documents("observations", dict(id=1, created_at_epoch=1000, title="Untitled")), [])

    def test_layouts_follow_each_release_line(self):
        # Expected values follow ChromaSync and normalizePlatformSource at v13.28.0, v13.29.0 and v13.34.0
        # (unchanged through v15.17.0), written out by hand.
        title_only = dict(id=1, created_at_epoch=1000, project="p", title="Title")
        self.assertEqual(reindex.documents("observations", title_only, "13.28"), [])
        self.assertEqual(reindex.documents("observations", title_only, "13.29")[0][0], "obs_1_title")
        cases = [("pi-mono", "pi-mono", "pi"), ("Kimi CLI", "kimi-cli", "kimi"), ("agy", "agy", "antigravity-cli"),
                 ("Claude Code", "claude", "claude"), ("transcript", "codex", "codex"), ("", "claude", "claude")]
        for raw, old, new in cases:
            row = dict(id=2, created_at_epoch=1000, project="p", narrative="n", platform_source=raw)
            self.assertEqual(reindex.documents("observations", row, "13.28")[0][2]["platform_source"], old, raw)
            self.assertEqual(reindex.documents("observations", row, "13.34")[0][2]["platform_source"], new, raw)
        self.assertEqual(reindex.documents("observations", dict(row, platform_source="pi-mono"), "13.29")[0][2]["platform_source"], "pi-mono")

    def test_text_and_metadata_cleanup_matches_add_documents(self):
        row = dict(id=3, created_at_epoch=1000, project="p", memory_session_id=None, narrative="a\0b", merged_into_project="", files_read="[]")
        doc = reindex.documents("observations", row)[0]
        self.assertEqual(doc[1], "a�b")
        self.assertNotIn("memory_session_id", doc[2])
        self.assertNotIn("merged_into_project", doc[2])
        self.assertEqual(reindex.documents("observations", row, "13.28")[0][1], "a\0b")
        prompt = reindex.documents("prompts", dict(id=4, created_at_epoch=1000, project="p", prompt_text="t", platform_source="Pi-Mono", prompt_number=None))[0]
        self.assertEqual(prompt[2]["platform_source"], "Pi-Mono")
        self.assertNotIn("prompt_number", prompt[2])
        self.assertEqual(reindex.file_list('[{"a": 1}]'), [{"a": 1}])
        self.assertEqual(reindex._js_string({"a": 1}), "[object Object]")

    def test_rows_without_project_are_not_indexed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root / "memory.db")
            with closing(sqlite3.connect(root / "memory.db")) as db:
                db.execute("INSERT INTO observations(id, project, narrative, created_at_epoch) VALUES(9, NULL, 'orphan', 1000)")
                db.commit()
            collection = Collection()
            reindex.rebuild(root / "memory.db", root / "new", lambda _: Client(collection))
            self.assertNotIn("obs_9_narrative", collection.docs)
            self.assertNotIn("", json.loads((root / "new/cleaner-watermarks.json").read_text()))
            self.assertFalse((root / "new/cleaner-progress.json").exists())

    def write_store(self, path, docs):
        """A minimal Chroma 1.x SQLite store holding `docs` in the claude-mem collection."""
        with closing(sqlite3.connect(path)) as store:
            store.executescript("""
            CREATE TABLE collections(id TEXT PRIMARY KEY, name TEXT);
            CREATE TABLE segments(id TEXT PRIMARY KEY, collection TEXT);
            CREATE TABLE embeddings(id INTEGER PRIMARY KEY, segment_id TEXT, embedding_id TEXT, seq_id INTEGER);
            CREATE TABLE embedding_metadata(id INTEGER, key TEXT, string_value TEXT, int_value INTEGER, float_value REAL, bool_value INTEGER);
            INSERT INTO collections VALUES('c', 'cm__claude-mem');
            INSERT INTO segments VALUES('s', 'c');
            """)
            for rowid, (identifier, text, metadata) in enumerate(docs, start=1):
                store.execute("INSERT INTO embeddings VALUES(?, 's', ?, ?)", (rowid, identifier, rowid))
                store.execute("INSERT INTO embedding_metadata(id, key, string_value) VALUES(?, 'chroma:document', ?)", (rowid, text))
                for key, value in metadata.items():
                    column = "int_value" if isinstance(value, int) else "string_value"
                    store.execute(f"INSERT INTO embedding_metadata(id, key, {column}) VALUES(?, ?, ?)", (rowid, key, value))
            store.commit()

    def test_probe_accepts_the_known_format_and_refuses_a_changed_one(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root / "memory.db")
            expected, _ = reindex.source_snapshot(root / "memory.db")
            docs = [(i, text, meta) for i, (text, meta) in expected.items()]
            (root / "same").mkdir()
            self.write_store(root / "same/chroma.sqlite3", docs)
            reindex.probe_format(root / "memory.db", root / "same")
            (root / "renamed").mkdir()
            self.write_store(root / "renamed/chroma.sqlite3", [("v2_" + i, text, meta) for i, text, meta in docs])
            with self.assertRaises(ValueError):
                reindex.probe_format(root / "memory.db", root / "renamed")
            (root / "extra").mkdir()
            self.write_store(root / "extra/chroma.sqlite3", [(i, text, dict(meta, schema=2)) for i, text, meta in docs])
            with self.assertRaises(ValueError):
                reindex.probe_format(root / "memory.db", root / "extra")
            (root / "empty").mkdir()
            self.write_store(root / "empty/chroma.sqlite3", [])
            reindex.probe_format(root / "memory.db", root / "empty")

    def test_full_rebuild_includes_summary_and_prompt_only_projects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db = root / "memory.db"
            fixture(db)
            before = db.read_bytes()
            collection = Collection()
            reindex.rebuild(db, root / "new", lambda _: Client(collection))
            self.assertEqual(set(collection.docs), {"obs_1_narrative", "obs_1_fact_0", "obs_2_title", "summary_7_request", "summary_7_notes", "prompt_8"})
            self.assertEqual(collection.docs["obs_1_narrative"][1]["platform_source"], "codex")
            marks = json.loads((root / "new/cleaner-watermarks.json").read_text())
            self.assertEqual(marks["summary-only"]["summaries"], 7)
            self.assertEqual(marks["prompt-only"]["prompts"], 8)
            self.assertEqual(db.read_bytes(), before)
            with self.assertRaises(ValueError):
                reindex.rebuild(db, root / "new", lambda _: Client(collection))

    def test_mismatched_index_is_not_accepted(self):
        class Broken(Collection):
            def count(self):
                return 0
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root / "memory.db")
            with self.assertRaises(ValueError):
                reindex.rebuild(root / "memory.db", root / "new", lambda _: Client(Broken()))
            self.assertFalse((root / "new/cleaner-watermarks.json").exists())

    def test_write_during_verification_is_not_accepted(self):
        class Stored(Collection):
            def get(self, limit, offset, include):
                ids = sorted(self.docs)[offset:offset + limit]
                return {"ids": ids, "documents": [self.docs[i][0] for i in ids], "metadatas": [self.docs[i][1] for i in ids]}

        class Verifying(Client):
            def get_collection(self, name):
                assert name == "cm__claude-mem"
                return self.collection

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root / "memory.db")
            collection = Stored()
            reindex.rebuild(root / "memory.db", root / "new", lambda _: Client(collection))
            (root / "new/chroma.sqlite3").touch()
            reindex.verify_index(root / "memory.db", root / "new", lambda _: Verifying(collection))

            def writing(_):
                # Another process writes after the database was read and before the comparison ends.
                with closing(sqlite3.connect(root / "memory.db")) as db:
                    db.execute("UPDATE observations SET narrative='Changed during verification' WHERE id=1")
                    db.commit()
                return Verifying(collection)

            with self.assertRaisesRegex(ValueError, "changed during verification"):
                reindex.verify_index(root / "memory.db", root / "new", writing)

    @unittest.skipUnless(os.getenv("CLEANER_TEST_CHROMA") == "1", "optional real Chroma integration")
    def test_real_chroma_rebuild_and_query(self):
        import chromadb
        from chromadb.config import Settings
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root / "memory.db")
            reindex.rebuild(root / "memory.db", root / "new")
            client = chromadb.PersistentClient(path=str(root / "new"), settings=Settings(anonymized_telemetry=False))
            collection = client.get_collection("cm__claude-mem")
            self.assertEqual(collection.count(), 6)
            result = collection.query(query_texts=["Retained prompt"], n_results=1)
            self.assertEqual(result["ids"][0], ["prompt_8"])
            reindex.verify_index(root / "memory.db", root / "new")
            with closing(sqlite3.connect(root / "memory.db")) as db:
                db.execute("UPDATE observations SET narrative='Changed content' WHERE id=1")
                db.commit()
            with self.assertRaises(ValueError):
                reindex.verify_index(root / "memory.db", root / "new")


if __name__ == "__main__":
    unittest.main()

"""Rebuild claude-mem's derived Chroma collection from a read-only SQLite snapshot.

GRUZ runs this helper through `uv` (see ClaudeMemoryRuntime.swift) while the claude-mem
worker is stopped. Document IDs and metadata follow the Apache-2.0 claude-mem ChromaSync
contract (thedotmack/claude-mem 13.28 to 15.x), so claude-mem keeps using the rebuilt index
as if it had written it. The contract changed twice in that range; `--layout` selects the
variant matching the installed worker (see LAYOUTS). No provider inference or cloud sync is used.

Contract with the Swift side: exit status 0 means success; on failure the output tail is shown
to the user. During a rebuild, `cleaner-progress.json` in the output folder reports progress,
and `cleaner-watermarks.json` is written last, only after the index has been verified.
"""

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3

# The ChromaSync variants: whether an observation without narrative, text or facts gets a title
# document and NUL bytes become U+FFFD (both added in 13.29.0), and whether "pi-mono" is
# normalized to "pi" (13.34.0). Later releases up to 15.x kept the 13.34 format.
LAYOUTS = {
    "13.28": {"title_documents": False, "replace_nul": False, "pi_mono": False, "newer_sources": False},
    "13.29": {"title_documents": True, "replace_nul": True, "pi_mono": False, "newer_sources": True},
    "13.34": {"title_documents": True, "replace_nul": True, "pi_mono": True, "newer_sources": True},
}
LATEST_LAYOUT = "13.34"

INDEX_QUERIES = {
    # ChromaSync backfills project by project, so rows without a project are never indexed.
    "observations": "SELECT t.*, s.platform_source FROM observations t LEFT JOIN sdk_sessions s ON t.memory_session_id=s.memory_session_id WHERE t.project IS NOT NULL",
    "summaries": "SELECT t.*, s.platform_source FROM session_summaries t LEFT JOIN sdk_sessions s ON t.memory_session_id=s.memory_session_id WHERE t.project IS NOT NULL",
    "prompts": "SELECT t.*, s.memory_session_id, s.project, s.platform_source FROM user_prompts t JOIN sdk_sessions s ON t.session_db_id=s.id WHERE s.project IS NOT NULL",
}


def platform_source(value, layout):
    """claude-mem's normalizePlatformSource for the given layout."""
    source = "-".join(str(value or "").strip().lower().split())
    if not source:
        return "claude"
    if source == "transcript" or "codex" in source:
        return "codex"
    if "cursor" in source:
        return "cursor"
    if "claude" in source:
        return "claude"
    if layout["newer_sources"] and "kimi" in source:
        return "kimi"
    if layout["pi_mono"] and source == "pi-mono":
        return "pi"
    if layout["newer_sources"] and (source in ("agy", "antigravity") or source.startswith("antigravity-")):
        return "antigravity-cli"
    return source


def string_list(value):
    """Parse a `facts` or `concepts` column like claude-mem's parseStringListField.

    A JSON array keeps its non-blank strings. Anything else (a JSON string, other JSON, or plain
    text, including text with commas) becomes one entry, so no fact is dropped or split.
    """
    if not value:
        return []
    text = str(value)
    try:
        decoded = json.loads(text)
    except (ValueError, TypeError):
        return [text] if text.strip() else []
    if isinstance(decoded, list):
        return [item for item in decoded if isinstance(item, str) and item.strip()]
    if isinstance(decoded, str):
        return [decoded] if decoded.strip() else []
    return [text] if text.strip() else []


def _js_string(value):
    """String conversion as JavaScript's String() and Array.join() perform it."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, list):
        return ",".join(_js_string(item) for item in value)
    if isinstance(value, dict):
        return "[object Object]"
    return str(value)


def file_list(value):
    """Parse `files_read` / `files_modified` like claude-mem's parseFileList."""
    if not value:
        return []
    text = str(value)
    try:
        decoded = json.loads(text)
    except (ValueError, TypeError):
        return [text]
    if isinstance(decoded, list):
        return decoded
    return ["null" if decoded is None else _js_string(decoded)]


def documents(kind, row, layout_name=LATEST_LAYOUT):
    """Return the (id, text, metadata) documents ChromaSync would create for one SQLite row."""
    layout = LAYOUTS[layout_name]
    row = dict(row)
    identifier = row["id"]
    metadata = {
        "sqlite_id": identifier,
        "doc_type": {"observations": "observation", "summaries": "session_summary", "prompts": "user_prompt"}[kind],
        "memory_session_id": row.get("memory_session_id"),
        "project": row.get("project"),
        "created_at_epoch": row["created_at_epoch"],
    }
    if kind == "prompts":
        # Prompts keep the session's raw source; only observations and summaries are normalized.
        metadata.update(platform_source=row.get("platform_source") or "claude", prompt_number=row.get("prompt_number"))
        result = [(f"prompt_{identifier}", row.get("prompt_text") or "", metadata)]
    elif kind == "observations":
        metadata.update(merged_into_project=row.get("merged_into_project"),
                        platform_source=platform_source(row.get("platform_source"), layout),
                        type=row.get("type") or "discovery", title=row.get("title") or "Untitled")
        if row.get("subtitle"):
            metadata["subtitle"] = row["subtitle"]
        concepts = string_list(row.get("concepts"))
        if concepts:
            metadata["concepts"] = ",".join(concepts)
        for field in ("files_read", "files_modified"):
            values = file_list(row.get(field))
            if values:
                metadata[field] = ",".join(_js_string(item) for item in values)
        result = []
        for field in ("narrative", "text"):
            if row.get(field):
                result.append((f"obs_{identifier}_{field}", row[field], dict(metadata, field_type=field)))
        for index, fact in enumerate(string_list(row.get("facts"))):
            result.append((f"obs_{identifier}_fact_{index}", fact, dict(metadata, field_type="fact", fact_index=index)))
        if not result and layout["title_documents"]:
            title = (row.get("title") or "").strip()
            title = "" if title == "Untitled" else title
            text = "\n".join(part for part in (title, (row.get("subtitle") or "").strip()) if part)
            if text:
                result.append((f"obs_{identifier}_title", text, dict(metadata, field_type="title")))
    else:
        metadata.update(merged_into_project=row.get("merged_into_project"),
                        platform_source=platform_source(row.get("platform_source"), layout),
                        prompt_number=row.get("prompt_number") or 0)
        result = [(f"summary_{identifier}_{field}", row[field], dict(metadata, field_type=field))
                  for field in ("request", "investigated", "learned", "completed", "next_steps", "notes") if row.get(field)]
    # ChromaSync.addDocuments drops empty metadata values and, from 13.29, replaces NUL bytes.
    return [(doc_id, text.replace("\0", "\ufffd") if layout["replace_nul"] else text,
             {key: value for key, value in meta.items() if value is not None and value != ""})
            for doc_id, text, meta in result]


def default_client_factory(path):
    import chromadb
    from chromadb.config import Settings
    return chromadb.PersistentClient(path=path, settings=Settings(anonymized_telemetry=False))


def source_rows(db):
    """(kind, row) for every source row, in index order. The caller holds one read transaction."""
    for kind, query in INDEX_QUERIES.items():
        for row in db.execute(query):
            yield kind, row


def add_watermark(watermarks, kind, row):
    marks = watermarks.setdefault(row["project"], {"observations": 0, "summaries": 0, "prompts": 0, "titleOnlyRequeued": True})
    marks[kind] = max(marks[kind], row["id"])


def open_snapshot(database):
    db = sqlite3.connect(Path(database).resolve(strict=True).as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    # One read transaction, so every pass sees the same snapshot.
    db.execute("BEGIN")
    return closing(db)


def rebuild(database, output, client_factory=None, layout=LATEST_LAYOUT):
    """Build a new index in `output`, which must not exist yet; `client_factory` is replaced in tests."""
    database = Path(database).resolve(strict=True)
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError("Destination already exists; refusing to overwrite an index")
    output.mkdir(mode=0o700, parents=False)
    client = (client_factory or default_client_factory)(str(output))
    collection = client.create_collection("cm__claude-mem")
    watermarks = {}
    expected_ids = set()
    batch = []
    written = 0
    total = 0

    def flush():
        nonlocal written
        if not batch:
            return
        collection.add(ids=[doc[0] for doc in batch], documents=[doc[1] for doc in batch], metadatas=[doc[2] for doc in batch])
        written += len(batch)
        temporary = output / "cleaner-progress.tmp"
        temporary.write_text(json.dumps({"completed": written, "total": total}))
        temporary.replace(output / "cleaner-progress.json")
        batch.clear()

    with open_snapshot(database) as db:
        total = sum(len(documents(kind, row, layout)) for kind, row in source_rows(db))
        for kind, row in source_rows(db):
            add_watermark(watermarks, kind, row)
            for doc in documents(kind, row, layout):
                if doc[0] in expected_ids:
                    raise ValueError("Duplicate document ID; database session relationships are ambiguous")
                expected_ids.add(doc[0])
                batch.append(doc)
                if len(batch) >= 128:
                    flush()
        flush()
    if collection.count() != len(expected_ids):
        raise ValueError("Chroma document count does not match SQLite")
    actual_ids = set()
    for offset in range(0, len(expected_ids), 1000):
        actual_ids.update(collection.get(limit=1000, offset=offset, include=[])["ids"])
    if actual_ids != expected_ids:
        raise ValueError("Chroma document IDs do not match SQLite")
    (output / "cleaner-progress.json").unlink(missing_ok=True)
    # Written last: its presence marks the index as complete and verified.
    with (output / "cleaner-watermarks.json").open("x") as handle:
        json.dump(watermarks, handle, sort_keys=True)
    print(json.dumps({"verified": True, "documents": len(expected_ids), "projects": len(watermarks)}), flush=True)


def source_snapshot(database, layout=LATEST_LAYOUT):
    """Documents and watermarks the database holds now, read in one transaction."""
    expected = {}
    watermarks = {}
    with open_snapshot(database) as db:
        for kind, row in source_rows(db):
            add_watermark(watermarks, kind, row)
            for identifier, document, metadata in documents(kind, row, layout):
                if identifier in expected:
                    raise ValueError("Duplicate source document ID")
                expected[identifier] = (document, metadata)
    return expected, watermarks


def verify_index(database, output, client_factory=None, layout=LATEST_LAYOUT):
    """Validate a completed staging index against current source content before recovery.

    The database is read again after the comparison: a write that lands while the index is being
    compared would otherwise leave an accepted index older than the database."""
    output = Path(output)
    if output.is_symlink() or not (output / "chroma.sqlite3").is_file() or not (output / "cleaner-watermarks.json").is_file():
        raise ValueError("No completed staging index")
    expected, watermarks = source_snapshot(database, layout)
    if json.loads((output / "cleaner-watermarks.json").read_text()) != watermarks:
        raise ValueError("Staging watermarks no longer match the database")
    client = (client_factory or default_client_factory)(str(output))
    collection = client.get_collection("cm__claude-mem")
    if collection.count() != len(expected):
        raise ValueError("Staging index is incomplete")
    seen = set()
    for offset in range(0, len(expected), 500):
        page = collection.get(limit=500, offset=offset, include=["documents", "metadatas"])
        for identifier, document, metadata in zip(page["ids"], page["documents"], page["metadatas"]):
            if expected.get(identifier) != (document, metadata):
                raise ValueError("Staging document no longer matches the database")
            seen.add(identifier)
    if seen != set(expected):
        raise ValueError("Staging document IDs do not match")
    if source_snapshot(database, layout) != (expected, watermarks):
        raise ValueError("The database changed during verification")
    print(json.dumps({"verified": True, "documents": len(expected)}), flush=True)


PROBE_SIZE = 500


def stored_documents(index, limit):
    """The newest documents claude-mem wrote to its collection, read from Chroma's SQLite store
    read-only, without starting Chroma: {id: (text, metadata)}."""
    store = sqlite3.connect(Path(index, "chroma.sqlite3").resolve(strict=True).as_uri() + "?mode=ro", uri=True)
    with closing(store):
        newest = store.execute(
            "SELECT e.id, e.embedding_id FROM embeddings e JOIN segments s ON s.id = e.segment_id "
            "JOIN collections c ON c.id = s.collection WHERE c.name = 'cm__claude-mem' ORDER BY e.seq_id DESC LIMIT ?", (limit,)).fetchall()
        result = {}
        for rowid, identifier in newest:
            text, metadata = None, {}
            for key, string, integer, real, boolean in store.execute(
                    "SELECT key, string_value, int_value, float_value, bool_value FROM embedding_metadata WHERE id = ?", (rowid,)):
                value = next((v for v in (string, integer, real, boolean) if v is not None), None)
                if key == "chroma:document":
                    text = value
                else:
                    metadata[key] = value
            result[identifier] = (text, metadata)
        return result


def probe_format(database, index, layout=LATEST_LAYOUT, limit=PROBE_SIZE):
    """Check that the installed worker writes documents the way `layout` describes, by comparing its
    newest documents with what this helper produces for the same rows. A release that changes the
    format fails here, before GRUZ deletes anything.

    `memory_session_id` is ignored: claude-mem keeps the value it saw when it indexed a prompt, which
    can predate the session's id. A few differences are tolerated (a row edited after indexing,
    a document of a deleted row); a format change affects nearly every document."""
    stored = stored_documents(index, limit)
    if not stored:
        print(json.dumps({"probed": 0}), flush=True)
        return
    expected, _ = source_snapshot(database, layout)
    without_session = lambda metadata: {k: v for k, v in metadata.items() if k != "memory_session_id"}
    present = [identifier for identifier in stored if identifier in expected]
    different = [identifier for identifier in present
                 if expected[identifier][0] != stored[identifier][0]
                 or without_session(expected[identifier][1]) != without_session(stored[identifier][1])]
    print(json.dumps({"probed": len(stored), "present": len(present), "different": len(different)}), flush=True)
    if len(present) < len(stored) / 2 or len(different) > max(2, len(present) // 50):
        sample = different[0] if different else next(iter(set(stored) - set(present)))
        raise ValueError(f"The index uses a document format this helper does not reproduce (for example {sample})")


def main():
    parser = argparse.ArgumentParser(description="Rebuild or verify claude-mem's Chroma index for GRUZ.")
    parser.add_argument("--check", action="store_true", help="only check that the embedding model is available")
    parser.add_argument("--verify", action="store_true", help="verify an existing index in --output instead of building one")
    parser.add_argument("--probe", action="store_true", help="compare the newest documents of the index in --output with this helper's format")
    parser.add_argument("--database", help="claude-mem SQLite database, opened read-only")
    parser.add_argument("--output", help="index folder; must not exist unless --verify is given")
    parser.add_argument("--layout", choices=sorted(LAYOUTS), default=LATEST_LAYOUT,
                        help="ChromaSync document format of the installed claude-mem worker")
    args = parser.parse_args()
    os.environ["ANONYMIZED_TELEMETRY"] = "False"
    if args.check:
        from chromadb.utils.embedding_functions import DefaultEmbeddingFunction
        vectors = DefaultEmbeddingFunction()(["GRUZ index readiness check"])
        if len(vectors) != 1:
            raise RuntimeError("Embedding model unavailable")
        print('{"ready": true}')
    elif args.database and args.output:
        if args.probe:
            probe_format(args.database, args.output, layout=args.layout)
        elif args.verify:
            verify_index(args.database, args.output, layout=args.layout)
        else:
            rebuild(args.database, args.output, layout=args.layout)
    else:
        parser.error("Pass --check or both --database and --output")


if __name__ == "__main__":
    main()

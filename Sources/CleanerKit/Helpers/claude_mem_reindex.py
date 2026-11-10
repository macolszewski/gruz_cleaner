"""Rebuild claude-mem's derived Chroma collection from a read-only SQLite snapshot.

GRUZ runs this helper through `uv` (see ClaudeMemoryRuntime.swift) while the claude-mem
worker is stopped. Document IDs and metadata follow the Apache-2.0 claude-mem ChromaSync
contract (thedotmack/claude-mem, 13.28-13.35), so claude-mem keeps using the rebuilt index
as if it had written it. No provider inference or cloud sync is used.

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

INDEX_QUERIES = {
    "observations": "SELECT t.*, s.platform_source FROM observations t LEFT JOIN sdk_sessions s ON t.memory_session_id=s.memory_session_id",
    "summaries": "SELECT t.*, s.platform_source FROM session_summaries t LEFT JOIN sdk_sessions s ON t.memory_session_id=s.memory_session_id",
    "prompts": "SELECT t.*, s.memory_session_id, s.project, s.platform_source FROM user_prompts t JOIN sdk_sessions s ON t.session_db_id=s.id",
}


def string_list(value):
    """Parse a JSON array column, falling back to comma-separated text written by older versions."""
    if not value:
        return []
    try:
        decoded = json.loads(value)
    except (ValueError, TypeError):
        return [part.strip() for part in str(value).split(",") if part.strip()]
    return [item for item in decoded if isinstance(item, str) and item] if isinstance(decoded, list) else []


def documents(kind, row):
    """Return the (id, text, metadata) documents ChromaSync would create for one SQLite row."""
    row = dict(row)
    identifier = row["id"]
    metadata = {
        "sqlite_id": identifier,
        "doc_type": {"observations": "observation", "summaries": "session_summary", "prompts": "user_prompt"}[kind],
        "memory_session_id": row.get("memory_session_id") or "",
        "project": row.get("project") or "",
        "platform_source": row.get("platform_source") or "claude",
        "created_at_epoch": row["created_at_epoch"],
    }
    if row.get("merged_into_project") is not None:
        metadata["merged_into_project"] = row["merged_into_project"]
    if kind == "observations":
        metadata.update(type=row.get("type") or "discovery", title=row.get("title") or "Untitled")
        if row.get("subtitle"):
            metadata["subtitle"] = row["subtitle"]
        for field in ("concepts", "files_read", "files_modified"):
            values = string_list(row.get(field))
            if values:
                metadata[field] = ",".join(values)
        result = []
        for field in ("narrative", "text"):
            if row.get(field):
                result.append((f"obs_{identifier}_{field}", row[field], dict(metadata, field_type=field)))
        for index, fact in enumerate(string_list(row.get("facts"))):
            result.append((f"obs_{identifier}_fact_{index}", fact, dict(metadata, field_type="fact", fact_index=index)))
        if not result:
            title = (row.get("title") or "").strip()
            title = "" if title == "Untitled" else title
            text = "\n".join(part for part in (title, (row.get("subtitle") or "").strip()) if part)
            if text:
                result.append((f"obs_{identifier}_title", text, dict(metadata, field_type="title")))
        return result
    metadata["prompt_number"] = row.get("prompt_number") or 0
    if kind == "summaries":
        return [(f"summary_{identifier}_{field}", row[field], dict(metadata, field_type=field))
                for field in ("request", "investigated", "learned", "completed", "next_steps", "notes") if row.get(field)]
    return [(f"prompt_{identifier}", row.get("prompt_text") or "", metadata)]


def rebuild(database, output, client_factory=None):
    """Build a new index in `output`, which must not exist yet; `client_factory` is replaced in tests."""
    database = Path(database).resolve(strict=True)
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError("Destination already exists; refusing to overwrite an index")
    output.mkdir(mode=0o700, parents=False)
    if client_factory is None:
        import chromadb
        from chromadb.config import Settings
        client_factory = lambda path: chromadb.PersistentClient(path=path, settings=Settings(anonymized_telemetry=False))
    client = client_factory(str(output))
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

    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        # One read transaction, so counting and indexing see the same snapshot.
        db.execute("BEGIN")
        total = sum(len(documents(kind, row)) for kind, query in INDEX_QUERIES.items() for row in db.execute(query))
        for kind, query in INDEX_QUERIES.items():
            for row in db.execute(query):
                project = row["project"] or ""
                marks = watermarks.setdefault(project, {"observations": 0, "summaries": 0, "prompts": 0, "titleOnlyRequeued": True})
                marks[kind] = max(marks[kind], row["id"])
                for doc in documents(kind, row):
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
    # Written last: its presence marks the index as complete and verified.
    with (output / "cleaner-watermarks.json").open("x") as handle:
        json.dump(watermarks, handle, sort_keys=True)
    print(json.dumps({"verified": True, "documents": len(expected_ids), "projects": len(watermarks)}), flush=True)


def verify_index(database, output):
    """Validate a completed staging index against current source content before recovery."""
    import chromadb
    from chromadb.config import Settings
    output = Path(output)
    if output.is_symlink() or not (output / "chroma.sqlite3").is_file() or not (output / "cleaner-watermarks.json").is_file():
        raise ValueError("No completed staging index")
    expected = {}
    watermarks = {}
    with closing(sqlite3.connect(Path(database).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        for kind, query in INDEX_QUERIES.items():
            for row in db.execute(query):
                marks = watermarks.setdefault(row["project"] or "", {"observations": 0, "summaries": 0, "prompts": 0, "titleOnlyRequeued": True})
                marks[kind] = max(marks[kind], row["id"])
                for identifier, document, metadata in documents(kind, row):
                    if identifier in expected:
                        raise ValueError("Duplicate source document ID")
                    expected[identifier] = (document, metadata)
    if json.loads((output / "cleaner-watermarks.json").read_text()) != watermarks:
        raise ValueError("Staging watermarks no longer match the database")
    client = chromadb.PersistentClient(path=str(output), settings=Settings(anonymized_telemetry=False))
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
    print(json.dumps({"verified": True, "documents": len(expected)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description="Rebuild or verify claude-mem's Chroma index for GRUZ.")
    parser.add_argument("--check", action="store_true", help="only check that the embedding model is available")
    parser.add_argument("--verify", action="store_true", help="verify an existing index in --output instead of building one")
    parser.add_argument("--database", help="claude-mem SQLite database, opened read-only")
    parser.add_argument("--output", help="index folder; must not exist unless --verify is given")
    args = parser.parse_args()
    os.environ["ANONYMIZED_TELEMETRY"] = "False"
    if args.check:
        from chromadb.utils.embedding_functions import DefaultEmbeddingFunction
        vectors = DefaultEmbeddingFunction()(["GRUZ index readiness check"])
        if len(vectors) != 1:
            raise RuntimeError("Embedding model unavailable")
        print('{"ready": true}')
    elif args.database and args.output:
        if args.verify:
            verify_index(args.database, args.output)
        else:
            rebuild(args.database, args.output)
    else:
        parser.error("Pass --check or both --database and --output")


if __name__ == "__main__":
    main()

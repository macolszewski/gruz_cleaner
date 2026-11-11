# claude-mem maintenance

[claude-mem](https://github.com/thedotmack/claude-mem) is a memory plugin for AI coding agents. It stores observations, session summaries, prompts and tool calls in SQLite and keeps a Chroma vector index of them. The **AI memory > claude-mem** section in GRUZ removes selected memory by date and project and then rebuilds the derived indexes, so removed records disappear from search as well.

This section is separate from the regular scan: claude-mem data is records in a live database, not folders, and removing it safely needs the plugin's own API.

## Data model

The data folder is `~/.claude-mem` by default. `CLAUDE_MEM_DATA_DIR` (from the environment or `~/.claude-mem/settings.json`) moves it. The worker port, Chroma mode, embedding function and cloud sync settings are read from the environment and `settings.json` in the data folder; the default port is 37777.

| Data | Location | How GRUZ removes it |
|---|---|---|
| Observations | `observations` table | Worker API `DELETE /api/observation/:id` |
| Session summaries | `session_summaries` | Worker API `DELETE /api/summary/:id` |
| User prompts | `user_prompts` | Worker API `DELETE /api/prompt/:id` |
| Tool call history | `tool_uses` | Local SQL transaction, after the worker is stopped |
| Full-text indexes | three FTS5 tables | `rebuild`, `integrity-check`, then `VACUUM` |
| Vector index | `chroma/` | A new collection built from the remaining database |
| Index progress | `chroma-sync-state.json` | New watermarks after the index is verified |
| Logs, observer session files | `logs/`, `observer-sessions/` | Selected regular files moved to the Trash |

Record dates come from `created_at_epoch` (milliseconds). A prompt's project comes from its session in `sdk_sessions`. The date filter is either "older than" or "since (inclusive)" a chosen day, split exactly at the start of that day in the local time zone. Log and observer files use their modification date and have no reliable project, so the project filter does not apply to them.

## Workflow

The preview only reads the database and files. It shows the record ids and file paths in the selected range before anything is removed. After confirmation, GRUZ:

1. Takes a lock so that only one GRUZ instance maintains a given data folder.
2. Checks the worker: it must serve the same database file, report version 13.x from 13.28.0 on, and have no active sessions, no processing in progress and an empty queue, as the worker itself reports them. Rows an earlier claude-mem version left in the `pending_messages` table are shown in the preview but do not block maintenance: the worker keeps its queue in memory and never processes them, and GRUZ does not remove them.
3. Compares the current records and files with the preview. Any difference stops the operation; the preview must be refreshed and confirmed again.
4. Prepares the local indexing environment before deleting anything (this may download dependencies on first use).
5. Makes a consistent SQLite copy with the SQLite backup API (which handles WAL correctly, unlike copying the file) and writes a maintenance marker, `.cleaner-maintenance.json`, into the data folder.
6. Deletes observations, summaries and prompts one by one through the worker API, checking each record again right before its deletion. A failure stops the deletions; there is no fallback to direct SQL. The result reports how many records were removed.
7. Stops the worker through its API and uses `lsof` to confirm that no process still has files in the data folder open. Without that confirmation, maintenance stops.
8. Removes the selected tool call rows in one transaction, moves selected log and observer files to the Trash, rebuilds the FTS tables, runs `VACUUM` and an SQLite integrity check.
9. Rebuilds the Chroma index from scratch into a separate `.cleaner-chroma-*` folder with a bundled Python helper, reporting progress in documents. The rebuild includes projects that have only summaries or prompts. Before installing the new index, the helper checks the set of document ids and the document count against the database.
10. Moves the old `chroma/` folder and `chroma-sync-state.json` into the backup, installs the new index and watermarks, starts the worker again (with Bun) and waits until it reports ready on the same database.

**Rebuild indexes** runs the same steps without deleting any records or files. It is also the way to finish maintenance that was interrupted: when the worker is stopped and the marker exists, only a rebuild is allowed. If an earlier rebuild finished its `.cleaner-chroma-*` folder, GRUZ reuses it after comparing every id, document, metadata entry and watermark with the current database, and skips embedding again. An incomplete or mismatched folder is ignored and a new one is built.

Every run appends a line to `~/Library/Logs/GRUZ/operations.log`.

The operation spans the worker, SQLite, Chroma and the file system, so it is not one global transaction. The result and the log show partial completion and whether a rebuild is still needed.

## Requirements

- claude-mem worker 13.x, version 13.28.0 or later, running when maintenance starts. An unknown schema stops the operation with an error. Newer 13.x versions are not guaranteed to be compatible.
- [Bun](https://bun.sh), to start the worker again.
- [uv](https://docs.astral.sh/uv/), to run the reindex helper on Python 3.13 with `chromadb==1.5.9`, `onnxruntime>=1.20` and `protobuf<7` (uv downloads Python 3.13 if it is missing). The first run may download these packages and the default embedding model; embedding itself runs locally.
- Local Chroma with the default embedding model. Remote Chroma and embedding functions that need API keys are refused before anything is deleted.
- No agent sessions using claude-mem during maintenance.

## Backups

Backups are written to `~/Library/Application Support/GRUZ/ClaudeMemBackups/<uuid>/`: the SQLite copy, the old `chroma/` folder and the old `chroma-sync-state.json`. The backup folder is created with permissions `0700` and the database copy with `0600`.

**Backups contain the removed data and take disk space until you delete them.** GRUZ does not remove them, and it never restores an old database or index automatically: that could bring back records locally that were already deleted in the cloud. `.cleaner-chroma-*` folders left by a failed rebuild may stay in the data folder for diagnosis.

Not touched by this section: configuration, sync identity and sync state tables, `sdk_sessions` metadata (including the first prompt of each session), original agent transcripts, backups, Knowledge Agent corpora and memory of other integrations.

## Cloud sync

Removing source rows with direct SQL would bypass claude-mem's sync protocol and could leave copies in the cloud. GRUZ deletes synchronized records only through the worker API, which writes the right deletion entries into the sync queue and refuses deletions it cannot attribute.

- With cloud sync configured, deletions may propagate to cmem.ai and to other devices.
- Records that came from another device (`origin_device_id` set) are excluded from the preview and must be removed on the device they came from.
- GRUZ leaves propagation to claude-mem's queue. Finishing local maintenance does not confirm that deletions reached the cloud.
- Do not restore an old database copy into a synchronized installation without first reconciling the cloud state.

## Usage quota

**Removing memory does not reset the cmem.ai usage quota.** The service refuses requests with `allowance_exhausted` when an account has used its allowance; that is a limit on service usage counted by the provider, not on the size of the local database. claude-mem has no supported way to reset the quota by deleting memory.

## Tests

Swift tests use separate databases in temporary folders and a fake runtime; they never touch real claude-mem data.

```bash
swift test
python3 -m unittest discover -s Tests/ClaudeMemoryReindexTests -v
```

The Python tests use a fake Chroma client. An optional integration test runs a real rebuild with Chroma and checks embeddings and search on synthetic memory:

```bash
CLEANER_TEST_CHROMA=1 uv run --no-project --python 3.13 \
  --with chromadb==1.5.9 --with 'onnxruntime>=1.20' --with 'protobuf<7' \
  python -m unittest discover -s Tests/ClaudeMemoryReindexTests -v
```

## References

The data layout and API were checked against claude-mem 13.28 to 13.35:

- [data paths](https://github.com/thedotmack/claude-mem/blob/356b7c08f64c29f931171e264e848772a039da62/src/shared/paths.ts)
- [deletion API](https://github.com/thedotmack/claude-mem/blob/356b7c08f64c29f931171e264e848772a039da62/src/services/worker/http/routes/DataRoutes.ts)
- [Chroma document format](https://github.com/thedotmack/claude-mem/blob/356b7c08f64c29f931171e264e848772a039da62/src/services/sync/ChromaSync.ts)
- [index watermarks](https://github.com/thedotmack/claude-mem/blob/356b7c08f64c29f931171e264e848772a039da62/src/services/sync/ChromaSyncState.ts)
- [cmem.ai gateway](https://github.com/thedotmack/claude-mem/blob/356b7c08f64c29f931171e264e848772a039da62/src/shared/cmem-gateway.ts)

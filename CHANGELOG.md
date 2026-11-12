# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.3.0]

### Changed

- A slow Docker or simulator query no longer holds back the rest of the scan: their storage is
  claimed first and their CLI queries run alongside the rules, projects and leftovers.
- Project folders are walked once for build artifacts and Cargo manifests together, with the same
  results as the two separate walks before.
- All folder walks of a scan share one limit on parallel work, outside Swift Concurrency's threads.
- Directory listings, preserved-data patterns and measurements are shared within one scan, so
  overlapping rules and leftover candidates no longer read the same folders again.
- The Rust signature is computed while walking, in name order, instead of collecting and sorting a
  text record of every entry. Selections kept from an earlier version need a new scan.
- The app keeps its item index and filtered lists until the result or a filter changes, computes the
  selection count and size in one pass, and reads and writes the last scan away from the main thread.
- `gruz-scan --stats` prints counts of the file system work; `--fs-width` sets the limit on
  parallel folder walks.

## [1.2.0]

### Changed

- claude-mem maintenance supports every release from 13.28.0 to 15.x, not only 13.x. The Chroma
  index is rebuilt in the document format of the installed worker, and the full-text indexes are read
  from the database schema. Before anything is deleted, the newest documents of the current index are
  compared with the helper's output, so a release that changes the format is refused.

### Fixed

- claude-mem: the default worker port is claude-mem's own (37700 plus the last two digits of the user
  id), not 37777.
- claude-mem: maintenance is refused when another component controls the worker (external
  autostart, remote worker, server mode, shared work-view state, a host other than 127.0.0.1) or an
  auto-update is in progress, and the stopped worker is checked again before every write.
- claude-mem: counters the worker updates in the background no longer invalidate the preview, rows
  without a project are no longer indexed, and empty metadata values match what claude-mem writes.
- The indexing helper no longer leaves `cleaner-progress.json` in the installed index.

## [1.1.0]

### Added

- Test results: Playwright (`test-results`, `playwright-report`, `blob-report` next to a Playwright
  configuration), Cypress (`screenshots`, `videos`, `downloads` in a project with a Cypress
  configuration) and .NET `TestResults`. They are **Caution**, since an old trace may be the only
  record of a failure.
- The Go module cache, cleared with `go clean -modcache` only while `go env GOMODCACHE` still names
  the scanned folder.
- Git dependencies of Cargo (`~/.cargo/git`) and Dart pub (`~/.pub-cache/git`), as **Caution**.
- Nx task cache (`.nx/cache` next to `nx.json`), Nox environments (`.nox`) and the .NET central
  `artifacts/bin` and `artifacts/obj` (`UseArtifactsOutput`), never `artifacts/publish` or `package`.
- Codex and Cursor worktrees outside project folders, each with its Git status.
- Archived Codex sessions, the Hugging Face Datasets cache and Whisper models.
- Rules can bind a command to the scanned folder with `preconditions`; artifact definitions can
  require a file next to the parent folder (`parentSiblingsAny`, `parentSiblingContainsAny`).

### Changed

- Project items from definitions with several folder names now show the folder (`app/bin`, `app/obj`)
  instead of the same project name twice.
- Rows an earlier claude-mem version left in `pending_messages` no longer block maintenance forever.
  The worker's own queue (which it keeps in memory) decides; the rows are shown and left untouched.

### Fixed

Fixes from a second technical audit, of 1.0.1.

- Docker commands could reach another engine when the CLI context changed during a long plan, because
  the engine check ran once per plan. Every Docker read and removal now names the endpoint found during
  the scan (`docker --host`), and the engine identity is checked again before each operation.
- `uv cache clean` follows a symbolic link put in place of the scanned cache folder and cleans its
  target. Commands that act on a folder now run only while it is still a real directory.
- The symlinked-folder check covered only the home and temporary folders, not the Android SDK under
  `/opt/homebrew`. It now covers every place where removal is allowed.
- A `build` folder with only generic names inside (`lib`, `tmp`) was offered as regenerable build
  output. Such folders are now **Caution** with a note, and folders with files tracked by Git are
  not offered at all.
- A folder the scan could not read looked the same as an empty one. Unreadable places are now listed
  in a scan warning, and a cache folder that may hide JetBrains Local History it cannot read is
  protected instead of offered.
- `git status` during a scan ran clean filters configured in the repository (Git LFS and others).
  They are now switched off for the scan.
- When the operation log failed partway through a plan, the remaining operations still ran. The plan
  now stops, and each operation is recorded before it starts.
- Stopping a command at its deadline signalled only the command, not the helpers it started. Commands
  now run in their own process group; stopping one ends the whole group, and helpers left behind when
  it exits are ended before its result is reported.
- A write to the claude-mem database while the rebuilt index was being compared could go unnoticed.
  The comparison now runs right before the index is installed and fails when the database changed
  during it.

## [1.0.1]

Fixes from an external technical audit of 1.0.0. The theme: what the review sheet shows must be
exactly what gets removed, and results must say honestly what happened.

### Fixed

- A rule match reached through a symbolic link folder (for example `~/.npm/_npx` linked to a project's
  `src`) was offered as a cache. Rule globs and the denylist now refuse paths with a symlinked folder
  below the home or temporary folder.
- JetBrains caches included Local History, which can restore deleted files and uncommitted changes.
  Only indexes and caches are offered now, and Local History is protected even from the generic
  "Other app caches" rule.
- The Hugging Face rule covered the login token. It now offers only the model stores, and the token is
  protected.
- The local Maven repository was **Regenerable** although it holds locally installed artifacts; it is
  **Caution** now, with an accurate description.
- A `build` folder next to `pyproject.toml` or `CMakeLists.txt` could be a source package. It now needs
  generated files inside and no source files.
- `uv cache clean` could clean a cache configured elsewhere (`UV_CACHE_DIR`) than the folder shown.
  It now runs with `--cache-dir` set to the measured folder.
- Docker commands ran against whatever engine the CLI context pointed to at removal time. Each
  command now checks that it talks to the scanned engine, and a tag is removed only while it still
  points to the scanned image.
- Scanning an agent worktree with `git status` could start a configured fsmonitor program; Git now
  runs with fsmonitor and optional locks disabled.
- An operation where only some paths were removed was reported as done and disappeared from the list.
  It is now reported as partly done, the remaining paths stay, and the failures are written to the
  operation log together with command output.
- If the operation log cannot be written, nothing is removed.
- Unreadable folders were measured as if complete. Partly measured items are marked and excluded from
  the "What grew" history.
- A Spotlight error made an app look uninstalled. Such candidates are no longer reported as leftovers.
- External commands now have a deadline, bounded output and proper termination; the app refuses to
  quit or start a scan while a removal runs.
- The claude-mem index helper parsed `facts` and file lists differently from claude-mem, so a fact
  stored as a JSON string was not indexed. It now follows claude-mem's parsers, and a freshly rebuilt
  index is verified against the current database before it is installed.
- The claude-mem helper ran on the newest Python found by uv, for which `onnxruntime` may have no
  wheels yet (Python 3.15); it now runs on Python 3.13.

### Changed

- Faster scans: claimed paths are indexed by ancestor, and app leftovers are sized before Spotlight is
  asked, a few queries at a time.
- CI runs the claude-mem helper against a real Chroma, and the release workflow publishes only when CI
  passed for the tagged commit.

## [1.0.0]

First public release.

### Added

- Read-only scan of caches, build artifacts, Docker and OrbStack data, simulators, AI tool data, browser and app caches, system logs, leftovers of uninstalled apps, installed applications and unrecognized large folders.
- A rule catalog of over 100 known locations, each with a description, safety level and regeneration note.
- Review sheet with exact paths, commands and total size; Trash by default; visibly marked permanent operations with an extra confirmation; operation log.
- Rust and Cargo cleanup by profile and component that keeps release binaries and refuses to run during active builds.
- "What grew" view comparing scans of the same scope.
- claude-mem maintenance: prune records by date and project, rebuild FTS and Chroma indexes, with backups.
- English and Polish interface and rule catalog, with an in-app language setting.
- `gruz-scan`: read-only command line report in text or JSON.

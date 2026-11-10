# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

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

### Changed

- Faster scans: claimed paths are indexed by ancestor, and app leftovers are sized before Spotlight is
  asked, a few queries at a time.
- CI tests on macOS 15 and macOS 26, runs the claude-mem helper against a real Chroma, and the release
  workflow publishes only after the full CI passes on the tagged commit.

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

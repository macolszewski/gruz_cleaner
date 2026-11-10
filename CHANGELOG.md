# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

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

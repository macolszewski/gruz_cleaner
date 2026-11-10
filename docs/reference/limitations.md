# Limitations

This page collects what GRUZ does not do, or does only approximately. Most limits are deliberate:
when GRUZ cannot be sure, it shows the data and leaves the decision to you.

## Platform and distribution

- **macOS 15 or later, Apple Silicon only.** Release builds are made on Apple Silicon; there is no
  Intel or universal build. You can [build from source](../guide/getting-started.md#build-from-source)
  on other supported Macs.
- **Not notarized.** The first launch needs **Open Anyway** in System Settings > Privacy & Security. Builds signed ad hoc lose the
  Full Disk Access grant after every rebuild.
- **English and Polish only.** See [Localization](localization.md) for adding a language.
- **The command line tool only reports.** `gruz-scan` is not part of the release zip and cannot
  remove anything. There is no AppleScript, URL scheme or other automation that can remove data.

## Sizes are estimates

GRUZ sums allocated blocks, like `du`, and the result sheet reports the measured change in free
space after a removal. The item sizes are still estimates of what removal frees:

- **APFS clones** share blocks between files. Each clone is counted in full, so removing one may free
  little. `uv`, for example, clones files from its cache into virtual environments, so clearing its
  cache frees less than its measured size.
- **Hard links** are counted once within an item, but a file linked from two items is counted in
  both. Rust components of one profile often share hard links.
- **Docker** sizes come from Docker's own report and may overlap.
- **The Trash** frees nothing until it is emptied, because it is on the same disk.
- **OrbStack** returns space freed by Docker to macOS gradually, after the commands finish.

## What GRUZ cannot see

- **Without Full Disk Access**, the Trash, Mail, Messages and iPhone backups are not measured.
- **Unreadable contents.** When part of a folder cannot be read, its item is marked as partly measured
  and its real size may be larger. A location that cannot be read at all is not shown.
- **Symbolic links.** A location reached through a symbolic link folder (for example a cache folder
  that links elsewhere) is not offered for removal, because the rule never saw what is really there.
- **Docker data is visible only while Docker runs.** GRUZ reads it through the `docker` CLI. If
  Docker Desktop or OrbStack is not running, only the VM disk image is shown.
- **Docker data is removed only through the `docker` CLI**, one image, container or volume at a time.
  The VM disk image itself can never be removed from GRUZ.
- **Project artifacts are found only in your project folders**, up to 12 levels deep, without
  following symlinks or crossing volumes. Artifacts elsewhere are not reported.
- **Unrecognized folders cannot be removed.** GRUZ does not guess what an undescribed folder is.
- **Applications are listed, not removed.** Uninstall apps in the Finder, with Homebrew or with
  JetBrains Toolbox.

## Heuristics

- **App leftovers** are matched by bundle identifier. An app installed in an unusual place, or one
  whose data folder is named differently, can be missed, so every leftover is **Caution** and goes to
  the Trash.
- **Version rules** (Playwright browsers, Node.js under nvm, Flutter SDKs under FVM, JetBrains
  settings) keep the newest version and offer older ones. GRUZ cannot tell which version a project
  still uses.
- **App leftovers need Spotlight.** When Spotlight does not answer, possible leftovers are not shown
  at all and the scan says how many were skipped.
- **Agent worktree status** comes from `git status`. GRUZ disables the fsmonitor hook and optional
  locks, but Git may still run clean filters configured for the repository (Git LFS, for example).
- **Age** is the newest modification time inside an item. A folder that is read often but never
  written can look old.

## Rust and Cargo

- Cargo is never run, and only literal TOML strings in Cargo configuration are understood. Templated
  target directories, `--config` overrides and `CARGO_TARGET_DIR` set only in a shell profile are not
  seen by the app.
- Removal is refused while any `cargo`, `rustc`, `rust-analyzer`, `sccache`, `lldb` or `gdb` process
  runs, anywhere on the system. This is intentionally conservative.
- After `.fingerprint` alone is removed, the profile stays blocked until Cargo builds it again.

See [Rust and Cargo](../guide/rust.md#limitations) for the full list.

## claude-mem

- Supports claude-mem worker 13.x from 13.28.0 on, with local Chroma and the default embedding model.
- Needs Bun and uv. The first run may download Python packages and the embedding model.
- Removing memory does not reset the cmem.ai usage quota.
- Backups contain the removed data and stay on disk until you delete them.

See [claude-mem maintenance](../guide/claude-mem.md#requirements).

## What grew

- History starts with the first complete scan; scans with warnings are not stored.
- Changing the project folders or the Full Disk Access state starts a new history.
- Without a baseline, Rust components show files created since yesterday, which is not net growth.

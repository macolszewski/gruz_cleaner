# Rust and Cargo

Cargo `target` folders grow quickly: a debug profile of a medium-sized workspace with integration tests can reach tens of gigabytes. Removing the whole `target` folder is wasteful (the release build and finished app bundles go with it) and risky (a configured target folder may hold other things). The Rust and Cargo category therefore splits each target into profiles and components and checks the folder again right before removal.

The code is in `Sources/ScannerKit/Rust` (discovery and measurement) and `Sources/CleanerKit/RustRemovalGuard.swift` (checks before removal).

## What the category shows

For each Cargo target, the category shows a tree:

```
my-project                      (target folder)
  Debug and tests (release is kept)
    deps
    incremental
    build
    .fingerprint
    examples
    Kept: my-app                (finished binary, not selectable)
  Profile release
    ...
  Profile aarch64-apple-darwin/debug
    ...
```

- A **profile** is a folder that contains both `.cargo-lock` and `.fingerprint`. This covers `debug`, `release`, custom profiles and per-target-triple folders (searched up to two levels below `target`).
- Inside a profile, only the generated components `deps`, `incremental`, `build`, `.fingerprint` and `examples` can be selected. They are `regenerable` and move to the Trash.
- Everything else in a profile (finished binaries, `.app` bundles, other files) is shown as "Kept: name", as user data that cannot be selected. Selecting a profile group therefore selects only its generated components.
- Selecting **Debug and tests (release is kept)** clears what the next `cargo build` or `cargo test` recreates, without touching the release profile.
- A target without any recognized profile is shown as "Unrecognized target layout" with Caution and no action.

## Discovery

`RustDiscovery` walks the configured project folders (up to 16 levels, no symlinks, no volume crossing) looking for `Cargo.toml`. It skips `.git`, `node_modules`, `.venv`, `venv`, `.build`, `target`, `vendor`, `Pods` and hidden folders, except `.claude`, `.codex` and `.worktrees`, so agent worktrees inside a project are found too.

For each manifest it considers these target folders:

- the standard `target` next to `Cargo.toml`;
- `build.target-dir` and `build.build-dir` from Cargo configuration: `$CARGO_HOME/config(.toml)` (default `~/.cargo`) and `.cargo/config(.toml)` in the manifest's folder and every ancestor. Relative values are resolved against the folder that contains `.cargo`;
- absolute paths from `CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET_DIR` and `CARGO_BUILD_BUILD_DIR` in GRUZ's own environment.

Configuration values are accepted only as literal TOML strings. Values with `~`, `$`, `{` (templates or variables) or other TOML forms are ignored rather than guessed. A target folder that is a symlink, or lies behind one, is skipped. Cargo is never run: no metadata command, no build script, no network.

An app launched from Finder does not inherit the environment of a terminal, so `CARGO_TARGET_DIR` set in a shell profile is not visible to it. Shared or templated target folders need manual review.

`target` folders that sit next to `pom.xml` are Maven output and are handled by a separate artifact rule, not by this feature.

## Measurement

Each component is measured with `lstat` metadata only. File contents are never read or hashed. The measurement records:

- allocated size, counting each `(device, inode)` once;
- the newest modification time;
- the size of files created since the start of yesterday (local time), used by the growth view;
- a signature: a SHA-256 over the path, inode, mode, size, blocks, link count and timestamps of every entry, used to detect changes before removal.

A component gets no action, and shows the reason in its note, when the walk finds:

- a symlink, a special file or an unreadable entry;
- an entry on another volume;
- `.git`, `Cargo.toml`, `Cargo.lock`, `config.json` or `session.json`;
- a file or folder with the extension `.app`, `.db`, `.sqlite`, `.sqlite3` or `.sql`.

Generated build output never contains these, so finding one means the folder is not what it looks like.

When the scan finds components it could not make removable, it adds a warning that the target needs manual review.

## Checks before removal

Rust items go through the regular safety model (review sheet, denylist, Trash by default, extra confirmation for permanent deletion). `SystemRustRemovalGuard` adds these checks, both when the review sheet computes blockers and again immediately before the operation:

1. The operation removes exactly the scanned component, which is still a direct child of its profile, inside its target, with its `Cargo.toml` still present and no symlink on the path.
2. GRUZ opens the profile's existing `.cargo-lock` (without following links, without creating it) and takes an exclusive, non-blocking `flock`, the same lock Cargo takes while building. If Cargo holds it, removal is refused. The lock is held until the operation finishes, so a build cannot start in the middle of it. The lock file itself is never removed.
3. No `cargo`, `rustc`, `rust-analyzer`, `sccache`, `lldb` or `gdb` process may be running, anywhere on the system. This is intentionally conservative.
4. No running process may have its executable inside the profile (a test binary or a debug build of the app).
5. The component is measured again; any problem or a different signature means it changed since the scan and needs a new scan.
6. The lock file must still be the same inode GRUZ holds, so a replaced profile folder is detected.

Any failure skips the operation with the reason in the result and the operation log.

## Limitations

- **Trash does not free space** until the Trash is emptied, because it is on the same volume. Permanent deletion stays a separate, explicitly confirmed choice.
- **Sizes are estimates.** Hard links between components of the same profile are counted in each component, and APFS clones share blocks, so the sum of selected components can be larger than what removal frees.
- Permanently deleting one component can change hard link counts in another, which then fails the signature check until the next scan.
- After `.fingerprint` alone is removed, the profile is no longer recognized and stays blocked until Cargo builds it again.
- Advanced TOML, configuration templates and `--config` overrides are not interpreted.
- The process check cannot prevent a build that starts between the check and the removal; the held `.cargo-lock` covers that window for Cargo itself.

## What grew

The **What grew** toggle works in every category; [What grew](what-grew.md) describes it in full. For Rust it has one extra fallback: when a component has no comparable baseline yet, it is still shown if it contains files created since the start of yesterday, with their size. That is not net growth: files may have been rewritten, moved or deleted in between, and creation times say nothing about removed data.

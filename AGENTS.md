# Agent guide

Instructions for AI coding agents working on GRUZ. Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md).

GRUZ is a native macOS app (SwiftUI, Swift 6.2, SwiftPM) that finds reclaimable disk space (caches, build artifacts, Docker data, leftovers of removed apps) and explains every item. The user decides what to remove; the app shows, explains and, only after explicit confirmation, removes.

## Hard rule: the agent never deletes anything

- Never delete, move, trash, truncate or overwrite any file or folder outside this repository. No exceptions for tests, demos or "just checking".
- Never run commands that remove or prune data: `rm` outside the repo, `docker image/volume/container rm`, `docker * prune`, `docker builder prune`, `xcrun simctl delete/erase`, `brew cleanup`, `uv cache clean`, `npm cache clean`, `dotnet nuget locals --clear`, emptying the Trash, and similar.
- Never trigger cleaning in the built app. Launching it to scan and browse is fine; confirming a removal is the user's job.
- Disk analysis is read-only: `du`, `df`, `ls`, `find` without `-delete`/`-exec rm`, `docker system df`, `docker * ls/inspect`, `xcrun simctl list`, `mdfind`, `defaults read`.
- Tests of the cleaning path use test doubles (for example a fake `TrashService` that only records calls) on fixtures created by the test inside a temporary folder.

## Layout and commands

| Target | Role |
|---|---|
| `ScannerKit` | Read-only scan. Rule catalog in `Sources/ScannerKit/Rules/*.json`. Must not depend on `CleanerKit`; no `removeItem`, `trashItem` or state-changing processes. |
| `CleanerKit` | The only module that removes data. Revalidates every operation before running it. |
| `GRUZ` | SwiftUI app. |
| `gruz-scan` | Read-only report CLI. Has no `CleanerKit` dependency. |

```bash
swift build && swift test
python3 -m unittest discover -s Tests/ClaudeMemoryReindexTests -v
./scripts/check-localizations.py      # run after touching any user-visible string
./scripts/build-app.sh                # build/GRUZ.app
./scripts/make-icns.sh                # Resources/AppIcon.svg -> Resources/AppIcon.icns (commit both)
swift run gruz-scan [--children] [--json] [--root <folder>]
```

## Architecture rules

- Cleaning requires: user selection in the GUI, a review sheet listing exact paths/commands and the total size, then explicit confirmation. Nothing preselected.
- No CLI, AppleScript, URL scheme or other API may trigger cleaning. Automation may only scan or export a report.
- The default action moves to Trash. Permanent deletion is allowed only when visibly marked on the item and in the review sheet, and it needs an additional confirmation alert.
- Items no rule describes are *Unrecognized* and cannot be removed.
- The hard-coded denylist (home root, `~/Documents`, `~/Desktop`, `.git` folders, `/System`, project roots, ...) wins over any rule.
- Every `command` action must pass `CommandPolicy`; tests check that removable rule paths pass the denylist.
- Docker and OrbStack data is cleaned only through the `docker` CLI. Named volumes hold databases and are always `caution`.
- What the user reviewed must be what gets removed. Docker commands carry `CommandCheck`s (engine identity, image id behind a tag) that the executor repeats before running; commands acting on a folder take it as an explicit argument (`{path}` in rule `argv`).
- `safe`/`regenerable` means everything under the rule's paths comes back. When a tool keeps irreplaceable data in its cache folder (JetBrains Local History, the Hugging Face token), target the disposable subfolders and add the rest to `Denylist.preservedPatterns`.
- Results are honest: a partly done operation is `.partial`, never `.done`; unreadable contents mark an item `isPartiallyMeasured`; an unknown answer (Spotlight error) is never treated as "not installed".
- New locations: add a rule to the right `rules-NN-*.json` (file order is priority on overlapping paths) plus its translation in `Rules/Localizations/pl.json`. See [docs/reference/rules.md](docs/reference/rules.md).

## Language

- Code, identifiers, comments, docs and commit messages: English.
- The UI is localized. English is the development language (keys are the English text); Polish is a complete translation. Library modules use `String(localized: "...", bundle: .scannerKit)` / `.cleanerKit`; the app target uses plain SwiftUI literals (main bundle). Counts need `.stringsdict` plural rules. See [docs/reference/localization.md](docs/reference/localization.md).
- Do not use em or en dashes in any text; use a hyphen, comma, colon or parentheses.

## Known pitfalls

- `List(selection:)` with optional tags did not bind in the sidebar on macOS 26; the sidebar uses `Button` rows.
- Never show live system state (Full Disk Access) from the cached `last-scan.json`; it is checked live on launch, at scan start and when the app becomes active.
- An ad-hoc signature changes on every build, so macOS forgets the Full Disk Access grant. `scripts/build-app.sh` signs with the first "Apple Development" identity (`SIGN_IDENTITY` overrides it).
- `String(cString: &entry.pointee.fts_name)` reads a flexible array member that is not null-terminated in Swift; use `(fts_path as NSString).lastPathComponent`.
- `Category` collides with the Objective-C runtime type; app code writes `ScannerKit.Category`.
- GUI apps do not inherit the shell `PATH`; `ExecutableLocator` searches Homebrew, OrbStack, `~/.local/bin`, nvm and similar locations.
- SwiftPM's generated `Bundle.module` does not search `Contents/Resources`; use `Bundle.scannerKit` / `Bundle.cleanerKit`.
- Sizes: OrbStack's sparse disk image must be measured by allocated blocks (`st_blocks`), not logical size; `uv` clones files into `.venv` on APFS, so `uv cache clean` frees less than the cache size.

## Verifying UI changes

`./scripts/screenshots.sh` builds a debug app and captures every screenshot scenario (`-GRUZScreenshot main|review|projects|growth|settings`) from fictional `DemoScan` data into `docs/images`. In a scenario the model never scans or removes anything. Use it to check UI changes and refresh the docs images; never publish screenshots of a real disk.

For a real scan, build and launch with `./scripts/build-app.sh && open build/GRUZ.app` and take a screenshot of the window with `screencapture -x -o -l <window id>` (window id from `CGWindowListCopyWindowInfo`, owner "GRUZ", layer 0). Scan and browse only; never confirm a removal.

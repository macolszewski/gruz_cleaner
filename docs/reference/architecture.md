# Architecture

GRUZ is a native macOS app that finds disk space that can be reclaimed and explains what each item is. It shows and describes; the user decides what to remove. This principle shapes the module layout, the scan pipeline and every step of the removal path.

## Modules

The project is a single SwiftPM package (`Package.swift`) with four targets.

| Target | Kind | Role |
|---|---|---|
| `ScannerKit` | library | Read-only discovery and measurement. Holds the rule catalog (`Sources/ScannerKit/Rules`), the denylist and the command allow-list. |
| `CleanerKit` | library | The only module that removes data. Depends on `ScannerKit`. |
| `GRUZ` | app | SwiftUI interface: categories, item list, details, review sheet, settings. |
| `gruz-scan` | CLI | Prints a report (text or JSON). Depends on `ScannerKit` only. |

The dependency direction is a safety property, not just tidiness:

- `ScannerKit` must not depend on `CleanerKit`. It contains no `removeItem`, `trashItem` or state-changing process launches. Its process launcher (`Subprocess`) is internal, and `ReadOnlyCommand` runs only commands from the read-only list in `CommandPolicy`.
- `gruz-scan` has no access to `CleanerKit`, so it cannot remove anything even by mistake.
- There is no CLI flag, AppleScript dictionary, URL scheme or other API that can trigger cleaning. Automation can scan or export a report; removal is only reachable through the GUI.

Build and test commands are in the [README](https://github.com/macolszewski/gruz_cleaner#build-from-source). The app bundle is assembled by `scripts/build-app.sh`, which copies the library resource bundles and the app's own `.lproj` folders into `Contents/Resources` (see [localization.md](localization.md)).

## Scan pipeline

`Scanner.scan` (`Sources/ScannerKit/Scanning/Scanner.swift`) runs a fixed sequence of sources. Each source returns `ScanItem` trees: leaves are removable units (a folder, a Docker image, a simulator), groups collect related leaves. Items are passed to the UI as soon as each stage finishes, so results appear progressively.

| Order | Source | What it reports |
|---|---|---|
| 1 (parallel) | `DockerSource` | Unused images, stopped containers, unused volumes and BuildKit cache, read from `docker system df -v --format '{{json .}}'`. Also the Docker VM disk image (OrbStack or Docker Desktop) as an informational item. |
| 1 (parallel) | `SimulatorSource` | Simulator devices from `xcrun simctl list devices --json`, titled by device name and runtime instead of UUID. Devices for a runtime that is no longer installed are `safe`, others `caution`. |
| 2 | `RuleSource` | Known locations from the rule catalog (`rules-*.json`). See [rules.md](rules.md). |
| 3 (parallel) | `ProjectSource` | Regenerable folders inside project folders (`artifacts.json`), plus Rust/Cargo targets (see [rust.md](../guide/rust.md)). |
| 3 (parallel) | `ApplicationsSource` | Installed `.app` bundles in `/Applications` and `~/Applications`. Informational only. |
| 4 | `OrphanSource` | Library folders of apps that are no longer installed (`orphans.json`). |
| 5 | `UnrecognizedSource` | Large folders no rule describes. Informational only. |

### Claim registry and overlap

A location must be reported once, by the most specific source. `ClaimRegistry` (`Sources/ScannerKit/Scanning/ScanContext.swift`) records every path a source has taken.

- Docker and simulators run first and claim their storage (the OrbStack group container, the Docker Desktop container, `~/Library/Developer/CoreSimulator/Devices`), so rules and orphan detection do not report the same bytes as plain folders.
- Rules are resolved sequentially in catalog order: files sorted by name, then array order inside each file. A path that is already claimed, or that lies inside a claimed path, is skipped. A removable rule never takes a folder that contains a more specific, already claimed item. This is why specific rules go into lower-numbered files and catch-alls such as `~/Library/Caches/*` into `rules-90-system.json`.
- Project artifacts, orphans and Rust targets claim what they report.
- Unrecognized items are measured without the claimed subfolders inside them, so they show only the undescribed remainder.

### Sources in more detail

**Project artifacts.** `ProjectSource` walks the configured project folders with `fts`, without following symlinks or crossing volumes, up to 12 levels deep. It skips `.git`, `~/Library` and hidden folders other than artifact names and `.claude`. A folder name alone is not enough: each artifact definition has context conditions (`node_modules` next to `package.json`, `bin`/`obj` next to a `*.csproj`, `.venv` containing `pyvenv.cfg`, `build` next to `pubspec.yaml`, `build.gradle`, `CMakeLists.txt` and similar). Without the context check, a `bin` folder with scripts or a `build` folder with sources would be offered for removal. The walk does not descend into a recognized artifact.

Agent worktrees (`.claude/worktrees/*`) are listed one per worktree with a `git status --porcelain` summary in the item note, because a worktree may hold uncommitted work.

**Project folders.** By default the scan uses whichever of `~/Developer`, `~/workspace`, `~/Projects`, `~/code`, `~/src`, `~/dev`, `~/repos` exist, or `~/Developer` when none does. The list is editable in Settings. The project folders themselves are always protected by the denylist; only artifacts inside them can be removed.

**Orphans.** `OrphanSource` looks for folders named like bundle identifiers in the directories listed in `orphans.json` (`Containers`, `Group Containers`, `Application Support`, `Caches`, `Saved Application State` and others). A folder name is reduced to a bundle identifier by stripping a Team ID prefix (`ABCDE12345.`), a `group.` prefix and suffixes such as `.savedState`. The identifier counts as installed when:

- an app, or a helper, extension, framework or XPC service inside an installed app, has the same identifier;
- one identifier is a dot-separated prefix of the other;
- `aliases` in `orphans.json` maps it to an installed app (needed because, for example, OrbStack's app identifier is `dev.kdrag0n.MacVirt` while its data folder is `dev.orbstack`);
- Spotlight (`mdfind`) finds an app with that identifier outside the usual folders.

Identifiers starting with `com.apple.` and those matching `ignoredIDs` are never reported. Orphans below `minimumSizeMB` are hidden. Every orphan is `caution` and moves to the Trash: matching by identifier is a heuristic, and an app installed in an unusual place could be missed.

**Applications.** Removing an app is a different decision from clearing a cache, so installed apps are listed with their size for information and cannot be selected.

**Unrecognized.** Large folders (100 MB by default, configurable) in `~/Library/Application Support`, `~/Library/Caches`, `~/Library/Containers`, `~/Library/Group Containers`, `~/.cache`, `~/.local/share` and hidden folders in the home folder that no other source claimed. They are `caution` with no action. The list is the main input for new rules.

## Safety model

Removal is designed so that a mistake requires several independent failures.

1. **Read-only scan.** See [Modules](#modules). The scanner cannot change anything.
2. **Hard-coded denylist wins over rules.** `Denylist` (`Sources/ScannerKit/Support/Denylist.swift`) refuses, regardless of any rule:
   - exact protected folders: `/`, `/Applications`, `/Library`, `/Users`, the home folder, `~/Library` and its main subfolders (`Application Support`, `Caches`, `Containers`, `Group Containers`, `Logs`, `Developer`, `Preferences`), `~/.cache`, `~/.config`, `~/.local`, `~/Downloads`, `~/.Trash`, the user temp folder, the common project folder names and the configured project folders;
   - whole subtrees: `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Library/Keychains`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Photos`, `~/.ssh`, `~/.gnupg` and others;
   - any path with a `.git` component;
   - anything outside the allowed roots (the home folder, `/private/var/folders`, `/var/folders` and the Homebrew Android SDK folder);
   - paths whose parent folders are symlinks that resolve into a protected place.

   Removable rule paths that hit the denylist are dropped during the scan, a unit test checks every removable rule path against it, and `CleaningExecutor` checks it again right before running.
3. **Nothing is preselected.** Only leaves with an action, outside `userData` and informational categories, are selectable (`ScanItem.isSelectable`). There is no "clean everything" shortcut. Items hidden by a filter are never acted on, even if they were selected earlier.
4. **Review sheet.** Selecting items does nothing by itself. The review sheet lists every operation with its exact paths or command line, the total size and any blockers, and only its confirm button runs anything. `CleaningExecutor.execute` refuses a plan unless it receives a `CleaningConfirmation` for that exact plan.
5. **Trash by default.** Path actions move items to the Trash with `FileManager.trashItem`, so a mistake can be undone.
6. **Permanent deletion is visible and confirmed twice.** Items whose action is `permanentDelete` or a command (Docker, `xcrun simctl delete`, `uv cache clean` and similar) are marked as permanent in the list and shown in a separate section of the review sheet with the exact command. The user can also switch a Trash item to "Skip Trash" in the review sheet. Running a plan with any permanent operation requires an extra confirmation alert; without it, those operations are skipped.
7. **Owner app must be closed.** Rules with `requiresAppClosed` list `ownerBundleIDs`. If one of these apps is running, the operation is blocked and the review sheet says which app to quit.
8. **Command allow-list.** `CommandPolicy` (`Sources/ScannerKit/Support/CommandPolicy.swift`) is an exhaustive list of argv patterns. Clean commands: `docker image|volume|container rm <name>`, `docker builder prune --force`, `xcrun simctl delete <udid>`, `uv cache clean`, `uv cache prune`, `npm cache clean --force`, `brew cleanup --prune=all`, `dotnet nuget locals all --clear`. Operands may not start with `-`. Rules with other commands fail to load, and the executor refuses them again. Read-only commands have a separate list used by the scanner.
9. **Re-validation before running.** Blockers are computed when the review sheet opens, can be refreshed, and are computed again for every operation just before it runs. A path that no longer exists is reported, not recreated or guessed. Rust artifacts have additional checks ([rust.md](../guide/rust.md)).
10. **Operation log.** Every confirmed operation, including skipped and failed ones, is appended as one JSON line to `~/Library/Logs/GRUZ/operations.log` (time, item, size, action with exact paths or command, status).

After a run, the result sheet shows each operation's status and the measured change in free space on the volume, which is more honest than the sum of estimated sizes.

The cleaning path is never exercised on real data during development. Tests drive `CleaningExecutor` through test doubles of `FileOperations`, `CommandRunning` and the other protocols, on fixtures the test creates in a temporary folder.

## Docker and OrbStack

Docker Desktop and OrbStack keep all images, containers, volumes and Linux machines inside one VM disk image. Deleting that file would destroy everything at once, and deleting files inside it is impossible from macOS. Docker data is therefore cleaned only through the `docker` CLI, one image, container or volume at a time. OrbStack returns freed space to macOS by itself, gradually, after the commands finish.

- The VM disk image is shown as an informational `userData` item, so the user sees where the space is, but it cannot be selected.
- OrbStack's disk image is a sparse file whose nominal size can be several times larger than the data it holds. Sizes are measured in allocated blocks, so the item shows the real usage.
- Unused images are `regenerable` and sized by their unique part; layers shared with other images stay.
- Stopped containers are `caution`: removing one loses changes written to its file system.
- **Named volumes are always `caution`.** They usually hold databases and project files, and "not attached to any container" does not mean "not needed". Anonymous volumes (64 hex characters or the anonymous label) are also `caution` because they may hold test database data.
- BuildKit cache is `safe` and counts only records that are neither in use nor shared, which is closer to what `docker builder prune` can actually free than the total cache size.

If Docker is not running, the scan adds a warning and shows only the disk image.

## Size measurement

`SizeCalculator` walks trees with `fts`, without following symlinks or crossing volumes, and sums allocated blocks (`st_blocks * 512`, what `du` reports) rather than logical sizes. Hard links are counted once per measurement. The numbers are still estimates of what removal frees:

- **APFS clones** share blocks between files. Each clone is counted in full, so removing one may free little. Some tools clone heavily; `uv`, for example, clones files from its cache into virtual environments, so clearing its cache frees less than its measured size.
- **Hard links** are deduplicated within one item, not across items. A file linked from two items is counted in both.
- **Docker** sizes come from Docker's own report and may overlap.
- **The Trash** frees nothing until it is emptied, and the Trash is on the same volume.

The UI labels sizes as estimates, and the result sheet reports the measured change in free space.

## Age filters

The age of an item is the newest modification time of anything inside it (creation time for Docker images, last boot for simulators). Two kinds of thresholds hide recent data:

- A global filter in Settings ("only data older than N days"), off by default.
- Per-rule defaults (`defaultAgeDays` in the catalog), for example 30 days for Claude Code and Codex sessions and 7 days for temporary files. Each can be changed or disabled in Settings.

When both apply, the longer threshold wins. Items without a date are always shown. The "What grew" view ignores age filters ([What grew](../guide/what-grew.md)).

## Full Disk Access

Without Full Disk Access the app cannot read the Trash, Mail, Messages or iPhone backups, so those locations are missing from the scan. The app checks the permission by trying to list a TCC-protected folder (`~/Library/Mail`, `~/Library/Safari`, `~/Library/Messages` or `~/.Trash`).

The check runs live: at launch, before every scan and whenever the app becomes active. The result is never taken from a cached scan, because the cached `last-scan.json` may predate granting the permission. `build-app.sh` signs with a stable development certificate when one is available, since macOS ties the grant to the signature and an ad-hoc signature changes with every build.

## Persistence

- `~/Library/Application Support/GRUZ/last-scan.json`: the last scan, shown at launch while a new scan runs. Cached Rust items from older versions without revalidation data are shown without an action.
- `~/Library/Application Support/GRUZ/usage-history-v1.json`: compact size history for the "What grew" view.
- `~/Library/Logs/GRUZ/operations.log`: the operation log.
- `UserDefaults`: project folders, age filters, the unrecognized size threshold.

## Localization

English is the development language and Polish a complete translation, covering the interface and the rule catalog. See [localization.md](localization.md).

# Rule catalog

Every item GRUZ can explain comes from the rule catalog: JSON files in `Sources/ScannerKit/Rules`, bundled into the app. A rule describes one known location, what it contains, how risky removal is, how the data comes back and what removal does. The catalog is written in English; translations are separate files (see [Translations](#translations)).

The catalog is decoded by `Sources/ScannerKit/Model/Rule.swift`. When this page and that file disagree, the code is right.

## Files and priority

| File | Content |
|---|---|
| `rules-NN-*.json` | Known locations, as an array of rules. |
| `artifacts.json` | Regenerable folders inside project folders, as an array of artifact definitions. |
| `orphans.json` | Where to look for leftovers of uninstalled apps, plus exceptions and aliases. |
| `Localizations/<lang>.json` | Translated texts of rules and artifacts, keyed by id. |

Rule files are loaded in file name order and, inside a file, in array order. On overlapping paths the earlier rule wins: a path that is already claimed, or lies inside a claimed path, is skipped, and a removable rule never takes a folder that contains an already claimed one. The two-digit prefix sets the priority:

| File | Scope |
|---|---|
| `rules-10-packages.json` | Package managers and toolchains |
| `rules-20-xcode.json` | Xcode |
| `rules-30-android.json` | Android SDK and emulators |
| `rules-40-ai.json` | AI tools |
| `rules-50-browsers.json` | Browsers |
| `rules-60-apps.json` | App caches and app data |
| `rules-90-system.json` | System folders and catch-alls |

Put specific rules in lower-numbered files and broad patterns (such as `~/Library/Caches/*`) at the end. Docker storage and simulator devices are claimed by their own sources before any rule runs ([architecture.md](architecture.md#claim-registry-and-overlap)).

## Rule fields

```json
{
  "id": "spotify.cache",
  "category": "apps",
  "app": "Spotify",
  "title": "Spotify playback cache",
  "description": "Song fragments stored for faster playback.",
  "regeneration": "Spotify downloads them again when needed.",
  "safety": "safe",
  "paths": ["~/Library/Caches/com.spotify.client"],
  "action": { "type": "trash" },
  "requiresAppClosed": true,
  "ownerBundleIDs": ["com.spotify.client"]
}
```

| Field | Required | Default | Meaning |
|---|---|---|---|
| `id` | yes | | Unique across all rules and artifacts. Also the key for translations and for per-rule age overrides in Settings. Convention: `tool.what`, lower case. |
| `category` | yes | | Sidebar category, see [Categories](#categories). |
| `app` | no | none | Owner shown next to the title (a product name). |
| `title` | yes | | Short name of the item. |
| `description` | yes | | What the data is and what removal means. |
| `regeneration` | no | none | How the data comes back, if it does. |
| `safety` | yes | | `safe`, `regenerable`, `caution` or `userData`, see [Safety levels](#safety-levels). |
| `kind` | no | `path` | `path` or `versions`, see [Kinds](#kinds). |
| `paths` | yes | | One or more path patterns. Must not be empty. |
| `action` | no | none | What removal does, see [Actions](#actions). Without an action the item is informational. |
| `requiresAppClosed` | no | `false` | Block removal while one of `ownerBundleIDs` is running. |
| `ownerBundleIDs` | no | `[]` | Bundle identifiers of the owning apps. Used by `requiresAppClosed`. |
| `defaultAgeDays` | no | none | Default age threshold: only data older than this is shown. The user can change or disable it in Settings. |
| `childTitle` | no | `name` | How to title the children of a group, see [Child titles](#child-titles). |
| `excludeNames` | no | `[]` | Glob patterns matched against the last path component of each match; matching paths are dropped. |
| `group` | no | `false` | Show matches as a group with one child per path, even when only one path matches. |
| `versionPattern` | for `versions` | none | Regular expression for `kind: versions`. |
| `note` | no | none | Extra remark shown in the details panel. |

### Paths

- `~` expands to the home folder and `$TMPDIR` to the user temp folder (`/var/folders/.../T`).
- Any path component may be a glob (`*`, `?`, `[...]`, as in `fnmatch`). Hidden entries match only patterns that start with a dot.
- Paths are expanded and sorted; each match becomes a child when the rule is grouped.
- Matches with zero allocated size are dropped. A rule with no non-empty match produces no item.
- Removable paths that the [denylist](architecture.md#safety-model) refuses are dropped silently. Informational rules may point at protected folders (for example `~/.Trash`), since they can never be removed.

A rule produces a group when `group` is `true`, when more than one path matches, or when the rule is `kind: versions`. The group itself has no action; its children do.

### Kinds

- `path`: every match of `paths` is an item.
- `versions`: each match of `paths` is a folder of versioned entries. Its children are matched in full against `versionPattern`, which must have a named group `version` and may have a named group `name`. For each `name`, the newest version (dotted numeric comparison) is kept and all older ones are offered. Examples from the catalog:

| Rule | `versionPattern` | Effect |
|---|---|---|
| `playwright.old` | `^(?<name>.+)-(?<version>[0-9]+)$` | Keeps the newest `chromium-*`, `webkit-*`, `ffmpeg-*` each. |
| `nvm.old` | `^v(?<version>[0-9.]+)$` | Keeps the newest Node version. |
| `jetbrains.old-config` | `^(?<name>[A-Za-z]+)(?<version>[0-9]{4}\.[0-9]+)$` | Keeps the newest configuration folder per IDE. |

A `versions` rule selects entries by version number only; it cannot tell which version a project actually uses. Pick the safety level with that in mind.

### Child titles

| `childTitle` | Child title | Use |
|---|---|---|
| `name` | Last path component. | Default. |
| `parentAndName` | `parent / name`. Claude Code project folder names (`-Users-me-x`) are decoded to `~/x`. | Sessions, system images, browser profiles. |
| `derivedData` | Xcode DerivedData folder without its hash suffix (`App-abcd...` -> `App`). | `xcode.deriveddata`. |
| `huggingFace` | Hugging Face cache folder as `org/model` (`models--org--model` -> `org/model`). | Model caches. |

### Categories

| Value | Sidebar title |
|---|---|
| `docker` | Docker and OrbStack |
| `packages` | Package managers |
| `projects` | Projects |
| `rust` | Rust and Cargo |
| `xcode` | Xcode and simulators |
| `android` | Android |
| `ai` | AI tools |
| `apps` | App caches |
| `browsers` | Browsers |
| `system` | System and logs |
| `orphans` | App leftovers |
| `applications` | Applications |
| `unrecognized` | Unrecognized |

`applications` and `unrecognized` are informational: their items are never selectable. `docker`, `projects`, `rust`, `orphans`, `applications` and `unrecognized` are filled by dedicated sources; rules normally use the others.

## Safety levels

| Value | Title | Meaning |
|---|---|---|
| `safe` | Safe | A cache the program recreates by itself. Removal costs at most a download or a slower first start. |
| `regenerable` | Regenerable | Build output or dependencies. Recreating them takes a build, an install or a large download. |
| `caution` | Caution | May hold data that cannot be recreated (databases, sessions, settings). Remove only when you know what it is. |
| `userData` | User data | Not junk. Shown for information only; it cannot have an action and cannot be selected. |

Choose the level by the worst realistic case for a typical user, not the common case. Session transcripts, archives, backups, emulator disks and anything that may hold a database are `caution`.

## Actions

| `action` | Effect | Permanent |
|---|---|---|
| `{ "type": "trash" }` | Moves each path to the Trash. | no |
| `{ "type": "permanentDelete" }` | Removes each path, bypassing the Trash. | yes |
| `{ "type": "command", "argv": [...] }` | Runs an allow-listed command once. | yes |
| absent | Informational item. | |

Prefer `trash`. The user can still switch a Trash item to "Skip Trash" in the review sheet. Use a `command` when the tool has an official cleanup command that does better than removing the folder, for example `uv cache clean` (`uv` keeps its cache consistent) or `docker builder prune --force`. Every `argv` must match `CommandPolicy` exactly; the allowed commands are listed in [architecture.md](architecture.md#safety-model). Adding a new command means changing `CommandPolicy` and its tests, which is a deliberate code review step, not a catalog edit.

Permanent actions are marked on the item and confirmed by an extra alert before they run.

## Owner apps

Set `requiresAppClosed: true` with `ownerBundleIDs` when the app keeps files open or would rewrite a half-removed cache, typical for Electron apps, IDEs, browsers and Xcode. Removal is blocked while any listed app is running, and the review sheet names the app to quit. Find a bundle identifier with:

```bash
mdls -name kMDItemCFBundleIdentifier -r /Applications/Example.app
```

`ownerBundleIDs` without `requiresAppClosed` is informational and is also allowed on `userData` rules.

## Age defaults

`defaultAgeDays` hides recent data by default. The catalog uses it for data that is valuable while fresh: Claude Code and Codex sessions, Claude Code file history, `npx` packages and voice recordings (30 days), and the user temp folder (7 days, since running programs hold files there). The user can change or disable each threshold in Settings; when the global age filter is also on, the longer threshold applies. See [architecture.md](architecture.md#age-filters).

## Validation

`RuleCatalog.load` decodes all files and then `validate()` rejects the whole catalog when:

- two rules or artifacts share an `id`;
- a rule has no `paths`;
- a `userData` rule has an `action`;
- a `versions` rule has no `versionPattern`;
- a `command` action does not match `CommandPolicy`.

Unknown `category`, `safety`, `kind`, `childTitle` or action `type` values fail decoding. The test suite adds:

- `builtInCatalogLoadsAndValidates`: the catalog loads and every command is allow-listed;
- `removableRulesNeverTargetProtectedPaths`: every path of a removable rule, with globs replaced by a sample name, passes the denylist;
- `RuleTranslationTests`: every translation file is complete (see below).

## Artifact definitions (`artifacts.json`)

Artifacts are folders inside the user's project folders that a build or install recreates.

```json
{
  "id": "artifact.node_modules",
  "dirNames": ["node_modules"],
  "siblingsAny": ["package.json"],
  "title": "npm dependencies (node_modules)",
  "description": "Installed JavaScript packages of the project.",
  "regeneration": "npm install (or yarn/pnpm/bun install) in the project folder.",
  "safety": "regenerable"
}
```

| Field | Required | Default | Meaning |
|---|---|---|---|
| `id` | yes | | Unique across rules and artifacts. Convention: `artifact.name`. |
| `dirNames` | yes | | Folder names to look for. |
| `siblingsAny` | no | `[]` | At least one entry next to the folder must match one of these globs. |
| `insideAny` | no | `[]` | At least one entry inside the folder must match one of these globs. |
| `parentName` | no | none | Required name of the parent folder. |
| `title` | yes | | Group title in the Projects category. |
| `description` | yes | | What the folder contains. |
| `regeneration` | no | none | How to recreate it. |
| `safety` | yes | | Safety level. |
| `action` | no | `trash` | Action for each found folder. |
| `childrenAreItems` | no | `false` | The found folder is a container; each subfolder becomes an item (agent worktrees). |
| `gitStatusCheck` | no | `false` | Run `git status --porcelain` on each item and show the result in its note. |

The context conditions are what make a name match trustworthy. `bin` is a .NET build folder only next to a project file; elsewhere it may hold scripts. `build` is build output next to `pubspec.yaml`, `build.gradle` or `CMakeLists.txt`, but may be source code elsewhere. Always add a sibling or inside condition unless the name is unambiguous (`__pycache__`, `.mypy_cache`).

When a folder name matches but no definition's conditions hold, the walk still does not descend into it, unless some definition with that name uses `parentName`. `artifact.rust-target` is special: matching folders are handed to the Rust analysis ([rust.md](../guide/rust.md)).

Artifacts are always shown in the Projects category (Rust targets in Rust and Cargo), one group per definition.

## Orphan configuration (`orphans.json`)

| Field | Meaning |
|---|---|
| `searchDirs` | Library folders searched for folders named after bundle identifiers. |
| `ignoredIDs` | Glob patterns of identifiers that are not apps (updaters, crash reporters, SDKs) and must never be reported. `com.apple.*` is always ignored. |
| `aliases` | Folder identifier -> bundle identifier of the app that owns it, for apps whose data folder is named differently from the app. |
| `minimumSizeMB` | Orphans smaller than this are not shown. |

All four fields are required. When an installed app is reported as an orphan, add an alias; when a helper tool's folder is reported, add it to `ignoredIDs`.

## Translations

Translations are in `Sources/ScannerKit/Rules/Localizations/<lang>.json`, one object keyed by rule or artifact id:

```json
{
  "spotify.cache": {
    "title": "Cache odtwarzanej muzyki Spotify",
    "description": "Fragmenty utworów zapisane do szybszego odtwarzania.",
    "regeneration": "Spotify pobierze je ponownie, gdy będą potrzebne."
  }
}
```

Translatable fields are `app`, `title`, `description`, `regeneration` and `note` for rules, and `title`, `description` and `regeneration` for artifacts. Missing fields keep the English text at runtime. Paths, actions, safety levels and all other fields are never translated.

`RuleTranslationTests` runs for every language in `Localization.supportedLanguages` except English and requires:

- an entry for every rule and artifact id, and no entries for unknown ids;
- a non-empty `title` and `description` in every entry;
- `regeneration` and `note` exactly when the English rule has them;
- no `app` or `note` in artifact entries.

`app` is optional for rules: product names usually stay the same and fall back to English. The tests also check that loading a translation changes no ids, paths, actions or safety levels. See [localization.md](localization.md) for the rest of the localization setup.

## Worked example: adding a rule

Suppose the Unrecognized category shows `~/Library/Caches/dev.zed.Zed` at 1.2 GB. Zed is an editor; the folder is its cache.

1. **Identify the data.** Look inside the folder, read the vendor's documentation and check what happens when the folder is missing. Suppose the cache is rebuilt automatically when missing; then the level is `safe`. Zed may write to the cache while running, so it should be closed first:

   ```bash
   mdls -name kMDItemCFBundleIdentifier -r /Applications/Zed.app   # dev.zed.Zed
   ```

2. **Add the rule** to `Sources/ScannerKit/Rules/rules-60-apps.json`. This file sorts before `rules-90-system.json`, so the new rule claims the folder before the `system.other-caches` catch-all for `~/Library/Caches/*` would:

   ```json
   {
     "id": "zed.cache",
     "category": "apps",
     "app": "Zed",
     "title": "Zed cache",
     "description": "Cached data of the Zed editor.",
     "regeneration": "Zed recreates it when needed.",
     "safety": "safe",
     "paths": ["~/Library/Caches/dev.zed.Zed"],
     "action": { "type": "trash" },
     "requiresAppClosed": true,
     "ownerBundleIDs": ["dev.zed.Zed"]
   }
   ```

3. **Add the Polish translation** to `Sources/ScannerKit/Rules/Localizations/pl.json`. `regeneration` is required because the English rule has it; `app` can be omitted:

   ```json
   "zed.cache": {
     "title": "Cache Zed",
     "description": "Dane podręczne edytora Zed.",
     "regeneration": "Zed odtworzy je, gdy będą potrzebne."
   }
   ```

   Add the same id to every other translation file, if there are more languages.

4. **Run the tests:**

   ```bash
   swift test --filter RuleTests
   swift test --filter RuleTranslationTests
   swift test
   ```

5. **Check the result** on your machine without the GUI. The report is read-only:

   ```bash
   swift run gruz-scan --children | grep -i zed
   ```

   The folder should now appear under App caches, not under Unrecognized.

## Unrecognized items as rule candidates

The Unrecognized category lists large folders in the usual Library and home locations that nothing describes. They are shown with size and path, as `caution`, and cannot be removed. Each one is a candidate for a rule: find out what it is, then add a rule as above. If it is personal data, add a `userData` rule without an action so the folder is described and no longer appears as unrecognized. If it belongs to an app that is no longer installed but was not detected as an orphan, check `orphans.json` (`searchDirs`, `aliases`) instead.

# Contributing to GRUZ

Thanks for helping. GRUZ removes data from people's disks, so every change is held to one standard: **it must never make it easier to delete something the user did not see and confirm.**

## Ground rules

- **Nothing is removed without the user.** Scanning is read-only. Removal needs a selection in the GUI, the review sheet with exact paths, commands and total size, and explicit confirmation. Nothing is preselected.
- **No automation can clean.** The CLI, URL schemes, AppleScript and any future API may scan or export reports, never remove.
- **The denylist wins.** Hard-coded protected paths (`~`, `~/Documents`, `~/Desktop`, `.git` folders, `/System`, project roots, ...) override every rule.
- **Trash by default.** Permanent deletion is allowed only when it is marked on the item and in the review sheet, and it needs an extra confirmation.
- **Unknown means untouchable.** Folders no rule describes appear as *Unrecognized* and cannot be removed.
- `ScannerKit` must stay read-only and must not depend on `CleanerKit`.

## Development setup

Requirements: macOS 15 or later, Xcode 26 (Swift 6.2 or later).

```bash
swift build                         # all targets
swift test                          # Swift Testing
python3 -m unittest discover -s Tests/ClaudeMemoryReindexTests -v
./scripts/check-localizations.py    # every string translated
./scripts/build-app.sh              # build/GRUZ.app
swift run gruz-scan --children   # read-only report of your own disk
```

**Never test removal on real data.** Tests of the cleaning path use test doubles (for example a fake Trash service that only records what it was asked to do) on fixtures the test creates in a temporary folder. When you try the app on your machine, scan and browse freely, but review the confirmation sheet line by line before you confirm anything.

## Adding a location to the rule catalog

Most contributions are new rules: a cache or a tool folder GRUZ should recognize. Rules are JSON files in `Sources/ScannerKit/Rules`; see [docs/reference/rules.md](docs/reference/rules.md) for every field and a worked example. A good rule:

- describes what the folder is, how risky removing it is and how it comes back, in plain words;
- uses the most conservative `safety` level that is true;
- prefers the tool's own clean command (added to `CommandPolicy`) when the tool keeps an index of its files;
- comes with a translation in `Rules/Localizations/pl.json` (ask for help in the PR if you do not speak Polish);
- passes `swift test`, which also checks that removable rule paths cannot reach protected locations.

The *Unrecognized* category in the app is a good source of candidates.

## Localization

English is the development language; Polish is a full translation. Any user-visible string you add needs a Polish entry, and counts need plural rules. `./scripts/check-localizations.py` tells you what is missing. New languages are welcome: see [docs/reference/localization.md](docs/reference/localization.md).

## Code style

- Swift 6 strict concurrency, no warnings.
- Code, identifiers, comments and commit messages in English.
- Comments explain *why*, not *what*. No commented-out code.
- Keep changes focused: one concern per pull request. Mention refactors you noticed instead of mixing them in.
- User-facing copy follows the macOS Human Interface Guidelines: Title Case for buttons and menus, sentence case for labels.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org/): `feat(rules): recognize Bun cache`, `fix(scanner): ...`.
- Describe what changed and how you verified it. For UI changes add a screenshot.
- CI runs the build, all tests, the localization check and the app bundle build.

## Reporting bugs

Open an issue with the macOS version, GRUZ version and steps to reproduce. If GRUZ offered to remove something it should not have, that is a safety bug: please follow [SECURITY.md](SECURITY.md) if it could lead to data loss for others.

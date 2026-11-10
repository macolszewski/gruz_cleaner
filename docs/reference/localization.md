# Localization

GRUZ's development language is English. Polish is a complete translation of the interface and the rule catalog. This page describes how strings are looked up, how to check translations and how to add a language.

## Principles

- Source strings in Swift are English, and they are the localization keys. There are no symbolic keys such as `scan.button.title`.
- `Package.swift` sets `defaultLocalization: "en"`.
- `en.lproj/Localizable.strings` contains only a comment: the English text is the key. English plural rules are in `en.lproj/Localizable.stringsdict`.
- Every other language has a `Localizable.strings` with all keys and a `Localizable.stringsdict` with the same plural keys as English.
- Byte sizes, dates and numbers go through formatters (`ByteCountFormatter`, `Date.FormatStyle`, `.formatted()`), so they follow the user's locale.
- Text that must not be translated (paths, identifiers, product names on their own) is passed as a `String` value or with `Text(verbatim:)`, so the compiler does not extract it as a key.

## Where strings are

Each module that shows text has its own translation files:

| Module | Translation files | Lookup |
|---|---|---|
| `ScannerKit` | `Sources/ScannerKit/Resources/<lang>.lproj/` | `String(localized: "...", bundle: .scannerKit)` |
| `CleanerKit` | `Sources/CleanerKit/Resources/<lang>.lproj/` | `String(localized: "...", bundle: .cleanerKit)` |
| `GRUZ` (app) | `Sources/GRUZ/Resources/<lang>.lproj/` | SwiftUI literals (`Text("Scan")`, `Button("Remove")`, `.help("...")`) and `String(localized: "...")` without `bundle:` |
| Rule catalog | `Sources/ScannerKit/Rules/Localizations/<lang>.json` | `RuleCatalog.load(from:language:)` |

### Library bundles

SwiftPM generates `Bundle.module` for targets with resources. Inside `GRUZ.app` the library resource bundles are placed in `Contents/Resources`, but the generated accessor only searches the app's root folder (where a nested bundle would break code signing) and the absolute build path of the machine that compiled it. In a distributed app neither exists, so `Bundle.module` would fail.

`ScannerKit` and `CleanerKit` therefore define their own accessors, `Bundle.scannerKit` and `Bundle.cleanerKit` (`ResourceBundle.swift` in each module). They look for `GRUZ_ScannerKit.bundle` or `GRUZ_CleanerKit.bundle` in the main bundle's resources and fall back to `Bundle.module` for `swift run` and tests. Every `String(localized:)` in a library must pass the module's bundle; the checker enforces this.

### App strings

SwiftUI resolves string literals in the main bundle. To avoid passing `bundle:` to every `Text`, `Button` and `Toggle`, the app target excludes its `Resources` folder from SwiftPM (`exclude: ["Resources"]` in `Package.swift`), and `scripts/build-app.sh` copies `Sources/GRUZ/Resources/*.lproj` into `GRUZ.app/Contents/Resources`. A consequence: when the app runs as a bare binary through `swift run GRUZ`, there is no main bundle with translations and the interface is English.

### Interpolation and plurals

Interpolated strings become format keys. `String(localized: "\(count) items in \(name)", bundle: .scannerKit)` has the key `%lld items in %@` (`Int` -> `%lld`, `String` -> `%@`, `Double` -> `%lf`). A translation that needs a different word order uses positional specifiers:

```
"%lld items in %@" = "%2$@: %1$lld elementów";
```

Any user-visible count of things uses a `.stringsdict` plural rule rather than "item(s)" phrasing. English needs `one` and `other`; Polish needs `one`, `few`, `many` and `other` (1 plik, 2 pliki, 5 plików, 1,5 pliku).

### Rule catalog

Rules are written in English. `RuleCatalog.load` validates the English catalog, then, when the requested language is not English and `Localizations/<lang>.json` exists, replaces `app`, `title`, `description`, `regeneration` and `note` of rules and `title`, `description` and `regeneration` of artifacts. Absent fields keep English. Paths, actions and safety levels are never translated, and a test checks that loading a translation does not change them. Field requirements and the completeness test are described in [rules.md](rules.md#translations).

## Choosing the language

`Localization.current` (`Sources/ScannerKit/Support/Localization.swift`) is the language the process uses. It is resolved by Foundation from the user's preferred languages, limited to the localizations the main bundle declares in `CFBundleLocalizations` (written by `build-app.sh`). The rule catalog is loaded in the same language, so rule texts and the interface never disagree.

The user can pick the language in two places:

- the Language setting in GRUZ's Settings;
- macOS per-app language: System Settings > General > Language & Region > Applications.

A scan stores already-localized texts (titles, descriptions, notes) in `last-scan.json`. A cached scan made in a different language is discarded at launch instead of being shown in the wrong language; a new scan starts anyway.

`gruz-scan` has no Info.plist declaring localizations, so it falls back to the development language and prints English.

## Checking translations

```bash
./scripts/check-localizations.py
```

The script compiles the package with `-emit-localized-strings`, so the Swift compiler writes every `String(localized:)` and SwiftUI literal key to `.stringsdata` files, and compares those keys with the translation files of each module. It builds into a separate scratch folder (`.build/l10n-check`, or `L10N_SCRATCH`) to force a full compile; `--skip-build` reuses a previous build. A run takes about ten seconds on a warm cache.

It fails on:

- keys used in code but missing from a translation;
- translations whose key no longer appears in code;
- English plural rules (`en.lproj/Localizable.stringsdict`) for keys not used in code, and plural keys that differ between English and another language;
- format specifiers that differ between a key and its translation (positional `%1$` forms are allowed);
- `String(localized:)` calls in `ScannerKit` or `CleanerKit` without the module's `bundle:`;
- two Swift files with the same name (their `.stringsdata` outputs would overwrite each other);
- Polish letters in Swift sources or in English rule files, which indicate untranslated text.

Rule catalog completeness is checked by `RuleTranslationTests` in `swift test`, not by this script.

## Adding a language

The steps below use German (`de`) as an example.

1. **Declare the language** in `Localization.supportedLanguages` (`Sources/ScannerKit/Support/Localization.swift`):

   ```swift
   public static let supportedLanguages = ["en", "pl", "de"]
   ```

   `RuleTranslationTests` picks it up automatically.

2. **Add it to the app bundle** in `scripts/build-app.sh`, inside `CFBundleLocalizations`:

   ```xml
   <string>de</string>
   ```

   Without this, Foundation never selects the language for the app.

3. **Add it to the checker** in `scripts/check-localizations.py`:

   ```python
   LANGUAGES = ["pl", "de"]
   ```

4. **Create the `.lproj` folders** in all three modules, each with `Localizable.strings` (every key) and `Localizable.stringsdict` (the same plural keys as `en.lproj`, with the plural categories German needs):

   ```
   Sources/ScannerKit/Resources/de.lproj/
   Sources/CleanerKit/Resources/de.lproj/
   Sources/GRUZ/Resources/de.lproj/
   ```

   The Polish files are a convenient template for the key list.

5. **Translate the rule catalog** in `Sources/ScannerKit/Rules/Localizations/de.json`, with an entry for every rule and artifact id.

6. **Add the language to the picker** in GRUZ's Settings, so it can be chosen inside the app.

7. **Verify:**

   ```bash
   ./scripts/check-localizations.py
   swift test
   ./scripts/build-app.sh
   ```

   Then switch the language in Settings or in System Settings and check the main window, the review sheet and Settings for truncated or untranslated text.

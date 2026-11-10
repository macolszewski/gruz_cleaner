#!/usr/bin/env python3
"""Checks that every localizable string in the Swift sources has a translation.

The Swift compiler extracts each `String(localized:)` and SwiftUI string literal into
`.stringsdata` files (`-emit-localized-strings`). This script compares those keys with the
`Localizable.strings` and `Localizable.stringsdict` files of every module and fails on:

- keys used in code but missing from a translation,
- translations whose key no longer appears in code,
- format specifiers that differ between a key and its translation,
- `String(localized:)` calls in library modules that do not name the module's bundle,
- non-ASCII Polish letters in Swift sources or English rule files (untranslated text).

Usage: scripts/check-localizations.py [--skip-build]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = Path(os.environ.get("L10N_SCRATCH", ROOT / ".build" / "l10n-check")).resolve()
MODULES = {
    # module name -> bundle expression required in `String(localized:)` calls (None: main bundle)
    "ScannerKit": ".scannerKit",
    "CleanerKit": ".cleanerKit",
    "GRUZ": None,
}
LANGUAGES = ["pl"]
FORMAT_SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]")
POLISH_LETTERS = re.compile(r"[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]")

errors: list[str] = []


def plist(path: Path) -> object:
    """Reads a plist, .strings or .stringsdata file through plutil."""
    output = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)], check=True, capture_output=True
    ).stdout
    return json.loads(output)


def extract_keys(skip_build: bool) -> dict[str, set[str]]:
    with tempfile.TemporaryDirectory() as out:
        if not skip_build:
            # A separate scratch path forces a full compile, so every file emits its strings.
            subprocess.run(
                [
                    "swift", "build", "--scratch-path", str(SCRATCH),
                    "-Xswiftc", "-emit-localized-strings",
                    "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out,
                ],
                cwd=ROOT, check=True, stdout=subprocess.DEVNULL,
            )
        keys: dict[str, set[str]] = {module: set() for module in MODULES}
        for data_file in Path(out).glob("*.stringsdata"):
            data = plist(data_file)
            source = Path(data["source"])
            try:
                module = source.relative_to(ROOT / "Sources").parts[0]
            except ValueError:
                continue  # generated sources (resource accessors)
            if module not in keys:
                continue
            for entry in data["tables"].get("Localizable", []):
                key = entry["key"]
                if re.search(r"[A-Za-z]", FORMAT_SPECIFIER.sub("", key)):
                    keys[module].add(key)
        return keys


def check_unique_source_names() -> None:
    # .stringsdata files are named after the source file, so equal names would overwrite each other.
    seen: dict[str, Path] = {}
    for path in (ROOT / "Sources").rglob("*.swift"):
        if path.name in seen:
            errors.append(f"duplicate source file name breaks string extraction: {path} and {seen[path.name]}")
        seen[path.name] = path


def check_bundles() -> None:
    for module, bundle in MODULES.items():
        if bundle is None:
            continue
        for path in (ROOT / "Sources" / module).rglob("*.swift"):
            text = path.read_text()
            for match in re.finditer(r"String\(localized:", text):
                depth, end = 0, match.start()
                for end in range(match.start(), len(text)):
                    if text[end] == "(":
                        depth += 1
                    elif text[end] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                call = text[match.start():end + 1]
                if f"bundle: {bundle}" not in call:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{path.relative_to(ROOT)}:{line}: String(localized:) must pass bundle: {bundle}")


def check_untranslated_text() -> None:
    files = list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "Sources/ScannerKit/Rules").glob("*.json"))
    for path in files:
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            if POLISH_LETTERS.search(line):
                errors.append(f"{path.relative_to(ROOT)}:{number}: Polish text outside a translation file")


def check_module(module: str, used: set[str]) -> None:
    resources = ROOT / "Sources" / module / "Resources"
    english_plurals = resources / "en.lproj" / "Localizable.stringsdict"
    english_plural_keys = set(plist(english_plurals)) if english_plurals.exists() else set()
    for key in sorted(english_plural_keys - used):
        errors.append(f"{module} en: plural rule for a key not used in code: {key!r}")

    for language in LANGUAGES:
        strings_file = resources / f"{language}.lproj" / "Localizable.strings"
        plurals_file = resources / f"{language}.lproj" / "Localizable.stringsdict"
        strings = plist(strings_file) if strings_file.exists() else {}
        plurals = plist(plurals_file) if plurals_file.exists() else {}
        available = set(strings) | set(plurals)

        for key in sorted(used - available):
            errors.append(f"{module} {language}: missing translation for {key!r}")
        for key in sorted(available - used):
            errors.append(f"{module} {language}: translation for a key not used in code: {key!r}")
        for key in sorted(english_plural_keys ^ set(plurals)):
            errors.append(f"{module} {language}: plural rules differ from en.lproj for {key!r}")
        for key, value in strings.items():
            if sorted(FORMAT_SPECIFIER.findall(key)) != sorted(
                re.sub(r"%\d+\$", "%", spec) for spec in FORMAT_SPECIFIER.findall(value)
            ):
                errors.append(f"{module} {language}: format specifiers differ in {key!r} -> {value!r}")


def main() -> int:
    skip_build = "--skip-build" in sys.argv
    check_unique_source_names()
    check_bundles()
    check_untranslated_text()
    keys = extract_keys(skip_build)
    for module, used in keys.items():
        check_module(module, used)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"\n{len(errors)} localization problem(s).", file=sys.stderr)
        return 1
    total = sum(len(k) for k in keys.values())
    print(f"Localizations complete: {total} strings in {len(keys)} modules, languages: en, {', '.join(LANGUAGES)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

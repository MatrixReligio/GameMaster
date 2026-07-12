#!/usr/bin/env python3
"""CI guard: every String(localized:) key in App/Sources and Sources must exist in
Localizable.xcstrings with translations for all supported languages, and the
catalog must not contain dead keys."""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
LANGS = ["zh-Hans", "zh-Hant", "ja", "ko"]

# `localized: "…"` labels (from String(localized:)), tolerating a wrapped
# `String(` and interleaved comments before the label. \(…) interpolations
# become %@ placeholders, matching what the compiler emits as the key.
PATTERN = re.compile(r'localized:\s*"((?:[^"\\]|\\.)*)"', re.DOTALL)


SCAN_DIRS = ["App/Sources", "Sources"]


def used_keys() -> set[str]:
    keys: set[str] = set()
    for scan in SCAN_DIRS:
      for swift in (ROOT / scan).rglob("*.swift"):
        for match in PATTERN.finditer(swift.read_text(encoding="utf-8")):
            literal = match.group(1)
            key = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "%@", literal)
            key = key.replace('\\"', '"').replace("\\n", "\n")
            keys.add(key)
    return keys


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    catalog_keys = set(catalog["strings"].keys())
    used = used_keys()

    failures = []
    for key in sorted(used - catalog_keys):
        failures.append(f"MISSING from catalog: {key!r}")
    for key in sorted(catalog_keys - used):
        failures.append(f"DEAD key in catalog (not used in App/Sources): {key!r}")
    for key, entry in sorted(catalog["strings"].items()):
        localizations = entry.get("localizations", {})
        for lang in LANGS:
            value = localizations.get(lang, {}).get("stringUnit", {}).get("value")
            if not value:
                failures.append(f"UNTRANSLATED [{lang}]: {key!r}")
            elif value.count("%@") != key.count("%@"):
                failures.append(f"PLACEHOLDER mismatch [{lang}]: {key!r}")

    if failures:
        print("\n".join(failures))
        print(f"\n{len(failures)} localization problem(s).")
        return 1
    print(f"localization OK: {len(catalog_keys)} keys x {len(LANGS)} languages")
    return 0


if __name__ == "__main__":
    sys.exit(main())

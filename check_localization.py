#!/usr/bin/env python3
"""List the strings a localization is missing, using English as the master.

Usage:
    ./check_localization.py            # summary for every language
    ./check_localization.py fr         # what fr.lproj is missing
    ./check_localization.py fr de ja   # several at once
    ./check_localization.py fr --values    # also print the English text
    ./check_localization.py fr --file RenameWords.strings
"""

import argparse
import re
import sys
from pathlib import Path

BUNDLE = (
    Path(__file__).resolve().parent
    / "layout/Library/Application Support/BHT/BHTwitter.bundle"
)

# "KEY" = "value"; with escaped quotes allowed on both sides.
ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
# Comments have to go first, otherwise a /* ... */ containing a pair fools us.
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT = re.compile(r"^\s*//.*$", re.MULTILINE)


def parse(path):
    """Return {key: value} in file order, or None if the file is absent."""
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8-sig")
    text = BLOCK_COMMENT.sub("", LINE_COMMENT.sub("", text))
    return {m.group(1): m.group(2) for m in ENTRY.finditer(text)}


def languages():
    return sorted(
        d.name[: -len(".lproj")] for d in BUNDLE.glob("*.lproj") if d.is_dir()
    )


def report(code, master, filename, show_values):
    strings = parse(BUNDLE / f"{code}.lproj" / filename)
    if strings is None:
        print(f"{code}: no {filename} (all {len(master)} strings missing)")
        return 1

    missing = [k for k in master if k not in strings]
    empty = [k for k in master if k in strings and not strings[k].strip()]
    extra = [k for k in strings if k not in master]

    done = len(master) - len(missing) - len(empty)
    pct = done / len(master) * 100 if master else 100.0
    print(f"\n{code} — {done}/{len(master)} translated ({pct:.1f}%)")

    def dump(title, keys):
        if not keys:
            return
        print(f"  {title} ({len(keys)}):")
        for k in keys:
            if show_values and k in master:
                print(f'    {k} = "{master[k]}"')
            else:
                print(f"    {k}")

    dump("missing", missing)
    dump("empty", empty)
    dump("not in en (stale?)", extra)
    if not (missing or empty or extra):
        print("  complete")
    return len(missing) + len(empty)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("codes", nargs="*", help="language codes, e.g. fr ja zh_CN")
    ap.add_argument("--file", default="Localizable.strings", help="strings file to compare")
    ap.add_argument(
        "--values", action="store_true", help="print the English text for each key"
    )
    args = ap.parse_args()

    master = parse(BUNDLE / "en.lproj" / args.file)
    if not master:
        sys.exit(f"no master strings found at en.lproj/{args.file}")

    codes = args.codes or [c for c in languages() if c != "en"]
    for code in codes:
        if not (BUNDLE / f"{code}.lproj").is_dir():
            print(f"{code}: no {code}.lproj (have: {', '.join(languages())})")
            continue
        report(code, master, args.file, args.values)


if __name__ == "__main__":
    main()

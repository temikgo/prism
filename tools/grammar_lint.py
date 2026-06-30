import os
import re
import sys

import _common

GLOSSARY = os.path.join(_common.ROOT, "client-godot", "glossary.gd")

# A crude plural template the rules generator leaves for _fix_plurals to decline,
# e.g. "ход(ов)", "карт(ы)", "кристалл(ов)". A Cyrillic word glued to a
# parenthesised suffix. If one survives into the printed text (no matching
# _fix_plurals replacement), the player reads "3 ход(ов)".
TEMPLATE = re.compile(r"[А-Яа-яёЁ]+\([А-Яа-яёЁ]+\)")
# An unrendered substitution placeholder. The generator uses bare "N" / %d / %s,
# never braces -- a "{...}" in a user-facing string is a leaked template.
PLACEHOLDER = re.compile(r"\{[^}]*\}")
STRING_LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')


def covered_literals(src):
    """The exact strings _fix_plurals knows how to decline (its .replace args)."""
    block = src
    m = re.search(r"func _fix_plurals\(.*?\n(.*?)\n\treturn s", src, re.S)
    if m:
        block = m.group(1)
    return re.findall(r'\.replace\("((?:[^"\\]|\\.)*)"', block)


def main():
    src = open(GLOSSARY, encoding="utf-8").read()
    covered = covered_literals(src)
    errors = []

    for lit in STRING_LIT.findall(src):
        stripped = lit
        for c in covered:
            stripped = stripped.replace(c, "")
        for m in TEMPLATE.findall(stripped):
            errors.append("glossary.gd: undeclined template '%s' in \"%s\"" % (m, lit))
        for m in PLACEHOLDER.findall(lit):
            errors.append("glossary.gd: unrendered placeholder '%s' in \"%s\"" % (m, lit))

    cards = _common.load_cards()
    for c in cards:
        fields = []
        nm = c.get("name", {}) or {}
        fields += [nm.get("ru", ""), nm.get("en", "")]
        fields.append((c.get("text", {}) or {}).get("ru", ""))
        for f in fields:
            for m in TEMPLATE.findall(f):
                errors.append("%s: template '%s' in flavor/name '%s'" % (c["id"], m, f))
            for m in PLACEHOLDER.findall(f):
                errors.append("%s: placeholder '%s' in flavor/name '%s'" % (c["id"], m, f))

    print("grammar lint: %d declension target(s), %d glossary string(s) scanned"
          % (len(covered), len(STRING_LIT.findall(src))))
    if errors:
        print("GRAMMAR LEAKS (%d):" % len(errors))
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print("OK -- no undeclined templates or unrendered placeholders")


if __name__ == "__main__":
    main()

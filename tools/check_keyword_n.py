import os
import re
import sys

import _common

# A keyword whose glossary description contains the template "N" (e.g. "Резонанс
# N", "+N/+N") MUST carry an `n` on every card that has it. Otherwise the printed
# rules leak a literal "N" and the engine reads keywordN() == 0, silently
# neutering the card (caught live on green_thicket_brute: "Резонанс N", +0/+0).
# The set of N-templated keywords is derived from glossary.gd itself, so adding a
# new numeric keyword needs no edit here.

GLOSSARY = os.path.join(_common.ROOT, "client-godot", "glossary.gd")
STANDALONE_N = re.compile(r"(?<![A-Za-z])N(?![A-Za-z])")


def n_templated_keywords():
    src = open(GLOSSARY, encoding="utf-8").read()
    m = re.search(r"const KW\s*:=\s*\{(.*?)\n\}", src, re.S)
    block = m.group(1) if m else src
    out = set()
    for kid, desc in re.findall(r'"([a-z_]+)"\s*:\s*"((?:[^"\\]|\\.)*)"', block):
        if STANDALONE_N.search(desc):
            out.add(kid)
    return out


def main():
    needs_n = n_templated_keywords()
    cards = _common.load_cards()
    bad = []
    for c in cards:
        for k in c.get("keywords", []):
            if k.get("id") in needs_n and "n" not in k:
                bad.append((c["id"], k.get("id")))

    print("keyword-N lint: %d N-templated keyword(s) %s"
          % (len(needs_n), sorted(needs_n)))
    if bad:
        print("KEYWORDS MISSING n (%d) -- these print a literal 'N' and fire at 0:"
              % len(bad))
        for cid, kid in bad:
            print("  %-34s %s" % (cid, kid))
        sys.exit(1)
    print("OK -- every N-templated keyword carries its n")


if __name__ == "__main__":
    main()

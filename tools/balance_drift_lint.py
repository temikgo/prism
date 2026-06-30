import os
import sys

import _common

sys.path.insert(0, os.path.join(_common.ROOT, "tools"))
import balance  # noqa: E402


# Every coefficient in balance.py must price something real: a keyword/effect
# that at least one card carries, or one the engine actually implements (a
# reserved-but-built mechanic awaiting a card). A coefficient that is neither can
# never fire -- it is phantom drift from an old set draft and only adds noise.
# This gate keeps the KW/EFF tables honest as the set churns.
def engine_src():
    src = ""
    for sub in (("engine", "src"), ("engine", "include", "prism")):
        d = os.path.join(_common.ROOT, *sub)
        for fn in os.listdir(d):
            if fn.endswith((".cpp", ".hpp", ".h")):
                src += open(os.path.join(d, fn), encoding="utf-8").read()
    return src


def main():
    cards = _common.load_cards()
    used_kw, used_eff = set(), set()
    for c in cards:
        for k in c.get("keywords", []):
            used_kw.add(k["id"])
        for e in c.get("effects", []):
            used_eff.add(e["action"])
    src = engine_src()

    def implemented(name):
        return ('"%s"' % name) in src

    phantoms = []
    for kw in balance.KW:
        if kw not in used_kw and not implemented(kw):
            phantoms.append(("keyword", kw))
    for eff in balance.EFF:
        if eff not in used_eff and not implemented(eff):
            phantoms.append(("effect", eff))

    if phantoms:
        print("balance.py drift: coefficient prices nothing real (no card, no engine impl)")
        for kind, name in phantoms:
            print("  %-8s %-16s -- can never fire; drop the coefficient or build the %s" % (kind, name, kind))
        sys.exit(1)
    print("balance drift: OK (%d keyword + %d effect coefficients, all carded or implemented)"
          % (len(balance.KW), len(balance.EFF)))


if __name__ == "__main__":
    main()

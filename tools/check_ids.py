import re
import sys

import _common


def snake(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def expected_id(card):
    cols = card.get("color", [])
    if not cols:
        prefix = "neutral"
    elif len(cols) >= 5:
        prefix = "prismatic"
    else:
        prefix = "_".join(cols)
    return prefix + "_" + snake(card.get("name", {}).get("en", ""))


def main():
    cards = _common.load_cards()
    bad = []
    for c in cards:
        if c["type"] == "hero":
            continue  # heroes use mythic names, not the color+en rule
        en = c.get("name", {}).get("en")
        if not en:
            bad.append((c["id"], "MISSING en-name"))
            continue
        exp = expected_id(c)
        if c["id"] != exp:
            bad.append((c["id"], "should be  " + exp))
    n = len(_common.nonhero(cards))
    if bad:
        print("ID MISMATCHES (%d/%d):" % (len(bad), n))
        for i, m in bad:
            print("  %-34s %s" % (i, m))
        sys.exit(1)
    print("all %d non-hero ids OK (id == colors_+_snake(en))" % n)


if __name__ == "__main__":
    main()

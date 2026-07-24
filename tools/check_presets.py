import collections
import json
import os
import sys

import _common

PRESETS = os.path.join(_common.ROOT, "client-godot", "presets.json")

# Every preset deck must be playable exactly as shipped: each id resolves to a
# real non-hero card, the list is 40 cards with at most 2 copies (DeckRules),
# and the preset's colour tag matches a colour actually present in the deck.
# This is the gate the id-rename cascade lacked: renaming a card in
# cards/sample.json without updating presets.json shipped decks that crashed
# the client on selection.

DECK_SIZE = 40
MAX_COPIES = 2


def main():
    cards = {c["id"]: c for c in _common.load_cards()}
    presets = json.load(open(PRESETS, encoding="utf-8"))
    errors = []

    for p in presets:
        pid = p.get("id", "?")
        ids = p.get("cards", [])
        counts = collections.Counter(ids)

        for cid, n in counts.items():
            c = cards.get(cid)
            if c is None:
                errors.append("%s: unknown card id '%s'" % (pid, cid))
                continue
            if c.get("type") == "hero":
                errors.append("%s: hero card '%s' inside the deck list" % (pid, cid))
            if n > MAX_COPIES:
                errors.append("%s: %d copies of '%s' (max %d)" % (pid, n, cid, MAX_COPIES))

        if len(ids) != DECK_SIZE:
            errors.append("%s: %d cards (must be exactly %d)" % (pid, len(ids), DECK_SIZE))

        tag = p.get("color", "")
        if tag:
            present = set()
            for cid in ids:
                present.update(cards.get(cid, {}).get("color", []))
            for col in tag.split("_"):
                if col not in present:
                    errors.append("%s: colour tag '%s' but no %s card in the deck"
                                  % (pid, tag, col))

    if errors:
        print("presets: %d problem(s) in %s" % (len(errors), os.path.relpath(PRESETS, _common.ROOT)))
        for e in errors:
            print("  " + e)
        sys.exit(1)
    print("presets: OK (%d preset decks, all ids resolve, %d/<=%d legal, colours match)"
          % (len(presets), DECK_SIZE, MAX_COPIES))


if __name__ == "__main__":
    main()

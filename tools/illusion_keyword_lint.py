import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT = os.path.join(ROOT, "cards", "sample.json")

# resonance snapshots a scaling bonus (+N/+N per crystal) at the moment the body
# is summoned. Anything that re-summons the body from base stats throws that
# snapshot away:
#   - haunt/split spawn a fresh ghost/token from the printed body;
#   - violet is the illusion colour -- the body is prime mirage fodder, and a
#     mirage copy spawns fresh, so the accumulated scaling is lost on the copy.
# So a snapshot-scaling keyword wants a body that STICKS, while rebirth/illusion
# want a DISPOSABLE body. Carrying both on one card is dead value (the audit:
# green_violet_amethyst_golem = resonance + haunt in violet).
SNAPSHOT_KW = {"resonance"}
RESUMMON_KW = {"haunt", "split"}
ILLUSION_COLOR = "violet"


def card_kws(card):
    return {k.get("id") for k in card.get("keywords", [])}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    cards = json.load(open(path, encoding="utf-8"))

    errors = []
    checked = 0
    for c in cards:
        if c.get("type") != "creature":
            continue
        kws = card_kws(c)
        snap = kws & SNAPSHOT_KW
        if not snap:
            continue
        checked += 1
        clash = kws & RESUMMON_KW
        if clash:
            errors.append("%s: %s snapshots at summon but %s re-summons a fresh body -> scaling lost"
                          % (c["id"], "/".join(sorted(snap)), "/".join(sorted(clash))))
        elif ILLUSION_COLOR in c.get("color", []):
            errors.append("%s: %s snapshot on a %s (illusion) card -> wasted on the mirage copy"
                          % (c["id"], "/".join(sorted(snap)), ILLUSION_COLOR))

    print("illusion/snapshot lint: %d snapshot-keyword creature(s) checked" % checked)
    if errors:
        print("DEAD-ON-COPY (%d):" % len(errors))
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print("OK -- no snapshot keyword stranded on a rebirth/illusion body")


if __name__ == "__main__":
    main()

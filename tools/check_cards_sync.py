import os
import sys

from _common import ROOT

# Gate: cards/sample.json (engine master) and client-godot/cards.json (client
# copy) must be byte-for-byte identical. The engine loads the first, the client
# the second; a drift silently desyncs rules from what players see. Edit both.

MASTER = os.path.join(ROOT, "cards", "sample.json")
CLIENT = os.path.join(ROOT, "client-godot", "cards.json")


def main():
    with open(MASTER, "rb") as f:
        a = f.read()
    with open(CLIENT, "rb") as f:
        b = f.read()
    if a == b:
        print("cards/sample.json == client-godot/cards.json (%d bytes)" % len(a))
        return
    print("MISMATCH: cards/sample.json and client-godot/cards.json differ")
    print("  master %d bytes, client %d bytes" % (len(a), len(b)))
    print("  edit BOTH in sync (card-data invariant, ARCHITECTURE A1/A8)")
    sys.exit(1)


if __name__ == "__main__":
    main()

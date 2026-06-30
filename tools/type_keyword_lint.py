import sys

import _common

# A keyword that references a card TYPE in its payoff is only as live as that
# type's population. Few spells -> spell-matters keywords are dead (the audit:
# pinpoint/birefringence/echo_beast on a creature-heavy set). Each entry maps a
# keyword to the type it leans on and the minimum share of the (non-hero) set
# that type must reach for the keyword to pull its weight.
TYPE_KEYWORDS = {
    "birefringence": ("spell", 0.25),
    "pinpoint": ("spell", 0.25),
    "echo": ("spell", 0.25),
}


def main():
    cards = _common.load_cards()
    nonhero = _common.nonhero(cards)
    by_type = {}
    for c in nonhero:
        by_type[c.get("type")] = by_type.get(c.get("type"), 0) + 1
    total = len(nonhero)

    carriers = {}
    for c in nonhero:
        for kid in _common.card_kws(c):
            if kid in TYPE_KEYWORDS:
                carriers.setdefault(kid, []).append(c["id"])

    print("type<->keyword lint: %d non-hero cards %s" % (total, by_type))
    errors = []
    for kid, (typ, min_ratio) in TYPE_KEYWORDS.items():
        ids = carriers.get(kid, [])
        if not ids:
            continue
        have = by_type.get(typ, 0)
        ratio = have / total if total else 0.0
        status = "ok" if ratio >= min_ratio else "THIN"
        print("  %-14s leans on %-8s -> %d/%d = %.0f%% (need %.0f%%) [%d carrier(s)] %s"
              % (kid, typ, have, total, ratio * 100, min_ratio * 100, len(ids), status))
        if ratio < min_ratio:
            errors.append("%s needs >=%.0f%% %s cards, set has %.0f%% (carriers: %s)"
                          % (kid, min_ratio * 100, typ, ratio * 100, ", ".join(ids)))

    if errors:
        print("\nTYPE-STARVED KEYWORDS (%d):" % len(errors))
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print("OK -- every type-referencing keyword has enough of its type")


if __name__ == "__main__":
    main()

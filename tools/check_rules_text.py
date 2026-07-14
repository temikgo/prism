import os
import re
import sys

import _common

GLOSSARY = os.path.join(_common.ROOT, "client-godot", "glossary.gd")

# Every card must PRINT what it does. The rules line is generated from the card's
# data (Glossary.KW for keywords, Glossary.EFFECT for effect actions,
# Glossary.TRIGGER for their timing) -- so a keyword/action/trigger the glossary
# has never heard of renders as nothing at all, and the card ships blank. That is
# exactly how the redesign's Bulwark/Reflux/prowess wave and the start_of_turn
# aura (Витраж) reached the client with an empty description. This gate fails the
# build on the blank card, not on the playtester.

# Keywords that never print their own chip: they are folded into an effect's
# timing (delay) or carried as a bespoke printed `rules` string (the pentas).
FOLDED_KW = {"delay", "echo", "mirror", "cleave", "breaker", "vanguard"}


def gd_keys(src, const):
    """The keys of a GDScript `const NAME := { "a": ..., }` dictionary."""
    m = re.search(r"const %s := \{(.*?)\n\}" % const, src, re.S)
    if not m:
        sys.exit("glossary.gd: const %s not found" % const)
    return set(re.findall(r'"(\w+)":', m.group(1)))


def main():
    src = open(GLOSSARY, encoding="utf-8").read()
    kw_texts = gd_keys(src, "KW")
    eff_texts = gd_keys(src, "EFFECT")
    triggers = gd_keys(src, "TRIGGER")

    errors = []
    for c in _common.load_cards():
        cid = c.get("id", "?")
        hero = c.get("type") == "hero"
        prints = []  # what the generated rules line would actually say

        for k in c.get("keywords", []):
            kid = k.get("id", "")
            if kid not in kw_texts:
                errors.append("%s: keyword '%s' has no Glossary.KW entry -- prints nothing" % (cid, kid))
            elif kid not in FOLDED_KW:
                prints.append(kid)

        for e in c.get("effects", []):
            act = e.get("action", "")
            trg = e.get("trigger", "on_play")
            if act not in eff_texts:
                errors.append("%s: effect '%s' has no Glossary.EFFECT sentence -- prints nothing" % (cid, act))
                continue
            if trg not in triggers:
                errors.append("%s: trigger '%s' has no Glossary.TRIGGER label -- the card cannot say WHEN "
                              "'%s' fires" % (cid, trg, act))
                continue
            prints.append(act)

        if hero:
            continue  # a hero prints its passive keyword only; no effects to check
        if not prints and not c.get("rules"):
            errors.append("%s: prints NO rules text at all -- the player cannot tell what it does" % cid)

    if errors:
        print("rules text: %d card(s) would ship with missing rules" % len(errors))
        for e in errors:
            print("  " + e)
        sys.exit(1)
    print("rules text: OK (every card prints its keywords, effects and their timing)")


if __name__ == "__main__":
    main()

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "client-godot", "art")


# Guards the recurring "art looks low-quality in-game" regression: the source art
# is high-res (896x1344) shown small (cards ~110px), so without mipmaps the
# minification aliases into grain. Godot's default texture import leaves
# mipmaps OFF, so every freshly (re)imported art silently loses them. Tokens.art
# samples mipmaps (TEXTURE_FILTER_LINEAR_WITH_MIPMAPS) but only helps if the
# import actually generated them -- this check enforces that, plus that every art
# png carries its .import sidecar (i.e. it was imported at all).
def main():
    if not os.path.isdir(ART):
        print("no art dir at " + ART)
        sys.exit(1)
    pngs = sorted(f for f in os.listdir(ART) if f.endswith(".png"))
    bad = []
    for png in pngs:
        imp = os.path.join(ART, png + ".import")
        if not os.path.exists(imp):
            bad.append((png, "MISSING .import (not imported)"))
            continue
        body = open(imp, encoding="utf-8").read()
        if "mipmaps/generate=true" not in body:
            bad.append((png, "mipmaps/generate is not true (aliases when downscaled)"))
    if bad:
        print("ART IMPORT PROBLEMS (%d/%d):" % (len(bad), len(pngs)))
        for f, m in bad:
            print("  %-40s %s" % (f, m))
        sys.exit(1)
    print("all %d art imports OK (mipmaps on, sidecar present)" % len(pngs))


if __name__ == "__main__":
    main()

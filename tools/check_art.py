import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "client-godot", "art")
THUMB = os.path.join(ROOT, "client-godot", "art_thumb")


def mipmapped(import_path):
    return os.path.exists(import_path) and \
        "mipmaps/generate=true" in open(import_path, encoding="utf-8").read()


# Guards the recurring "art looks low-quality in-game" regression: the source art
# is high-res (896x1344) shown small (cards ~110px), so without mipmaps the
# minification aliases into grain. Godot's default texture import leaves
# mipmaps OFF, so every freshly (re)imported art silently loses them. Tokens.art
# samples mipmaps (TEXTURE_FILTER_LINEAR_WITH_MIPMAPS) but only helps if the
# import actually generated them -- this check enforces that, plus that every art
# png carries its .import sidecar (i.e. it was imported at all).
#
# Also enforces that every art has a deck-builder thumbnail (art_thumb/, also
# mipmapped): a new card without one would make the pool fall back to the heavy
# master art. Fix: `python3 tools/gen_thumbs.py` then re-import.
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
        elif not mipmapped(imp):
            bad.append((png, "mipmaps/generate is not true (aliases when downscaled)"))
        tp = os.path.join(THUMB, png)
        if not os.path.exists(tp):
            bad.append((png, "MISSING thumbnail (run tools/gen_thumbs.py)"))
        elif not os.path.exists(tp + ".import"):
            bad.append((png, "thumbnail not imported"))
        elif not mipmapped(tp + ".import"):
            bad.append((png, "thumbnail mipmaps off (reimport art_thumb)"))
    if bad:
        print("ART IMPORT PROBLEMS (%d/%d):" % (len(bad), len(pngs)))
        for f, m in bad:
            print("  %-40s %s" % (f, m))
        sys.exit(1)
    print("all %d art imports OK (master + thumbnail, mipmaps on)" % len(pngs))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate small art thumbnails for the deck-builder card pool.

Cards are only ever shown ~150-180px, so the 896x1344 masters are ~5x oversized:
loading 85 of them stalls the pool open and eats ~400MB VRAM. These downscaled
copies (Lanczos, kept well above display size, mipmaps enabled at import) look
identical at pool size but are several times cheaper. The board/match keep using
the full-res masters -- only the deck builder reads these.

Run: python3 tools/gen_thumbs.py   ->   client-godot/art_thumb/<id>.png
"""

import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "client-godot", "art")
DST = os.path.join(ROOT, "client-godot", "art_thumb")
WIDTH = 360  # ~2x the largest on-screen size (~176px) -> always minified, crisp

os.makedirs(DST, exist_ok=True)
made = 0
skipped = 0
for fn in sorted(os.listdir(SRC)):
    if not fn.lower().endswith(".png"):
        continue
    src = os.path.join(SRC, fn)
    dst = os.path.join(DST, os.path.splitext(fn)[0] + ".png")
    # Incremental: only (re)generate when the thumbnail is missing or older than
    # its source, so adding a new card regenerates just that one.
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        skipped += 1
        continue
    im = Image.open(src).convert("RGBA")
    h = round(im.height * WIDTH / im.width)
    im.resize((WIDTH, h), Image.LANCZOS).save(dst, "PNG", optimize=True)
    made += 1
print(f"thumbnails ({WIDTH}px): {made} generated, {skipped} up-to-date "
      f"-> {os.path.relpath(DST, ROOT)}")
if made:
    print("note: run the Godot import once so the new thumbnails get mipmaps "
          "(check_art.py enforces this).")

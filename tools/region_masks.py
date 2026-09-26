"""Part masks for recolouring: which pixels of a sprite are skin, hair,
eyes, top, bottoms, shoes (and which to leave alone: outline, whites,
sword).

    python tools/region_masks.py [--only KEY_SUBSTRING] [--seeds 2]

For each master (art_src/mc/v2/<body>_master_64.png) and every animation
key (art_src/mc/v2/anim_keys/**.png) it asks Qwen-Image-Edit to repaint the
sprite as a flat colour-coded segmentation map in the same pose, reads the
colour back at each pixel, and writes art_src/mc/v2/region_masks/<name>.png:
an L image whose value is the region id (REGIONS). Colour alone can't do
this -- the male's trousers share the skin tones and hair shares browns
with the boots and belt -- so the model's understanding of the figure does.

Dark shading inside a part (which the map may paint as outline) inherits
the part of its neighbours; true outline stays 0.
"""
import argparse
import colorsys
import glob
import os
import sys
import urllib.parse

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comfy_gen as cg      # noqa: E402
import qwen_edit as qe      # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V2 = os.path.join(ROOT, "art_src", "mc", "v2")
OUT = os.path.join(V2, "region_masks")

REGIONS = {0: "keep", 1: "skin", 2: "hair", 3: "eyes", 4: "top", 5: "bottoms", 6: "shoes"}
SEG = {  # map colour -> region
    (255, 0, 0): 2, (255, 255, 0): 1, (0, 255, 255): 3, (0, 200, 0): 4,
    (0, 80, 255): 5, (200, 0, 200): 6, (255, 255, 255): 0, (0, 0, 0): 0,
}
PROMPT = ("Recolor this pixel art character into a flat color-coded segmentation map. Keep the exact same "
          "pose, outline, shapes and pixel positions; only change the colors, using flat pure colors with no "
          "shading: hair pure red, skin (face, neck, arms, hands, any bare legs) pure yellow, eyes pure cyan, "
          "shirt pure green, trousers and belt pure blue, boots and shoes pure magenta, sword pure white. "
          "Keep the black outline black. White background.")


def classify(c):
    return min(SEG, key=lambda s: sum((a - b) ** 2 for a, b in zip(c[:3], s)))


def mask_from(sprite, seg):
    """Region id per sprite pixel, from the segmentation render (1024 px)."""
    k = seg.width / sprite.width
    sp, sg = sprite.load(), seg.convert("RGB").load()
    W, H = sprite.size
    reg = {}
    for y in range(H):
        for x in range(W):
            if not sp[x, y][3]:
                continue
            c = sg[int((x + 0.5) * k), int((y + 0.5) * k)]
            reg[(x, y)] = SEG[classify(c)]
    # shading the map painted as outline/white: take the neighbours' part,
    # unless the sprite pixel really is outline-dark or eye/blade white
    for _ in range(3):
        for (x, y), r in list(reg.items()):
            if r:
                continue
            _, l, s = colorsys.rgb_to_hls(*(v / 255 for v in sp[x, y][:3]))
            if l < 0.1 or l > 0.93 or (s < 0.12 and l > 0.5):
                continue
            nb = [reg.get((x + dx, y + dy), 0) for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy]
            nb = [n for n in nb if n]
            if nb:
                reg[(x, y)] = max(set(nb), key=nb.count)
    out = Image.new("L", sprite.size, 0)
    o = out.load()
    for (x, y), r in reg.items():
        o[x, y] = r
    return out, sum(1 for r in reg.values() if r) / max(1, len(reg))


def run_one(path, name, seeds):
    sprite = Image.open(path).convert("RGBA")
    up = cg.upload(qe.prep(path, 1024), "seg_" + name + ".png")
    best = None
    for s in range(1, seeds + 1):
        saved, _ = cg.run(qe.workflow([up], PROMPT, s, "farroad_seg_" + name), os.path.join(OUT, "_raw"))
        seg = Image.open(saved[0])
        mask, cover = mask_from(sprite, seg)
        if best is None or cover > best[1]:
            best = (mask, cover, saved[0])
    best[0].save(os.path.join(OUT, name + ".png"))
    return best[1]


def targets():
    out = []
    for body in ("male", "female"):
        out.append((os.path.join(V2, f"{body}_master_64.png"), f"master_{body}"))
    for p in sorted(glob.glob(os.path.join(V2, "anim_keys", "*", "*.png"))):
        base = os.path.basename(p)[:-4]
        name = base.split("_", 1)[1] if base[:2].isdigit() else base
        out.append((p, name))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--seeds", type=int, default=2)
    ap.add_argument("--redo", action="store_true", help="regenerate masks that already exist")
    a = ap.parse_args()
    os.makedirs(os.path.join(OUT, "_raw"), exist_ok=True)
    for path, name in targets():
        if a.only and a.only not in name:
            continue
        if not a.redo and os.path.exists(os.path.join(OUT, name + ".png")):
            continue
        cover = run_one(path, name, a.seeds)
        print(f"{name}: {cover:.0%} of pixels in a part")


if __name__ == "__main__":
    main()

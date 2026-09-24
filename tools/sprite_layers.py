#!/usr/bin/env python3
"""
Farroad sprite layer splitter (unit art pipeline).

Takes one animation's frames (a folder of numbered PNGs, e.g. a PixelLab
export) and produces what the Godot LayeredCharacter needs:

  body_<n>.png   the frame with the head removed (one per frame)
  face.png       the head's skin + outline, eyes filled in with skin
  eyes.png       the eye pixels only
  hair.png       the hair pixels only
  preview.png    original vs. recombined, side by side, per frame
  manifest.json  canvas size, head origin, per-frame head offsets, stats

The head is cut from the reference frame (frame 0 by default) and tracked
into every other frame by searching for the offset where it matches best.
Face/eyes/hair are split by colour (see classify()). Both steps are
automatic first passes: the tracking stats and preview.png show how well
they worked, and the layers are meant to be touched up by hand.

Usage:
  python tools/sprite_layers.py <frames_dir> <out_dir> [--head-box x0,y0,x1,y1]
      [--ref 0] [--search 8] [--fps 8]

Needs Pillow (pip install pillow).
"""
import argparse
import colorsys
import json
import os
import re
import sys
from collections import deque

from PIL import Image


def load_frames(folder):
    names = [n for n in os.listdir(folder) if n.lower().endswith(".png")]
    names.sort(key=lambda n: int(re.sub(r"\D", "", n) or 0))
    if not names:
        sys.exit("no PNG frames in " + folder)
    return [Image.open(os.path.join(folder, n)).convert("RGBA") for n in names]


def auto_head_box(img):
    """Top of the sprite down to the neck: the narrowest opaque row found
    between 18% and 40% of the sprite's height."""
    x0, y0, x1, y1 = img.split()[3].getbbox()
    h = y1 - y0
    px = img.load()
    best_y, best_w = None, 10 ** 9
    for y in range(y0 + int(h * 0.18), y0 + int(h * 0.40)):
        xs = [x for x in range(x0, x1) if px[x, y][3] > 0]
        w = (max(xs) - min(xs) + 1) if xs else 0
        if 0 < w < best_w:
            best_w, best_y = w, y
    if best_y is None:
        best_y = y0 + int(h * 0.3)
    return (x0, y0, x1, best_y)


def head_mask(img, box):
    px = img.load()
    return [(x, y) for y in range(box[1], box[3]) for x in range(box[0], box[2]) if px[x, y][3] > 0]


def diff(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])


def track(ref, frame, mask, search):
    """Offset (dx, dy) that best matches the reference head in `frame`.
    Score = mean colour difference over the head mask, with missing pixels
    counted as a full mismatch."""
    rp, fp = ref.load(), frame.load()
    W, H = frame.size
    best = (0, 0, 10 ** 9)
    for dy in range(-search, search + 1):
        for dx in range(-search, search + 1):
            total = 0
            for (x, y) in mask:
                X, Y = x + dx, y + dy
                if 0 <= X < W and 0 <= Y < H and fp[X, Y][3] > 0:
                    total += diff(rp[x, y], fp[X, Y])
                else:
                    total += 765
                if total >= best[2] * len(mask):
                    break
            score = total / len(mask)
            if score < best[2]:
                best = (dx, dy, score)
    return best


def hsl(c):
    h, l, s = colorsys.rgb_to_hls(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
    return h * 360.0, s, l


def is_skin(c):
    h, s, l = hsl(c)
    return (5 <= h <= 45) and s >= 0.25 and l >= 0.45


def is_eye_color(c):
    """Iris (blue/green/violet hues) or eye white."""
    h, s, l = hsl(c)
    return (l >= 0.82) or (70 <= h <= 290 and s >= 0.15 and l >= 0.2)


def is_dark(c):
    return hsl(c)[2] < 0.22


def classify(img, mask, box):
    """Label each head pixel 'hair', 'eyes' or 'face'.
    - eyes: iris/white pixels in the face band, plus the dark lash/outline
      pixels directly touching them.
    - hair: non-skin, non-eye pixels connected to the top of the head
      (flood fill from the head's top rows that stops at skin and eyes).
    - face: everything else (skin, ears, mouth, face outline).
    """
    px = img.load()
    in_mask = set(mask)
    skin = {p for p in mask if is_skin(px[p])}
    top = min(y for (_, y) in mask)
    face_rows = [y for (_, y) in skin] or [top]
    fy0, fy1 = min(face_rows), max(face_rows)

    def in_eye_band(p):
        rel = (p[1] - fy0) / max(1, fy1 - fy0)
        return 0.15 <= rel <= 0.65

    eyes = {p for p in mask if p not in skin and in_eye_band(p) and is_eye_color(px[p])}
    # Lashes/eye outline: dark pixels touching an eye pixel (two passes).
    for _ in range(2):
        grow = set()
        for (x, y) in eyes:
            for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1), (x + 1, y - 1), (x - 1, y - 1)):
                if n in in_mask and n not in eyes and n not in skin and is_dark(px[n]) and in_eye_band(n):
                    grow.add(n)
        eyes |= grow

    seeds = [p for p in mask if p[1] <= top + 2 and p not in skin and p not in eyes]
    hair = set(seeds)
    q = deque(seeds)
    while q:
        x, y = q.popleft()
        for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if n in in_mask and n not in hair and n not in skin and n not in eyes:
                hair.add(n)
                q.append(n)
    labels = {}
    for p in mask:
        labels[p] = "eyes" if p in eyes else ("hair" if p in hair else "face")
    return labels


def nearest_skin(px, p, labels, radius=4):
    x, y = p
    for r in range(1, radius + 1):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                n = (x + dx, y + dy)
                if labels.get(n) == "face" and is_skin(px[n]):
                    return px[n]
    return (224, 176, 144, 255)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--head-box", help="x0,y0,x1,y1 in reference-frame pixels (default: auto to the neck)")
    ap.add_argument("--ref", type=int, default=0)
    ap.add_argument("--search", type=int, default=8)
    ap.add_argument("--fps", type=float, default=8)
    a = ap.parse_args()

    frames = load_frames(a.frames_dir)
    ref = frames[a.ref]
    W, H = ref.size
    box = tuple(int(v) for v in a.head_box.split(",")) if a.head_box else auto_head_box(ref)
    mask = head_mask(ref, box)
    labels = classify(ref, mask, box)
    rp = ref.load()
    os.makedirs(a.out_dir, exist_ok=True)

    # Head layers, cropped to the head box (origin stored in the manifest).
    bw, bh = box[2] - box[0], box[3] - box[1]
    layers = {k: Image.new("RGBA", (bw, bh), (0, 0, 0, 0)) for k in ("face", "eyes", "hair")}
    for p, lab in labels.items():
        layers[lab].putpixel((p[0] - box[0], p[1] - box[1]), rp[p])
        if lab == "eyes":
            layers["face"].putpixel((p[0] - box[0], p[1] - box[1]), nearest_skin(rp, p, labels))
    for k, im in layers.items():
        im.save(os.path.join(a.out_dir, k + ".png"))

    offsets, scores, residuals = [], [], []
    for i, f in enumerate(frames):
        dx, dy, score = track(ref, f, mask, a.search)
        offsets.append([dx, dy])
        scores.append(round(score, 1))
        body = f.copy()
        bp, fp = body.load(), f.load()
        # Remove the tracked head silhouette from the body frame.
        for (x, y) in mask:
            X, Y = x + dx, y + dy
            if 0 <= X < W and 0 <= Y < H:
                bp[X, Y] = (0, 0, 0, 0)
        body.save(os.path.join(a.out_dir, "body_%d.png" % i))
        # Recombine and measure how far it drifts from the original frame.
        comp = body.copy()
        for k in ("face", "eyes", "hair"):
            comp.alpha_composite(layers[k], (box[0] + dx, box[1] + dy))
        cp = comp.load()
        changed = sum(1 for y in range(H) for x in range(W)
                      if (cp[x, y][3] > 0) != (fp[x, y][3] > 0) or (fp[x, y][3] > 0 and diff(cp[x, y], fp[x, y]) > 60))
        opaque = sum(1 for y in range(H) for x in range(W) if fp[x, y][3] > 0)
        residuals.append(round(100.0 * changed / max(1, opaque), 1))
        if i == 0:
            sheet = Image.new("RGBA", (W * len(frames), H * 2), (40, 40, 48, 255))
        sheet.alpha_composite(f, (i * W, 0))
        sheet.alpha_composite(comp, (i * W, H))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(os.path.join(a.out_dir, "preview.png"))

    counts = {k: sum(1 for v in labels.values() if v == k) for k in ("face", "eyes", "hair")}
    manifest = {
        "canvas": [W, H], "frames": len(frames), "fps": a.fps,
        "head_origin": [box[0], box[1]], "head_size": [bw, bh],
        "offsets": offsets,
        "layers": ["face", "eyes", "hair"],
        "stats": {"match_score": scores, "recombine_diff_pct": residuals, "head_pixels": counts},
    }
    with open(os.path.join(a.out_dir, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1)
    print("head box", box, "pixels", counts)
    for i in range(len(frames)):
        print("frame %d  offset %+d,%+d  match %.1f  recombined differs on %.1f%% of pixels"
              % (i, offsets[i][0], offsets[i][1], scores[i], residuals[i]))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Farroad art pipeline: turn an AI "pixel art" image into a real sprite.

Stable Diffusion draws pixel art as big soft blocks (e.g. every art pixel
is ~6x6 screen pixels with blurred edges and thousands of colours). This:

  1. detects the block size and grid phase (or use --block),
  2. samples one colour per block (the block's most common colour, ignoring
     its edges) -> a true 1:1 pixel image,
  3. makes the background transparent (flood fill from the border through
     colours close to the corner colour),
  4. reduces to a small shared palette (--colors),
  5. crops to the sprite and optionally drops tiny specks.

Usage:
  python tools/pixelize.py in.png out.png [--block N] [--colors 32]
      [--bg-tolerance 40] [--keep-largest] [--preview preview.png]

Needs Pillow.
"""
import argparse
from collections import Counter, deque

from PIL import Image


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def detect_block(img, lo=3, hi=16):
    """Find the block size k and phase p where strong colour edges line up
    on a k-pixel grid. Returns (k, px, py)."""
    px = img.load()
    W, H = img.size
    xs, ys = Counter(), Counter()
    for y in range(0, H, 2):
        for x in range(1, W):
            a, b = px[x - 1, y], px[x, y]
            if abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > 60:
                xs[x] += 1
    for x in range(0, W, 2):
        for y in range(1, H):
            a, b = px[x, y - 1], px[x, y]
            if abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > 60:
                ys[y] += 1

    def best(counter):
        total = sum(counter.values()) or 1
        out = None
        for k in range(lo, hi + 1):
            for p in range(k):
                hit = sum(v for pos, v in counter.items() if pos % k == p)
                # allow edges one pixel off the grid (anti-aliasing)
                near = sum(v for pos, v in counter.items() if (pos - p) % k in (1, k - 1))
                score = (hit + 0.5 * near) / total - 1.0 / k
                if out is None or score > out[0]:
                    out = (score, k, p)
        return out

    sx, sy = best(xs), best(ys)
    k = sx[1] if sx[0] >= sy[0] else sy[1]
    # re-pick phases for the chosen k
    def phase(counter):
        return max(range(k), key=lambda p: sum(v for pos, v in counter.items() if pos % k == p))
    return k, phase(xs), phase(ys)


def downsample(img, k, ox, oy):
    px = img.load()
    W, H = img.size
    cols, rows = (W - ox) // k, (H - oy) // k
    out = Image.new("RGB", (cols, rows))
    op = out.load()
    m = 1 if k >= 4 else 0   # skip the blurred block border
    for j in range(rows):
        for i in range(cols):
            c = Counter()
            for y in range(oy + j * k + m, oy + (j + 1) * k - m):
                for x in range(ox + i * k + m, ox + (i + 1) * k - m):
                    p = px[x, y]
                    c[(p[0] // 8 * 8, p[1] // 8 * 8, p[2] // 8 * 8)] += 1
            op[i, j] = c.most_common(1)[0][0]
    return out


def remove_background(img, tol):
    """Flood-fill from the border through pixels close to the corner colours."""
    px = img.load()
    W, H = img.size
    corners = [px[0, 0], px[W - 1, 0], px[0, H - 1], px[W - 1, H - 1]]
    bg = Counter(corners).most_common(1)[0][0]

    def close(c):
        return abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2]) <= tol

    seen = set()
    q = deque([(x, y) for x in range(W) for y in (0, H - 1)] + [(x, y) for y in range(H) for x in (0, W - 1)])
    while q:
        p = q.popleft()
        if p in seen:
            continue
        x, y = p
        if not (0 <= x < W and 0 <= y < H) or not close(px[p]):
            continue
        seen.add(p)
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    out = img.convert("RGBA")
    op = out.load()
    for p in seen:
        op[p] = (0, 0, 0, 0)
    return out


def components(img):
    px = img.load()
    W, H = img.size
    seen, comps = set(), []
    for y in range(H):
        for x in range(W):
            if px[x, y][3] and (x, y) not in seen:
                comp, q = [], deque([(x, y)])
                seen.add((x, y))
                while q:
                    cx, cy = q.popleft()
                    comp.append((cx, cy))
                    for n in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                        if 0 <= n[0] < W and 0 <= n[1] < H and n not in seen and px[n][3]:
                            seen.add(n)
                            q.append(n)
                comps.append(comp)
    return comps


def quantize(img, colors):
    alpha = img.split()[3]
    q = img.convert("RGB").quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    out = q.convert("RGBA")
    out.putalpha(alpha)
    return out


def pixelize(src, block=None, colors=32, bg_tol=90, keep_largest=False, min_speck=4):
    img = src.convert("RGB")
    if block:
        k, ox, oy = block, 0, 0
        _, ox, oy = detect_block(img, block, block)
    else:
        k, ox, oy = detect_block(img)
    small = downsample(img, k, ox, oy)
    sprite = remove_background(small, bg_tol)
    comps = components(sprite)
    sp = sprite.load()
    if comps:
        biggest = max(comps, key=len)
        for comp in comps:
            if (keep_largest and comp is not biggest) or len(comp) < min_speck:
                for p in comp:
                    sp[p] = (0, 0, 0, 0)
    sprite = quantize(sprite, colors)
    bbox = sprite.split()[3].getbbox()
    if bbox:
        sprite = sprite.crop(bbox)
    return sprite, k, len(comps)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--block", type=int)
    ap.add_argument("--colors", type=int, default=32)
    ap.add_argument("--bg-tolerance", type=int, default=90)
    ap.add_argument("--keep-largest", action="store_true", help="drop everything but the largest figure")
    ap.add_argument("--preview", help="write a side-by-side preview (source | result x block size)")
    a = ap.parse_args()
    src = Image.open(a.src)
    sprite, k, n = pixelize(src, a.block, a.colors, a.bg_tolerance, a.keep_largest)
    sprite.save(a.dst)
    print("%s: block %dpx -> %dx%d sprite, %d colours, %d figure(s)"
          % (a.dst, k, sprite.width, sprite.height, len(sprite.getcolors(4096) or []) - 1, n))
    if a.preview:
        big = sprite.resize((sprite.width * k, sprite.height * k), Image.NEAREST)
        pv = Image.new("RGBA", (src.width + big.width + 10, max(src.height, big.height)), (40, 40, 48, 255))
        pv.paste(src.convert("RGBA"), (0, 0))
        pv.alpha_composite(big, (src.width + 10, 0))
        pv.save(a.preview)


if __name__ == "__main__":
    main()

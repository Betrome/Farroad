#!/usr/bin/env python3
"""
Farroad art pipeline: make a breathing idle loop from ONE sprite.

Classic pixel-art idle: the legs stay planted while everything above a
"waist" row dips down a pixel or two and comes back up. Every frame uses the
original pixels, so the character never changes between frames, which is
what AI-generated frames struggle with.

Usage:
  python tools/idle_bob.py sprite.png out_dir [--waist 0.55] [--depth 1]
      [--frames 4] [--scale 4]

Writes out_dir/0.png ... (frames on a canvas 'depth' px taller at the
top, so every frame is the same size) and out_dir/preview.gif (scaled up).
--waist is the fraction of the sprite's height (from the top) where the
bob stops; --depth is how many pixels the upper body dips at the bottom
of the breath.
"""
import argparse
import math
import os

from PIL import Image


def bob_frames(sprite, waist_frac=0.55, depth=1, frames=4):
    W, H = sprite.size
    waist = int(H * waist_frac)
    out = []
    for i in range(frames):
        # 0 at the top of the breath, `depth` at the bottom, back again.
        s = round(depth * (1 - math.cos(2 * math.pi * i / frames)) / 2)
        f = Image.new("RGBA", (W, H + depth), (0, 0, 0, 0))
        # legs: unchanged, anchored to the bottom
        legs = sprite.crop((0, waist, W, H))
        f.paste(legs, (0, depth + waist))
        # upper body: shifted down by s, overlapping the waist row
        upper = sprite.crop((0, 0, W, waist))
        f.alpha_composite(upper, (0, depth + s))
        out.append(f)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sprite")
    ap.add_argument("out_dir")
    ap.add_argument("--waist", type=float, default=0.55)
    ap.add_argument("--depth", type=int, default=1)
    ap.add_argument("--frames", type=int, default=4)
    ap.add_argument("--scale", type=int, default=4)
    ap.add_argument("--ms", type=int, default=160, help="ms per frame in the preview gif")
    a = ap.parse_args()
    sprite = Image.open(a.sprite).convert("RGBA")
    frames = bob_frames(sprite, a.waist, a.depth, a.frames)
    os.makedirs(a.out_dir, exist_ok=True)
    for i, f in enumerate(frames):
        f.save(os.path.join(a.out_dir, "%d.png" % i))
    big = []
    for f in frames:
        bg = Image.new("RGBA", f.size, (40, 40, 48, 255))
        bg.alpha_composite(f)
        big.append(bg.convert("RGB").resize((f.width * a.scale, f.height * a.scale), Image.NEAREST))
    big[0].save(os.path.join(a.out_dir, "preview.gif"), save_all=True, append_images=big[1:],
                duration=a.ms, loop=0)
    print("%d frames, %dx%d, waist row %d, depth %dpx -> %s"
          % (len(frames), frames[0].width, frames[0].height, int(sprite.height * a.waist), a.depth, a.out_dir))


if __name__ == "__main__":
    main()

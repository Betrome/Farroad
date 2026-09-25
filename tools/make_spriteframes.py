#!/usr/bin/env python3
"""
Farroad art pipeline: write a Godot SpriteFrames .tres for one unit.

Expects frames already exported into godot-project/sprites/units/<id>/ as
<anim>_<n>.png (all on one shared canvas, feet on the same row), and writes
godot-project/sprites/units/<id>.tres -- the path UnitView.gd looks for, so
the unit switches from its placeholder shape to this art with no code
change.

Metadata UnitView reads (see UnitView._build):
  pixel_scale  draw at this whole-number scale instead of squeezing the art
               into the placeholder square (pixel art must not be resized
               by fractional amounts)
  anchor       the point on the canvas (texture pixels) that sits on the
               unit's ground position: the middle of the feet
  body_size    the character's own width/height on the canvas (for bars and
               the tap area)

Usage:
  python tools/make_spriteframes.py <id> --anim idle:6:loop --anim attack:14
      [--scale 1] [--anchor X,Y] [--body W,H]
(--anim name:fps[:loop]; frame count comes from the files on disk.)
"""
import argparse
import glob
import os
import re

from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..", "godot-project")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("unit_id")
    ap.add_argument("--anim", action="append", required=True)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--anchor")
    ap.add_argument("--body")
    a = ap.parse_args()

    folder = os.path.join(ROOT, "sprites", "units", a.unit_id)
    ext, anims, idx = [], [], 1
    first = None
    for spec in a.anim:
        parts = spec.split(":")
        name, fps, loop = parts[0], float(parts[1]), len(parts) > 2 and parts[2] == "loop"
        files = sorted(glob.glob(os.path.join(folder, name + "_*.png")),
                       key=lambda p: int(re.findall(r"_(\d+)\.png$", p)[0]))
        if not files:
            raise SystemExit("no frames for " + name)
        first = first or files[0]
        frames = []
        for f in files:
            res = "res://sprites/units/%s/%s" % (a.unit_id, os.path.basename(f))
            ext.append('[ext_resource type="Texture2D" path="%s" id="%d"]' % (res, idx))
            frames.append('{"duration": 1.0, "texture": ExtResource("%d")}' % idx)
            idx += 1
        anims.append('{"frames": [%s], "loop": %s, "name": &"%s", "speed": %s}'
                     % (", ".join(frames), "true" if loop else "false", name, fps))

    img = Image.open(first).convert("RGBA")
    bb = img.split()[3].getbbox()
    anchor = [float(v) for v in a.anchor.split(",")] if a.anchor else [(bb[0] + bb[2]) / 2.0, float(bb[3])]
    body = [float(v) for v in a.body.split(",")] if a.body else [float(bb[2] - bb[0]), float(bb[3] - bb[1])]

    lines = ['[gd_resource type="SpriteFrames" load_steps=%d format=3]' % (len(ext) + 1), ""]
    lines += ext
    lines += ["", "[resource]",
              "animations = [%s]" % ", ".join(anims),
              "metadata/pixel_scale = %s" % a.scale,
              "metadata/anchor = Vector2(%s, %s)" % tuple(anchor),
              "metadata/body_size = Vector2(%s, %s)" % tuple(body), ""]
    out = os.path.join(ROOT, "sprites", "units", a.unit_id + ".tres")
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    print("wrote %s: %d frames, anchor %s, body %s" % (out, len(ext), anchor, body))


if __name__ == "__main__":
    main()

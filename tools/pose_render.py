#!/usr/bin/env python3
"""
Farroad art pipeline: draw OpenPose skeleton images for ControlNet.

Keypoints use the OpenPose COCO-18 order (x, y, confidence triples):
  0 nose, 1 neck, 2 R-shoulder, 3 R-elbow, 4 R-wrist, 5 L-shoulder,
  6 L-elbow, 7 L-wrist, 8 R-hip, 9 R-knee, 10 R-ankle, 11 L-hip,
  12 L-knee, 13 L-ankle, 14 R-eye, 15 L-eye, 16 R-ear, 17 L-ear
("R"/"L" are the character's own right/left). Colours and limb order match
the standard OpenPose/controlnet_aux drawing, which is what the SD 1.5
OpenPose ControlNet was trained on.

As a library: render(keypoints, width, height) -> PIL image.
From the command line: python tools/pose_render.py pose.json out.png
(pose.json = DWPreprocessor's openpose_json output).
"""
import json
import math
import sys

from PIL import Image, ImageDraw

LIMBS = [(1, 2), (1, 5), (2, 3), (3, 4), (5, 6), (6, 7), (1, 8), (8, 9), (9, 10),
         (1, 11), (11, 12), (12, 13), (1, 0), (0, 14), (14, 16), (0, 15), (15, 17)]
COLORS = [(255, 0, 0), (255, 85, 0), (255, 170, 0), (255, 255, 0), (170, 255, 0), (85, 255, 0),
          (0, 255, 0), (0, 255, 85), (0, 255, 170), (0, 255, 255), (0, 170, 255), (0, 85, 255),
          (0, 0, 255), (85, 0, 255), (170, 0, 255), (255, 0, 255), (255, 0, 170), (255, 0, 85)]


def render(kp, width, height):
    pts = [(kp[3 * i], kp[3 * i + 1], kp[3 * i + 2]) for i in range(18)]
    img = Image.new("RGB", (width, height), (0, 0, 0))
    d = ImageDraw.Draw(img)
    stick = max(2, round(4 * width / 512))
    for i, (a, b) in enumerate(LIMBS):
        (x1, y1, c1), (x2, y2, c2) = pts[a], pts[b]
        if c1 <= 0 or c2 <= 0:
            continue
        col = tuple(int(v * 0.6) for v in COLORS[i])
        # OpenPose draws each limb as an ellipse along the bone.
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        length = math.hypot(x2 - x1, y2 - y1) / 2
        ang = math.atan2(y2 - y1, x2 - x1)
        poly = []
        for t in range(0, 360, 10):
            r = math.radians(t)
            ex, ey = length * math.cos(r), stick * math.sin(r)
            poly.append((mx + ex * math.cos(ang) - ey * math.sin(ang), my + ex * math.sin(ang) + ey * math.cos(ang)))
        d.polygon(poly, fill=col)
    for i, (x, y, c) in enumerate(pts):
        if c > 0:
            d.ellipse((x - stick, y - stick, x + stick, y + stick), fill=COLORS[i])
    return img


def main():
    data = json.load(open(sys.argv[1]))
    frame = data[0] if isinstance(data, list) else data
    kp = frame["people"][0]["pose_keypoints_2d"]
    img = render(kp, frame["canvas_width"], frame["canvas_height"])
    if "sword" in frame:   # blender_rig.py adds the sword as a grey hilt->tip line
        (a, b) = frame["sword"]
        ImageDraw.Draw(img).line([tuple(a), tuple(b)], fill=(200, 200, 200),
                                 width=max(3, round(6 * frame["canvas_width"] / 512)))
    img.save(sys.argv[2])


if __name__ == "__main__":
    main()

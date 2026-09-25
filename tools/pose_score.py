#!/usr/bin/env python3
"""
Farroad art pipeline: how close are two poses? (COCO-18 keypoints)

Both poses are normalised before comparing: the neck goes to the origin
and everything is divided by the neck -> mid-hip length (one "torso").
Then:
  joint  mean distance over the body joints 0-13 present in both, in torsos
  limb   mean absolute angle difference (degrees) over 12 body segments:
         upper arms, forearms, thighs, shins, neck->nose, neck->mid-hip,
         shoulder line, hip line. The most meaningful number. Segments seen
         end-on (too short in 2D, e.g. the shoulder line in a side view) are
         skipped.
  sword  angle difference (degrees) of the weapon line (hilt -> tip),
         when both poses have one.
Missing points (confidence 0) are skipped; a pose missing its neck or both
hips cannot be normalised.

Facing: sprites face RIGHT. A reference that faces left is mirrored
(x -> width - x) before comparing. Labels are kept: in Farroad keypoint
files "R" means the sword arm / the limbs nearer the camera, whichever
anatomical side that is, so mirroring does not swap them.

Keypoint files: the rig's openpose.json ({"people": [{"pose_keypoints_2d":
[...54 numbers]}], "sword": [[x, y], [x, y]], "canvas_width": W}), a
DWPreprocessor openpose_json (a list of such frames), or a hand-annotated
file in the same format.

Usage:
  python tools/pose_score.py REF.json OTHER.json [--mirror auto|yes|no]
As a library: score(ref, other) -> dict (see load(), face_right()).
"""
import argparse
import json
import math

BODY = range(14)
SEGMENTS = [   # (name, from, to); -1 = mid-hip
    ("r_upper_arm", 2, 3), ("r_forearm", 3, 4), ("l_upper_arm", 5, 6), ("l_forearm", 6, 7),
    ("r_thigh", 8, 9), ("r_shin", 9, 10), ("l_thigh", 11, 12), ("l_shin", 12, 13),
    ("head", 1, 0), ("torso", 1, -1), ("shoulders", 5, 2), ("hips", 11, 8),
]
MIN_LEN = {"limb": 0.08, "shoulders": 0.2, "hips": 0.15}
NAMES = ["nose", "neck", "r_shoulder", "r_elbow", "r_wrist", "l_shoulder", "l_elbow", "l_wrist",
         "r_hip", "r_knee", "r_ankle", "l_hip", "l_knee", "l_ankle", "r_eye", "l_eye", "r_ear", "l_ear"]


class Pose:
    """18 (x, y, confidence) points (image pixels, y down) plus an optional sword line."""

    def __init__(self, pts, sword=None, width=512, height=512):
        self.pts = [tuple(p) for p in pts]
        self.sword = [tuple(s) for s in sword] if sword else None
        self.width, self.height = width, height

    def ok(self, i):
        return self.pts[i][2] > 0

    def xy(self, i):
        if i == -1:
            if not (self.ok(8) and self.ok(11)):
                return self.xy(8) if self.ok(8) else (self.xy(11) if self.ok(11) else None)
            return ((self.pts[8][0] + self.pts[11][0]) / 2, (self.pts[8][1] + self.pts[11][1]) / 2)
        return self.pts[i][:2] if self.ok(i) else None

    def to_json(self):
        kp = []
        for p in self.pts:
            kp += [round(p[0], 1), round(p[1], 1), p[2]]
        d = {"canvas_width": self.width, "canvas_height": self.height, "people": [{"pose_keypoints_2d": kp}]}
        if self.sword:
            d["sword"] = [list(map(lambda v: round(v, 1), s)) for s in self.sword]
        return d


def load(src):
    """A Pose from a path or an already-parsed openpose dict/list."""
    d = json.load(open(src)) if isinstance(src, str) else src
    if isinstance(d, Pose):
        return d
    if isinstance(d, list):
        d = d[0]
    people = d.get("people") or [{}]
    kp = people[0].get("pose_keypoints_2d") or [0] * 54
    W, H = d.get("canvas_width", 512), d.get("canvas_height", 512)
    pts = [(kp[3 * i], kp[3 * i + 1], kp[3 * i + 2]) for i in range(18)]
    if pts and max((p[0] for p in pts if p[2] > 0), default=2) <= 1.0:   # DWPose may give 0-1 coords
        pts = [(x * W, y * H, c) for x, y, c in pts]
    return Pose(pts, d.get("sword"), W, H)


def parse_points(text, width=512, height=512):
    """Hand annotation: 'nose x,y; neck x,y; ...' in COCO order (0-13, then optional
    eyes/ears) with '-' for a missing point, then optional 'sword x,y x,y' (hilt, tip)."""
    parts = [p.strip() for p in text.replace("\n", ";").split(";") if p.strip()]
    pts, sword = [], None
    for p in parts:
        words = p.split()
        if words[0].lower() == "sword":
            sword = [tuple(float(v) for v in w.split(",")) for w in words[1:3]]
            continue
        val = words[-1]
        if val == "-":
            pts.append((0.0, 0.0, 0.0))
        else:
            x, y = (float(v) for v in val.split(","))
            pts.append((x, y, 1.0))
    pts += [(0.0, 0.0, 0.0)] * (18 - len(pts))
    return Pose(pts[:18], sword, width, height)


def facing(pose):
    """+1 if the figure faces right, -1 if left, 0 if unclear (nose vs neck/ears)."""
    votes = 0.0
    if pose.ok(0) and pose.ok(1):
        votes += pose.pts[0][0] - pose.pts[1][0]
    for ear in (16, 17):
        if pose.ok(0) and pose.ok(ear):
            votes += pose.pts[0][0] - pose.pts[ear][0]
    if pose.sword:
        votes += 0.25 * (pose.sword[1][0] - pose.sword[0][0])
    return 1 if votes > 1e-6 else (-1 if votes < -1e-6 else 0)


def mirror(pose):
    W = pose.width
    pts = [((W - x) if c > 0 else 0.0, y, c) for x, y, c in pose.pts]
    sword = [(W - x, y) for x, y in pose.sword] if pose.sword else None
    return Pose(pts, sword, pose.width, pose.height)


def face_right(pose, mode="auto"):
    """(pose facing right, mirrored?)"""
    flip = mode == "yes" or (mode == "auto" and facing(pose) < 0)
    return (mirror(pose) if flip else pose), flip


def normalise(pose):
    """{index: (x, y)} with the neck at the origin, in torso lengths, plus the sword vector."""
    neck, mid = pose.xy(1), pose.xy(-1)
    if neck is None or mid is None:
        raise ValueError("pose needs a neck and a hip to normalise")
    s = math.hypot(mid[0] - neck[0], mid[1] - neck[1]) or 1.0
    out = {i: ((pose.pts[i][0] - neck[0]) / s, (pose.pts[i][1] - neck[1]) / s)
           for i in range(18) if pose.ok(i)}
    out[-1] = ((mid[0] - neck[0]) / s, (mid[1] - neck[1]) / s)
    sw = None
    if pose.sword:
        (a, b) = pose.sword
        sw = (b[0] - a[0], b[1] - a[1])
    return out, sw


def limb_errors(a, b):
    """{segment: angle difference} between two normalise() outputs. A segment that is
    nearly end-on in either pose (shorter than MIN_LEN torsos; the shoulder and hip
    lines of a side view) has no meaningful direction and is skipped."""
    out = {}
    for name, i, j in SEGMENTS:
        if i in a and j in a and i in b and j in b:
            va = (a[j][0] - a[i][0], a[j][1] - a[i][1])
            vb = (b[j][0] - b[i][0], b[j][1] - b[i][1])
            m = MIN_LEN.get(name, MIN_LEN["limb"])
            if math.hypot(*va) > m and math.hypot(*vb) > m:
                out[name] = adiff(angle(va), angle(vb))
    return out


def angle(v):
    return math.degrees(math.atan2(v[1], v[0]))


def adiff(a, b):
    return abs((a - b + 180) % 360 - 180)


ARM_SWAP = [(2, 5), (3, 6), (4, 7)]
LEG_SWAP = [(8, 11), (9, 12), (10, 13)]


def swapped(pose, pairs):
    pts = list(pose.pts)
    for i, j in pairs:
        pts[i], pts[j] = pts[j], pts[i]
    return Pose(pts, pose.sword, pose.width, pose.height)


def fix_sides(ref, other):
    """Detectors often swap left/right limbs on side-on figures. Relabel `other`'s arms
    so the wrist nearer the sword hilt is "R" (else whichever labelling matches `ref`
    better), and its legs by whichever labelling matches `ref` better.
    Returns (pose, [what was swapped])."""
    done = []

    def err(p):
        a, _ = normalise(ref)
        b, _ = normalise(p)
        e = limb_errors(a, b)
        return sum(e.values()) / max(1, len(e))
    if other.sword and other.ok(4) and other.ok(7):
        h = other.sword[0]
        d = lambda i: math.hypot(other.pts[i][0] - h[0], other.pts[i][1] - h[1])  # noqa: E731
        if d(7) < d(4):
            other, _ = swapped(other, ARM_SWAP), done.append("arms")
    elif err(swapped(other, ARM_SWAP)) < err(other):
        other, _ = swapped(other, ARM_SWAP), done.append("arms")
    if err(swapped(other, LEG_SWAP)) < err(other):
        other, _ = swapped(other, LEG_SWAP), done.append("legs")
    return other, done


def score(ref, other, mirror_mode="no", side_swap=False):
    """Compare `other` against `ref` (both Pose/dict/path). mirror_mode applies to ref;
    side_swap relabels other's left/right limbs first (see fix_sides; for detector output)."""
    ref, other = load(ref), load(other)
    ref, flipped = face_right(ref, mirror_mode)
    other, _ = face_right(other, "no")
    swaps = []
    if side_swap:
        other, swaps = fix_sides(ref, other)
    a, sa = normalise(ref)
    b, sb = normalise(other)
    joints = {NAMES[i]: math.hypot(a[i][0] - b[i][0], a[i][1] - b[i][1]) for i in BODY if i in a and i in b}
    limbs = limb_errors(a, b)
    res = {"joint": round(sum(joints.values()) / len(joints), 3) if joints else None,
           "limb": round(sum(limbs.values()) / len(limbs), 1) if limbs else None,
           "sword": round(adiff(angle(sa), angle(sb)), 1) if sa and sb else None,
           "mirrored": flipped, "side_swaps": swaps, "joints": {k: round(v, 3) for k, v in joints.items()},
           "limbs": {k: round(v, 1) for k, v in limbs.items()}}
    worst = sorted(limbs.items(), key=lambda kv: -kv[1])[:3]
    res["worst"] = [k for k, v in worst if v > 15]
    return res


def fmt(res):
    na = lambda v: -1 if v is None else v   # noqa: E731
    s = "joint %.3f  limb %.1f deg" % (na(res["joint"]), na(res["limb"]))
    if res.get("sword") is not None:
        s += "  sword %.1f deg" % res["sword"]
    if res.get("worst"):
        s += "  (worst: %s)" % ", ".join("%s %.0f" % (k, res["limbs"][k]) for k in res["worst"])
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref")
    ap.add_argument("other")
    ap.add_argument("--mirror", default="auto", choices=("auto", "yes", "no"),
                    help="mirror the reference to face right (auto = if it faces left)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    res = score(a.ref, a.other, a.mirror)
    print(json.dumps(res, indent=1) if a.json else ("(ref mirrored) " if res["mirrored"] else "") + fmt(res))


if __name__ == "__main__":
    main()

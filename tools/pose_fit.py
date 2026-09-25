"""
Fit the Farroad rig to a 2D target pose (runs inside Blender).

  blender -b --factory-startup -P tools/pose_fit.py -- TARGET.json OUT_DIR
      [--init POSE.json] [--evals 60000] [--seed 1] [--fit-azimuth -45] [--no-render]

TARGET.json is a COCO-18 keypoint file (see tools/pose_score.py): the
reference's skeleton, "R" = the sword arm / the limbs nearer the camera.
It is mirrored to face right if it faces left ("mirror": "auto"|"yes"|"no").
Optional keys steer the fit:
  "fit": {"set":    {param: value},   # start value (e.g. "aim.pitch": 60)
          "lock":   [param, ...],     # keep these at their start value
          "weights": {"joint": 25, "sword": 0.6, "limb": 1},
          "prior":  {param: [value, weight]},  # soft pull toward a value
          "proportions": "human"|"rig",  # body the target was measured on
          "sword_full": true}   # ask for a full-length (unforeshortened) blade
Params (see PARAMS): hips.x/y/z (offset), rot.x/y/z, spine.x/y/z, head.x/y/z
(rot.y + = hips pitch forward, spine.z - = lean forward, spine.x + = lean
sideways toward the camera, spine.y = twist, rot.z = turn about the vertical),
hand.R.x/y/z, hand.L.x/y/z, elbow.R/L and knee.R/L (pole angle, degrees:
0 = elbows bend back / knees bend forward), foot.R.x/y, foot.L.x/y,
aim.yaw/aim.pitch (sword direction; yaw 0 = straight forward, +90 = the
character's left; pitch + = up).

The fit projects the rig through the real camera and minimises
  limb-angle error + joint * joint error + sword * sword-angle error
  + penalties (feet off the ground, feet not spread along Y, limbs out of
  frame, the off hand hidden behind the torso, the blade across the face)
with a pattern search (coordinate steps that grow on success and shrink
on failure) from a back-projected first guess, then a few perturbed
restarts. Writes OUT_DIR/pose.json (blender_rig.apply_pose format),
fit.json (scores + params) and the guides (depth/shaded/openpose).
A human reference ("proportions": "human", the default) is first retargeted
onto the rig's limb lengths (directions and foreshortening kept), so the
joint term compares like with like; target_rig.json is that skeleton and
fit.json's "score" is measured against it.
--fit-azimuth fits in another camera angle (e.g. 0 = side view, for side-on
references) and still renders the guides from the battle camera.
"""
import json
import math
import os
import random
import sys
import time

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_rig as br  # noqa: E402
import pose_score as ps  # noqa: E402

SIZE = 512
# name, default, step, lo, hi
PARAMS = [
    ("hips.x", 0.0, 0.15, -1.5, 1.5), ("hips.y", 0.0, 0.1, -1.0, 1.0), ("hips.z", 0.0, 0.1, -1.1, 0.3),
    ("rot.x", 0.0, 8, -45, 45), ("rot.y", 0.0, 8, -60, 60), ("rot.z", 0.0, 10, -90, 90),
    ("spine.x", 0.0, 8, -50, 50), ("spine.y", 0.0, 8, -50, 50), ("spine.z", 0.0, 8, -60, 60),
    ("head.x", 0.0, 8, -40, 40), ("head.y", 0.0, 8, -40, 40), ("head.z", 0.0, 8, -40, 40),
    ("hand.R.x", 0.12, 0.2, -3, 3), ("hand.R.y", -0.5, 0.2, -2.5, 2.5), ("hand.R.z", 1.72, 0.2, 0, 5),
    ("hand.L.x", 0.12, 0.2, -3, 3), ("hand.L.y", 0.5, 0.2, -2.5, 2.5), ("hand.L.z", 1.72, 0.2, 0, 5),
    ("elbow.R", 0.0, 30, -400, 400), ("elbow.L", 0.0, 30, -400, 400),
    ("foot.R.x", 0.0, 0.15, -2.5, 2.5), ("foot.R.y", -0.2, 0.1, -2.0, 1.0),
    ("foot.L.x", 0.0, 0.15, -2.5, 2.5), ("foot.L.y", 0.2, 0.1, -1.0, 2.0),
    ("knee.R", 0.0, 20, -75, 75), ("knee.L", 0.0, 20, -75, 75),      # knees bend forward-ish
    ("aim.yaw", 0.0, 15, -200, 200), ("aim.pitch", 0.0, 15, -90, 90),
]
NAMES = [p[0] for p in PARAMS]
IDX = {n: i for i, n in enumerate(NAMES)}
DEFAULT_WEIGHTS = {"limb": 1.0, "joint": 10.0, "sword": 0.6, "feet": 300.0, "spread": 150.0,
                   "frame": 2.0, "hidden": 15.0, "reg": 0.03, "short": 60.0,
                   "clear": 60.0}
# limb lengths as a share of the neck -> mid-hip length, to compare foreshortening
# (how much of each limb's length shows in 2D) between a real person and the chibi rig
TORSO = br.NECK_Z - br.HIP_Z
PROPORTIONS = {
    "human": {"upper_arm": 0.58, "forearm": 0.52, "thigh": 0.83, "shin": 0.83, "sword": 1.8},
    "rig": {"upper_arm": br.UPPER_ARM / TORSO, "forearm": br.FOREARM / TORSO,
            "thigh": (br.HIP_Z - br.KNEE_Z) / TORSO, "shin": (br.KNEE_Z - br.ANKLE_Z) / TORSO,
            "sword": (br.SWORD_LEN + 0.12) / TORSO},
}
LIMB_SEGS = [("upper_arm", 2, 3), ("forearm", 3, 4), ("upper_arm", 5, 6), ("forearm", 6, 7),
             ("thigh", 8, 9), ("shin", 9, 10), ("thigh", 11, 12), ("shin", 12, 13)]


RETARGET = [  # (joint, parent, kind): rebuilt from the neck outward
    (0, 1, None), (2, 1, "shoulder"), (5, 1, "shoulder"), (3, 2, "upper_arm"), (4, 3, "forearm"),
    (6, 5, "upper_arm"), (7, 6, "forearm"), (8, -1, "hip"), (11, -1, "hip"),
    (9, 8, "thigh"), (10, 9, "shin"), (12, 11, "thigh"), (13, 12, "shin"),
    (14, 0, None), (15, 0, None), (16, 0, None), (17, 0, None)]
WIDTHS = {"human": {"shoulder": 0.36, "hip": 0.19},
          "rig": {"shoulder": br.SHOULDER_X / TORSO, "hip": br.HIP_X / TORSO}}


def retarget(norm, sword, frm="human", to="rig"):
    """Move a normalised skeleton onto another body's proportions: every segment keeps
    its 2D direction and the share of its length that shows, but gets the new body's
    limb lengths (so joint positions become comparable with the chibi rig)."""
    if frm == to:
        return norm, sword
    pf, pt = dict(PROPORTIONS[frm], **WIDTHS[frm]), dict(PROPORTIONS[to], **WIDTHS[to])
    out = {1: norm[1], -1: norm[-1]}
    for j, i, kind in RETARGET:
        if j in norm and i in norm and i in out:
            k = pt[kind] / pf[kind] if kind else 1.0
            out[j] = (out[i][0] + (norm[j][0] - norm[i][0]) * k, out[i][1] + (norm[j][1] - norm[i][1]) * k)
    if sword:
        sword = (sword[0] * pt["sword"] / pf["sword"], sword[1] * pt["sword"] / pf["sword"])
    return out, sword


def retarget_pose(pose, frm="human"):
    """A Pose (pixel coords) rebuilt on rig proportions, for scoring and display."""
    if frm == "rig":
        return pose
    norm, _ = ps.normalise(pose)
    neck, mid = pose.xy(1), pose.xy(-1)
    s = math.hypot(mid[0] - neck[0], mid[1] - neck[1]) or 1
    sw = None
    if pose.sword:
        (a, b) = pose.sword
        sw = ((b[0] - a[0]) / s, (b[1] - a[1]) / s)
    rn, rsw = retarget(norm, sw, frm)
    pts = [(neck[0] + rn[i][0] * s, neck[1] + rn[i][1] * s, 1.0) if i in rn else (0.0, 0.0, 0.0) for i in range(18)]
    sword = None
    if rsw and 4 in rn:
        h = (pts[4][0], pts[4][1])
        sword = [h, (h[0] + rsw[0] * s, h[1] + rsw[1] * s)]
    return ps.Pose(pts, sword, pose.width, pose.height)


def shown(norm, props, sword=None):
    """{segment index: share of its true length visible in 2D} (norm = pose_score.normalise output;
    sword = the normalised sword vector, scored as segment "sword")."""
    out = {}
    if sword:
        out["sword"] = min(1.2, math.hypot(*sword) / props["sword"])
    for k, (kind, i, j) in enumerate(LIMB_SEGS):
        if i in norm and j in norm:
            out[k] = min(1.2, math.hypot(norm[j][0] - norm[i][0], norm[j][1] - norm[i][1]) / props[kind])
    return out


# ---------------------------------------------------------------- rig access
class Rig:
    def __init__(self, scene):
        self.scene = scene
        self.rig = bpy.data.objects["rig"]
        self.pb = self.rig.pose.bones
        self.mw = self.rig.matrix_world

    def world(self, bone, tail=False):
        b = self.pb[bone]
        return self.mw @ (b.tail if tail else b.head)

    def set(self, v):
        """Put parameter vector v on the rig (two depsgraph updates)."""
        g = lambda n: v[IDX[n]]  # noqa: E731
        hips = br.ctrl_obj("hips")
        hips.location = br.HIPS_REST + Vector((g("hips.x"), g("hips.y"), g("hips.z")))
        hips.rotation_euler = [math.radians(g("rot." + a)) for a in "xyz"]
        for bn in ("spine", "head"):
            self.pb[bn].rotation_euler = [math.radians(g(bn + "." + a)) for a in "xyz"]
        bpy.context.view_layer.update()
        hands = {}
        for side in ("R", "L"):
            sh = self.world("upper_arm." + side)
            h = Vector((g("hand.%s.x" % side), g("hand.%s.y" % side), g("hand.%s.z" % side)))
            reach = br.REACH * (br.UPPER_ARM + br.FOREARM)
            if (h - sh).length > reach:
                h = sh + (h - sh).normalized() * reach
            hands[side] = h
            br.ctrl_obj("hand." + side).location = h
            br.ctrl_obj("elbow." + side).location = pole(sh, h, g("elbow." + side), Vector((-1, 0, 0)))
            hp = self.world("thigh." + side)
            f = Vector((g("foot.%s.x" % side), g("foot.%s.y" % side), br.ANKLE_Z))
            br.ctrl_obj("foot." + side).location = f
            br.ctrl_obj("knee." + side).location = pole(hp, f, g("knee." + side), Vector((1, 0, 0)))
        yaw, pitch = math.radians(g("aim.yaw")), math.radians(g("aim.pitch"))
        d = Vector((math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)))
        br.ctrl_obj("aim.R").location = hands["R"] + d * 3.0
        shl = self.world("upper_arm.L")
        br.ctrl_obj("aim.L").location = hands["L"] + (hands["L"] - shl).normalized() * 1.5
        bpy.context.view_layer.update()

    def keypoints(self):
        kp, sword = br.project_keypoints(self.scene, SIZE, update=False)
        return ps.Pose([(kp[3 * i], kp[3 * i + 1], 1.0) for i in range(18)], sword, SIZE, SIZE)

    def feet_lift(self):
        return sum(max(0.0, br.ctrl_obj("foot." + s).matrix_world.translation.z - br.ANKLE_Z - 0.01)
                   for s in ("R", "L"))

    def hand_hidden(self, kp):
        """How far the off hand (L) sits inside the torso outline while being behind it."""
        cam = self.scene.camera
        fwd = (cam.matrix_world.to_3x3() @ Vector((0, 0, -1))).normalized()
        hand = self.world("hand.L", tail=True)
        chest = (self.world("spine") + self.world("spine", tail=True)) / 2
        if (hand - chest).dot(fwd) <= 0.1:        # in front of (or level with) the chest
            return 0.0
        quad = [kp.xy(i) for i in (2, 5, 11, 8)]
        return inside(kp.xy(7), quad)


def seg_dist(p, a, b):
    ax, ay = b[0] - a[0], b[1] - a[1]
    L = ax * ax + ay * ay or 1e-9
    t = max(0.0, min(1.0, ((p[0] - a[0]) * ax + (p[1] - a[1]) * ay) / L))
    return math.hypot(p[0] - a[0] - t * ax, p[1] - a[1] - t * ay)


def blade_on_face(norm, sword, clear=0.45):
    """How far (torso lengths) the sword line cuts into a circle around the head in 2D.
    A blade drawn across the face makes Qwen hide it behind the head, cut off from the hands."""
    if not sword or 4 not in norm or 16 not in norm or 17 not in norm:
        return 0.0
    head = ((norm[16][0] + norm[17][0]) / 2, (norm[16][1] + norm[17][1]) / 2)
    hilt = norm[4]
    tip = (hilt[0] + sword[0], hilt[1] + sword[1])
    return max(0.0, clear - seg_dist(head, hilt, tip))


def pole(a, b, ang, base):
    """A pole point 2 units from the a-b midpoint, `ang` degrees around the a->b axis from `base`."""
    axis = (b - a)
    if axis.length < 1e-6:
        axis = Vector((0, 0, -1))
    axis.normalize()
    b0 = base - axis * base.dot(axis)
    if b0.length < 1e-3:
        b0 = Vector((0, 0, 1)) - axis * axis.z
    b0.normalize()
    b1 = axis.cross(b0)
    t = math.radians(ang)
    return (a + b) / 2 + (b0 * math.cos(t) + b1 * math.sin(t)) * 2.0


def inside(p, quad):
    """0 if p is outside the polygon, else its depth inside (pixels, capped)."""
    if p is None or any(q is None for q in quad):
        return 0.0
    n = len(quad)
    sign, dmin = None, 1e9
    for i in range(n):
        (x1, y1), (x2, y2) = quad[i], quad[(i + 1) % n]
        cr = (x2 - x1) * (p[1] - y1) - (y2 - y1) * (p[0] - x1)
        s = cr > 0
        if sign is None:
            sign = s
        elif s != sign:
            return 0.0
        seg = math.hypot(x2 - x1, y2 - y1) or 1
        dmin = min(dmin, abs(cr) / seg)
    return min(dmin, 40.0) / 10.0


# ---------------------------------------------------------------- objective
class Objective:
    def __init__(self, rig, target, weights, priors, proportions="human", sword_full=True):
        self.rig = rig
        self.w = dict(DEFAULT_WEIGHTS, **weights)
        self.priors = priors
        raw, tsw = ps.normalise(target)
        if tsw:   # the sword vector in torso lengths, like the joints
            neck, mid = target.xy(1), target.xy(-1)
            tl = math.hypot(mid[0] - neck[0], mid[1] - neck[1]) or 1
            tsw = (tsw[0] / tl, tsw[1] / tl)
        self.tshown = shown(raw, PROPORTIONS[proportions], tsw)
        if tsw and sword_full:
            # a foreshortened blade reads as a stub on a 60 px sprite (and a reference's
            # blade length is rarely reliable), so always ask for a full-length sword
            self.tshown["sword"] = 0.95
        # joints are compared on the reference rebuilt with the rig's limb lengths
        self.ta, self.tsw = retarget(raw, tsw, proportions, "rig")
        self.n = 0

    def terms(self, v):
        self.rig.set(v)
        self.n += 1
        kp = self.rig.keypoints()
        b, sb = ps.normalise(kp)
        a = self.ta
        limbs = list(ps.limb_errors(a, b).values())
        joints = [math.hypot(a[i][0] - b[i][0], a[i][1] - b[i][1]) for i in ps.BODY if i in a]
        t = {"limb": sum(limbs) / max(1, len(limbs)), "joint": sum(joints) / max(1, len(joints))}
        sbn = None
        if sb:
            neck, mid = kp.xy(1), kp.xy(-1)
            bl = math.hypot(mid[0] - neck[0], mid[1] - neck[1]) or 1
            sbn = (sb[0] / bl, sb[1] / bl)
        bs = shown(b, PROPORTIONS["rig"], sbn)
        diffs = [abs(self.tshown[k] - bs[k]) for k in self.tshown if k in bs]
        t["short"] = sum(diffs) / max(1, len(diffs))
        t["sword"] = ps.adiff(ps.angle(self.tsw), ps.angle(sb)) if self.tsw and sb else 0.0
        t["feet"] = self.rig.feet_lift()
        fy = v[IDX["foot.L.y"]] - v[IDX["foot.R.y"]]
        t["spread"] = max(0.0, 0.3 - fy)
        out = 0.0
        pts = [kp.xy(i) for i in range(14)] + (list(kp.sword) if kp.sword else [])
        for x, y in pts:
            out += max(0, 8 - x) + max(0, x - (SIZE - 8)) + max(0, 8 - y) + max(0, y - (SIZE - 8))
        t["frame"] = out / 10.0
        t["hidden"] = self.rig.hand_hidden(kp)
        t["clear"] = blade_on_face(b, sbn)
        # forward/back leans (rot.y, spine.z) are free; sideways leans, twists and turning
        # the body away from the battle camera cost a little
        reg = abs(v[IDX["rot.x"]]) + abs(v[IDX["spine.x"]]) + abs(v[IDX["spine.y"]]) \
            + 0.5 * abs(v[IDX["rot.z"]]) + 0.5 * sum(abs(v[IDX["head." + a]]) for a in "xyz")
        for name, (val, wt) in self.priors.items():
            reg += wt * abs(v[IDX[name]] - val)
        t["reg"] = reg
        return t, kp

    def __call__(self, v):
        t, _ = self.terms(v)
        return sum(self.w[k] * t[k] for k in t)


# ---------------------------------------------------------------- first guess
def first_guess(rig, target, obj=None):
    """Back-project the target through the camera: feet on the ground plane,
    hands nearest the shoulders, hips in the body's mid plane, poles toward
    the target elbows/knees, aim along the target sword."""
    scene = rig.scene
    v = [p[1] for p in PARAMS]
    rig.set(v)
    rest = rig.keypoints()
    ra, _ = ps.normalise(rest)
    neck_px = rest.xy(1)
    torso_px = math.hypot(rest.xy(-1)[0] - neck_px[0], rest.xy(-1)[1] - neck_px[1])
    ta, tsw = (obj.ta, obj.tsw) if obj is not None else ps.normalise(target)
    cam = scene.camera
    m3 = cam.matrix_world.to_3x3()
    right, up, fwd = m3 @ Vector((1, 0, 0)), m3 @ Vector((0, 1, 0)), m3 @ Vector((0, 0, -1))
    ortho = cam.data.ortho_scale
    # anchor: target mid-hip over the rest mid-hip (x), lowest target ankle on the rest ankle row (y)
    ankles = [i for i in (10, 13) if i in ta]
    low = max(ankles, key=lambda i: ta[i][1]) if ankles else None
    ox = rest.xy(-1)[0] - ta[-1][0] * torso_px
    oy = (rest.xy(10)[1] - ta[low][1] * torso_px) if low is not None else neck_px[1]
    px = {i: (ox + p[0] * torso_px, oy + p[1] * torso_px) for i, p in ta.items()}

    def line(p):
        U, V = (p[0] / SIZE - 0.5) * ortho, (0.5 - p[1] / SIZE) * ortho
        return cam.matrix_world.translation + right * U + up * V, fwd

    def on_plane(p, axis, value):
        o, d = line(p)
        if abs(d[axis]) < 1e-6:
            return None
        return o + d * ((value - o[axis]) / d[axis])

    def nearest(p, q):
        o, d = line(p)
        return o + d * (q - o).dot(d)

    # at 8 degrees of elevation a ground-plane hit is ill-conditioned, so every point is
    # put on a plane of constant Y (the body's side planes) and the height follows from that
    hp = on_plane(px[-1], 1, 0.0)
    feet_z = []
    for side, ank, fy in (("R", 10, -0.3), ("L", 13, 0.3)):
        if ank in px:
            f = on_plane(px[ank], 1, fy)
            if f is not None:
                v[IDX["foot.%s.x" % side]], v[IDX["foot.%s.y" % side]] = f.x, fy
                feet_z.append(f.z)
    if hp is not None:
        ground = min(feet_z) - br.ANKLE_Z if feet_z else 0.0
        v[IDX["hips.x"]] = max(-1.2, min(1.2, hp.x))
        v[IDX["hips.z"]] = max(-1.0, min(0.2, hp.z - ground - br.HIP_Z))
    rig.set(v)
    for side, (ank, wri, elb, kne) in (("R", (10, 4, 3, 9)), ("L", (13, 7, 6, 12))):
        sh = rig.world("upper_arm." + side)
        if wri in px:
            h = on_plane(px[wri], 1, sh.y * 1.1) or nearest(px[wri], sh)
            for a, val in zip("xyz", h):
                v[IDX["hand.%s.%s" % (side, a)]] = val
    if tsw:   # the sword direction nearest "straight forward" that projects onto the target's
        want = math.atan2(tsw[1], tsw[0])
        best = None
        for yaw in range(-180, 181, 5):
            for pitch in range(-85, 86, 5):
                y, p = math.radians(yaw), math.radians(pitch)
                d = Vector((math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)))
                sx, sy = d.dot(right), -d.dot(up)
                if math.hypot(sx, sy) < 0.25:
                    continue
                err = ps.adiff(math.degrees(math.atan2(sy, sx)), math.degrees(want)) + 0.08 * abs(yaw)
                if best is None or err < best[0]:
                    best = (err, yaw, pitch)
        v[IDX["aim.yaw"]], v[IDX["aim.pitch"]] = best[1], best[2]
    if obj is not None:       # elbow/knee bend directions: scan each against the objective
        for _ in range(2):
            for name, rng_ in (("elbow.R", range(-180, 180, 30)), ("elbow.L", range(-180, 180, 30)),
                               ("knee.R", range(-75, 76, 25)), ("knee.L", range(-75, 76, 25))):
                scores = []
                for ang in rng_:
                    v[IDX[name]] = ang
                    scores.append((obj(v), ang))
                v[IDX[name]] = min(scores)[1]
    return v


# ---------------------------------------------------------------- search
def clamp(v):
    return [max(PARAMS[i][3], min(PARAMS[i][4], x)) for i, x in enumerate(v)]


def pattern_search(f, v, free, steps, max_evals, rng, min_step=0.02):
    best = f(v)
    evals = 1
    steps = list(steps)
    while evals < max_evals:
        improved = False
        order = list(free)
        rng.shuffle(order)
        for i in order:
            for sgn in (1, -1):
                w = list(v)
                w[i] += sgn * steps[i]
                w = clamp(w)
                if w[i] == v[i]:
                    continue
                e = f(w)
                evals += 1
                if e < best - 1e-6:
                    v, best, improved = w, e, True
                    steps[i] *= 1.6
                    break
            else:
                steps[i] *= 0.6
        if not improved and all(steps[i] < min_step * PARAMS[i][2] for i in free):
            break
    return v, best, evals


def fit(scene, target, init=None, max_evals=30000, seed=1, spec=None):
    """Multi-start pattern search: short runs from several first guesses
    (crouch depth x torso lean x pole flips), then the best few refined."""
    spec = spec or {}
    rig = Rig(scene)
    rng = random.Random(seed)
    lock = set(spec.get("lock", []))
    free = [i for i, n in enumerate(NAMES) if n not in lock]
    obj = Objective(rig, target, spec.get("weights", {}), {k: tuple(x) for k, x in spec.get("prior", {}).items()},
                    spec.get("proportions", "human"), spec.get("sword_full", True))
    t0 = time.time()
    base = list(init) if init else first_guess(rig, target, obj)
    starts = [base]
    if not init or spec.get("multistart"):
        for dz in (0.0, -0.3, -0.6):
            for lean in (-10, 0, 20):      # + = forward
                for flip in (0, 180):
                    w = list(base)
                    w[IDX["hips.z"]] += dz
                    w[IDX["spine.z"]] = -lean
                    w[IDX["elbow.L"]] += flip
                    starts.append(w)
    runs = []
    for w in starts:
        for k, val in spec.get("set", {}).items():
            w[IDX[k]] = val
        w = clamp(w)
        runs.append((obj(w), w))
    start_err = runs[0][0]
    short = max(300, int(max_evals * 0.35 / len(runs)))
    done = []
    for e, w in runs:
        w, e, _ = pattern_search(obj, w, free, [p[2] for p in PARAMS], short, rng)
        done.append((e, w))
    done.sort(key=lambda t: t[0])
    budget = max_evals - obj.n
    best, v = done[0]
    top = done[:3]
    for e, w in top:            # refine the best few, then perturbed restarts around the winner
        w, e, _ = pattern_search(obj, w, free, [0.5 * p[2] for p in PARAMS], budget // 6, rng)
        if e < best:
            v, best = w, e
    for r in range(3):
        budget = max_evals - obj.n
        if budget <= 200:
            break
        w = list(v)
        for i in free:
            w[i] += rng.gauss(0, 0.8 * PARAMS[i][2])
        w = clamp(w)
        w, e, _ = pattern_search(obj, w, free, [0.6 * p[2] for p in PARAMS], budget // (3 - r), rng)
        if e < best:
            v, best = w, e
    terms, kp = obj.terms(v)
    return v, {"objective": round(best, 2), "start_objective": round(start_err, 2), "starts": len(starts),
               "evals": obj.n, "seconds": round(time.time() - t0, 1),
               "terms": {k: round(x, 3) for k, x in terms.items()}}, kp


def to_pose(rig_scene, v):
    rig = Rig(rig_scene)
    rig.set(v)
    pose = br.read_pose(rig_scene)
    pose["fit_params"] = {n: round(x, 3) for n, x in zip(NAMES, v)}
    return pose


def params_from_pose(pose):
    """Recover a parameter vector from a pose.json written by this tool."""
    fp = pose.get("fit_params")
    if not fp:
        return None
    return [fp.get(n, PARAMS[i][1]) for i, n in enumerate(NAMES)]


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    target_path, out_dir = argv[0], argv[1]
    opt = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d  # noqa: E731
    with open(target_path) as fh:
        tj = json.load(fh)
    target, flipped = ps.face_right(ps.load(tj), tj.get("mirror", "auto"))
    spec = tj.get("fit", {})
    extra = opt("--spec")
    if extra:
        with open(extra) as fh:
            e = json.load(fh)
        for k in ("set", "weights", "prior"):
            spec.setdefault(k, {}).update(e.get(k, {}))
        spec["lock"] = list(set(spec.get("lock", [])) | set(e.get("lock", [])))
    init = None
    if opt("--init"):
        with open(opt("--init")) as fh:
            init = params_from_pose(json.load(fh))
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    br.build(scene)
    scene.render.resolution_x = scene.render.resolution_y = SIZE   # square, as rendered
    br.apply_pose(scene, {})
    render_az = -45
    fit_az = float(opt("--fit-azimuth", render_az))
    br.set_camera(scene, 4.7, fit_az, 8)
    v, report, kp = fit(scene, target, init, int(opt("--evals", 60000)), int(opt("--seed", 1)), spec)
    report["fit_azimuth"] = fit_az
    report["fit_view_score"] = ps.score(retarget_pose(target, spec.get("proportions", "human")), kp)
    br.set_camera(scene, 4.7, render_az, 8)
    pose = to_pose(scene, v)
    rig = Rig(scene)
    props = spec.get("proportions", "human")
    report["score"] = ps.score(retarget_pose(target, props), rig.keypoints())
    report["mirrored_reference"] = flipped
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "pose.json"), "w") as fh:
        json.dump(pose, fh, indent=1)
    with open(os.path.join(out_dir, "target_right.json"), "w") as fh:
        json.dump(target.to_json(), fh)
    with open(os.path.join(out_dir, "target_rig.json"), "w") as fh:
        json.dump(retarget_pose(target, props).to_json(), fh)
    with open(os.path.join(out_dir, "fit.json"), "w") as fh:
        json.dump(report, fh, indent=1)
    print("fit:", json.dumps({k: report[k] for k in ("objective", "start_objective", "evals", "seconds")}))
    print("score:", ps.fmt(report["score"]))
    if "--no-render" not in argv:
        br.render_guides(scene, out_dir, size=SIZE)


if __name__ == "__main__":
    main()

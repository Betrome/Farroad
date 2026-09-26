"""Small, layered motion for sprite frames -- so no frame is ever a frozen copy.

Otsoga's Joanna idle (the smoothness Ian liked) changes something on every
frame: the torso breathes, the head follows a frame later, sword and shield
tilt a pixel at a time, the legs stay planted. Ours used to shift the whole
upper body by one pixel (2 distinct frames out of 6) and hold attack poses
as identical copies. This builds frames the same way, from one sword-free
pose and its part map (tools/region_masks.py ids, per pixel):

    layers  legs (static) < torso < arms < head, each moved by whole pixels;
            each layer is also drawn at every offset between its parent's and
            its own, so a 1 px lag never opens a seam
    sword   redrawn with tools/sword_fix.py at the moved grip and a small
            angle offset, fist back on top

idle_frames() -> the 6-frame breathing idle; hold_frames() -> a held pose that
stays alive (sword tilt, head dip) for N frames.
"""
import math

from PIL import Image

import sword_fix as sf

SKIN, HAIR, EYES, TOP, BOTTOMS, SHOES = 1, 2, 3, 4, 5, 6


def _dilate(pts, r, W, H):
    out = set(pts)
    for (x, y) in pts:
        for dx in range(-r, r + 1):
            for dy in range(-r, r + 1):
                q = (x + dx, y + dy)
                if 0 <= q[0] < W and 0 <= q[1] < H:
                    out.add(q)
    return out


def layers(img, parts, with_torso=True):
    """{name: set of pixels} for head, arms, torso, legs (sword already removed)."""
    px, pt = img.load(), parts.load()
    W, H = img.size
    opaque = {(x, y) for y in range(H) for x in range(W) if px[x, y][3]}
    part = {p: pt[p] for p in opaque}
    hairy = {p for p, v in part.items() if v in (HAIR, EYES)}
    head = {p for p in _dilate(hairy, 3, W, H) if p in part and part[p] in (HAIR, EYES, SKIN, 0)}
    tops = [p[1] for p, v in part.items() if v == TOP]
    bots = [p[1] for p, v in part.items() if v == BOTTOMS]
    waist = min(bots) if bots else (max(tops) if tops else H)
    upper = {p for p in opaque if p[1] < waist and p not in head}
    arms = {p for p in upper if part[p] == SKIN}
    arms |= {p for p in _dilate(arms, 1, W, H) if p in upper and part.get(p) == 0}
    torso = (upper - arms) if with_torso else set()
    legs = opaque - head - arms - torso
    return {"head": head, "arms": arms, "torso": torso, "legs": legs}


def compose(img, parts, lay, off):
    """Redraw the layers with their offsets {name: (dx, dy)}; children fill
    toward their parent's offset so nothing tears. Returns (image, parts)."""
    W, H = img.size
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    pout = Image.new("L", img.size, 0)
    src, ps = img.load(), parts.load()
    o, po = out.load(), pout.load()
    parent = {"legs": None, "torso": "legs", "arms": "torso", "head": "torso"}

    def draw(name, dx, dy):
        for (x, y) in lay[name]:
            q = (x + dx, y + dy)
            if 0 <= q[0] < W and 0 <= q[1] < H:
                o[q] = src[x, y]
                po[q] = ps[x, y]

    for name in ("legs", "torso", "arms", "head"):
        dx, dy = off.get(name, (0, 0))
        par = parent[name]
        pdx, pdy = off.get(par, (0, 0)) if par else (dx, dy)
        steps = max(abs(dx - pdx), abs(dy - pdy))
        for s in range(steps, -1, -1):     # from the parent's offset to its own
            t = s / steps if steps else 0.0
            draw(name, round(dx + (pdx - dx) * t), round(dy + (pdy - dy) * t))
    return out, pout


def with_sword(img, parts, grip, angle, layer):
    """Paint the standard sword; its pixels get part 0 (never recoloured)."""
    if layer is None or grip is None:
        return img, parts, None
    out = sf.fix(img, grip, angle, layer, None)
    a, b = img.load(), out.load()
    p2 = parts.copy()
    pp = p2.load()
    for y in range(img.height):
        for x in range(img.width):
            if a[x, y] != b[x, y]:
                pp[x, y] = 0
    r = math.radians(angle)
    L = 2 + sf.BLADE
    return out, p2, [grip[0], grip[1], grip[0] + math.cos(r) * L, grip[1] + math.sin(r) * L]


# ---- the breathing idle: 6 distinct frames, something moves every step
IDLE_TORSO = [0, 0, 1, 1, 1, 0]
IDLE_HEAD = [0, 0, 0, 1, 1, 1]          # follows the torso one frame later
IDLE_SWORD = [0, -2, -4, -3, -1, 1]     # degrees


def idle_frames(img, parts, grip, angle, layer="front"):
    lay = layers(img, parts)
    out = []
    for dt, dh, da in zip(IDLE_TORSO, IDLE_HEAD, IDLE_SWORD):
        f, p = compose(img, parts, lay, {"torso": (0, dt), "arms": (0, dt), "head": (0, dh)})
        g = (grip[0], grip[1] + dt) if grip else None
        out.append(with_sword(f, p, g, angle + da, layer))
    return out


# ---- a held pose that stays alive
HOLD_SWORD = [0, 1.5, 3, 1.5, 0, -1.5]
HOLD_HEAD = [0, 0, 1, 1, 0, 0]


def hold_frames(img, parts, grip, angle, layer, n):
    lay = layers(img, parts, with_torso=False)
    out = []
    for k in range(n):
        dh = HOLD_HEAD[k % len(HOLD_HEAD)] if n > 2 else 0
        f, p = compose(img, parts, lay, {"head": (0, dh)}) if dh else (img, parts)
        out.append(with_sword(f, p, grip, (angle + HOLD_SWORD[k % len(HOLD_SWORD)]) if grip else angle, layer))
    return out

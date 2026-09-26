"""Give every frame the same sword: erase the blade Qwen (or the master)
drew and paint one standard pixel sword at the pose's grip and angle.

The sword is baked into the frames (not a Godot node) so it can pass
behind the body in flashy moves; `layer` says which: "front" draws over the
body and puts the fist back on top of the grip, "behind" only fills
transparent pixels. Colours come from STEEL (one new colour, the rest are
in the masters' palettes); length from BLADE/GRIP, in pixels at 64 px.

As a library:
    fix(img, grip, angle_deg, layer="front", erase=None) -> new image
    detect(img) -> (grip, angle_deg) from the light-grey blade Qwen drew
Angles are screen degrees: 0 = pointing right, 90 = pointing down.
"""
import math

from PIL import Image

OUTLINE = (19, 37, 50, 255)
STEEL = (158, 174, 186, 255)       # the one colour the masters didn't have
EDGE = (255, 255, 255, 255)
GUARD = (101, 59, 35, 255)
GRIP_C = (36, 16, 13, 255)
BLADE, GRIP = 20, 3                # pixels (about the rig's sword at 64 px)
SKIN = {(240, 204, 154), (220, 176, 107), (169, 99, 64)}


def _px(p):
    return int(round(p[0])), int(round(p[1]))


def sword_layer(size, grip, angle_deg):
    """The sword alone on a transparent layer, plus the grip pixels."""
    a = math.radians(angle_deg)
    ux, uy = math.cos(a), math.sin(a)
    nx, ny = -uy, ux
    if ny > 0 or (ny == 0 and nx < 0):     # highlight on the upper side
        nx, ny = -nx, -ny
    layer = {}
    grip_px = set()
    for k in range(-GRIP, 1):
        p = _px((grip[0] + ux * k, grip[1] + uy * k))
        layer[p] = GRIP_C
        grip_px.add(p)
    for k in (-2, -1, 0, 1, 2):            # crossguard
        layer[_px((grip[0] + ux * 1.5 + nx * k, grip[1] + uy * 1.5 + ny * k))] = GUARD
    for i in range(2, 2 + BLADE):
        c = (grip[0] + ux * i, grip[1] + uy * i)
        layer[_px(c)] = EDGE if i == 1 + BLADE else STEEL
        if i < BLADE:                      # the point tapers to one pixel
            e = _px((c[0] + nx, c[1] + ny))
            layer.setdefault(e, EDGE)
    body = set(layer)
    for (x, y) in list(body):             # 1-px dark outline around the steel
        if layer[(x, y)] in (STEEL, EDGE):
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                q = (x + dx, y + dy)
                if q not in body:
                    layer.setdefault(q, OUTLINE)
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    for (x, y), c in layer.items():
        if 0 <= x < size[0] and 0 <= y < size[1]:
            img.putpixel((x, y), c)
    return img, grip_px


def erase_pixels(img, pts):
    """Remove old blade pixels: transparent if they touch the outside,
    otherwise the most common neighbouring colour (a crude inpaint)."""
    img = img.copy()
    px = img.load()
    pts = set(pts)
    W, H = img.size
    for (x, y) in sorted(pts, key=lambda p: 0):
        px[x, y] = (0, 0, 0, 0)
    for _ in range(2):                     # close up holes left inside the body
        for (x, y) in pts:
            if px[x, y][3]:
                continue
            nb = [px[x + dx, y + dy] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
                  if 0 <= x + dx < W and 0 <= y + dy < H and (x + dx, y + dy) not in pts]
            solid = [c for c in nb if c[3]]
            if len(solid) >= 3:
                px[x, y] = max(set(solid), key=solid.count)
    return img


def keep_body(img):
    """Drop stray opaque specks (old blade fragments): keep only the largest
    8-connected opaque region, which is the character."""
    px = img.load()
    W, H = img.size
    todo = {(x, y) for y in range(H) for x in range(W) if px[x, y][3]}
    comps = []
    while todo:
        stack, comp = [todo.pop()], []
        while stack:
            p = stack.pop()
            comp.append(p)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (p[0] + dx, p[1] + dy)
                    if q in todo:
                        todo.remove(q)
                        stack.append(q)
        comps.append(comp)
    out = img.copy()
    o = out.load()
    for comp in sorted(comps, key=len)[:-1]:
        for p in comp:
            o[p] = (0, 0, 0, 0)
    return out


def fix(img, grip, angle_deg, layer="front", erase=None):
    base = keep_body(erase_pixels(img, erase)) if erase else img.copy()
    sword, grip_px = sword_layer(img.size, grip, angle_deg)
    out = base.copy()
    if layer == "front":
        out.alpha_composite(sword)
        # the fist wraps the grip: put the hand's skin pixels back on top
        src = base.load()
        o = out.load()
        for (x, y) in grip_px:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (x + dx, y + dy)
                    if 0 <= q[0] < img.width and 0 <= q[1] < img.height and src[q][:3] in SKIN and src[q][3]:
                        o[q] = src[q]
    else:
        s, o = sword.load(), out.load()
        for y in range(img.height):
            for x in range(img.width):
                if s[x, y][3] and not o[x, y][3]:
                    o[x, y] = s[x, y]
    return out


def detect(img):
    """(grip, angle, blade pixels) from the light-grey blade in a Qwen key."""
    import attack_anim as aa
    found = aa.blade(img)
    if not found:
        return None
    hilt, tip = found
    ang = math.degrees(math.atan2(tip[1] - hilt[1], tip[0] - hilt[0]))
    L = math.hypot(tip[0] - hilt[0], tip[1] - hilt[1]) or 1
    grip = (hilt[0] - 2 * (tip[0] - hilt[0]) / L, hilt[1] - 2 * (tip[1] - hilt[1]) / L)
    px = img.load()
    W, H = img.size
    blade_pts = {(x, y) for y in range(H) for x in range(W) if aa.is_blade(px[x, y])}
    # plus the old blade's dark outline: dark pixels touching both the blade and the outside
    for (x, y) in list(blade_pts):
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                q = (x + dx, y + dy)
                if q in blade_pts or not (0 <= q[0] < W and 0 <= q[1] < H) or not px[q][3]:
                    continue
                if sum(px[q][:3]) < 150:
                    outside = any(0 <= q[0] + ex < W and 0 <= q[1] + ey < H and not px[q[0] + ex, q[1] + ey][3]
                                  for ex, ey in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                    if outside:
                        blade_pts.add(q)
    return grip, ang, blade_pts

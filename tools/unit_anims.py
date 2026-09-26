"""Build a unit's in-game animation set from keyframes (the standard
pipeline's assembly step) and write its Godot SpriteFrames.

    python tools/unit_anims.py UNIT_ID --body male|female [--keys DIR] [--scale 1.3]

Per animation: keys in order, each with a hold (frames), a sword layer
("front"/"behind"/None = no sword on screen), and a role. Every key gets the
same standard sword (tools/sword_fix.py), is aligned to the idle (torso over
torso, feet on the ground; "air" keys keep the torso height instead), and
every frame of every animation is padded onto ONE shared canvas with the
feet at a fixed anchor, so the character keeps its pixel size and position
while the frame around it grows (lying down is wide, a raised sword is tall).

Frames go to godot-project/sprites/units/<id>/<anim>_<n>.png and the
SpriteFrames .tres gets, besides pixel_scale/anchor/body_size:
  weapon  {anim: [[grip_x, grip_y, tip_x, tip_y] or null per frame]} in canvas
          pixels -- where Godot draws the elemental trail/light
  impact  {anim: frame index}  -- the frame the hit lands on
"""
import argparse
import json
import math
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import attack_anim as aa   # noqa: E402  (anchor/blade helpers)
import living_frames as lf  # noqa: E402
import sword_fix as sf      # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.path.join(ROOT, "godot-project")

# (key, hold, sword layer, align) -- align "feet" or "air"
ANIMS = {
    "attack": {"fps": 14, "steps": [
        ("chop_anticipation", 2, "front", "feet"), ("chop_windup", 4, "behind", "feet"),
        ("chop_mid", 1, "front", "feet", "smear"), ("chop_impact", 4, "front", "feet", "impact"),
        ("chop_follow", 2, "front", "feet"), ("chop_recover", 2, "front", "feet")]},
    "jump": {"fps": 12, "steps": [("jump_crouch", 2, "front", "feet"), ("air_tuck", 1, "front", "air")]},
    "land": {"fps": 12, "steps": [("landing", 2, "front", "feet")]},
    "hurt": {"fps": 12, "steps": [("hit_flinch", 3, "front", "feet")]},
    "dead": {"fps": 10, "steps": [("collapse_knees", 3, "front", "feet"), ("topple", 2, "front", "feet"),
                                  ("lying", 1, "front", "feet")]},
}
LOOPS = {"idle"}

# Where each master holds its sword (master_64 coords, facing right) and which
# of the master's own pixels are its old sword, to be erased: rects of
# (x0, y0, x1, y1, "all" | "blue_or_dark").
MASTER_SWORD = {
    "male": {"grip": (40, 41), "angle": 28, "erase": [(42, 39, 56, 49, "all")]},
    "female": {"grip": (42, 39), "angle": 40,
               "erase": [(17, 34, 27, 41, "blue_or_dark"), (41, 36, 47, 42, "blue_or_dark")]},
}


def master_erase(img, rects):
    px = img.load()
    pts = []
    for x0, y0, x1, y1, mode in rects:
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = px[x, y]
                if c[3] and (mode == "all" or c[2] >= c[0] or sum(c[:3]) < 60):
                    pts.append((x, y))
    return pts


SWORDS = {}   # key -> (hilt, tip) from the manifest, when it gives one


def load_manifest(keys_dir, body):
    """{key: path} from anim_keys/manifest.json (animations -> [{key, frames:
    {body: {file, sword: {hilt, tip}}}}]); also any <key>_<body>.png file."""
    paths = {}
    man = os.path.join(keys_dir, "manifest.json")
    if os.path.exists(man):
        with open(man) as fh:
            data = json.load(fh)
        for anim, keys in data.get("animations", {}).items():
            for k in keys:
                fr = k.get("frames", {}).get(body)
                if not fr:
                    continue
                paths[k["key"]] = os.path.join(keys_dir, anim, fr["file"])
                sw = fr.get("sword")
                if sw and sw.get("hilt") and sw.get("tip"):
                    SWORDS[k["key"]] = (tuple(sw["hilt"]), tuple(sw["tip"]))
    for root, _, files in os.walk(keys_dir):
        for f in files:
            if f.endswith(f"_{body}.png"):
                name = f[: -len(f"_{body}.png")]
                name = name.split("_", 1)[1] if name[:2].isdigit() else name
                paths.setdefault(name, os.path.join(root, f))
    return paths


def corridor_pixels(img, hilt, tip, width=3.2):
    """Steel-looking pixels (grey, or the dark outline) along the old blade
    line: what Qwen drew there, whatever shade it came out."""
    import colorsys
    px = img.load()
    hx, hy = hilt
    tx, ty = tip
    L = math.hypot(tx - hx, ty - hy) or 1
    ux, uy = (tx - hx) / L, (ty - hy) / L
    out = []
    for y in range(img.height):
        for x in range(img.width):
            c = px[x, y]
            if not c[3]:
                continue
            t = (x - hx) * ux + (y - hy) * uy
            if t < 1 or t > L + 2:
                continue
            if abs((x - hx) * uy - (y - hy) * ux) > width:
                continue
            _, l, sat = colorsys.rgb_to_hls(c[0] / 255, c[1] / 255, c[2] / 255)
            if sat < 0.35 or l < 0.12 or (c[2] > c[0] and l > 0.45):
                out.append((x, y))
    return out


def sword_spec(img, layer, known=None, old_line=None):
    """(the key with its own blade erased, grip, angle) -- the standard sword
    is drawn per frame later (tools/living_frames.py)."""
    if layer is None:
        return img, None, None
    det = sf.detect(img)
    if known:
        grip, ang = known
        px = img.load()
        pts = {p for p in det[2] if aa.is_blade(px[p])} if det else set()
        if old_line:
            pts |= set(corridor_pixels(img, *old_line))
    elif det:
        grip, ang, pts = det
    else:
        return img, None, None
    erased = sf.keep_body(sf.erase_pixels(img, pts)) if pts else img
    return erased, grip, ang


def standard_sword(img, layer, known=None, old_line=None):
    """(new image, [grip, tip] or None)."""
    if layer is None:
        return img, None
    det = sf.detect(img)
    if known:
        grip, ang = known
        px = img.load()
        # light blade pixels only: the dark-outline pass in sf.detect can eat a forearm
        pts = {p for p in det[2] if aa.is_blade(px[p])} if det else set()
        if old_line:
            pts |= set(corridor_pixels(img, *old_line))
    elif det:
        grip, ang, pts = det
    else:
        return img, None
    out = sf.fix(img, grip, ang, layer, pts)
    a = math.radians(ang)
    L = 2 + sf.BLADE
    return out, [grip[0], grip[1], grip[0] + math.cos(a) * L, grip[1] + math.sin(a) * L]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("unit_id")
    ap.add_argument("--body", required=True)
    ap.add_argument("--keys", default=os.path.join(ROOT, "art_src", "mc", "v2", "anim_keys"))
    ap.add_argument("--fallback", default=os.path.join(ROOT, "art_src", "mc", "v2", "practice_keys"))
    ap.add_argument("--scale", type=float, default=1.3)
    a = ap.parse_args()

    paths = load_manifest(a.fallback, a.body)
    if os.path.isdir(a.keys):
        paths.update({k: v for k, v in load_manifest(a.keys, a.body).items() if v})

    # ---- idle: the master, breathing in layers (tools/living_frames.py)
    master = Image.open(os.path.join(ROOT, "art_src", "mc", "v2", f"{a.body}_master_64.png")).convert("RGBA")
    ms = dict(MASTER_SWORD[a.body])
    erase = [(x + PAD, y + PAD) for x, y in master_erase(master, ms["erase"])]
    ms["grip"] = (ms["grip"][0] + PAD, ms["grip"][1] + PAD)
    master = _pad(master)
    m_orig = master.copy()
    master = sf.keep_body(sf.erase_pixels(master, erase))          # sword-free
    master_parts = parts_of(master, load_mask(f"master_{a.body}", (64, 64)), m_orig)
    refs = part_refs(master, master_parts)
    ref = aa.anchor(master)
    torso_y_ref = _torso_y(master)
    placed = {"idle": [(f, (0, 0), w, pt) for f, pt, w in
                       lf.idle_frames(master, master_parts, ms["grip"], ms["angle"])]}
    master = placed["idle"][0][0]

    # ---- every other animation, aligned to the idle; held frames stay alive
    roles = {}
    for anim, spec in ANIMS.items():
        out = []
        for step in spec["steps"]:
            key, hold, layer, align = step[:4]
            role = step[4] if len(step) > 4 else None
            if key not in paths or not paths[key] or not os.path.exists(paths[key]):
                raise SystemExit(f"missing key {key} for {a.body}")
            img = _pad(Image.open(paths[key]).convert("RGBA"))
            known = None
            if key in SWORDS:
                (hx, hy), (tx, ty) = SWORDS[key]
                hx, hy, tx, ty = hx + PAD, hy + PAD, tx + PAD, ty + PAD
                L = math.hypot(tx - hx, ty - hy) or 1
                known = ((hx - 2 * (tx - hx) / L, hy - 2 * (ty - hy) / L),
                         math.degrees(math.atan2(ty - hy, tx - hx)))
            orig = img.copy()
            erased, grip, ang = sword_spec(img, layer, known, ((hx, hy), (tx, ty)) if known else None)
            parts = parts_of(erased, load_mask(f"{key}_{a.body}", (64, 64)), orig)
            ax, ay = aa.anchor(erased)
            dx = ref[0] - ax
            dy = (torso_y_ref - _torso_y(erased)) if align == "air" else (ref[1] - ay)
            for h, (f, p, weapon) in enumerate(lf.hold_frames(erased, parts, grip, ang, layer, hold)):
                out.append((f, (dx, dy), weapon, p))
                if role and h == 0:
                    roles.setdefault(anim, {})[role] = len(out) - 1
        placed[anim] = out

    # ---- one shared canvas: union of every frame's box, feet anchor fixed
    x0 = y0 = 10 ** 6
    x1 = y1 = -10 ** 6
    for frames in placed.values():
        for img, (dx, dy), _, _ in frames:
            bb = img.getbbox()
            x0, y0 = min(x0, bb[0] + dx), min(y0, bb[1] + dy)
            x1, y1 = max(x1, bb[2] + dx), max(y1, bb[3] + dy)
    pad = 1
    ox, oy = -math.floor(x0) + pad, -math.floor(y0) + pad
    W, H = int(math.ceil(x1) + ox + pad), int(math.ceil(y1) + oy + pad)
    folder = os.path.join(GODOT, "sprites", "units", a.unit_id)
    os.makedirs(folder, exist_ok=True)
    for f in os.listdir(folder):
        if f.endswith(".png") or f.endswith(".png.import"):
            os.remove(os.path.join(folder, f))
    weapon_meta, fps = {}, {"idle": 8}
    for anim, frames in placed.items():
        weapon_meta[anim] = []
        for n, (img, (dx, dy), weapon, parts) in enumerate(frames):
            canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            at = (int(round(dx)) + ox, int(round(dy)) + oy)
            canvas.alpha_composite(img, at)
            # each opaque pixel's part goes in its alpha (255 - part) for the
            # recolour shader (godot-project/shaders/unit_recolor.gdshader)
            pcan = Image.new("L", (W, H), 0)
            pcan.paste(parts, at)
            cp, pp = canvas.load(), pcan.load()
            for yy in range(H):
                for xx in range(W):
                    c = cp[xx, yy]
                    if c[3]:
                        cp[xx, yy] = (c[0], c[1], c[2], 255 - pp[xx, yy])
            canvas.save(os.path.join(folder, f"{anim}_{n}.png"))
            weapon_meta[anim].append(None if weapon is None else
                                     [round(weapon[0] + dx + ox, 1), round(weapon[1] + dy + oy, 1),
                                      round(weapon[2] + dx + ox, 1), round(weapon[3] + dy + oy, 1)])
        fps[anim] = ANIMS[anim]["fps"] if anim in ANIMS else 8
    anchor = (ref[0] + ox, ref[1] + oy)
    mbb = master.getbbox()
    body = (mbb[2] - mbb[0], mbb[3] - mbb[1])
    impact = {anim: r["impact"] for anim, r in roles.items() if "impact" in r}
    write_tres(a.unit_id, placed, fps, a.scale, anchor, body, weapon_meta, impact, refs)
    print(f"{a.unit_id}: canvas {W}x{H}, anchor {anchor}, frames " +
          ", ".join(f"{k} {len(v)}" for k, v in placed.items()))


PAD = 32   # work canvas margin, so a sword reaching past the 64 px key isn't clipped
MASKS = os.path.join(ROOT, "art_src", "mc", "v2", "region_masks")
SWORD_COLS = {sf.OUTLINE[:3], sf.STEEL[:3], sf.EDGE[:3], sf.GUARD[:3], sf.GRIP_C[:3]}


def load_mask(name, size):
    """Part ids (tools/region_masks.py) padded like the key, or all-zero."""
    path = os.path.join(MASKS, name + ".png")
    m = Image.new("L", (size[0] + 2 * PAD, size[1] + 2 * PAD), 0)
    if os.path.exists(path):
        m.paste(Image.open(path).convert("L"), (PAD, PAD))
    return m


def parts_of(img, mask, orig):
    """Part id for every opaque pixel of the finished key: the mask where the
    pixel is still the key's own, 0 for the painted sword, and for anything
    else (pixels the sword clean-up filled in) the neighbours' part."""
    px, mk, og = img.load(), mask.load(), orig.load()
    W, H = img.size
    out = Image.new("L", img.size, 0)
    o = out.load()
    todo = []
    for y in range(H):
        for x in range(W):
            c = px[x, y]
            if not c[3]:
                continue
            if c == og[x, y]:
                o[x, y] = mk[x, y]
            elif c[:3] in SWORD_COLS:
                o[x, y] = 0
            else:
                todo.append((x, y))
    for _ in range(3):
        for (x, y) in todo:
            if o[x, y]:
                continue
            nb = [o[x + dx, y + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                  if (dx or dy) and 0 <= x + dx < W and 0 <= y + dy < H and o[x + dx, y + dy]]
            if nb:
                o[x, y] = max(set(nb), key=nb.count)
    return out


def part_refs(img, parts):
    """Each part's reference brightness: the luma of its most common colour
    (its main lit tone) -- the shader maps that tone to the chosen colour."""
    px, pt = img.load(), parts.load()
    counts = {i: {} for i in range(7)}
    for y in range(img.height):
        for x in range(img.width):
            c = px[x, y]
            if c[3] and pt[x, y]:
                counts[pt[x, y]][c[:3]] = counts[pt[x, y]].get(c[:3], 0) + 1
    refs = []
    for i in range(7):
        if not counts[i]:
            refs.append(0.5)
            continue
        if i == 3:   # eyes: the iris -- the brightest tone that isn't the white
            c = max((k for k in counts[i] if sum(k) < 700), key=lambda k: sum(k), default=max(counts[i], key=counts[i].get))
        else:
            c = max(counts[i], key=counts[i].get)
        refs.append(round((0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255, 4))
    return refs


def _pad(img):
    out = Image.new("RGBA", (img.width + 2 * PAD, img.height + 2 * PAD), (0, 0, 0, 0))
    out.alpha_composite(img, (PAD, PAD))
    return out


def _torso_y(img):
    px = img.load()
    ys = [y for y in range(img.height) for x in range(img.width) if aa.is_shirt(px[x, y])]
    return sum(ys) / len(ys) if ys else img.height / 2


def _gd(v):
    if v is None:
        return "null"
    if isinstance(v, dict):
        return "{" + ", ".join(f'"{k}": {_gd(x)}' for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_gd(x) for x in v) + "]"
    return repr(float(v)) if isinstance(v, float) else str(v)


def write_tres(uid, placed, fps, scale, anchor, body, weapon, impact, part_ref):
    ext, anims, idx = [], [], 1
    for anim, frames in placed.items():
        refs = []
        for n in range(len(frames)):
            ext.append('[ext_resource type="Texture2D" path="res://sprites/units/%s/%s_%d.png" id="%d"]' % (uid, anim, n, idx))
            refs.append('{"duration": 1.0, "texture": ExtResource("%d")}' % idx)
            idx += 1
        anims.append('{"frames": [%s], "loop": %s, "name": &"%s", "speed": %s}'
                     % (", ".join(refs), "true" if anim in LOOPS else "false", anim, float(fps[anim])))
    lines = ['[gd_resource type="SpriteFrames" load_steps=%d format=3]' % (len(ext) + 1), ""] + ext + [
        "", "[resource]", "animations = [%s]" % ", ".join(anims),
        "metadata/pixel_scale = %s" % scale,
        "metadata/anchor = Vector2(%s, %s)" % (float(anchor[0]), float(anchor[1])),
        "metadata/body_size = Vector2(%s, %s)" % (float(body[0]), float(body[1])),
        "metadata/weapon = %s" % _gd(weapon),
        "metadata/impact = %s" % _gd(impact),
        "metadata/part_ref = %s" % _gd([float(v) for v in part_ref]), ""]
    with open(os.path.join(GODOT, "sprites", "units", uid + ".tres"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))


if __name__ == "__main__":
    main()

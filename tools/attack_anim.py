"""Assemble FFBE-style attack animations from 64 px keyframes.

    python tools/attack_anim.py [ATTACK ...] [--out art_src/mc/v2/attacks] [--fps 12]

Timing (Ian's rule, from Brave Exvius): idle -> wind-up held ~4 frames ->
1-2 smear frames -> strike held ~4 frames with a weapon trail -> recovery ->
idle. Keys come from art_src/mc/v2/practice_keys/<pose>_<body>.png (Qwen
re-poses of the masters, see the combat-pose skill) and the idle from the
master itself.

Each key is re-aligned so the torso and the feet line up with the idle.
The trail is drawn on its own layer from the blade tips the tool finds in
the wind-up and strike keys: an arc swept around the strike's hilt for cuts,
streaks behind the blade for thrusts. The smear frame is the mid-swing key
(when there is one) with the start of the trail over it.

Writes per attack and body: sprite_NN.png, trail_NN.png, frames.json
(key and hold per frame) and preview.gif (4x, sprite + trail); plus
<attack>/preview_both.gif with male and female side by side.
"""
import argparse
import colorsys
import json
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS = os.path.join(ROOT, "art_src", "mc", "v2", "practice_keys")
MASTER = os.path.join(ROOT, "art_src", "mc", "v2", "{body}_master_64.png")
BG = (236, 229, 210, 255)   # parchment-ish battle field, for previews only

# Each step: (key, frames, role). role: "idle", "windup", "smear", "strike", "recover".
ATTACKS = {   # sweep: +1 = clockwise on screen (y down), -1 = counter-clockwise
    "thrust": {"trail": "line", "steps": [
        ("@idle", 2, "idle"), ("thrust_windup", 4, "windup"), ("lunge", 1, "smear"),
        ("lunge", 4, "strike"), ("lunge", 2, "recover"), ("@idle", 3, "idle")]},
    "overhead_chop": {"trail": "arc", "sweep": 1, "steps": [
        ("@idle", 2, "idle"), ("chop_windup", 4, "windup"), ("chop_mid", 1, "smear"),
        ("chop_end", 4, "strike"), ("chop_end", 2, "recover"), ("@idle", 3, "idle")]},
    "rising_slash": {"trail": "arc", "sweep": -1, "steps": [
        ("@idle", 2, "idle"), ("boar_tooth", 4, "windup"), ("rising_slash", 1, "smear"),
        ("rising_slash", 4, "strike"), ("rising_slash", 2, "recover"), ("@idle", 3, "idle")]},
    "horizontal_slash": {"trail": "arc", "sweep": 1, "steps": [
        ("@idle", 2, "idle"), ("slash_windup", 4, "windup"), ("hslash_mid", 1, "smear"),
        ("hslash_follow", 4, "strike"), ("hslash_follow", 2, "recover"), ("@idle", 3, "idle")]},
}


def load(key, body):
    path = MASTER.format(body=body) if key == "@idle" else os.path.join(KEYS, f"{key}_{body}.png")
    return Image.open(path).convert("RGBA")


def _hls(c):
    return colorsys.rgb_to_hls(c[0] / 255, c[1] / 255, c[2] / 255)


def is_shirt(c):
    h, l, s = _hls(c)
    return c[3] and c[2] > c[0] + 20 and 0.12 < l < 0.62 and s > 0.2


def is_blade(c):
    h, l, s = _hls(c)
    return c[3] and l > 0.55 and (s < 0.3 or (c[2] >= c[0] and s < 0.55))


def anchor(im):
    """(torso x, feet y): the shirt's centre column and the lowest opaque row."""
    px = im.load()
    xs = [x for y in range(im.height) for x in range(im.width) if is_shirt(px[x, y])]
    bb = im.getbbox()
    return (sum(xs) / len(xs) if xs else im.width / 2), bb[3]


def blade(im):
    """(hilt, tip): among light-grey pixel clusters of 3+ pixels, the one
    nearest the torso (the hilt) and the one farthest from it (the tip)."""
    px = im.load()
    pts = {(x, y) for y in range(im.height) for x in range(im.width) if is_blade(px[x, y])}
    keep = []
    while pts:
        stack, comp = [pts.pop()], []
        while stack:
            p = stack.pop()
            comp.append(p)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (p[0] + dx, p[1] + dy)
                    if q in pts:
                        pts.remove(q)
                        stack.append(q)
        if len(comp) >= 3:
            keep += comp
    if len(keep) < 4:
        return None
    ax, _ = anchor(im)
    bb = im.getbbox()
    torso = (ax, bb[1] + (bb[3] - bb[1]) * 0.4)
    dist = lambda p: math.hypot(p[0] - torso[0], p[1] - torso[1])   # noqa: E731
    return min(keep, key=dist), max(keep, key=dist)


def shifted(im, dx, dy, size=64):
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(im, (int(round(dx)), int(round(dy))))
    return out


def trail_layer(kind, windup, strike, progress, sweep=1, size=64):
    """One trail frame. progress 0 = the moment of impact, 1 = faded out;
    negative = the smear frame (trail only just started)."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if not windup or not strike:
        return layer
    d = ImageDraw.Draw(layer)
    hilt, tip = strike
    fade = max(0.0, 1.0 - max(progress, 0.0))
    if kind == "line":
        # speed streaks behind the thrust, shrinking toward the tip as it fades
        vx, vy = tip[0] - hilt[0], tip[1] - hilt[1]
        L = math.hypot(vx, vy) or 1
        ux, uy = vx / L, vy / L
        nx, ny = -uy, ux
        for off, length in ((-3, 0.8), (0, 1.2), (3, 0.7)):
            ln = L * length * (0.4 + 0.6 * fade) if progress >= 0 else L * length * 0.5
            x0, y0 = tip[0] + nx * off - ux * ln, tip[1] + ny * off - uy * ln
            x1, y1 = tip[0] + nx * off - ux * 3, tip[1] + ny * off - uy * 3
            d.line([(x0, y0), (x1, y1)], fill=(255, 255, 255, int(255 * fade) if progress >= 0 else 170), width=1)
        if progress == 0:   # impact flash at the tip
            d.ellipse([tip[0] - 2, tip[1] - 2, tip[0] + 2, tip[1] + 2], fill=(255, 255, 255, 230))
        return layer
    # arc: swept around the strike hilt from the wind-up tip direction to the strike tip
    a0 = math.atan2(windup[1][1] - hilt[1], windup[1][0] - hilt[0])
    a1 = math.atan2(tip[1] - hilt[1], tip[0] - hilt[0])
    da = (a1 - a0) % (2 * math.pi)                          # clockwise distance
    if sweep < 0:
        da -= 2 * math.pi                                    # counter-clockwise
    r_out = math.hypot(tip[0] - hilt[0], tip[1] - hilt[1]) + 1
    if progress < 0:           # smear: only the first half of the sweep, faint
        start, end, alpha = 0.0, 0.55, 150
    else:                      # impact frames: the tail shortens toward the tip
        start, end, alpha = 0.25 + 0.65 * progress, 1.0, int(235 * fade + 40)
    steps = 24
    outer, inner = [], []
    for i in range(steps + 1):
        t = start + (end - start) * i / steps
        a = a0 + da * t
        w = 0.3 + 0.35 * (t - start) / max(end - start, 1e-6)   # thicker toward the leading edge
        outer.append((hilt[0] + r_out * math.cos(a), hilt[1] + r_out * math.sin(a)))
        inner.append((hilt[0] + r_out * (1 - w) * math.cos(a), hilt[1] + r_out * (1 - w) * math.sin(a)))
    d.polygon(outer + inner[::-1], fill=(170, 225, 255, int(alpha * 0.6)))
    d.line(outer, fill=(255, 255, 255, alpha), width=1)
    return layer


def build(name, body, out_dir, fps):
    spec = ATTACKS[name]
    idle = load("@idle", body)
    ref = anchor(idle)
    cache = {}
    for key, _, _ in spec["steps"]:
        if key not in cache:
            im = load(key, body)
            a = anchor(im)
            cache[key] = shifted(im, ref[0] - a[0], ref[1] - a[1])
    wkey = next(k for k, _, r in spec["steps"] if r == "windup")
    skey = next(k for k, _, r in spec["steps"] if r == "strike")
    wb, sb = blade(cache[wkey]), blade(cache[skey])
    d = os.path.join(out_dir, name, body)
    os.makedirs(d, exist_ok=True)
    frames, meta, n = [], [], 0
    for key, count, role in spec["steps"]:
        for k in range(count):
            sprite = cache[key]
            if role == "strike":
                trail = trail_layer(spec["trail"], wb, sb, k / count, spec.get("sweep", 1))
            elif role == "smear":
                trail = trail_layer(spec["trail"], wb, sb, -1, spec.get("sweep", 1))
            else:
                trail = Image.new("RGBA", sprite.size, (0, 0, 0, 0))
            sprite.save(os.path.join(d, "sprite_%02d.png" % n))
            trail.save(os.path.join(d, "trail_%02d.png" % n))
            meta.append({"frame": n, "key": key, "role": role})
            frame = Image.new("RGBA", sprite.size, BG)
            frame.alpha_composite(sprite)
            frame.alpha_composite(trail)
            frames.append(frame)
            n += 1
    with open(os.path.join(d, "frames.json"), "w") as fh:
        json.dump({"attack": name, "body": body, "fps": fps, "frames": meta,
                   "blade_windup": wb, "blade_strike": sb}, fh, indent=1)
    big = [f.resize((256, 256), Image.NEAREST).convert("RGB") for f in frames]
    big[0].save(os.path.join(d, "preview.gif"), save_all=True, append_images=big[1:],
                duration=int(1000 / fps), loop=0)
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("attacks", nargs="*", default=list(ATTACKS))
    ap.add_argument("--out", default=os.path.join(ROOT, "art_src", "mc", "v2", "attacks"))
    ap.add_argument("--fps", type=int, default=12)
    a = ap.parse_args()
    for name in a.attacks:
        pair = [build(name, b, a.out, a.fps) for b in ("male", "female")]
        both = []
        for fm, ff in zip(*pair):
            canvas = Image.new("RGB", (512 + 16, 256), BG[:3])
            canvas.paste(fm.resize((256, 256), Image.NEAREST).convert("RGB"), (0, 0))
            canvas.paste(ff.resize((256, 256), Image.NEAREST).convert("RGB"), (272, 0))
            both.append(canvas)
        both[0].save(os.path.join(a.out, name, "preview_both.gif"), save_all=True, append_images=both[1:],
                     duration=int(1000 / a.fps), loop=0)
        print(name, len(both), "frames")


if __name__ == "__main__":
    main()

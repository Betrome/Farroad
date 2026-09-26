#!/usr/bin/env python3
"""
Farroad art pipeline: one combat-pose practice round, end to end.

  python tools/pose_practice.py run ROUND.json      # fit + render + Qwen + pixelize
  python tools/pose_practice.py finish ROUND_DIR    # score + contact sheet + gallery
  python tools/pose_practice.py gallery WORK_DIR    # rebuild gallery.html
  python tools/pose_practice.py batch WORK_DIR r001 r010 OUT.png   # combined sheet

ROUND.json (written by hand or by a driver script):
  {"work": WORK_DIR (default: the folder above the round file), "round": 12, "pose": "lunge", "target": "refs/lunge.json",
   "intent": "a deep fencing lunge, sword arm fully extended forward",
   "spec": {...pose_fit "fit" overrides...}, "init": "rounds/r011/pose.json" (optional),
   "fit_azimuth": -45, "guide": "openpose" | "openpose_body" | "openpose_hilt" | "openpose_body_hilt",
   "seed": 1,
   "prompt": optional full prompt (else built from intent), "evals": 60000}

`run` writes WORK/rounds/rNNN/: the fit (pose.json, fit.json, guides), the
Qwen results (male_qwen.png, female_qwen.png), the pixelized 64 px sprites
(male_px.png, female_px.png) and annotate.png. If the desktop's DWPose model
works it also writes male_kp.json / female_kp.json; otherwise annotate the
sprites by hand (annotate.png shows both at 8x with a 4 px grid; write
male_kp.txt / female_kp.txt in tools/pose_score.parse_points format, sprite
pixel units, "R" = the sword arm).
`finish ROUND_DIR [--notes notes.json]` scores reference->rig, rig->male and
rig->female, draws sheet.png (reference skeleton | rig shaded | rig skeleton |
male x4 | female x4 | scores), writes record.json and rebuilds the gallery.
"""
import argparse
import html
import json
import os
import shutil
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import comfy_gen as cg  # noqa: E402
import pose_render  # noqa: E402
import pose_score as ps  # noqa: E402
import qwen_edit as qe  # noqa: E402
from pixelize import pixelize, shared_palette  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLENDER = os.environ.get("BLENDER", r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe")
MASTERS = {"male": os.path.join(ROOT, "art_src", "mc", "v2", "male_master_64.png"),
           "female": os.path.join(ROOT, "art_src", "mc", "v2", "female_master_64.png")}
PROMPT = ("Re-pose the pixel art character from image 1 so the body matches the stick-figure skeleton in "
          "image 2: {intent}. The grey line in image 2 is the sword, held in the character's right hand "
          "(the hand nearer the viewer), and the character faces right. Keep the same character, outfit, "
          "colours, proportions and pixel art style. Plain white background.")
TILE = 256


# ---------------------------------------------------------------- run
SERIES = {"r": "rounds", "t": "targeted"}   # round-number prefix -> folder


def round_dir(cfg):
    pre = cfg.get("series", "r")
    return os.path.join(cfg["work"], SERIES[pre], "%s%03d" % (pre, cfg["round"]))


def body_spec(cfg, body):
    """cfg["spec"] with cfg["spec_by_body"][body] merged in (set/prior/weights update, lock unions)."""
    spec = json.loads(json.dumps(cfg.get("spec", {})))
    for k, v in cfg.get("spec_by_body", {}).get(body, {}).items():
        if k == "lock":
            spec["lock"] = sorted(set(spec.get("lock", [])) | set(v))
        elif isinstance(v, dict):
            spec.setdefault(k, {}).update(v)
        else:
            spec[k] = v
    return spec


BODIES = ("male", "female")   # each master gets a guide fitted on its own body profile


def fit_cmd(cfg, out, body):
    """The Blender command that fits one body into out/<body>/."""
    target = os.path.join(cfg["work"], cfg["target"])
    bdir = os.path.join(out, body)
    os.makedirs(bdir, exist_ok=True)
    spec_path = os.path.join(bdir, "spec.json")
    with open(spec_path, "w") as fh:
        json.dump(body_spec(cfg, body), fh, indent=1)
    cmd = [BLENDER, "-b", "--factory-startup", "-P", os.path.join(ROOT, "tools", "pose_fit.py"), "--",
           target, bdir, "--body", body, "--spec", spec_path, "--evals", str(cfg.get("evals", 60000)),
           "--seed", str(cfg.get("fit_seed", 1)), "--fit-azimuth", str(cfg.get("fit_azimuth", -45))]
    ib = cfg.get("init_by_body", {}).get(body)
    if ib or cfg.get("init"):   # a previous round's folder (its <body>/pose.json) or a pose.json
        init = os.path.join(cfg["work"], ib or cfg["init"])
        if not init.endswith(".json"):
            init = os.path.join(init, body, "pose.json")
        cmd += ["--init", init]
    return cmd


def fit(cfg, out):
    """Fit both bodies (two Blender processes in parallel)."""
    procs = {b: subprocess.Popen(fit_cmd(cfg, out, b), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
             for b in BODIES}
    for b, pr in procs.items():
        so, se = pr.communicate(timeout=1800)
        log = "\n".join(line for line in so.splitlines() if line.startswith(("fit:", "score:", "Error", "Trace")))
        print(b, log)
        if not os.path.exists(os.path.join(out, b, "openpose.png")):
            print(so[-3000:], se[-3000:])
            raise SystemExit("fit failed: " + b)


def guide_image(out, kind):
    """The skeleton passed to Qwen as image 2."""
    src = os.path.join(out, "openpose.png")
    if kind == "openpose":
        return src
    data = json.load(open(os.path.join(out, "openpose.json")))
    kp = data["people"][0]["pose_keypoints_2d"]
    if kind.startswith("openpose_body"):      # no face points: just the body and the sword
        for i in (14, 15, 16, 17):
            kp[3 * i + 2] = 0
    img = pose_render.render(kp, 512, 512)
    if kind.endswith("hilt"):
        draw_sword(ImageDraw.Draw(img), data["sword"][0], data["sword"][1])
    else:
        ImageDraw.Draw(img).line([tuple(data["sword"][0]), tuple(data["sword"][1])], fill=(200, 200, 200), width=6)
    path = os.path.join(out, "guide_%s.png" % kind)
    img.save(path)
    return path


def draw_sword(d, hilt, tip):
    """A sword that shows which end is which: a short dark grip, a crossguard across the
    blade at the hilt end, and a light blade tapering to a point."""
    import math
    (hx, hy), (tx, ty) = hilt, tip
    L = math.hypot(tx - hx, ty - hy) or 1
    ux, uy = (tx - hx) / L, (ty - hy) / L
    nx, ny = -uy, ux
    g = 0.12 * L                                  # guard sits a little way up from the fist
    gx, gy = hx + ux * g, hy + uy * g
    d.line([(hx - ux * 0.08 * L, hy - uy * 0.08 * L), (gx, gy)], fill=(110, 80, 60), width=7)
    w = 5
    bx, by = tx - ux * 3 * w, ty - uy * 3 * w      # where the edges start to meet at the point
    d.polygon([(gx + nx * w, gy + ny * w), (bx + nx * w, by + ny * w), (tx, ty),
               (bx - nx * w, by - ny * w), (gx - nx * w, gy - ny * w)], fill=(215, 215, 215))
    c = 22
    d.line([(gx + nx * c, gy + ny * c), (gx - nx * c, gy - ny * c)], fill=(170, 170, 170), width=6)


def wait_for_server(tries=60):
    for k in range(tries):
        try:
            cg.get("/queue")
            return
        except Exception as e:  # noqa: BLE001
            print("ComfyUI not reachable (%s); retrying in 60 s" % e)
            time.sleep(60)
    raise SystemExit("ComfyUI unreachable")


def qwen(cfg, out, guides):
    """Re-pose each master with the guide fitted on its own body."""
    prompt = cfg.get("prompt") or PROMPT.format(intent=cfg["intent"])
    wait_for_server()
    results = {}
    for who, master in MASTERS.items():
        pose_name = cg.upload(qe.prep(guides[who], 1024, bg=(0, 0, 0)), "pp_pose_%s.png" % who)
        if cfg.get("reuse_qwen") and os.path.exists(os.path.join(out, who + "_qwen.png")):
            results[who] = os.path.join(out, who + "_qwen.png")
            continue
        sprite_name = cg.upload(qe.prep(master, 1024), "pp_%s.png" % who)
        tmp = os.path.join(out, "_qwen_" + who)
        for attempt in range(5):
            try:
                saved, secs = cg.run(qe.workflow([sprite_name, pose_name], prompt, cfg.get("seed", 1), "farroad_pp"),
                                     tmp)
                break
            except Exception as e:  # noqa: BLE001
                print("qwen failed (%s); waiting" % e)
                time.sleep(60)
                wait_for_server()
        else:
            raise SystemExit("qwen kept failing")
        dst = os.path.join(out, who + "_qwen.png")
        shutil.move(saved[0], dst)
        shutil.rmtree(tmp, ignore_errors=True)
        print("%s: %.1fs" % (who, secs))
        results[who] = dst
    return results, prompt


# sword greys the masters lack: neutral (not blue-tinted) so the shirt's highlights
# don't snap to them, which also lets sprite_sword() find the blade by colour
STEEL = [(96, 99, 105), (140, 142, 146), (186, 188, 192), (228, 230, 232)]   # + a dark grey: blade outlines otherwise snap to hair brown


def palette_for(who, steel=True):
    """The master's palette (+ a few steel greys, or light blades snap to skin beige)."""
    ims = [Image.open(MASTERS[who])]
    if steel:
        sw = Image.new("RGBA", (len(STEEL), 1))
        sw.putdata([c + (255,) for c in STEEL])
        ims.append(sw)
    return shared_palette(ims)


def components8(img):
    """Opaque 8-connected components (a one-pixel diagonal blade stays in one piece)."""
    px = img.load()
    W, H = img.size
    seen, comps = set(), []
    for y in range(H):
        for x in range(W):
            if px[x, y][3] and (x, y) not in seen:
                comp, stack = [], [(x, y)]
                seen.add((x, y))
                while stack:
                    cx, cy = stack.pop()
                    comp.append((cx, cy))
                    for dx in (-1, 0, 1):
                        for dy in (-1, 0, 1):
                            n = (cx + dx, cy + dy)
                            if 0 <= n[0] < W and 0 <= n[1] < H and n not in seen and px[n][3]:
                                seen.add(n)
                                stack.append(n)
                comps.append(comp)
    return comps


def keep_near_largest(img, reach):
    """Drop opaque components farther than `reach` px from the largest one."""
    comps = components8(img)
    if len(comps) < 2:
        return img
    big = max(comps, key=len)
    bset = set(big)
    px = img.load()
    for comp in comps:
        if comp is big:
            continue
        near = any((x + dx, y + dy) in bset for x, y in comp
                   for dx in range(-reach, reach + 1) for dy in range(-reach, reach + 1))
        if not near:
            for p in comp:
                px[p] = (0, 0, 0, 0)
    return img


def cap_colours(img, n):
    """Merge the closest pair of colours (rarer into commoner) until at most n remain."""
    img = img.convert("RGBA")
    while True:
        cols = [(k, c) for k, c in img.getcolors(4096) if c[3] > 0]
        if len(cols) <= n:
            return img
        best = None
        for i in range(len(cols)):
            for j in range(i + 1, len(cols)):
                d = sum((a - b) ** 2 for a, b in zip(cols[i][1][:3], cols[j][1][:3]))
                if best is None or d < best[0]:
                    best = (d, i, j)
        _, i, j = best
        rare, common = (cols[i][1], cols[j][1]) if cols[i][0] < cols[j][0] else (cols[j][1], cols[i][1])
        px = img.load()
        for y in range(img.height):
            for x in range(img.width):
                if px[x, y] == rare:
                    px[x, y] = common


def pixel(out, who, src, bg_tol=40, steel=True, master=None, block=16, keep_place=False, air_px=0):
    # bg_tol 40, not pixelize's 90: Qwen's background is pure white, and a looser
    # flood fill eats the light-grey sword blade where it touches the background
    sprite, k, n, st = pixelize(Image.open(src), block=block, palette=palette_for(master or who, steel),
                                keep_largest=False, bg_tol=bg_tol, min_speck=1)
    # keep_largest would delete a blade that the 16 px downsample cut off from the hand;
    # keep every piece that lies within a few pixels of the main figure instead
    sprite = keep_near_largest(sprite, 3)
    sprite = cap_colours(sprite, 16)
    canvas = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    # bottom-centre on a 64 px canvas (feet on the same row as the master's)
    w, h = sprite.size
    if w > 64 or h > 64:
        sprite.thumbnail((64, 64), Image.NEAREST)
        w, h = sprite.size
    if keep_place:   # airborne poses: keep Qwen's placement (the ground line stays fixed, the body sits higher)
        qb = fg_bbox(Image.open(src))
        x0, y0 = int(round(qb[0] / block)), int(round(qb[1] / block))
        canvas.alpha_composite(sprite, ((64 - w) // 2, max(0, min(64 - h, y0))))   # centred; Qwen's height kept
    else:   # air_px: airborne poses sit that many pixels above the fixed ground line
        canvas.alpha_composite(sprite, ((64 - w) // 2, max(0, 64 - h - 2 - air_px) if h < 62 else 0))
    dst = os.path.join(out, who + "_px.png")
    canvas.save(dst)
    return dst, {"w": w, "h": h, "figures": n}


DW_ESTIMATOR = "dw-ll_ucoco_384.onnx"   # the torchscript default isn't on the desktop


def dwpose(img_path, bbox="None", pixel_art=True, size=1024, near=None):
    """COCO-18 keypoints from the desktop's DWPreprocessor, as a pose_score.Pose in
    `size` px canvas coordinates (None if nobody was found). Pixel art is nearest-
    upscaled onto a white square first; bbox "None" for sprites/renders ("yolox_l.onnx"
    finds nobody in stylised images), "yolox_l.onnx" first for photos."""
    if pixel_art:
        src = qe.prep(img_path, size)
    else:
        src = img_path
    name = cg.upload(src, "pp_dw.png")
    wf = {"1": {"class_type": "LoadImage", "inputs": {"image": name}},
          "2": {"class_type": "DWPreprocessor", "inputs": {
              "image": ["1", 0], "detect_hand": "disable", "detect_body": "enable", "detect_face": "disable",
              "resolution": 1024, "bbox_detector": bbox, "pose_estimator": DW_ESTIMATOR}},
          "3": {"class_type": "PreviewImage", "inputs": {"images": ["2", 0]}}}
    pid = cg.post("/prompt", {"prompt": wf})["prompt_id"]
    t0 = time.time()
    while True:
        h = cg.get("/history/" + pid)
        if pid in h:
            break
        if time.time() - t0 > 300:
            return None
        time.sleep(0.3)
    entry = h[pid]
    if entry.get("status", {}).get("status_str") == "error":
        print("dwpose error:", json.dumps(entry["status"])[:500])
        return None
    raw = entry["outputs"].get("2", {}).get("openpose_json")
    if not raw:
        return None
    frames = json.loads(raw[0])
    frame = frames[0] if isinstance(frames, list) else frames
    if not frame.get("people"):
        return None
    def count(p):
        return sum(1 for i in range(18) if p["pose_keypoints_2d"][3 * i + 2] > 0)

    def dist(p):   # neck (or first found joint) to `near`, in image pixels
        k = p["pose_keypoints_2d"]
        W, H = frame.get("canvas_width", size), frame.get("canvas_height", size)
        for i in (1, 0, 2, 5, 8, 11):
            if k[3 * i + 2] > 0:
                x, y = k[3 * i], k[3 * i + 1]
                if max(x, y) <= 1.0:
                    x, y = x * W, y * H
                return (x - near[0]) ** 2 + (y - near[1]) ** 2
        return 1e18
    # the person nearest `near` if given, else the most complete one
    best = min(frame["people"], key=dist) if near else max(frame["people"], key=count)
    return ps.load({"canvas_width": frame.get("canvas_width", size), "canvas_height": frame.get("canvas_height", size),
                    "people": [best]})


def fg_bbox(img, white=235):
    """Bounding box of the non-white / opaque pixels."""
    im = img.convert("RGBA")
    px = im.load()
    xs, ys = [], []
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a > 0 and min(r, g, b) < white:
                xs.append(x)
                ys.append(y)
    return (min(xs), min(ys), max(xs) + 1, max(ys) + 1) if xs else (0, 0, im.width, im.height)


def sprite_sword(sprite_path, pose=None):
    """The sword in a pixelized sprite as [hilt, tip] (sprite px): a line through the
    steel-coloured pixels (the masters have no such greys), hilt = the end nearer a wrist."""
    import math
    im = Image.open(sprite_path).convert("RGBA")
    px = im.load()
    steel = set(STEEL)
    mask = Image.new("RGBA", im.size, (0, 0, 0, 0))
    mp = mask.load()
    for y in range(im.height):
        for x in range(im.width):
            if px[x, y][3] and px[x, y][:3] in steel:
                mp[x, y] = (255, 255, 255, 255)
    comps = components8(mask)
    if not comps:
        return None
    # the blade = the longest steel piece (plus pieces lined up with it, a blade the
    # downsample broke up); stray steel pixels elsewhere are ignored
    pts = [(x + 0.5, y + 0.5) for x, y in max(comps, key=len)]
    if len(pts) < 4:
        return None
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    syy = sum((p[1] - my) ** 2 for p in pts)
    sxy = sum((p[0] - mx) * (p[1] - my) for p in pts)
    ang = 0.5 * math.atan2(2 * sxy, sxx - syy)
    ux, uy = math.cos(ang), math.sin(ang)
    proj = [(p[0] - mx) * ux + (p[1] - my) * uy for p in pts]
    if max(proj) - min(proj) < 4:
        return None
    a = (mx + ux * min(proj), my + uy * min(proj))
    b = (mx + ux * max(proj), my + uy * max(proj))
    if pose and pose.xy(1) and pose.xy(-1):
        # hilt = the end nearer the torso centre (more robust than the detected wrists,
        # which DWPose sometimes puts on the blade)
        n, m = pose.xy(1), pose.xy(-1)
        c = ((n[0] + m[0]) / 2, (n[1] + m[1]) / 2)
        if math.hypot(b[0] - c[0], b[1] - c[1]) < math.hypot(a[0] - c[0], a[1] - c[1]):
            a, b = b, a
    return [a, b]


def auto_keypoints(out, who, min_body=10):
    """DWPose on a few renderings of the sprite (64 px sprite x16 on 1024 and x6 on 512,
    the raw Qwen image); keeps the one with the most body joints and writes WHO_kp.json
    in 64 px sprite coordinates, with the sword found from the steel pixels.
    Returns the number of body joints (0-13) found, or 0 if none was usable
    (< min_body joints, or no neck/hip)."""
    sprite = os.path.join(out, who + "_px.png")
    qimg = os.path.join(out, who + "_qwen.png")
    best = None
    for kind, scale, canvas in (("px", 16, 1024), ("px", 6, 512), ("qwen", 1, 1024)):
        if kind == "px":
            im = Image.open(sprite).convert("RGBA")
            im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
            c = Image.new("RGBA", (canvas, canvas), (255, 255, 255, 255))
            off = ((canvas - im.width) // 2, (canvas - im.height) // 2)
            c.alpha_composite(im, off)
            src = os.path.join(out, "_dw_in.png")
            c.convert("RGB").save(src)
        else:
            src = qimg
        try:
            pose = dwpose(src, pixel_art=False)
        except Exception as e:  # noqa: BLE001
            print("dwpose failed:", e)
            pose = None
        n = sum(1 for i in range(14) if pose and pose.ok(i))
        if not (pose and n >= min_body and pose.ok(1) and (pose.ok(8) or pose.ok(11))):
            continue
        if best and n <= best[0]:
            continue
        if kind == "px":        # canvas (DWPose may report it resized) -> sprite pixels
            kx = canvas / pose.width
            k, ox, oy = kx / scale, -off[0] / scale, -off[1] / scale
        else:                   # align the Qwen figure's box with the sprite's
            qb, sb = fg_bbox(Image.open(qimg)), fg_bbox(Image.open(sprite))
            kx = Image.open(qimg).width / pose.width
            k = (sb[3] - sb[1]) / max(1, qb[3] - qb[1]) * kx
            ox, oy = sb[0] - qb[0] * k / kx, sb[1] - qb[1] * k / kx
        pts = [((x * k + ox), (y * k + oy), c_) if c_ > 0 else (0.0, 0.0, 0.0) for x, y, c_ in pose.pts]
        best = (n, pts, "dwpose:%s x%s" % (kind, scale))
    if not best:
        return 0
    n, pts, tag = best
    p64 = ps.Pose(pts, None, 64, 64)
    p64.sword = sprite_sword(sprite, p64)
    d = p64.to_json()
    d["source"] = tag
    with open(os.path.join(out, who + "_kp.json"), "w") as fh:
        json.dump(d, fh)
    return n


def rig_overlay(out, body, size=512):
    guide = Image.open(os.path.join(out, body, "openpose.png")).convert("RGB")
    shaded = Image.open(os.path.join(out, body, "shaded.png")).convert("RGB")
    return Image.blend(shaded, guide, 0.6).resize((size, size))


def draw_kp(img, pose, k):
    """Thin skeleton of a 64 px pose on an x`k` sprite tile (to check detections)."""
    from pose_render import LIMBS, COLORS
    d = ImageDraw.Draw(img)
    for n, (a, b) in enumerate(LIMBS[:12]):
        if pose.ok(a) and pose.ok(b):
            d.line([(pose.pts[a][0] * k, pose.pts[a][1] * k), (pose.pts[b][0] * k, pose.pts[b][1] * k)],
                   fill=COLORS[n] + (255,), width=2)
    if pose.sword:
        (hx, hy), (tx, ty) = pose.sword
        d.line([(hx * k, hy * k), (tx * k, ty * k)], fill=(255, 0, 255, 255), width=2)
        d.ellipse([hx * k - 4, hy * k - 4, hx * k + 4, hy * k + 4], outline=(255, 0, 255, 255), width=2)


def annotate_sheet(out):
    """Each body's rig guide over its shaded render, then both sprites at 8x with a
    4 px grid (labels in sprite pixels) and any detected skeleton, for checking or
    hand annotation."""
    tiles = [rig_overlay(out, b) for b in BODIES]
    for who in MASTERS:
        sp = Image.open(os.path.join(out, who + "_px.png")).convert("RGBA")
        big = Image.new("RGBA", (512, 512), (255, 255, 255, 255))
        big.alpha_composite(sp.resize((512, 512), Image.NEAREST))
        d = ImageDraw.Draw(big)
        for g in range(0, 65, 4):
            col = (255, 0, 0, 255) if g % 16 == 0 else (170, 170, 220, 255)
            d.line([(g * 8, 0), (g * 8, 512)], fill=col, width=1)
            d.line([(0, g * 8), (512, g * 8)], fill=col, width=1)
            if g % 8 == 0:
                d.text((g * 8 + 2, 2), str(g), fill=(200, 0, 0, 255))
                d.text((2, g * 8 + 2), str(g), fill=(200, 0, 0, 255))
        kp = os.path.join(out, who + "_kp.json")
        if os.path.exists(kp):
            draw_kp(big, ps.load(kp), 8)
        tiles.append(big)
    sheet = Image.new("RGB", (522 * len(tiles) - 10, 512), (60, 60, 60))
    for i, t in enumerate(tiles):
        sheet.paste(t.convert("RGB"), (i * 522, 0))
    sheet.save(os.path.join(out, "annotate.png"))


def cmd_run(path):
    cfg = json.load(open(path))
    cfg.setdefault("work", os.path.dirname(os.path.dirname(os.path.abspath(path))))   # WORK/cfg/rNNN.json
    out = round_dir(cfg)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "round.json"), "w") as fh:
        json.dump(cfg, fh, indent=1)
    if not (cfg.get("reuse_fit") and all(os.path.exists(os.path.join(out, b, "pose.json")) for b in BODIES)):
        fit(cfg, out)
    kind = cfg.get("guide", "openpose_hilt")
    guides = {b: guide_image(os.path.join(out, b), kind) for b in BODIES}
    results, prompt = qwen(cfg, out, guides)
    px, kps = {}, {}
    for who, src in results.items():
        px[who] = pixel(out, who, src, cfg.get("bg_tol", 40), cfg.get("steel", True))[1]
        kps[who] = auto_keypoints(out, who)
        print("%s: DWPose found %d/14 body joints%s" % (who, kps[who], "" if kps[who] else " -> annotate by hand"))
    annotate_sheet(out)
    with open(os.path.join(out, "run.json"), "w") as fh:
        json.dump({"prompt": prompt, "guide": kind, "pixel": px, "dwpose_joints": kps}, fh, indent=1)
    print("done:", out)


# ---------------------------------------------------------------- multi-seed (targeted run)
PROMPT3 = (" Image 3 is a grey mannequin in the same pose, showing the body's shape and depth; follow its "
           "silhouette but not its look.")


def qwen_one(images, prompt, seed, dst):
    """One Qwen edit of already-uploaded images, saved to dst."""
    tmp = dst + "_tmp"
    for attempt in range(5):
        try:
            saved, secs = cg.run(qe.workflow(images, prompt, seed, "farroad_pp"), tmp)
            break
        except Exception as e:  # noqa: BLE001
            print("qwen failed (%s); waiting" % e)
            time.sleep(60)
            wait_for_server()
    else:
        raise SystemExit("qwen kept failing")
    shutil.move(saved[0], dst)
    shutil.rmtree(tmp, ignore_errors=True)
    return dst


def cmd_run_multi(path):
    """A targeted round: fit both bodies, then Qwen with several seeds per body
    (cfg "seeds", default [1, 2, 3]). Optional "image3": "depth"|"shaded" adds that
    render as image 3; optional "second_prompt" re-edits each pixelized result once more
    (image 1 = the sprite, image 2 = the guide). Writes WHO_s<seed>_px.png etc."""
    cfg = json.load(open(path))
    cfg.setdefault("work", os.path.dirname(os.path.dirname(os.path.abspath(path))))
    cfg.setdefault("series", "t")
    out = round_dir(cfg)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "round.json"), "w") as fh:
        json.dump(cfg, fh, indent=1)
    if not (cfg.get("reuse_fit") and all(os.path.exists(os.path.join(out, b, "pose.json")) for b in BODIES)):
        fit(cfg, out)
    kind = cfg.get("guide", "openpose_body_hilt")
    prompt = cfg.get("prompt") or PROMPT.format(intent=cfg["intent"])
    if cfg.get("image3"):
        prompt += PROMPT3
    wait_for_server()
    for who, master in MASTERS.items():
        guide = guide_image(os.path.join(out, who), kind)
        gs = cfg.get("guide_scale_by_body", {}).get(who, cfg.get("guide_scale"))
        if gs:   # shrink the skeleton about its bottom centre (Qwen enlarges compact poses)
            g = Image.open(guide).convert("RGB")
            small = g.resize((int(g.width * gs), int(g.height * gs)), Image.LANCZOS)
            canvas = Image.new("RGB", g.size, (0, 0, 0))
            canvas.paste(small, ((g.width - small.width) // 2, g.height - small.height - int(g.height * 0.02)))
            guide = os.path.join(out, who, "guide_scaled.png")
            canvas.save(guide)
        ms = cfg.get("master_scale_by_body", {}).get(who)
        if ms:   # show the master smaller (x ms instead of x16) on the 1024 canvas, feet at the bottom
            im = Image.open(master).convert("RGBA")
            im = im.resize((im.width * ms, im.height * ms), Image.NEAREST)
            canvas = Image.new("RGBA", (1024, 1024), (255, 255, 255, 255))
            canvas.alpha_composite(im, ((1024 - im.width) // 2, 1024 - im.height - (1024 - 64 * 16) // 2))
            mpath = os.path.join(out, who, "master_scaled.png")
            canvas.convert("RGB").save(mpath)
            mname = cg.upload(mpath, "pp_%s.png" % who)
        else:
            mname = cg.upload(qe.prep(master, 1024), "pp_%s.png" % who)
        names = [mname,
                 cg.upload(qe.prep(guide, 1024, bg=(0, 0, 0)), "pp_pose_%s.png" % who)]
        if cfg.get("image3"):
            names.append(cg.upload(qe.prep(os.path.join(out, who, cfg["image3"] + ".png"), 1024, bg=(0, 0, 0)),
                                   "pp_img3_%s.png" % who))
        for seed in cfg.get("seeds", [1, 2, 3]):
            tag = "%s_s%d" % (who, seed)
            q = qwen_one(names, prompt, seed, os.path.join(out, tag + "_qwen.png"))
            pixel(out, tag, q, cfg.get("bg_tol", 40), cfg.get("steel", True), master=who, block=ms or 16,
                  keep_place=cfg.get("keep_place", False), air_px=cfg.get("air_px", 0))
            if cfg.get("second_prompt"):
                shutil.copy(os.path.join(out, tag + "_px.png"), os.path.join(out, tag + "_px1.png"))
                n2 = [cg.upload(qe.prep(os.path.join(out, tag + "_px.png"), 1024), "pp_2nd_%s.png" % who), names[1]]
                q2 = qwen_one(n2, cfg["second_prompt"], seed, os.path.join(out, tag + "_qwen2.png"))
                pixel(out, tag, q2, cfg.get("bg_tol", 40), cfg.get("steel", True), master=who)
            print(tag, "done")
    with open(os.path.join(out, "run.json"), "w") as fh:
        json.dump({"prompt": prompt, "guide": kind, "seeds": cfg.get("seeds", [1, 2, 3]),
                   "second_prompt": cfg.get("second_prompt"), "image3": cfg.get("image3")}, fh, indent=1)
    multi_sheet(out, None)
    print("done:", out)


def multi_sheet(out, rec, T=176):
    """reference | male rig | female rig | male seeds | female seeds, plus the notes."""
    cfg = json.load(open(os.path.join(out, "round.json")))
    seeds = cfg.get("seeds", [1, 2, 3])
    tiles = [("reference", skeleton_tile(ps.load(os.path.join(out, "male", "target_right.json")), T))]
    for b in BODIES:
        tiles.append(("%s rig" % b, rig_overlay(out, b, T)))
    for who in MASTERS:
        for sd in seeds:
            sp = Image.open(os.path.join(out, "%s_s%d_px.png" % (who, sd))).convert("RGBA").resize((T, T), Image.NEAREST)
            bg = Image.new("RGBA", (T, T), (236, 236, 228, 255))
            bg.alpha_composite(sp)
            tiles.append(("%s seed %d" % (who, sd), bg.convert("RGB")))
    W = len(tiles) * (T + 4) + 4
    sheet = Image.new("RGB", (W, T + 40 + 110), (30, 30, 36))
    d = ImageDraw.Draw(sheet)
    f = font(13)
    title = "%s%03d - %s (attempt %d)" % (cfg.get("series", "t"), cfg["round"], cfg["pose"], cfg.get("attempt", 1))
    if rec:
        pa = rec.get("pass", {})
        title += "    pass by eye: male %s/%d, female %s/%d" % (pa.get("male", "?"), len(seeds), pa.get("female", "?"), len(seeds))
    d.text((6, 4), title, fill="white", font=font(17))
    for i, (label, im) in enumerate(tiles):
        x = 4 + i * (T + 4)
        sheet.paste(im, (x, 28))
        d.text((x + 3, 30), label, fill=(255, 255, 120) if i < 3 else (40, 40, 120), font=f)
    y = T + 34
    for chunk in wrap((rec or {}).get("notes", ""), 230)[:6]:
        d.text((6, y), chunk, fill=(210, 210, 210), font=f)
        y += 17
    sheet.save(os.path.join(out, "sheet.png"))


def cmd_finish_multi(out):
    """notes.json must hold notes, change and pass {"male": n, "female": n} (judged by eye)."""
    cfg = json.load(open(os.path.join(out, "round.json")))
    run = json.load(open(os.path.join(out, "run.json")))
    scores = {}
    for b in BODIES:
        fitr = json.load(open(os.path.join(out, b, "fit.json")))
        scores["rig_" + b] = {k: fitr["score"][k] for k in ("joint", "limb", "sword")}
    scores["rig"] = {k: round(sum((scores["rig_" + b][k] or 0) for b in BODIES) / 2, 3) for k in ("joint", "limb", "sword")}
    rec = {"round": cfg["round"], "series": cfg.get("series", "t"), "pose": cfg["pose"], "attempt": cfg.get("attempt", 1),
           "intent": cfg.get("intent"), "spec": cfg.get("spec", {}), "spec_by_body": cfg.get("spec_by_body", {}),
           "run": run, "scores": scores}
    rec.update(json.load(open(os.path.join(out, "notes.json"))))
    multi_sheet(out, rec)
    with open(os.path.join(out, "record.json"), "w") as fh:
        json.dump(rec, fh, indent=1)
    print("%s%03d %s pass M %s F %s" % (rec["series"], rec["round"], rec["pose"], rec["pass"]["male"], rec["pass"]["female"]))
    cmd_gallery(cfg["work"])


# ---------------------------------------------------------------- finish
def load_kp(out, who):
    """WHO_kp.txt (hand annotation, overrides a bad detection) else WHO_kp.json (DWPose)."""
    t = os.path.join(out, who + "_kp.txt")
    if os.path.exists(t):
        return ps.parse_points(open(t).read(), 64, 64)
    j = os.path.join(out, who + "_kp.json")
    return ps.load(j) if os.path.exists(j) else None


def font(size):
    for f in ("arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


def skeleton_tile(pose, size=TILE):
    """A pose's skeleton re-drawn centred in a size x size tile (sword included)."""
    xs = [p[0] for p in pose.pts[:14] if p[2] > 0] + ([s[0] for s in pose.sword] if pose.sword else [])
    ys = [p[1] for p in pose.pts[:14] if p[2] > 0] + ([s[1] for s in pose.sword] if pose.sword else [])
    span = max(max(xs) - min(xs), max(ys) - min(ys), 1)
    k = (size * 0.86) / span
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    tr = lambda x, y: (size / 2 + (x - cx) * k, size / 2 + (y - cy) * k)  # noqa: E731
    kp = []
    for x, y, c in pose.pts:
        kp += list(tr(x, y)) + [c] if c > 0 else [0, 0, 0]
    img = pose_render.render(kp, size, size)
    if pose.sword:
        ImageDraw.Draw(img).line([tr(*pose.sword[0]), tr(*pose.sword[1])], fill=(200, 200, 200), width=4)
    return img


def sprite_tile(path, pose=None):
    sp = Image.open(path).convert("RGBA").resize((TILE, TILE), Image.NEAREST)
    bg = Image.new("RGBA", (TILE, TILE), (236, 236, 228, 255))
    bg.alpha_composite(sp)
    return bg.convert("RGB")


def contact_sheet(out, rec):
    tiles = []
    tgt = ps.load(os.path.join(out, "male", "target_right.json"))
    tiles.append(("reference skeleton", skeleton_tile(tgt)))
    for b in BODIES:
        tiles.append(("%s rig + guide" % b, rig_overlay(out, b, TILE)))
    for who in MASTERS:
        tiles.append((who + " (64px, x4)", sprite_tile(os.path.join(out, who + "_px.png"))))
    W = TILE * 6 + 7 * 6
    H = TILE + 34 + 150
    sheet = Image.new("RGB", (W, H), (30, 30, 36))
    d = ImageDraw.Draw(sheet)
    f, fb = font(14), font(18)
    d.text((8, 6), "Round %d - %s (attempt %d)" % (rec["round"], rec["pose"], rec.get("attempt", 1)), fill="white", font=fb)
    for i, (label, im) in enumerate(tiles):
        x = 6 + i * (TILE + 6)
        sheet.paste(im, (x, 30))
        d.text((x + 4, 32), label, fill=(255, 255, 120) if i < 3 else (40, 40, 120), font=f)
    x = 6 + 5 * (TILE + 6)
    s = rec["scores"]
    lines = []
    for b in BODIES:
        r = s["rig_" + b]
        lines.append("ref -> %s rig: limb %.1f" % (b, r["limb"]))
    for who in MASTERS:
        r = s.get(who)
        how = "DWPose" if rec.get("kp_source", {}).get(who, "").startswith("dw") else "hand"
        lines.append("rig -> %s sprite (%s)" % (who, how))
        if r:
            lines.append("  limb %.1f  joint %.2f" % (r["limb"], r["joint"]))
            if r.get("sword") is not None:
                lines.append("  sword %.1f deg" % r["sword"])
        else:
            lines.append("  (no keypoints)")
    art = rec.get("art", {})
    for who in MASTERS:
        if who in art:
            lines += wrap("%s: %s" % (who, art[who]), 34)
    d.rectangle([x, 30, x + TILE, 30 + TILE], fill=(20, 20, 24))
    for k, line in enumerate(lines):
        d.text((x + 6, 36 + 17 * k), line, fill="white", font=f)
    note = rec.get("notes", "")
    y = TILE + 38
    for chunk in wrap(note, 190)[:7]:
        d.text((8, y), chunk, fill=(210, 210, 210), font=f)
        y += 18
    sheet.save(os.path.join(out, "sheet.png"))


def wrap(text, n):
    words, lines, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > n:
            lines.append(cur)
            cur = w
        else:
            cur = (cur + " " + w).strip()
    if cur:
        lines.append(cur)
    return lines


def src_is_dw(out, who):
    return not os.path.exists(os.path.join(out, who + "_kp.txt")) and os.path.exists(os.path.join(out, who + "_kp.json"))


def cmd_finish(out, notes_path=None):
    cfg = json.load(open(os.path.join(out, "round.json")))
    run = json.load(open(os.path.join(out, "run.json")))
    scores, fits, src = {}, {}, {}
    for b in BODIES:
        fitr = json.load(open(os.path.join(out, b, "fit.json")))
        fits[b] = {k: fitr[k] for k in ("objective", "evals", "seconds", "terms")}
        scores["rig_" + b] = {k: fitr["score"][k] for k in ("joint", "limb", "sword", "worst", "limbs")}
    both = [scores["rig_" + b] for b in BODIES]
    scores["rig"] = {k: round(sum(r[k] or 0 for r in both) / len(both), 3) for k in ("joint", "limb", "sword")}
    for who in MASTERS:
        rig = ps.load(os.path.join(out, who, "openpose.json"))
        kp = load_kp(out, who)
        if kp and (not kp.sword or src_is_dw(out, who)):
            kp.sword = sprite_sword(os.path.join(out, who + "_px.png"), kp)
        kj = os.path.join(out, who + "_kp.json")
        if os.path.exists(os.path.join(out, who + "_kp.txt")):
            src[who] = "hand"
        else:
            src[who] = json.load(open(kj)).get("source", "hand") if os.path.exists(kj) else "none"
        scores[who] = ps.score(rig, kp, side_swap=True) if kp else None
    rec = {"round": cfg["round"], "pose": cfg["pose"], "attempt": cfg.get("attempt", 1),
           "intent": cfg.get("intent"), "spec": cfg.get("spec", {}), "init": cfg.get("init"),
           "fit_azimuth": cfg.get("fit_azimuth", -45), "guide": run["guide"], "prompt": run["prompt"],
           "fit": fits, "scores": scores, "pixel": run["pixel"], "kp_source": src}
    if notes_path:
        rec.update(json.load(open(notes_path)))
    elif os.path.exists(os.path.join(out, "notes.json")):
        rec.update(json.load(open(os.path.join(out, "notes.json"))))
    contact_sheet(out, rec)
    with open(os.path.join(out, "record.json"), "w") as fh:
        json.dump(rec, fh, indent=1)
    s = scores
    print("ref->rig M %s / F %s | male %s | female %s" % (
        ps.fmt(s["rig_male"]), ps.fmt(s["rig_female"]),
        ps.fmt(s["male"]) if s["male"] else "-", ps.fmt(s["female"]) if s["female"] else "-"))
    cmd_gallery(cfg["work"])


# ---------------------------------------------------------------- gallery
ARCHIVE = "archive_v1"   # rounds 1-25 on the old (one-body, long-torso) rig


def records(work, sub="rounds"):
    base = os.path.join(work, sub)
    out = []
    for d in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        p = os.path.join(base, d, "record.json")
        if os.path.exists(p):
            out.append(json.load(open(p)))
    return out


def cmd_gallery(work):
    recs = records(work)
    rows = gallery_rows(recs, "rounds")
    old = records(work, ARCHIVE + "/rounds")
    archive = ""
    if old:
        archive = ("<section><details><summary><b>Archive (old proportions): rounds 1-%d</b></summary>"
                   "<p>First practice run on the original rig (one body, torso too long, legs too short); "
                   "sprite keypoints annotated by hand.</p>%s%s</details></section>" % (
                       max(r["round"] for r in old), trend_table(old), "\n".join(gallery_rows(old, ARCHIVE + "/rounds"))))
    notes = ("<p>Rig with separate male and female body profiles (each sprite is re-posed with a guide fitted on its "
             "own body). Reference keypoints: DWPose (dw-ll_ucoco_384.onnx; yolox on a crop for photos) where it "
             "agreed with a hand check, hand-marked otherwise; authored poses are hand-drawn skeletons. Sprite "
             "keypoints: DWPose was tried from round 1 but on the 64 px chibi sprites it puts the neck/shoulders on "
             "the chin, so from round 3 the sprites are hand-annotated (the sheet says which). The sprite's sword "
             "angle comes from its steel pixels.</p>")
    tg = records(work, "targeted")
    targeted = ""
    if tg:
        trows = []
        for r in sorted(tg, key=lambda r: -r["round"]):
            pa = r.get("pass", {})
            n = len(r["run"].get("seeds", [1, 2, 3]))
            trows.append('<section><h2>t%03d &middot; %s <small>attempt %d</small></h2>'
                         '<p class="scores">pass (by eye): male <b>%s/%d</b> &middot; female <b>%s/%d</b>'
                         ' &middot; ref&rarr;rig limb %.1f&deg;</p><img src="targeted/t%03d/sheet.png" loading="lazy">'
                         '<p><b>Notes:</b> %s</p><p><b>Next:</b> %s</p></section>' % (
                             r["round"], html.escape(r["pose"]), r.get("attempt", 1), pa.get("male", "?"), n,
                             pa.get("female", "?"), n, r["scores"]["rig"]["limb"], r["round"],
                             html.escape(r.get("notes", "")), html.escape(r.get("change", ""))))
        targeted = ("<section><h2>Targeted run (weak poses, 3 Qwen seeds per body)</h2><p>Success = 3 of 3 seeds "
                    "pass by eye for both bodies.</p></section>" + "\n".join(trows))
    page = PAGE % (notes + trend_table(recs), targeted + "\n".join(rows) + archive)
    with open(os.path.join(work, "gallery.html"), "w", encoding="utf-8") as fh:
        fh.write(page)


def gallery_rows(recs, base):
    rows = []
    for r in sorted(recs, key=lambda r: -r["round"]):
        s = r["scores"]
        cell = lambda k: ("%.1f&deg;" % s[k]["limb"]) if s.get(k) else "-"  # noqa: E731
        sw = s["rig"].get("sword")
        rows.append(
            '<section><h2>Round %d &middot; %s <small>attempt %d</small></h2>'
            '<p class="scores">ref&rarr;rig limb <b>%.1f&deg;</b> joint %.2f%s &middot; rig&rarr;male <b>%s</b>'
            ' &middot; rig&rarr;female <b>%s</b></p>'
            '<img src="%s/r%03d/sheet.png" alt="round %d" loading="lazy">'
            '<p><b>Intent:</b> %s</p><p><b>Notes:</b> %s</p><p><b>Next:</b> %s</p></section>' % (
                r["round"], html.escape(r["pose"]), r.get("attempt", 1), s["rig"]["limb"], s["rig"]["joint"],
                (" sword %.0f&deg;" % sw) if sw else "", cell("male"), cell("female"),
                base, r["round"], r["round"], html.escape(r.get("intent") or ""), html.escape(r.get("notes", "")),
                html.escape(r.get("change", ""))))
    return rows


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Pose practice</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { --bg: #16161a; --fg: #e8e8e8; --muted: #a0a0a8; --card: #202026; --accent: #ffd860; }
body { background: var(--bg); color: var(--fg); font: 15px/1.45 system-ui, sans-serif; margin: 0 auto; padding: 16px; max-width: 1640px; }
section { background: var(--card); border-radius: 8px; padding: 12px 16px; margin: 16px 0; }
img { max-width: 100%%; height: auto; image-rendering: pixelated; display: block; }
h2 { margin: 0 0 4px; font-size: 18px; } small { color: var(--muted); font-weight: normal; }
.scores { color: var(--accent); margin: 4px 0 8px; }
table { border-collapse: collapse; font-size: 13px; } td, th { padding: 2px 8px; border-bottom: 1px solid #333; text-align: right; }
th:first-child, td:first-child { text-align: left; }
</style></head><body>
<h1>Farroad combat-pose practice</h1>
<p>Each round: reference skeleton &rarr; rig fit (pose_fit) &rarr; Qwen re-pose of both masters &rarr; pixelize (64 px, shown x4) &rarr; scores.
Limb = mean limb-angle error in degrees (lower is better). Newest first.</p>
%s
%s
</body></html>"""


def trend_table(recs):
    by = {}
    for r in sorted(recs, key=lambda r: r["round"]):
        by.setdefault(r["pose"], []).append(r)
    rows = []
    for pose, rs in by.items():
        f, l_ = rs[0], rs[-1]

        def sprite(r):
            vals = [r["scores"][w]["limb"] for w in MASTERS if r["scores"].get(w)]
            return ("%.1f" % (sum(vals) / len(vals))) if vals else "-"
        rows.append("<tr><td>%s</td><td>%d</td><td>%.1f &rarr; %.1f</td><td>%s &rarr; %s</td></tr>" % (
            html.escape(pose), len(rs), f["scores"]["rig"]["limb"], l_["scores"]["rig"]["limb"], sprite(f), sprite(l_)))
    return ("<section><h2>Trend per pose</h2><table><tr><th>pose</th><th>rounds</th><th>ref&rarr;rig limb (first &rarr; last)</th>"
            "<th>rig&rarr;sprites limb (first &rarr; last)</th></tr>%s</table></section>" % "".join(rows))


def cmd_batch(work, first, last, dst):
    """Stack the contact sheets of rounds first..last into one image."""
    ims = []
    for n in range(first, last + 1):
        p = os.path.join(work, "rounds", "r%03d" % n, "sheet.png")
        if os.path.exists(p):
            ims.append(Image.open(p).convert("RGB"))
    if not ims:
        raise SystemExit("no sheets")
    W = max(i.width for i in ims)
    out = Image.new("RGB", (W, sum(i.height for i in ims)), (0, 0, 0))
    y = 0
    for i in ims:
        out.paste(i, (0, y))
        y += i.height
    scale = min(1.0, 1400 / W)
    if scale < 1:
        out = out.resize((int(out.width * scale), int(out.height * scale)), Image.LANCZOS)
    out.save(dst)
    print(dst)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("run", "finish", "gallery", "batch", "run_multi", "finish_multi"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--notes")
    a = ap.parse_args()
    if a.cmd == "run":
        cmd_run(a.args[0])
    elif a.cmd == "finish":
        cmd_finish(a.args[0], a.notes)
    elif a.cmd == "run_multi":
        cmd_run_multi(a.args[0])
    elif a.cmd == "finish_multi":
        cmd_finish_multi(a.args[0])
    elif a.cmd == "gallery":
        cmd_gallery(a.args[0])
    else:
        cmd_batch(a.args[0], int(a.args[1]), int(a.args[2]), a.args[3])


if __name__ == "__main__":
    main()

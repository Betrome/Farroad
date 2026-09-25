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
def round_dir(cfg):
    return os.path.join(cfg["work"], "rounds", "r%03d" % cfg["round"])


def fit(cfg, out):
    target = os.path.join(cfg["work"], cfg["target"])
    spec_path = os.path.join(out, "spec.json")
    with open(spec_path, "w") as fh:
        json.dump(cfg.get("spec", {}), fh, indent=1)
    cmd = [BLENDER, "-b", "--factory-startup", "-P", os.path.join(ROOT, "tools", "pose_fit.py"), "--",
           target, out, "--spec", spec_path, "--evals", str(cfg.get("evals", 60000)),
           "--seed", str(cfg.get("fit_seed", 1)), "--fit-azimuth", str(cfg.get("fit_azimuth", -45))]
    if cfg.get("init"):
        cmd += ["--init", os.path.join(cfg["work"], cfg["init"])]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    log = "\n".join(line for line in r.stdout.splitlines() if line.startswith(("fit:", "score:", "Error", "Trace")))
    print(log)
    if not os.path.exists(os.path.join(out, "openpose.png")):
        print(r.stdout[-3000:], r.stderr[-3000:])
        raise SystemExit("fit failed")


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


def qwen(cfg, out, guide):
    prompt = cfg.get("prompt") or PROMPT.format(intent=cfg["intent"])
    wait_for_server()
    pose_name = cg.upload(qe.prep(guide, 1024, bg=(0, 0, 0)), "pp_pose.png")
    results = {}
    for who, master in MASTERS.items():
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


STEEL = [(120, 136, 148), (176, 188, 196), (224, 230, 234)]   # sword greys the masters lack


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


def pixel(out, who, src, bg_tol=40, steel=True):
    # bg_tol 40, not pixelize's 90: Qwen's background is pure white, and a looser
    # flood fill eats the light-grey sword blade where it touches the background
    sprite, k, n, st = pixelize(Image.open(src), block=16, palette=palette_for(who, steel),
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
    canvas.alpha_composite(sprite, ((64 - w) // 2, 64 - h - 2 if h < 62 else 0))
    dst = os.path.join(out, who + "_px.png")
    canvas.save(dst)
    return dst, {"w": w, "h": h, "figures": n}


def dwpose(img_path, out_json):
    """Keypoints for a sprite from the desktop's DWPreprocessor (no bbox detector)."""
    name = cg.upload(qe.prep(img_path, 1024), "pp_dw.png")
    wf = {"1": {"class_type": "LoadImage", "inputs": {"image": name}},
          "2": {"class_type": "DWPreprocessor", "inputs": {
              "image": ["1", 0], "detect_hand": "disable", "detect_body": "enable", "detect_face": "disable",
              "resolution": 1024, "bbox_detector": "None", "pose_estimator": "dw-ll_ucoco_384_bs5.torchscript.pt"}},
          "3": {"class_type": "SavePoseKpsAsJsonFile", "inputs": {"pose_kps": ["2", 1], "filename_prefix": "farroad_dw"}}}
    pid = cg.post("/prompt", {"prompt": wf})["prompt_id"]
    while True:
        h = cg.get("/history/" + pid)
        if pid in h:
            break
        time.sleep(0.5)
    if h[pid].get("status", {}).get("status_str") == "error":
        return False
    return False   # (the model is missing on the desktop; see SKILL.md) - wire the json fetch when it works


def annotate_sheet(out):
    """The rig guide over its shaded render, then both sprites at 8x with a 4 px grid
    (labels in sprite pixels) for hand annotation."""
    tiles = []
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
        tiles.append(big)
    guide = Image.open(os.path.join(out, "openpose.png")).convert("RGB")
    shaded = Image.open(os.path.join(out, "shaded.png")).convert("RGB")
    tiles = [Image.blend(shaded, guide, 0.6)] + tiles
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
    if not (cfg.get("reuse_fit") and os.path.exists(os.path.join(out, "pose.json"))):
        fit(cfg, out)
    guide = guide_image(out, cfg.get("guide", "openpose_hilt"))
    results, prompt = qwen(cfg, out, guide)
    px = {}
    for who, src in results.items():
        px[who] = pixel(out, who, src, cfg.get("bg_tol", 40), cfg.get("steel", True))[1]
    annotate_sheet(out)
    with open(os.path.join(out, "run.json"), "w") as fh:
        json.dump({"prompt": prompt, "guide": os.path.basename(guide), "pixel": px}, fh, indent=1)
    print("done:", out)


# ---------------------------------------------------------------- finish
def load_kp(out, who):
    j = os.path.join(out, who + "_kp.json")
    if os.path.exists(j):
        return ps.load(j)
    t = os.path.join(out, who + "_kp.txt")
    if os.path.exists(t):
        pose = ps.parse_points(open(t).read(), 64, 64)
        with open(j, "w") as fh:
            json.dump(pose.to_json(), fh)
        return pose
    return None


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
    tgt = ps.load(os.path.join(out, "target_right.json"))
    tiles.append(("reference skeleton", skeleton_tile(tgt)))
    tiles.append(("rig (shaded)", Image.open(os.path.join(out, "shaded.png")).convert("RGB").resize((TILE, TILE))))
    tiles.append(("rig skeleton (guide)", Image.open(os.path.join(out, "openpose.png")).convert("RGB").resize((TILE, TILE))))
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
    lines = ["ref -> rig", "  limb %.1f deg  joint %.2f" % (s["rig"]["limb"], s["rig"]["joint"])]
    if s["rig"].get("sword") is not None:
        lines.append("  sword %.1f deg" % s["rig"]["sword"])
    for who in MASTERS:
        r = s.get(who)
        lines.append("rig -> %s" % who)
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


def cmd_finish(out, notes_path=None):
    cfg = json.load(open(os.path.join(out, "round.json")))
    fitr = json.load(open(os.path.join(out, "fit.json")))
    run = json.load(open(os.path.join(out, "run.json")))
    rig = ps.load(os.path.join(out, "openpose.json"))
    scores = {"rig": {k: fitr["score"][k] for k in ("joint", "limb", "sword", "worst", "limbs")}}
    for who in MASTERS:
        kp = load_kp(out, who)
        scores[who] = ps.score(rig, kp) if kp else None
    rec = {"round": cfg["round"], "pose": cfg["pose"], "attempt": cfg.get("attempt", 1),
           "intent": cfg.get("intent"), "spec": cfg.get("spec", {}), "init": cfg.get("init"),
           "fit_azimuth": cfg.get("fit_azimuth", -45), "guide": run["guide"], "prompt": run["prompt"],
           "fit": {k: fitr[k] for k in ("objective", "evals", "seconds", "terms")},
           "fit_view_score": {k: fitr.get("fit_view_score", {}).get(k) for k in ("joint", "limb", "sword")},
           "scores": scores, "pixel": run["pixel"]}
    if notes_path:
        rec.update(json.load(open(notes_path)))
    elif os.path.exists(os.path.join(out, "notes.json")):
        rec.update(json.load(open(os.path.join(out, "notes.json"))))
    contact_sheet(out, rec)
    with open(os.path.join(out, "record.json"), "w") as fh:
        json.dump(rec, fh, indent=1)
    s = scores
    print("ref->rig %s | male %s | female %s" % (
        ps.fmt(fitr["score"]), ps.fmt(s["male"]) if s["male"] else "-", ps.fmt(s["female"]) if s["female"] else "-"))
    cmd_gallery(cfg["work"])


# ---------------------------------------------------------------- gallery
def records(work):
    base = os.path.join(work, "rounds")
    out = []
    for d in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        p = os.path.join(base, d, "record.json")
        if os.path.exists(p):
            out.append(json.load(open(p)))
    return out


def cmd_gallery(work):
    recs = records(work)
    rows = []
    for r in sorted(recs, key=lambda r: -r["round"]):
        s = r["scores"]
        cell = lambda k: ("%.1f&deg;" % s[k]["limb"]) if s.get(k) else "-"  # noqa: E731
        sw = s["rig"].get("sword")
        rows.append(
            '<section><h2>Round %d &middot; %s <small>attempt %d</small></h2>'
            '<p class="scores">ref&rarr;rig limb <b>%.1f&deg;</b> joint %.2f%s &middot; rig&rarr;male <b>%s</b>'
            ' &middot; rig&rarr;female <b>%s</b></p>'
            '<img src="rounds/r%03d/sheet.png" alt="round %d">'
            '<p><b>Intent:</b> %s</p><p><b>Notes:</b> %s</p><p><b>Next:</b> %s</p></section>' % (
                r["round"], html.escape(r["pose"]), r.get("attempt", 1), s["rig"]["limb"], s["rig"]["joint"],
                (" sword %.0f&deg;" % sw) if sw is not None else "", cell("male"), cell("female"),
                r["round"], r["round"], html.escape(r.get("intent") or ""), html.escape(r.get("notes", "")),
                html.escape(r.get("change", ""))))
    trend = trend_table(recs)
    page = """<!doctype html><html><head><meta charset="utf-8"><title>Pose practice</title>
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
</body></html>""" % (trend, "\n".join(rows))
    with open(os.path.join(work, "gallery.html"), "w", encoding="utf-8") as fh:
        fh.write(page)


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
    ap.add_argument("cmd", choices=("run", "finish", "gallery", "batch"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--notes")
    a = ap.parse_args()
    if a.cmd == "run":
        cmd_run(a.args[0])
    elif a.cmd == "finish":
        cmd_finish(a.args[0], a.notes)
    elif a.cmd == "gallery":
        cmd_gallery(a.args[0])
    else:
        cmd_batch(a.args[0], int(a.args[1]), int(a.args[2]), a.args[3])


if __name__ == "__main__":
    main()

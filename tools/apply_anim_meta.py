"""Applies exported animation meta to a unit's SpriteFrames (.tres): per-frame durations and named events.

    python tools/apply_anim_meta.py UNIT_ID META_DIR [--dry-run]

META_DIR holds one <anim>_meta.json per animation. Keys used:
  durations_ms  [ms per frame]   each frame's relative duration in SpriteFrames becomes
                                 ms / (1000 / speed), with the animation's fps (speed) as the base rate,
                                 so the frame lasts exactly ms milliseconds. A missing list, or a frame
                                 without an entry, keeps 1.0 (older assets are unchanged).
  events        {name: frame}    named event frames ("impact", "release", ...). Written to the SpriteFrames
                                 metadata "events" as {anim: {name: frame}}; the game reads impact and
                                 release timing from there before its older per-kind metadata, so frame
                                 counts can change without touching any code.
Animations without a meta file are left as they are. Run again after re-exporting; it is idempotent.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRES_DIR = os.path.join(ROOT, "godot-project", "sprites", "units")

ANIM_RE = re.compile(r'\{"frames": \[(.*?)\], "loop": (\w+), "name": &"(\w+)", "speed": ([\d.]+)\}')
FRAME_RE = re.compile(r'\{"duration": [\d.eE+-]+, ("texture": ExtResource\("\d+"\)\})')


def _gd(v):
    if isinstance(v, dict):
        return "{" + ", ".join('"%s": %s' % (k, _gd(x)) for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_gd(x) for x in v) + "]"
    if isinstance(v, bool):
        return "true" if v else "false"
    return repr(float(v)) if isinstance(v, float) else str(v)


def apply(text, metas):
    """Returns (new .tres text, report lines)."""
    report = []
    events = {}

    def anim_sub(m):
        frames, loop, name, speed = m.group(1), m.group(2), m.group(3), float(m.group(4))
        meta = metas.get(name)
        if meta is None:
            return m.group(0)
        durs = meta.get("durations_ms") or []
        idx = [0]

        def frame_sub(fm):
            i = idx[0]
            idx[0] += 1
            d = 1.0
            if i < len(durs) and durs[i] is not None:
                d = round(float(durs[i]) / (1000.0 / speed), 4)
            return '{"duration": %s, %s' % (repr(float(d)), fm.group(1))

        new_frames = FRAME_RE.sub(frame_sub, frames)
        n = idx[0]
        if durs and len(durs) != n:
            report.append("%s: %d durations for %d frames" % (name, len(durs), n))
        if meta.get("events"):
            events[name] = {k: int(v) for k, v in meta["events"].items()}
            for k, v in events[name].items():
                if not 0 <= v < n:
                    report.append("%s: event %s at frame %d is outside 0..%d" % (name, k, v, n - 1))
        report.append("%s: %d frames, speed %s%s" % (name, n, speed, ", durations applied" if durs else ""))
        return '{"frames": [%s], "loop": %s, "name": &"%s", "speed": %s}' % (new_frames, loop, name, m.group(4))

    out = ANIM_RE.sub(anim_sub, text)
    lines = [l for l in out.split("\n") if not l.startswith("metadata/events = ")]
    if events:
        # keep the events of animations this run doesn't mention
        old = re.search(r"^metadata/events = (.*)$", out, re.M)
        merged = {}
        if old:
            try:
                merged = json.loads(old.group(1).replace("&", ""))
            except ValueError:
                merged = {}
        merged.update(events)
        ev_line = "metadata/events = " + _gd(merged)
        pos = max(i for i, l in enumerate(lines) if l.startswith("metadata/")) + 1 if any(l.startswith("metadata/") for l in lines) else len(lines)
        lines.insert(pos, ev_line)
    return "\n".join(lines), report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("unit_id")
    ap.add_argument("meta_dir")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--tres", help="a .tres to patch instead of the unit's own (tests)")
    a = ap.parse_args()
    metas = {}
    for f in sorted(os.listdir(a.meta_dir)):
        if f.endswith("_meta.json"):
            with open(os.path.join(a.meta_dir, f), encoding="utf-8") as fh:
                metas[f[:-len("_meta.json")]] = json.load(fh)
    if not metas:
        sys.exit("no <anim>_meta.json files in " + a.meta_dir)
    path = a.tres or os.path.join(TRES_DIR, a.unit_id + ".tres")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    new, report = apply(text, metas)
    for r in report:
        print(r)
    missing = [k for k in metas if k not in {r.split(":")[0] for r in report}]
    if missing:
        print("not in the SpriteFrames (skipped): " + ", ".join(missing))
    if a.dry_run:
        print("dry run: nothing written")
        return
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(new)
    print("wrote " + path)


if __name__ == "__main__":
    main()

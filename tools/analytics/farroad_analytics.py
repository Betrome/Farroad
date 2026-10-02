"""Farroad gameplay stats: pulls the daily reports from the Google Sheet and
builds a dashboard page (report.html).

    python tools/analytics/farroad_analytics.py            # fetch new rows, build report
    python tools/analytics/farroad_analytics.py --no-fetch # rebuild from the local copy
    python tools/analytics/farroad_analytics.py --from-file reports.jsonl

The Sheet's web app URL and read key come from environment variables
FARROAD_ANALYTICS_URL / FARROAD_ANALYTICS_KEY, or from tools/analytics/.env
(KEY=value lines). Neither goes in the repo. Rows are cached in
tools/analytics/data/ so each run only downloads what's new.
"""
import argparse
import csv
import html
import json
import os
import statistics
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
CACHE = os.path.join(DATA_DIR, "reports.jsonl")
CURSOR = os.path.join(DATA_DIR, "cursor.txt")
CONTENT = os.path.join(HERE, "..", "..", "godot-project", "data", "content.json")
CONDS = os.path.join(HERE, "..", "..", "farroadgambitconditions.csv")


# ---------- fetching ----------

def load_env():
    env = {}
    path = os.path.join(HERE, ".env")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    url = os.environ.get("FARROAD_ANALYTICS_URL") or env.get("FARROAD_ANALYTICS_URL")
    key = os.environ.get("FARROAD_ANALYTICS_KEY") or env.get("FARROAD_ANALYTICS_KEY")
    return url, key


def fetch(url, key):
    os.makedirs(DATA_DIR, exist_ok=True)
    after = int(open(CURSOR).read().strip()) if os.path.exists(CURSOR) else 1
    added = 0
    while True:
        q = urllib.parse.urlencode({"key": key, "after": after})
        with urllib.request.urlopen(f"{url}?{q}", timeout=60) as r:
            data = json.loads(r.read().decode("utf-8"))
        if not data.get("ok"):
            sys.exit(f"Sheet refused the request: {data.get('error')}")
        with open(CACHE, "a", encoding="utf-8") as f:
            for row in data["rows"]:
                f.write(json.dumps(row) + "\n")
                added += 1
        after = data["last"]
        with open(CURSOR, "w") as f:
            f.write(str(after))
        if not data.get("more"):
            break
    print(f"Fetched {added} new report(s).")


def load_reports(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        rep = row.get("report", row)
        if isinstance(rep, str):
            try:
                rep = json.loads(rep)
            except json.JSONDecodeError:
                continue
        if isinstance(rep, dict) and rep.get("schema") == 1:
            out.append(rep)
    return out


# ---------- aggregation ----------

def names():
    try:
        c = json.load(open(CONTENT, encoding="utf-8"))
    except OSError:
        return {}, {}
    acts = {k: v.get("name", k) for k, v in c.get("ACTIONS", {}).items()}
    units = {u["id"]: u.get("name", u["id"]) for u in c.get("ROSTER", [])}
    return acts, units


def cond_names():
    try:
        return {r["id"]: r["label"] for r in csv.DictReader(open(CONDS, encoding="utf-8"))}
    except (OSError, KeyError):
        return {}


def merge_counters(reports):
    total = defaultdict(Counter)
    for r in reports:
        for group, vals in r.get("counters", {}).items():
            if group == "waves":
                continue
            for k, v in vals.items():
                total[group][k] += v
    return total


def players_with(reports, group):
    """How many players have each key in a counter group at least once."""
    seen = defaultdict(set)
    for r in reports:
        for k in r.get("counters", {}).get(group, {}):
            seen[k].add(r["id"])
    return Counter({k: len(v) for k, v in seen.items()})


def analyse(reports):
    acts, units = names()
    a = {"acts": acts, "units": units, "conds": cond_names()}
    ids = {r["id"] for r in reports}
    latest = {}
    for r in sorted(reports, key=lambda r: r.get("to", 0)):
        latest[r["id"]] = r
    snaps = [r["snapshot"] for r in latest.values()]
    c = merge_counters(reports)
    a["n_players"] = len(ids)
    a["n_reports"] = len(reports)
    a["versions"] = Counter(r.get("version", "?") for r in latest.values())
    a["platforms"] = Counter(r.get("platform", "?") for r in latest.values())
    days = defaultdict(set)
    for r in reports:
        d = datetime.fromtimestamp(r.get("to", 0), timezone.utc).strftime("%Y-%m-%d")
        days[d].add(r["id"])
    a["daily"] = sorted((d, len(p)) for d, p in days.items())
    a["minutes"] = c["session"].get("minutes", 0)
    a["fast_minutes"] = c["session"].get("minutesFast", 0)
    a["sessions"] = c["session"].get("starts", 0)
    a["offline"] = c["offline"]
    a["farthest"] = [s.get("farthest", 1) for s in snaps]
    a["power"] = [s.get("power", 0) for s in snaps]

    # Units: fielded share (wave clears they were in), owned rate, levels.
    a["party_waves"] = c["partyWaves"]
    a["unit_turns"] = c["unitTurns"]
    owned = Counter()
    levels = defaultdict(list)
    fielded = Counter()
    for s in snaps:
        for uid, u in s.get("units", {}).items():
            owned[uid] += 1
            levels[uid].append(u.get("lvl", 1))
        for uid in s.get("party", []):
            fielded[uid] += 1
    a["owned"], a["levels"], a["fielded"] = owned, levels, fielded

    # Actions and gambits: use in fights and how many players have them equipped.
    a["action_use"] = c["actionUse"]
    a["action_dmg"] = c["damageByAction"]
    equipped_by = Counter()
    cond_equipped = Counter()
    for s in snaps:
        acts_here, conds_here = set(), set()
        for u in s.get("units", {}).values():
            for cond, act in u.get("loadout", []):
                acts_here.add(act)
                conds_here.add(cond)
        equipped_by.update(acts_here)
        cond_equipped.update(conds_here)
    a["action_equipped"], a["cond_equipped"] = equipped_by, cond_equipped
    a["cond_fired"] = c["condFired"]
    a["use_by_ctx"] = {k[len("actionUse_"):]: v for k, v in c.items() if k.startswith("actionUse_")}

    # Spending.
    a["spend"] = c["spend"]
    a["aether_by_unit"] = c["aetherByUnit"]
    a["affinity_buys"] = c["affinityBuys"]
    a["lore_bonus"] = c["loreBonus"]
    a["lore_action"] = c["loreAction"]
    a["pulls"] = c["pulls"]
    a["shop"] = c["shop"]
    a["mc_charge"] = Counter(s.get("mcCharge") for s in snaps if s.get("mcCharge"))
    lore_levels = Counter()
    for s in snaps:
        for aid, b in s.get("bonuses", {}).items():
            lore_levels[aid] += sum(v for v in b.values() if isinstance(v, (int, float)))
    a["lore_levels"] = lore_levels

    # Quests, dungeons, Arena (sideBattles keys look like "quest_cleared:uid#2").
    side = Counter()
    by_kind = defaultdict(Counter)
    for k, v in c["sideBattles"].items():
        kind = k.split(":", 1)[0]
        side[kind] += v
        target = k.split(":", 1)[1] if ":" in k else "?"
        by_kind[kind][target] += v
    a["side"], a["side_detail"] = side, by_kind
    a["side_seconds"] = c["sideBattleSeconds"]
    quest_stage = Counter()
    for s in snaps:
        for uid, st in s.get("quests", {}).items():
            quest_stage[st] += 1
    a["quest_stage"] = quest_stage
    a["quest_players"] = len({r["id"] for r in reports if any(k.startswith("quest") for k in r["counters"].get("sideBattles", {}))})
    a["dungeon_players"] = len({r["id"] for r in reports if any(k.startswith("dungeon") for k in r["counters"].get("sideBattles", {}))})
    a["pvp_players"] = len({r["id"] for r in reports if any(k.startswith("pvp") for k in r["counters"].get("sideBattles", {}))})

    # Expeditions.
    a["expedition"] = c["expedition"]
    a["expedition_units"] = c["expeditionUnits"]
    a["expedition_depths"] = c["expeditionDepths"]
    a["expedition_players"] = len({r["id"] for r in reports
                                   if any(k.startswith("sent:") for k in r["counters"].get("expedition", {}))})

    # Waves: time, clears, wipes, summed over players.
    waves = defaultdict(lambda: [0.0, 0, 0, set()])
    for r in reports:
        for w, (secs, clears, wipes) in r.get("counters", {}).get("waves", {}).items():
            row = waves[int(w)]
            row[0] += secs
            row[1] += clears
            row[2] += wipes
            row[3].add(r["id"])
    a["waves"] = waves

    a["tutorials"] = c["tutorials"]
    a["features"] = c["features"]
    return a


# ---------- report page ----------

CSS = """
:root{--bg:#f7f4ee;--card:#fff;--ink:#2b2620;--dim:#7a7066;--bar:#c8963e;--bar2:#8a5a2b;--line:#e6dfd3}
@media (prefers-color-scheme:dark){:root{--bg:#1d1a17;--card:#26221e;--ink:#eee6da;--dim:#a69b8d;--bar:#d6a24e;--bar2:#b07a43;--line:#3a342d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,Segoe UI,sans-serif}
main{max-width:1100px;margin:0 auto;padding:20px 16px 60px}h1{margin:0 0 4px;font-size:26px}h2{margin:28px 0 10px;font-size:19px}
.sub{color:var(--dim);margin-bottom:16px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;overflow:hidden}
.card h3{margin:0 0 8px;font-size:15px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}.kpi b{display:block;font-size:22px}.kpi span{color:var(--dim)}
table{width:100%;border-collapse:collapse}td,th{padding:3px 6px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}
th{color:var(--dim);font-weight:600;font-size:12px}td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.bar{height:10px;background:var(--bar);border-radius:3px;min-width:2px}.bar.b2{background:var(--bar2)}td.bc{width:38%}
.note{color:var(--dim);font-size:12px;margin-top:6px}
"""


def esc(x):
    return html.escape(str(x))


def fmt(v):
    if isinstance(v, float):
        return f"{v:,.0f}" if abs(v) >= 100 else f"{v:,.1f}".rstrip("0").rstrip(".")
    return f"{v:,}" if isinstance(v, int) else esc(v)


def bar_table(title, rows, cols=("", "Count"), note="", limit=25, extra=None):
    """rows: list of (label, value[, extra cells...]) sorted already."""
    rows = rows[:limit]
    if not rows:
        return f'<div class="card"><h3>{esc(title)}</h3><div class="note">No data yet.</div></div>'
    top = max((r[1] for r in rows), default=1) or 1
    head = "".join(f"<th>{esc(c)}</th>" for c in cols) + "<th></th>"
    body = ""
    for r in rows:
        cells = f"<td>{esc(r[0])}</td><td class='n'>{fmt(r[1])}</td>"
        for x in r[2:]:
            cells += f"<td class='n'>{fmt(x)}</td>"
        body += f"<tr>{cells}<td class='bc'><div class='bar' style='width:{100 * r[1] / top:.1f}%'></div></td></tr>"
    n = f'<div class="note">{esc(note)}</div>' if note else ""
    return f'<div class="card"><h3>{esc(title)}</h3><table><tr>{head}</tr>{body}</table>{n}</div>'


def ranked(counter, label=lambda k: k):
    return [(label(k), v) for k, v in counter.most_common()]


def build_html(a):
    act = lambda k: a["acts"].get(k, k)
    unit = lambda k: a["units"].get(k, k)
    cond = lambda k: a["conds"].get(k, k)
    np = max(1, a["n_players"])
    P = []
    P.append(f"<h1>Farroad gameplay stats</h1><div class='sub'>{a['n_players']} players · {a['n_reports']} daily reports · built {datetime.now():%Y-%m-%d %H:%M}</div>")
    med = lambda xs: statistics.median(xs) if xs else 0
    hours = a["minutes"] / 60
    P.append("<div class='kpis'>" + "".join(f"<div class='kpi'><b>{v}</b><span>{esc(k)}</span></div>" for k, v in [
        ("players", a["n_players"]), ("hours played", fmt(hours)), ("sessions", fmt(a["sessions"])),
        ("median farthest wave", fmt(med(a["farthest"]))), ("median party Power", fmt(med(a["power"]))),
        ("time at 2x speed", f"{100 * a['fast_minutes'] / max(1, a['minutes']):.0f}%"),
    ]) + "</div>")

    P.append("<h2>Players</h2><div class='grid'>")
    P.append(bar_table("Active players per day", list(reversed(a["daily"]))[:30], ("Day", "Players")))
    buckets = Counter()
    for f in a["farthest"]:
        b = (f - 1) // 20 * 20 + 1
        buckets[b] += 1
    P.append(bar_table("How far players have got (farthest wave)", [(f"{b}-{b + 19}", buckets[b]) for b in sorted(buckets)], ("Waves", "Players"), limit=60))
    P.append(bar_table("Versions", ranked(a["versions"]), ("Version", "Players")))
    P.append(bar_table("Platforms", ranked(a["platforms"]), ("Platform", "Players")))
    off = a["offline"]
    P.append(bar_table("Coming back after time away", [("returns", off.get("returns", 0)),
        ("hours away (total)", off.get("seconds", 0) / 3600), ("waves gained while away", off.get("waveGain", 0))], ("", "Total")))
    P.append("</div>")

    P.append("<h2>Units</h2><div class='grid'>")
    pw_total = sum(a["party_waves"].values()) or 1
    rows = [(unit(k), v, f"{100 * v / pw_total:.0f}%", a["owned"].get(k, 0)) for k, v in a["party_waves"].most_common()]
    P.append(bar_table("Wave clears each unit fought in", rows, ("Unit", "Clears", "Share", "Owners")))
    rows = [(unit(k), a["fielded"].get(k, 0), f"{100 * a['fielded'].get(k, 0) / max(1, a['owned'][k]):.0f}%",
             f"{med(a['levels'][k]):.0f}") for k in sorted(a["owned"], key=lambda k: -a["fielded"].get(k, 0))]
    P.append(bar_table("Fielded right now (of players who own it)", rows, ("Unit", "Fielded", "Of owners", "Median lvl")))
    P.append(bar_table("Main character's charge action", ranked(a["mc_charge"], act), ("Action", "Players")))
    P.append("</div>")

    P.append("<h2>Actions</h2><div class='grid'>")
    rows = [(act(k), v, f"{a['action_dmg'].get(k, 0) / max(1, v):.0f}", a["action_equipped"].get(k, 0))
            for k, v in a["action_use"].most_common()]
    P.append(bar_table("Most used in fights", rows, ("Action", "Uses", "Dmg/use", "Equipped by"), limit=40))
    rows = [(act(k), v, f"{100 * v / np:.0f}%") for k, v in a["action_equipped"].most_common()]
    P.append(bar_table("Equipped (players with it in a loadout)", rows, ("Action", "Players", "Share"), limit=40))
    for ctx, cnt in sorted(a["use_by_ctx"].items()):
        if ctx != "road":
            P.append(bar_table(f"Used in {ctx} fights", ranked(cnt, act), ("Action", "Uses"), limit=15))
    P.append("</div>")

    P.append("<h2>Gambits</h2><div class='grid'>")
    P.append(bar_table("Equipped conditions", [(cond(k), v, f"{100 * v / np:.0f}%") for k, v in a["cond_equipped"].most_common()],
                       ("Condition", "Players", "Share"), limit=40))
    P.append(bar_table("Conditions that fired in fights", ranked(a["cond_fired"], cond), ("Condition", "Times"), limit=40,
                       note="A condition that's equipped a lot but rarely fires may be too strict."))
    P.append("</div>")

    P.append("<h2>Spending</h2><div class='grid'>")
    P.append(bar_table("Aether, Marks and Crystal spent on", ranked(a["spend"]), ("Spent on", "Amount")))
    P.append(bar_table("Aether spent per unit", ranked(a["aether_by_unit"], unit), ("Unit", "Aether")))
    P.append(bar_table("Affinities bought", ranked(a["affinity_buys"]), ("Affinity", "Points")))
    P.append(bar_table("Lore upgrades bought (by upgrade)", ranked(a["lore_bonus"]), ("Upgrade", "Bought")))
    P.append(bar_table("Lore upgrades bought (by action)", ranked(a["lore_action"], act), ("Action", "Bought"), limit=30))
    P.append(bar_table("Lore levels held right now", ranked(a["lore_levels"], act), ("Action", "Levels"), limit=30))
    P.append(bar_table("Marks pulls", ranked(a["pulls"]), ("Result", "Pulls")))
    P.append(bar_table("Shop purchases", ranked(a["shop"], lambda k: k.split(":", 1)[0] + ": " + act(k.split(":", 1)[-1]) if k.startswith("action:") else k), ("Item", "Bought"), limit=30))
    P.append("</div>")

    P.append("<h2>Quests, dungeons and the Arena</h2><div class='grid'>")
    P.append(bar_table("Players who tried each", [("Quests", a["quest_players"], f"{100 * a['quest_players'] / np:.0f}%"),
        ("Dungeons", a["dungeon_players"], f"{100 * a['dungeon_players'] / np:.0f}%"),
        ("Arena", a["pvp_players"], f"{100 * a['pvp_players'] / np:.0f}%"),
        ("Expeditions", a["expedition_players"], f"{100 * a['expedition_players'] / np:.0f}%")], ("", "Players", "Share")))
    P.append(bar_table("Results", ranked(a["side"]), ("Result", "Fights")))
    ss = a["side_seconds"]
    P.append(bar_table("Average fight length (seconds)", [(k, ss[k] / max(1, sum(v for kk, v in a["side"].items() if kk.startswith(k))))
        for k in ss], ("Kind", "Seconds")))
    P.append(bar_table("Quest stages reached (per owned unit)", [(f"stage {k}", v) for k, v in sorted(a["quest_stage"].items())], ("Stage", "Units")))
    for kind in ("quest_failed", "quest_abandoned", "dungeon_failed", "pvp_lost", "pvp_won"):
        if a["side_detail"].get(kind):
            P.append(bar_table(kind.replace("_", " ").capitalize(), ranked(a["side_detail"][kind], lambda k: unit(k.split("#")[0]) + (" #" + k.split("#")[1] if "#" in k else "")), ("Where", "Times"), limit=15))
    P.append("</div>")

    P.append("<h2>Expeditions</h2><div class='grid'>")
    e = a["expedition"]
    P.append(bar_table("Directions sent", [(k[5:], v) for k, v in e.most_common() if k.startswith("sent:")], ("Direction", "Sent")))
    P.append(bar_table("Party size", [(k[5:], v) for k, v in sorted(e.items()) if k.startswith("size:")], ("Units", "Sent")))
    P.append(bar_table("Outcomes", [(k, v) for k, v in e.most_common() if ":" not in k], ("", "Total")))
    P.append(bar_table("Depth reached when collected", [(f"wave {k}+", v) for k, v in sorted(a["expedition_depths"].items(), key=lambda kv: int(kv[0]))], ("Depth", "Expeditions")))
    P.append(bar_table("Units sent most", ranked(a["expedition_units"], unit), ("Unit", "Times")))
    P.append("</div>")

    P.append("<h2>Waves</h2><div class='grid'>")
    rows = []
    for w in sorted(a["waves"]):
        secs, clears, wipes, ids = a["waves"][w]
        tries = clears + wipes
        rows.append((f"wave {w}", secs / max(1, tries), clears, wipes, f"{100 * wipes / max(1, tries):.0f}%", len(ids)))
    hard = sorted(rows, key=lambda r: -r[3])[:25]
    P.append(bar_table("Hardest waves (most wipes)", [(r[0], r[3], r[2], r[4], r[5]) for r in hard], ("Wave", "Wipes", "Clears", "Wipe rate", "Players")))
    slow = sorted(rows, key=lambda r: -r[1])[:25]
    P.append(bar_table("Slowest waves (avg seconds per attempt)", [(r[0], r[1], r[2] + r[3]) for r in slow], ("Wave", "Seconds", "Attempts")))
    buckets = defaultdict(lambda: [0.0, 0])
    for w in a["waves"]:
        secs, clears, wipes, _ = a["waves"][w]
        b = (w - 1) // 10 * 10 + 1
        buckets[b][0] += secs
        buckets[b][1] += clears + wipes
    P.append(bar_table("Average seconds per wave, by 10s", [(f"{b}-{b + 9}", s / max(1, n)) for b, (s, n) in sorted(buckets.items())], ("Waves", "Seconds"), limit=200))
    P.append("</div>")

    P.append("<h2>Tutorials and features</h2><div class='grid'>")
    tut = defaultdict(lambda: [0, 0])
    for k, v in a["tutorials"].items():
        tid, how = k.rsplit(":", 1)
        tut[tid][0 if how == "done" else 1] += v
    P.append(bar_table("Tutorials", [(k, v[0], v[1], f"{100 * v[1] / max(1, sum(v)):.0f}%") for k, v in sorted(tut.items(), key=lambda kv: -sum(kv[1]))], ("Tutorial", "Done", "Skipped", "Skip rate")))
    P.append(bar_table("Features used", ranked(a["features"]), ("Feature", "Times")))
    P.append("</div>")
    return f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Farroad Stats</title><style>{CSS}</style></head><body><main>{''.join(P)}</main></body></html>"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-fetch", action="store_true", help="don't download, just rebuild from the local copy")
    ap.add_argument("--from-file", help="read reports from this JSONL file instead of the cache")
    ap.add_argument("--out", default=os.path.join(HERE, "report.html"))
    args = ap.parse_args()
    src = args.from_file or CACHE
    if not args.from_file and not args.no_fetch:
        url, key = load_env()
        if not url or not key:
            sys.exit("Set FARROAD_ANALYTICS_URL and FARROAD_ANALYTICS_KEY (or tools/analytics/.env), or use --no-fetch / --from-file.")
        fetch(url, key)
    reports = load_reports(src)
    if not reports:
        sys.exit("No reports to read yet.")
    a = analyse(reports)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(build_html(a))
    print(f"{len(reports)} reports from {a['n_players']} players -> {args.out}")


if __name__ == "__main__":
    main()

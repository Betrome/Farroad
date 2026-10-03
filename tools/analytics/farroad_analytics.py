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
        if isinstance(rep, dict) and rep.get("schema") == 1 and not str(rep.get("id", "")).startswith("test"):
            out.append(rep)   # ids starting "test" are setup checks, not players
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
            if not isinstance(vals, dict) or group in ("waves", "fightsSeen"):
                continue   # fight records / wave rows are read separately
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


def day_of(r):
    return datetime.fromtimestamp(r.get("to", 0), timezone.utc).strftime("%Y-%m-%d")


# Lore upgrade names as the game shows them.
BONUS_NAMES = {"swift": "Swift", "potent": "Potent", "lasting": "Lasting", "deepening": "Deepening",
               "surge": "Surge", "piercing": "Piercing", "broad": "Broad", "cleansing": "Cleansing",
               "thrifty": "Thrifty", "weighty": "Weighty"}
AFFINITY_NAMES = {"fire": "Fire", "water": "Water", "earth": "Earth", "air": "Air", "light": "Light",
                  "dark": "Dark", "body": "Body", "spirit": "Spirit"}
STAT_NAMES = {"evade": "Evade", "atkCrit": "ATK crit", "magCrit": "MAG crit"}
CTX_NAMES = {"road": "Road", "quest": "Quests", "dungeon": "Dungeons", "pvp": "Arena"}
# A win rate needs this many fights before it's ranked (fewer is noise).
MIN_FIGHTS = 20


def spend_label(k):
    parts = k.split(":")
    cur = parts[0].capitalize()
    if parts[0] == "aether":
        if len(parts) == 3 and parts[1] == "affinity":
            return f"Aether: {AFFINITY_NAMES.get(parts[2], parts[2])} affinity"
        if len(parts) == 3 and parts[1] == "stat":
            return f"Aether: {STAT_NAMES.get(parts[2], parts[2])}"
        return {"level": "Aether: levels", "recovery": "Aether: recovery",
                "affinity": "Aether: affinity (older reports)"}.get(parts[1], f"Aether: {parts[1]}")
    return f"{cur}: {parts[1] if len(parts) > 1 else ''}"


def win_table(c, kind, ctx=None):
    """Per action/unit: fights won and lost with it, win rate, and how far
    that sits from the average fight. kind is 'Actions' or 'Units'."""
    if ctx:
        w, l = c[f"fight{kind}_{ctx}_win"], c[f"fight{kind}_{ctx}_loss"]
        tw, tl = c["fights"].get(f"{ctx}:win", 0), c["fights"].get(f"{ctx}:loss", 0)
    else:
        w, l = c[f"fight{kind}_win"], c[f"fight{kind}_loss"]
        tw = sum(v for k, v in c["fights"].items() if k.endswith(":win"))
        tl = sum(v for k, v in c["fights"].items() if k.endswith(":loss"))
    base = tw / (tw + tl) if tw + tl else 0
    rows = {}
    for k in set(w) | set(l):
        n = w[k] + l[k]
        rows[k] = (w[k], l[k], n, (w[k] / n) if n else 0, ((w[k] / n) - base) if n else 0)
    return rows, base, tw + tl


def analyse(reports):
    acts, units = names()
    a = {"acts": acts, "units": units, "conds": cond_names()}
    ids = {r["id"] for r in reports}
    latest = {}
    for r in sorted(reports, key=lambda r: r.get("to", 0)):
        latest[r["id"]] = r
    snaps = [r["snapshot"] for r in latest.values()]
    c = merge_counters(reports)
    a["c"] = c
    a["n_players"] = len(ids)
    a["n_reports"] = len(reports)
    a["versions"] = Counter(r.get("version", "?") for r in latest.values())
    a["platforms"] = Counter(r.get("platform", "?") for r in latest.values())

    # Per day: the counters merged for that day's reports, and who reported.
    by_day = defaultdict(list)
    for r in reports:
        by_day[day_of(r)].append(r)
    a["days"] = sorted(by_day)
    a["day_c"] = {d: merge_counters(rs) for d, rs in by_day.items()}
    a["day_players"] = {d: len({r["id"] for r in rs}) for d, rs in by_day.items()}
    a["day_farthest"] = {d: statistics.median([r["snapshot"].get("farthest", 1) for r in rs]) for d, rs in by_day.items()}
    a["day_lore"] = {d: Counter() for d in by_day}
    for d, rs in by_day.items():
        for r in rs:
            a["day_lore"][d].update(r.get("counters", {}).get("loreBuys", {}))

    a["minutes"] = c["session"].get("minutes", 0)
    a["fast_minutes"] = c["session"].get("minutesFast", 0)
    a["sessions"] = c["session"].get("starts", 0)
    a["offline"] = c["offline"]
    a["farthest"] = [s.get("farthest", 1) for s in snaps]
    a["power"] = [s.get("power", 0) for s in snaps]

    # Units, from the latest snapshot per player.
    owned, fielded = Counter(), Counter()
    levels = defaultdict(list)
    unit_aff = defaultdict(Counter)       # uid -> axis -> total points held
    unit_pct = defaultdict(Counter)       # uid -> stat -> total steps held
    unit_actions = defaultdict(Counter)   # uid -> action -> players with it in the loadout
    unit_conds = defaultdict(Counter)
    unit_gear = defaultdict(Counter)
    action_units = defaultdict(Counter)   # action -> uid
    action_conds = defaultdict(Counter)   # action -> condition paired with it
    action_equipped, cond_equipped = Counter(), Counter()
    lore_held = defaultdict(Counter)      # action -> upgrade -> total levels held
    lore_holders = defaultdict(Counter)   # action -> upgrade -> players holding any
    for s in snaps:
        acts_here, conds_here = set(), set()
        for uid in s.get("party", []):
            fielded[uid] += 1
        for uid, u in s.get("units", {}).items():
            owned[uid] += 1
            levels[uid].append(u.get("lvl", 1))
            unit_aff[uid].update({k: v for k, v in u.get("aff", {}).items()})
            unit_pct[uid].update({k: v for k, v in u.get("pct", {}).items()})
            for gear in u.get("equip", {}).values():
                unit_gear[uid][gear] += 1
            for cond, act in u.get("loadout", []):
                unit_actions[uid][act] += 1
                unit_conds[uid][cond] += 1
                action_units[act][uid] += 1
                action_conds[act][cond] += 1
                acts_here.add(act)
                conds_here.add(cond)
        action_equipped.update(acts_here)
        cond_equipped.update(conds_here)
        for aid, b in s.get("bonuses", {}).items():
            for bid, lv in b.items():
                if isinstance(lv, (int, float)) and lv > 0:
                    lore_held[aid][bid] += lv
                    lore_holders[aid][bid] += 1
    a.update(owned=owned, fielded=fielded, levels=levels, unit_aff=unit_aff, unit_pct=unit_pct,
             unit_actions=unit_actions, unit_conds=unit_conds, unit_gear=unit_gear, action_units=action_units,
             action_conds=action_conds, action_equipped=action_equipped, cond_equipped=cond_equipped,
             lore_held=lore_held, lore_holders=lore_holders)
    a["mc_charge"] = Counter(s.get("mcCharge") for s in snaps if s.get("mcCharge"))
    lore_buys = defaultdict(Counter)
    for k, v in c["loreBuys"].items():
        aid, bid = k.rsplit(":", 1)
        lore_buys[aid][bid] += v
    a["lore_buys"] = lore_buys

    # Win contribution, overall and per kind of fight.
    a["win_actions"] = {ctx: win_table(c, "Actions", ctx) for ctx in [None, "road", "quest", "dungeon", "pvp"]}
    a["win_units"] = {ctx: win_table(c, "Units", ctx) for ctx in [None, "road", "quest", "dungeon", "pvp"]}

    # Quests and dungeons vs the Arena (sideBattles keys: "quest_cleared:uid#2").
    side = defaultdict(Counter)
    for k, v in c["sideBattles"].items():
        kind, _, target = k.partition(":")
        side[kind][target or "?"] += v
    a["side"] = side
    a["side_seconds"] = c["sideBattleSeconds"]
    a["quest_stage"] = Counter(st for s in snaps for st in s.get("quests", {}).values())
    def tried(prefix):
        return len({r["id"] for r in reports if any(k.startswith(prefix) for k in r["counters"].get("sideBattles", {}))})
    a["quest_players"], a["dungeon_players"], a["pvp_players"] = tried("quest"), tried("dungeon"), tried("pvp")
    a["expedition_players"] = len({r["id"] for r in reports
                                   if any(k.startswith("sent:") for k in r["counters"].get("expedition", {}))})
    a["pvp_record"] = [s.get("pvp", {}) for s in snaps]

    waves = defaultdict(lambda: [0.0, 0, 0, set()])
    for r in reports:
        for w, (secs, clears, wipes) in r.get("counters", {}).get("waves", {}).items():
            row = waves[int(w)]
            row[0] += secs
            row[1] += clears
            row[2] += wipes
            row[3].add(r["id"])
    a["waves"] = waves
    a["fx"] = analyse_fights(reports)
    return a


MIN_FIGHT_RECORDS = 10   # recorded fights needed before a row is ranked


def fight_records(reports):
    """Per-fight records with a weight: each pool is a sample of what the
    player fought, so a record counts for seen/kept fights."""
    out = []
    for r in reports:
        c = r.get("counters", {})
        seen = c.get("fightsSeen", {})
        for pool in ("fightsKey", "fightsRoad"):
            recs = c.get(pool) or []
            if not recs:
                continue
            w = max(1.0, seen.get(pool, len(recs)) / len(recs))
            for x in recs:
                if len(x) < 10:
                    continue
                ctx, key, won, turns, secs, fast, units, acts, enemies, fallen = x[:10]
                out.append({"ctx": ctx, "key": str(key), "won": bool(won), "turns": turns, "secs": secs,
                            "fast": bool(fast), "units": list(units), "acts": dict(acts), "enemies": list(enemies),
                            "fallen": list(fallen), "w": w, "player": r["id"]})
    return out


def bucket_of(f):
    try:
        w = int(f["key"])
    except ValueError:
        return None
    return (w - 1) // 10 * 10 + 1


class WL:
    """Weighted wins/losses plus the raw number of records behind them."""
    __slots__ = ("w", "l", "n")

    def __init__(self):
        self.w = self.l = 0.0
        self.n = 0

    def add(self, won, wt):
        self.n += 1
        if won:
            self.w += wt
        else:
            self.l += wt

    @property
    def rate(self):
        t = self.w + self.l
        return self.w / t if t else 0.0


def analyse_fights(reports):
    fs = fight_records(reports)
    fx = {"n": len(fs)}
    if not fs:
        return fx
    base = {}
    for ctx in ("road", "quest", "dungeon", "pvp"):
        t = WL()
        for f in fs:
            if f["ctx"] == ctx:
                t.add(f["won"], f["w"])
        base[ctx] = t
    fx["base"] = base

    # Clear speed: a Road win's turns against the median for wins in its
    # 10-wave band (turns, so 2x speed doesn't matter). <1 = quicker.
    band_turns = defaultdict(list)
    for f in fs:
        if f["ctx"] == "road" and f["won"] and bucket_of(f):
            band_turns[bucket_of(f)].append(f["turns"])
    band_med = {b: statistics.median(v) for b, v in band_turns.items()}
    for f in fs:
        b = bucket_of(f) if f["ctx"] == "road" else None
        f["speed"] = (f["turns"] / band_med[b]) if (f["won"] and b in band_med and band_med[b]) else None

    pairs_u, pairs_a = defaultdict(lambda: defaultdict(WL)), defaultdict(lambda: defaultdict(WL))
    enemy = defaultdict(lambda: defaultdict(WL))
    enemy_turns = defaultdict(list)
    enemy_fallen = defaultdict(Counter)
    unit_fall = defaultdict(lambda: [0.0, 0.0])            # uid -> [fell, fought]
    act_speed, unit_speed = defaultdict(list), defaultdict(list)
    act_enemy = defaultdict(lambda: defaultdict(WL))       # action -> enemy -> WL
    unit_partner = defaultdict(lambda: defaultdict(WL))    # uid -> partner -> WL
    stages = defaultdict(WL)
    stage_turns = defaultdict(list)
    stage_party = defaultdict(Counter)
    bands = defaultdict(WL)
    band_acts = defaultdict(Counter)
    for f in fs:
        ctx, won, wt = f["ctx"], f["won"], f["w"]
        us = sorted(set(f["units"]))
        acts = sorted(f["acts"])
        for i in range(len(us)):
            for j in range(i + 1, len(us)):
                pairs_u[ctx][(us[i], us[j])].add(won, wt)
                unit_partner[us[i]][us[j]].add(won, wt)
                unit_partner[us[j]][us[i]].add(won, wt)
        for i in range(len(acts)):
            for j in range(i + 1, len(acts)):
                pairs_a[ctx][(acts[i], acts[j])].add(won, wt)
        for e in set(f["enemies"]):
            name = e.rstrip("*")
            enemy[ctx][name].add(won, wt)
            enemy_turns[name].append(f["turns"])
            enemy_fallen[name].update(f["fallen"])
            for a_ in acts:
                act_enemy[a_][name].add(won, wt)
        for u in us:
            unit_fall[u][1] += wt
            if u in f["fallen"]:
                unit_fall[u][0] += wt
        if f["speed"] is not None:
            for a_ in acts:
                act_speed[a_].append(f["speed"])
            for u in us:
                unit_speed[u].append(f["speed"])
        if ctx in ("quest", "dungeon"):
            stages[(ctx, f["key"])].add(won, wt)
            stage_turns[(ctx, f["key"])].append(f["turns"])
            stage_party[(ctx, f["key"])][" + ".join(us)] += 1
        if ctx == "road" and bucket_of(f):
            bands[bucket_of(f)].add(won, wt)
            if won:
                band_acts[bucket_of(f)].update(f["acts"].keys())
    fx.update(pairs_u=pairs_u, pairs_a=pairs_a, enemy=enemy, enemy_turns=enemy_turns, enemy_fallen=enemy_fallen,
              unit_fall=unit_fall, act_speed=act_speed, unit_speed=unit_speed, act_enemy=act_enemy,
              unit_partner=unit_partner, stages=stages, stage_turns=stage_turns, stage_party=stage_party,
              bands=bands, band_acts=band_acts, band_med=band_med)
    return fx


# ---------- report page ----------

CSS = """
:root{--bg:#f7f4ee;--card:#fff;--ink:#2b2620;--dim:#7a7066;--bar:#c8963e;--good:#3f8f5a;--bad:#b4473c;--line:#e6dfd3}
@media (prefers-color-scheme:dark){:root{--bg:#1d1a17;--card:#26221e;--ink:#eee6da;--dim:#a69b8d;--bar:#d6a24e;--good:#6cc08a;--bad:#e07a6e;--line:#3a342d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,Segoe UI,sans-serif}
main{max-width:1150px;margin:0 auto;padding:20px 16px 60px}h1{margin:0 0 4px;font-size:26px}h2{margin:30px 0 10px;font-size:19px}
nav{display:flex;flex-wrap:wrap;gap:6px;margin:10px 0 4px}nav a{color:var(--ink);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:3px 10px;font-size:13px;background:var(--card)}
.sub{color:var(--dim);margin-bottom:12px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(330px,100%),1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;overflow:hidden}
.card h3{margin:0 0 8px;font-size:15px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}.kpi b{display:block;font-size:22px}.kpi span{color:var(--dim)}
table{width:100%;border-collapse:collapse}td,th{padding:3px 6px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}
th{color:var(--dim);font-weight:600;font-size:12px}td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.bar{height:10px;background:var(--bar);border-radius:3px;min-width:2px}td.bc{width:34%}
details.all{margin-top:8px}details.all>summary{cursor:pointer;color:var(--bar);font-weight:600;font-size:13px}details.all .card{border:0;padding:6px 0 0;background:none}.good{color:var(--good)}.bad{color:var(--bad)}.note{color:var(--dim);font-size:12px;margin-top:6px}
details.x{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:6px 0}
details.x>summary{cursor:pointer;padding:8px 12px;display:grid;grid-template-columns:minmax(140px,1.4fr) repeat(4,minmax(70px,1fr)) 120px;gap:8px;align-items:center;list-style:none}
details.x>summary::-webkit-details-marker{display:none}details.x>summary:hover{background:color-mix(in srgb,var(--bar) 10%,transparent)}
details.x[open]>summary{border-bottom:1px solid var(--line)}.xb{padding:12px;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(300px,100%),1fr));gap:12px}
.xh{display:grid;grid-template-columns:minmax(140px,1.4fr) repeat(4,minmax(70px,1fr)) 120px;gap:8px;padding:0 12px;color:var(--dim);font-size:12px;font-weight:600}
.xh span:not(:first-child),details.x>summary span:not(:first-child){text-align:right}details.x>summary span{min-width:0}
input.f{width:100%;max-width:320px;padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);margin:4px 0 8px}
svg.spark{width:100%;max-width:120px;height:26px}svg.chart{width:100%;height:auto}.legend{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:12px;color:var(--dim)}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:-1px}
@media (max-width:640px){details.x>summary,.xh{grid-template-columns:1.5fr 1fr 1fr 70px}details.x>summary span:nth-child(4),details.x>summary span:nth-child(5),.xh span:nth-child(4),.xh span:nth-child(5){display:none}}
"""

PALETTE = ["#c8963e", "#3f8f5a", "#4a78b8", "#b4473c", "#8a5ab0", "#2a9a9a", "#c46aa0", "#7d7d3a"]


def esc(x):
    return html.escape(str(x))


def fmt(v):
    if isinstance(v, float):
        return f"{v:,.0f}" if abs(v) >= 100 else f"{v:,.1f}".rstrip("0").rstrip(".")
    return f"{v:,}" if isinstance(v, int) else esc(v)


def pct(x, signed=False):
    s = f"{100 * x:+.0f}%" if signed else f"{100 * x:.0f}%"
    if signed:
        cls = "good" if x > 0.005 else ("bad" if x < -0.005 else "")
        return f"<span class='{cls}'>{s}</span>"
    return s


def bar_table(title, rows, cols=("", "Count"), note="", limit=25, raw=False):
    """rows: (label, value[, extra cells...]); extra cells are HTML if raw."""
    rows = rows[:limit]
    if not rows:
        return f'<div class="card"><h3>{esc(title)}</h3><div class="note">No data yet.</div>{f"<div class=note>{esc(note)}</div>" if note else ""}</div>'
    top = max((r[1] for r in rows), default=1) or 1
    head = "".join(f"<th>{esc(c)}</th>" for c in cols) + "<th></th>"
    body = ""
    for r in rows:
        cells = f"<td>{esc(r[0])}</td><td class='n'>{fmt(r[1])}</td>"
        for x in r[2:]:
            cells += f"<td class='n'>{x if raw else fmt(x)}</td>"
        body += f"<tr>{cells}<td class='bc'><div class='bar' style='width:{100 * r[1] / top:.1f}%'></div></td></tr>"
    n = f'<div class="note">{esc(note)}</div>' if note else ""
    return f'<div class="card"><h3>{esc(title)}</h3><table><tr>{head}</tr>{body}</table>{n}</div>'


def ranked(counter, label=lambda k: k):
    return [(label(k), v) for k, v in counter.most_common()]


def spark(values, color="#c8963e"):
    """A tiny line chart of a series (one point per day)."""
    if not values or max(values) == 0:
        return "<svg class='spark'></svg>"
    top = max(values)
    n = len(values)
    pts = " ".join(f"{(i / max(1, n - 1)) * 116 + 2:.1f},{24 - (v / top) * 20:.1f}" for i, v in enumerate(values))
    return f"<svg class='spark' viewBox='0 0 120 26'><polyline fill='none' stroke='{color}' stroke-width='1.6' points='{pts}'/></svg>"


def line_chart(title, days, series, fmt_y=lambda v: f"{100 * v:.0f}%", note=""):
    """series: [(label, [value per day])]."""
    if not days or not series:
        return f'<div class="card"><h3>{esc(title)}</h3><div class="note">No data yet.</div></div>'
    W, H, L, B = 640, 220, 40, 22
    top = max((max(v) for _, v in series if v), default=0) or 1
    n = len(days)
    x = lambda i: L + (i / max(1, n - 1)) * (W - L - 10)
    y = lambda v: 10 + (1 - v / top) * (H - B - 10)
    svg = [f"<svg class='chart' viewBox='0 0 {W} {H}'>"]
    for t in range(5):
        v = top * t / 4
        svg.append(f"<line x1='{L}' x2='{W - 10}' y1='{y(v):.1f}' y2='{y(v):.1f}' stroke='currentColor' stroke-opacity='.12'/>"
                   f"<text x='{L - 4}' y='{y(v) + 4:.1f}' font-size='10' text-anchor='end' fill='currentColor' fill-opacity='.6'>{esc(fmt_y(v))}</text>")
    for i in sorted({0, n // 2, n - 1}):
        svg.append(f"<text x='{x(i):.1f}' y='{H - 6}' font-size='10' text-anchor='middle' fill='currentColor' fill-opacity='.6'>{esc(days[i][5:])}</text>")
    legend = []
    for si, (label, vals) in enumerate(series):
        col = PALETTE[si % len(PALETTE)]
        pts = " ".join(f"{x(i):.1f},{y(v):.1f}" for i, v in enumerate(vals))
        svg.append(f"<polyline fill='none' stroke='{col}' stroke-width='2' points='{pts}'/>")
        legend.append(f"<span><i style='background:{col}'></i>{esc(label)}</span>")
    svg.append("</svg>")
    n_ = f'<div class="note">{esc(note)}</div>' if note else ""
    return f'<div class="card"><h3>{esc(title)}</h3>{"".join(svg)}<div class="legend">{"".join(legend)}</div>{n_}</div>'


def share_series(a, group, keys):
    """Each key's share of a counter group, per day."""
    out = []
    for k in keys:
        vals = []
        for d in a["days"]:
            g = a["day_c"][d].get(group, Counter())
            tot = sum(g.values())
            vals.append(g.get(k, 0) / tot if tot else 0)
        out.append(vals)
    return out


def win_rank_tables(a, kind, ctx, label):
    rows, base, total = (a["win_actions"] if kind == "Actions" else a["win_units"])[ctx]
    title = f"{CTX_NAMES.get(ctx, 'All fights')}: {kind.lower()} and wins"
    good = [(k, v) for k, v in rows.items() if v[2] >= MIN_FIGHTS]
    few = sorted(((k, v) for k, v in rows.items() if v[2] < MIN_FIGHTS), key=lambda kv: -kv[1][2])
    if not good:
        return bar_table(title, [], note=f"Needs {MIN_FIGHTS}+ fights per {kind[:-1].lower()} before ranking.")
    good.sort(key=lambda kv: -kv[1][4])
    cols = (kind[:-1], "Fights", "Win rate", "vs average")

    def table_rows(sub, ranked_=True):
        return [(label(k), v[2], pct(v[3]), pct(v[4], True) if ranked_ else "<span class='note'>few fights</span>")
                for k, v in sub]

    def tbl(sub, name):
        card = bar_table(name, table_rows(sub[:10]), cols, raw=True, limit=10)
        if len(sub) > 10 or few:
            # Ian: the full ranking, expandable under the top 10.
            full = table_rows(sub) + table_rows(few, False)
            more = (f"<details class='all'><summary>Show all {len(full)}</summary>"
                    f"{bar_table('', full, cols, raw=True, limit=len(full)).replace('<h3></h3>', '')}</details>")
            card = card[:-len("</div>")] + more + "</div>"
        return card

    note = (f"Average win rate {pct(base)} over {fmt(total)} fights. 'vs average' is how much more or less often fights "
            f"with it are won. It shows association, not cause: players further along use different things. "
            f"Anything with fewer than {MIN_FIGHTS} fights isn't ranked (listed last under Show all).")
    return (tbl(good, f"{title} — most") + tbl(list(reversed(good)), f"{title} — least") +
            f"<div class='card note'>{esc(note)}</div>")


def wl_rank_card(title, table, base_rate, label, col, note="", min_n=MIN_FIGHT_RECORDS):
    """Ranks WL entries by win rate vs base_rate: top 10 most and least,
    each with a Show all."""
    good = sorted(((k, v) for k, v in table.items() if v.n >= min_n), key=lambda kv: -(kv[1].rate))
    few = sorted(((k, v) for k, v in table.items() if v.n < min_n), key=lambda kv: -kv[1].n)
    cols = (col, "Fights", "Win rate", "vs average")

    def rows_of(sub, ok=True):
        return [(label(k), v.n, pct(v.rate), pct(v.rate - base_rate, True) if ok else "<span class='note'>few fights</span>")
                for k, v in sub]
    if not good:
        return bar_table(title, [], note=f"Needs {min_n}+ recorded fights per row before ranking.")
    out = ""
    for name, sub in ((f"{title} — most", good), (f"{title} — least", list(reversed(good)))):
        card = bar_table(name, rows_of(sub[:10]), cols, raw=True, limit=10)
        full = rows_of(sub) + rows_of(few, False)
        if len(full) > 10:
            more = (f"<details class='all'><summary>Show all {len(full)}</summary>"
                    f"{bar_table('', full, cols, raw=True, limit=len(full)).replace('<h3></h3>', '')}</details>")
            card = card[:-len("</div>")] + more + "</div>"
        out += card
    if note:
        out += f"<div class='card note'>{esc(note)}</div>"
    return out


def speed_text(vals):
    if not vals:
        return "–"
    r = statistics.mean(vals) - 1
    cls = "good" if r < -0.02 else ("bad" if r > 0.02 else "")
    word = "fewer" if r < 0 else "more"
    return f"<span class='{cls}'>{abs(100 * r):.0f}% {word} turns</span>"


def explorer(a, kind, keys, label):
    """Click-to-expand rows (native <details>, no script needed)."""
    wins = a["win_actions" if kind == "action" else "win_units"]
    days = a["days"]
    out = [f"<input class='f' placeholder='Filter {kind}s…' oninput=\"for(const d of this.parentNode.querySelectorAll('details.x'))d.style.display=d.dataset.n.includes(this.value.toLowerCase())?'':'none'\">",
           "<div class='xh'><span>" + ("Action" if kind == "action" else "Unit") + "</span><span>" +
           ("Uses" if kind == "action" else "Owners") + "</span><span>" + ("Equipped by" if kind == "action" else "Fielded") +
           "</span><span>Win rate</span><span>vs average</span><span>Trend</span></div>"]
    for k in keys:
        w = wins[None][0].get(k)
        wr = pct(w[3]) if w and w[2] else "–"
        lift = pct(w[4], True) if w and w[2] >= MIN_FIGHTS else "<span class='note'>few fights</span>"
        if kind == "action":
            uses = a["c"]["actionUse"].get(k, 0)
            col2, col3 = fmt(uses), fmt(a["action_equipped"].get(k, 0))
            trend = spark([a["day_c"][d]["actionUse"].get(k, 0) / max(1, sum(a["day_c"][d]["actionUse"].values())) for d in days])
        else:
            col2, col3 = fmt(a["owned"].get(k, 0)), fmt(a["fielded"].get(k, 0))
            trend = spark([a["day_c"][d]["partyWaves"].get(k, 0) / max(1, sum(a["day_c"][d]["partyWaves"].values())) for d in days])
        name = label(k)
        body = explorer_body(a, kind, k, label)
        out.append(f"<details class='x' data-n='{esc(name.lower())}'><summary><span><b>{esc(name)}</b></span><span>{col2}</span>"
                   f"<span>{col3}</span><span>{wr}</span><span>{lift}</span><span>{trend}</span></summary><div class='xb'>{body}</div></details>")
    return "".join(out)


def ctx_win_rows(table_by_ctx, k):
    rows = []
    for ctx in ["road", "quest", "dungeon", "pvp"]:
        r, base, _ = table_by_ctx[ctx]
        if k in r:
            w, l, n, wr, lift = r[k]
            rows.append((CTX_NAMES[ctx], n, pct(wr), pct(base), pct(lift, True) if n >= MIN_FIGHTS else "few fights"))
    return rows


def explorer_body(a, kind, k, label):
    act = lambda x: a["acts"].get(x, x)
    unit = lambda x: a["units"].get(x, x)
    cond = lambda x: a["conds"].get(x, x)
    days = a["days"]
    P = []
    if kind == "action":
        P.append(bar_table("Win rate by kind of fight", ctx_win_rows(a["win_actions"], k),
                           ("Where", "Fights", "Win rate", "Average", "vs average"), raw=True))
        bought = a["lore_buys"].get(k, Counter())
        held, holders = a["lore_held"].get(k, Counter()), a["lore_holders"].get(k, Counter())
        rows = [(BONUS_NAMES.get(b, b), bought.get(b, 0), fmt(held.get(b, 0)), fmt(holders.get(b, 0)))
                for b in sorted(set(bought) | set(held), key=lambda b: -(bought.get(b, 0) + held.get(b, 0)))]
        P.append(bar_table("Lore upgrades", rows, ("Upgrade", "Bought (period)", "Levels held", "Players"), raw=True,
                           note="Bought: purchases in these reports. Held: what players have on it now."))
        tops = [b for b, _ in (bought + held).most_common(4)]
        if tops and len(days) > 1:
            series = [(BONUS_NAMES.get(b, b), [a["day_lore"][d].get(f"{k}:{b}", 0) for d in days]) for b in tops]
            P.append(line_chart("Lore upgrades bought per day", days, series, fmt_y=lambda v: f"{v:.0f}"))
        uses = a["c"]["actionUse"].get(k, 0)
        dmg = a["c"]["damageByAction"].get(k, 0)
        ctx_rows = [(CTX_NAMES[c_], a["c"].get(f"actionUse_{c_}", Counter()).get(k, 0)) for c_ in CTX_NAMES]
        P.append(bar_table("Uses by kind of fight", [r for r in ctx_rows if r[1]], ("Where", "Uses"),
                           note=f"{fmt(dmg / max(1, uses))} damage per use on average."))
        fx = a["fx"]
        if fx["n"]:
            sp = fx["act_speed"].get(k, [])
            P.append(bar_table("Road clear speed", [("Turns vs the usual for that wave", len(sp), speed_text(sp))],
                               ("", "Clears", ""), raw=True,
                               note="Recorded Road wins: fewer turns than other clears in the same 10-wave band means it clears faster."))
            ae = fx["act_enemy"].get(k, {})
            rows = sorted(ae.items(), key=lambda kv: -kv[1].n)[:12]
            P.append(bar_table("Win rate against enemy types", [(e, v.n, pct(v.rate)) for e, v in rows], ("Enemy", "Fights", "Win rate"), raw=True))
        P.append(bar_table("Units that have it equipped", ranked(a["action_units"].get(k, Counter()), unit), ("Unit", "Players"), limit=10))
        P.append(bar_table("Gambit conditions it's paired with", ranked(a["action_conds"].get(k, Counter()), cond), ("Condition", "Players"), limit=10))
        if len(days) > 1:
            P.append(line_chart("Share of all action uses, per day", days,
                                [(act(k), share_series(a, "actionUse", [k])[0])]))
    else:
        P.append(bar_table("Win rate by kind of fight", ctx_win_rows(a["win_units"], k),
                           ("Where", "Fights", "Win rate", "Average", "vs average"), raw=True))
        lv = a["levels"].get(k, [])
        spent = a["c"]["aetherByUnit"].get(k, 0)
        P.append(bar_table("At a glance", [("Owners", a["owned"].get(k, 0)), ("Fielded now", a["fielded"].get(k, 0)),
            ("Median level", statistics.median(lv) if lv else 0), ("Wave clears fought in", a["c"]["partyWaves"].get(k, 0)),
            ("Aether spent on it", spent), ("Sent on expeditions", a["c"]["expeditionUnits"].get(k, 0))], ("", "")))
        n = max(1, a["owned"].get(k, 0))
        P.append(bar_table("Affinity points held (average per owner)", [(AFFINITY_NAMES.get(x, x), v / n) for x, v in a["unit_aff"][k].most_common()], ("Affinity", "Points")))
        P.append(bar_table("Evade / crit steps held (average per owner)", [(STAT_NAMES.get(x, x), v / n) for x, v in a["unit_pct"][k].most_common()], ("Stat", "Steps")))
        P.append(bar_table("Actions in its loadout", ranked(a["unit_actions"][k], act), ("Action", "Players"), limit=10))
        P.append(bar_table("Gambit conditions in its loadout", ranked(a["unit_conds"][k], cond), ("Condition", "Players"), limit=10))
        P.append(bar_table("Gear worn", ranked(a["unit_gear"][k]), ("Item", "Players"), limit=10))
        fx = a["fx"]
        if fx["n"]:
            fell, fought = fx["unit_fall"].get(k, [0, 0])
            sp = fx["unit_speed"].get(k, [])
            P.append(bar_table("In recorded fights", [("Fights (weighted)", fought, f"falls in {100 * fell / max(1, fought):.0f}%"),
                                ("Road clears", len(sp), speed_text(sp))], ("", "Fights", ""), raw=True))
            ptab = fx["unit_partner"].get(k, {})
            ranked_p = [(unit(p), v.n, pct(v.rate)) for p, v in sorted(ptab.items(), key=lambda kv: -kv[1].rate) if v.n >= MIN_FIGHT_RECORDS]
            if not ranked_p:
                ranked_p = [(unit(p), v.n, pct(v.rate)) for p, v in sorted(ptab.items(), key=lambda kv: -kv[1].n)]
            P.append(bar_table("Win rate with each partner", ranked_p, ("Partner", "Fights", "Win rate"), raw=True, limit=12))
        if len(days) > 1:
            P.append(line_chart("Share of wave clears it fought in, per day", days,
                                [(unit(k), share_series(a, "partyWaves", [k])[0])]))
    return "".join(P)


def fights_section(a, act, unit):
    fx = a["fx"]
    head = "<h2 id='fights'>Fights in detail</h2>"
    if not fx["n"]:
        return head + "<div class='card note'>No per-fight records yet.</div>"
    P = [head, f"<div class='note'>From {fmt(fx['n'])} recorded fights: every quest, dungeon and Arena fight, Road wipe and boss "
               f"wave, plus a sample of ordinary Road clears (weighted back up to how many were fought).</div><div class='grid'>"]
    for ctx in ("road", "quest", "dungeon", "pvp"):
        b = fx["base"][ctx]
        if not b.n:
            continue
        P.append(wl_rank_card(f"{CTX_NAMES[ctx]}: unit pairs", fx["pairs_u"][ctx], b.rate,
                              lambda k: f"{unit(k[0])} + {unit(k[1])}", "Pair"))
        P.append(wl_rank_card(f"{CTX_NAMES[ctx]}: action pairs", fx["pairs_a"][ctx], b.rate,
                              lambda k: f"{act(k[0])} + {act(k[1])}", "Pair"))
    for ctx in ("road", "quest", "dungeon"):
        if not fx["base"][ctx].n:
            continue
        rows = []
        for e, v in sorted(fx["enemy"][ctx].items(), key=lambda kv: kv[1].rate):
            top_fall = fx["enemy_fallen"][e].most_common(1)
            rows.append((e, v.n, pct(v.rate), f"{statistics.median(fx['enemy_turns'][e]):.0f}",
                         unit(top_fall[0][0]) if top_fall else "–"))
        P.append(bar_table(f"{CTX_NAMES[ctx]}: enemy types (hardest first)", rows,
                           ("Enemy", "Fights", "Win rate", "Median turns", "Falls most"), raw=True, limit=30))
    uf = sorted(((u, f / n) for u, (f, n) in fx["unit_fall"].items() if n), key=lambda x: -x[1])
    P.append(bar_table("Units that fall most often", [(unit(u), r * 100) for u, r in uf], ("Unit", "% of fights"), limit=30))
    sp = sorted(((k, v) for k, v in fx["act_speed"].items() if len(v) >= MIN_FIGHT_RECORDS), key=lambda kv: statistics.mean(kv[1]))
    P.append(bar_table("Actions in the quickest Road clears", [(act(k), len(v), speed_text(v)) for k, v in sp],
                       ("Action", "Clears", "Turns vs usual"), raw=True, limit=40,
                       note="Turns to clear compared with other clears in the same 10-wave band."))
    rows = []
    for (ctx, key), v in sorted(fx["stages"].items(), key=lambda kv: kv[1].rate):
        name = unit(key.split("#")[0]) + " " + "#".join(key.split("#")[1:])
        party = fx["stage_party"][(ctx, key)].most_common(1)[0][0]
        rows.append((f"{CTX_NAMES[ctx][:-1]}: {name}", v.n, pct(v.rate), f"{statistics.median(fx['stage_turns'][(ctx, key)]):.0f}",
                     " + ".join(unit(u) for u in party.split(" + "))))
    P.append(bar_table("Quest stages and dungeon waves (hardest first)", rows,
                       ("Where", "Fights", "Win rate", "Median turns", "Usual party"), raw=True, limit=60))
    rows = [(f"{b_}-{b_ + 9}", v.n, pct(v.rate), f"{fx['band_med'].get(b_, 0):.0f}",
             ", ".join(act(x) for x, _ in fx["band_acts"][b_].most_common(3))) for b_, v in sorted(fx["bands"].items())]
    P.append(bar_table("Road by 10 waves", rows, ("Waves", "Fights", "Win rate", "Turns to clear", "Top actions in wins"),
                       raw=True, limit=200))
    P.append("</div>")
    return "".join(P)


def build_html(a):
    act = lambda k: a["acts"].get(k, k)
    unit = lambda k: a["units"].get(k, k)
    cond = lambda k: a["conds"].get(k, k)
    np = max(1, a["n_players"])
    med = lambda xs: statistics.median(xs) if xs else 0
    c = a["c"]
    days = a["days"]
    P = []
    P.append(f"<h1>Farroad gameplay stats</h1><div class='sub'>{a['n_players']} players · {a['n_reports']} daily reports · "
             f"{esc(days[0]) if days else ''} to {esc(days[-1]) if days else ''} · built {datetime.now():%Y-%m-%d %H:%M}</div>")
    P.append("<nav>" + "".join(f"<a href='#{i}'>{t}</a>" for i, t in [
        ("players", "Players"), ("trends", "Trends"), ("wins", "Wins"), ("actions", "Actions"), ("units", "Units"),
        ("gambits", "Gambits"), ("spending", "Spending"), ("quests", "Quests & dungeons"), ("arena", "Arena"),
        ("expeditions", "Expeditions"), ("fights", "Fights"), ("waves", "Waves"), ("tutorials", "Tutorials")]) + "</nav>")
    hours = a["minutes"] / 60
    P.append("<div class='kpis'>" + "".join(f"<div class='kpi'><b>{v}</b><span>{esc(k)}</span></div>" for k, v in [
        ("players", a["n_players"]), ("hours played", fmt(hours)), ("sessions", fmt(a["sessions"])),
        ("median farthest wave", fmt(med(a["farthest"]))), ("median party Power", fmt(med(a["power"]))),
        ("time at 2x speed", f"{100 * a['fast_minutes'] / max(1, a['minutes']):.0f}%")]) + "</div>")

    P.append("<h2 id='players'>Players</h2><div class='grid'>")
    buckets = Counter((f - 1) // 20 * 20 + 1 for f in a["farthest"])
    P.append(bar_table("How far players have got (farthest wave)", [(f"{b}-{b + 19}", buckets[b]) for b in sorted(buckets)], ("Waves", "Players"), limit=60))
    P.append(bar_table("Versions", ranked(a["versions"]), ("Version", "Players")))
    P.append(bar_table("Platforms", ranked(a["platforms"]), ("Platform", "Players")))
    off = a["offline"]
    P.append(bar_table("Coming back after time away", [("returns", off.get("returns", 0)),
        ("hours away (total)", off.get("seconds", 0) / 3600), ("waves gained while away", off.get("waveGain", 0))], ("", "Total")))
    P.append("</div>")

    P.append("<h2 id='trends'>Trends</h2><div class='grid'>")
    if len(days) > 1:
        P.append(line_chart("Active players per day", days, [("players", [a["day_players"][d] for d in days])], fmt_y=lambda v: f"{v:.0f}"))
        P.append(line_chart("Minutes played per player, per day", days,
            [("minutes", [a["day_c"][d]["session"].get("minutes", 0) / max(1, a["day_players"][d]) for d in days])], fmt_y=lambda v: f"{v:.0f}"))
        P.append(line_chart("Median farthest wave", days, [("wave", [a["day_farthest"][d] for d in days])], fmt_y=lambda v: f"{v:.0f}"))
        top_units = [k for k, _ in c["partyWaves"].most_common(6)]
        P.append(line_chart("Units: share of wave clears", days, list(zip(map(unit, top_units), share_series(a, "partyWaves", top_units)))))
        top_acts = [k for k, _ in c["actionUse"].most_common(6)]
        P.append(line_chart("Actions: share of uses", days, list(zip(map(act, top_acts), share_series(a, "actionUse", top_acts)))))
        top_bonus = [k for k, _ in c["loreBonus"].most_common(6)]
        P.append(line_chart("Lore upgrades: share of purchases", days, list(zip([BONUS_NAMES.get(b, b) for b in top_bonus], share_series(a, "loreBonus", top_bonus)))))
    else:
        P.append("<div class='card note'>Trends appear once there are reports from more than one day.</div>")
    P.append("</div>")

    P.append("<h2 id='wins'>What wins</h2><div class='grid'>")
    for ctx in ["road", "quest", "dungeon", "pvp"]:
        P.append(win_rank_tables(a, "Units", ctx, unit))
    for ctx in ["road", "quest", "dungeon", "pvp"]:
        P.append(win_rank_tables(a, "Actions", ctx, act))
    P.append("</div>")

    P.append("<h2 id='actions'>Actions</h2><div class='note'>Click an action for its Lore upgrades, trends, win rates and who uses it.</div>")
    keys = sorted(set(c["actionUse"]) | set(a["action_equipped"]) | set(a["lore_held"]), key=lambda k: -c["actionUse"].get(k, 0))
    P.append(f"<div>{explorer(a, 'action', keys, act)}</div>")

    P.append("<h2 id='units'>Units</h2><div class='note'>Click a unit for its win rates, investment, loadouts and trend.</div>")
    keys = sorted(set(a["owned"]) | set(c["partyWaves"]), key=lambda k: -c["partyWaves"].get(k, 0))
    P.append(f"<div>{explorer(a, 'unit', keys, unit)}</div>")
    P.append("<div class='grid' style='margin-top:12px'>")
    P.append(bar_table("Main character's charge action", ranked(a["mc_charge"], act), ("Action", "Players")))
    P.append("</div>")

    P.append("<h2 id='gambits'>Gambits</h2><div class='grid'>")
    P.append(bar_table("Equipped conditions", [(cond(k), v, f"{100 * v / np:.0f}%") for k, v in a["cond_equipped"].most_common()], ("Condition", "Players", "Share"), limit=40))
    P.append(bar_table("Conditions that fired in fights", ranked(c["condFired"], cond), ("Condition", "Times"), limit=40,
                       note="A condition that's equipped a lot but rarely fires may be too strict."))
    P.append("</div>")

    P.append("<h2 id='spending'>Spending</h2><div class='grid'>")
    for cur in ["aether", "marks", "crystal"]:
        rows = [(spend_label(k), v) for k, v in c["spend"].most_common() if k.startswith(cur + ":")]
        P.append(bar_table(f"{cur.capitalize()} spent on", rows, ("Spent on", "Amount"), limit=30))
    P.append(bar_table("Aether spent per unit", ranked(c["aetherByUnit"], unit), ("Unit", "Aether")))
    P.append(bar_table("Lore upgrades bought", ranked(c["loreBonus"], lambda b: BONUS_NAMES.get(b, b)), ("Upgrade", "Bought")))
    P.append(bar_table("Marks pulls", ranked(c["pulls"]), ("Result", "Pulls")))
    P.append(bar_table("Shop purchases", ranked(c["shop"], lambda k: k.split(":", 1)[0] + ": " + (act(k.split(":", 1)[1]) if k.startswith("action:") else unit(k.split(":", 1)[1]) if k.startswith("unit:") else k.split(":", 1)[-1])), ("Item", "Bought"), limit=30))
    P.append("</div>")

    def side_rows(prefix):
        return [(k.replace("_", " "), sum(v.values())) for k, v in a["side"].items() if k.startswith(prefix)]
    def fight_secs(kind):
        n = sum(sum(v.values()) for k, v in a["side"].items() if k.startswith(kind))
        return a["side_seconds"].get(kind, 0) / max(1, n)
    P.append("<h2 id='quests'>Quests and dungeons</h2><div class='grid'>")
    P.append(bar_table("Players who tried them", [("Quests", a["quest_players"], f"{100 * a['quest_players'] / np:.0f}%"),
        ("Dungeons", a["dungeon_players"], f"{100 * a['dungeon_players'] / np:.0f}%")], ("", "Players", "Share")))
    P.append(bar_table("Results", side_rows("quest") + side_rows("dungeon"), ("Result", "Fights"),
                       note=f"Average fight: quests {fight_secs('quest'):.0f}s, dungeons {fight_secs('dungeon'):.0f}s."))
    P.append(bar_table("Quest stages reached (per owned unit)", [(f"stage {k}", v) for k, v in sorted(a["quest_stage"].items())], ("Stage", "Units")))
    qlab = lambda k: unit(k.split("#")[0]) + (" stage " + k.split("#")[1] if "#" in k else "")
    for kind in ("quest_failed", "quest_abandoned", "dungeon_failed"):
        if a["side"].get(kind):
            P.append(bar_table(kind.replace("_", " ").capitalize(), ranked(a["side"][kind], qlab), ("Where", "Times"), limit=15))
    P.append("</div>")

    P.append("<h2 id='arena'>Arena</h2><div class='grid'>")
    won, lost = a["side"].get("pvp_won", Counter()), a["side"].get("pvp_lost", Counter())
    rivals = sorted(set(won) | set(lost), key=lambda k: -(won[k] + lost[k]))
    P.append(bar_table("Players who fought", [("Arena", a["pvp_players"], f"{100 * a['pvp_players'] / np:.0f}%")], ("", "Players", "Share"),
                       note=f"Average fight {fight_secs('pvp'):.0f}s · {fmt(c['features'].get('pvpSkip', 0))} fights skipped."))
    P.append(bar_table("Results by opponent", [(("Shared code" if k == "code" else k.capitalize()), won[k] + lost[k], won[k], lost[k],
                       f"{100 * won[k] / max(1, won[k] + lost[k]):.0f}%") for k in rivals], ("Opponent", "Fights", "Won", "Lost", "Win rate")))
    P.append(win_rank_tables(a, "Units", "pvp", unit))
    P.append(win_rank_tables(a, "Actions", "pvp", act))
    P.append("</div>")

    P.append("<h2 id='expeditions'>Expeditions</h2><div class='grid'>")
    e = c["expedition"]
    P.append(bar_table("Players who sent one", [("Expeditions", a["expedition_players"], f"{100 * a['expedition_players'] / np:.0f}%")], ("", "Players", "Share")))
    P.append(bar_table("Directions sent", [(k[5:], v) for k, v in e.most_common() if k.startswith("sent:")], ("Direction", "Sent")))
    P.append(bar_table("Party size", [(k[5:], v) for k, v in sorted(e.items()) if k.startswith("size:")], ("Units", "Sent")))
    P.append(bar_table("Outcomes", [(k, v) for k, v in e.most_common() if ":" not in k], ("", "Total")))
    P.append(bar_table("Depth reached when collected", [(f"wave {k}+", v) for k, v in sorted(c["expeditionDepths"].items(), key=lambda kv: int(kv[0]))], ("Depth", "Expeditions")))
    P.append(bar_table("Units sent most", ranked(c["expeditionUnits"], unit), ("Unit", "Times")))
    P.append("</div>")

    P.append(fights_section(a, act, unit))
    P.append("<h2 id='waves'>Waves</h2><div class='grid'>")
    rows = []
    for w in sorted(a["waves"]):
        secs, clears, wipes, ids = a["waves"][w]
        tries = clears + wipes
        rows.append((f"wave {w}", secs / max(1, tries), clears, wipes, f"{100 * wipes / max(1, tries):.0f}%", len(ids)))
    P.append(bar_table("Hardest waves (most wipes)", [(r[0], r[3], r[2], r[4], r[5]) for r in sorted(rows, key=lambda r: -r[3])[:25]],
                       ("Wave", "Wipes", "Clears", "Wipe rate", "Players")))
    P.append(bar_table("Slowest waves (avg seconds per attempt)", [(r[0], r[1], r[2] + r[3]) for r in sorted(rows, key=lambda r: -r[1])[:25]], ("Wave", "Seconds", "Attempts")))
    buckets = defaultdict(lambda: [0.0, 0])
    for w, (secs, clears, wipes, _) in a["waves"].items():
        b = (w - 1) // 10 * 10 + 1
        buckets[b][0] += secs
        buckets[b][1] += clears + wipes
    P.append(bar_table("Average seconds per wave, by 10s", [(f"{b}-{b + 9}", s / max(1, n)) for b, (s, n) in sorted(buckets.items())], ("Waves", "Seconds"), limit=200))
    P.append("</div>")

    P.append("<h2 id='tutorials'>Tutorials and features</h2><div class='grid'>")
    tut = defaultdict(lambda: [0, 0])
    for k, v in c["tutorials"].items():
        tid, _, how = k.rpartition(":")
        tut[tid][0 if how == "done" else 1] += v
    P.append(bar_table("Tutorials", [(k, v[0], v[1], f"{100 * v[1] / max(1, sum(v)):.0f}%") for k, v in sorted(tut.items(), key=lambda kv: -sum(kv[1]))], ("Tutorial", "Done", "Skipped", "Skip rate")))
    P.append(bar_table("Features used", ranked(c["features"]), ("Feature", "Times")))
    P.append("</div>")
    return (f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<title>Farroad Stats</title><style>{CSS}</style></head><body><main>{''.join(P)}</main></body></html>")


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

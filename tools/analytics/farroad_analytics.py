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
import re
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
# Reports from development test runs, not players (one id per line).
IGNORE_FILE = os.path.join(HERE, "ignore_ids.txt")
IGNORE_IDS = {l.split("#")[0].strip() for l in open(IGNORE_FILE, encoding="utf-8")} - {""} if os.path.exists(IGNORE_FILE) else set()


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
        rid = str(rep.get("id", "")) if isinstance(rep, dict) else ""
        if isinstance(rep, dict) and rep.get("schema") == 1 and not rid.startswith("test") and rid not in IGNORE_IDS:
            out.append(rep)   # ids starting "test" are setup checks, not players
    return out


# ---------- Arena player names ----------
# Ian: show a player's Main Character name next to their id, for Arena players
# only. Reports never carry names; the Arena server has them (the leaderboard
# name). Read with the developer's own gcloud login, one document per player id,
# keeping only the name. Cached beside the report data (gitignored).
ARENA_NAMES = os.path.join(DATA_DIR, "arena_names.json")
ARENA_PROJECT = "farroad"


def _gcloud():
    import shutil
    exe = shutil.which("gcloud") or shutil.which("gcloud.cmd")
    if not exe:
        for base in (os.environ.get("LOCALAPPDATA", ""), os.path.expanduser("~")):
            cand = os.path.join(base, "Google", "Cloud SDK", "google-cloud-sdk", "bin", "gcloud.cmd")
            if os.path.exists(cand):
                return cand
    return exe


def load_arena_names():
    try:
        return json.load(open(ARENA_NAMES, encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def refresh_arena_names(ids):
    """Look up the names of these player ids on the Arena server. Skips quietly
    (keeping the cached names) if gcloud isn't available or not logged in."""
    import subprocess
    names = load_arena_names()
    exe = _gcloud()
    if not exe or not ids:
        return names
    try:
        tok = subprocess.run([exe, "auth", "print-access-token"], capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        tok = ""
    if not tok:
        print("Arena names: gcloud isn't logged in, using the saved names.")
        return names
    for pid in sorted(ids):
        url = f"https://firestore.googleapis.com/v1/projects/{ARENA_PROJECT}/databases/(default)/documents/players/{urllib.parse.quote(pid)}"
        try:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
            doc = json.load(urllib.request.urlopen(req, timeout=20))
            rec = json.loads(doc["fields"]["data"]["stringValue"])
            if rec.get("name"):
                names[pid] = str(rec["name"])   # the name only; nothing else is kept
        except Exception as e:   # no account on the server, or a network problem
            print(f"Arena names: {pid}: {type(e).__name__}")
    os.makedirs(DATA_DIR, exist_ok=True)
    json.dump(names, open(ARENA_NAMES, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    return names


# ---------- aggregation ----------

def names():
    try:
        c = json.load(open(CONTENT, encoding="utf-8"))
    except OSError:
        return {}, {}
    acts = {k: v.get("name", k) for k, v in c.get("ACTIONS", {}).items()}
    units = {u["id"]: u.get("name", u["id"]) for u in c.get("ROSTER", [])}
    units[MC_ID] = MC_LABEL   # Ian: each player names their own; report it as the Main Character
    return acts, units


# ---------- titles (mirrors FarroadProgression.unit_title) ----------
# A unit's title: the role from its two highest non-HP stats at level 100,
# led by its strongest elemental affinity (base + bought + gear), e.g. "Fire Warden".
PROG_GD = os.path.join(HERE, "..", "..", "godot-project", "scripts", "FarroadProgression.gd")
TITLE_LEVEL = 100
ROLE_TITLES = {"atk+mag": "Duelist", "atk+def": "Fighter", "atk+res": "Paladin", "atk+spd": "Rogue",
               "mag+def": "Warden", "mag+res": "Mage", "mag+spd": "Sorcerer", "def+res": "Tank", "def+spd": "Bruiser",
               "res+spd": "Warlock"}
TITLE_STATS = ["atk", "mag", "def", "res", "spd"]
TITLE_ELEMENTS = ["fire", "water", "earth", "air", "light", "dark", "spirit"]
MC_STAT_RANGE = {"atk": (8, 30), "mag": (7, 30), "def": (8, 45), "res": (8, 40), "spd": (11, 26)}
MC_GROWTH_RANGE = {"atk": (0.6, 2.7), "mag": (0.5, 2.7), "def": (0.8, 2.4), "res": (0.8, 1.7), "spd": (0.7, 1.6)}
MC_ID, MC_LABEL = "kesh", "Main Character"


def _content():
    try:
        return json.load(open(CONTENT, encoding="utf-8"))
    except OSError:
        return {}


def _growth_table():
    try:
        src = open(PROG_GD, encoding="utf-8").read()
    except OSError:
        return {}
    block = src.split("static var GROWTH := {", 1)[-1].split("\n}", 1)[0]
    return {m.group(1): {k: float(v) for k, v in re.findall(r'"(\w+)": ([\d.]+)', m.group(2))}
            for m in re.finditer(r'"(\w+)": \{([^}]*)\}', block)}


CONTENT_DATA = _content()
GROWTH = _growth_table()
ROSTER = {u["id"]: u for u in CONTENT_DATA.get("ROSTER", [])}
EQUIPMENT = CONTENT_DATA.get("EQUIPMENT", {})


def mc_growth(stats):
    """The MC's per-level growth, recovered from its point-bought base stats
    (both come from the same points, P.mcBuildStats)."""
    out = {}
    for k, (lo, hi) in MC_STAT_RANGE.items():
        p = min(15, max(0, round((float(stats.get(k, lo)) - lo) / (hi - lo) * 15)))
        glo, ghi = MC_GROWTH_RANGE[k]
        out[k] = round((glo + p / 15 * (ghi - glo)) * 10) / 10
    return out


def stats_at_100(uid, mc_stats=None):
    if uid == MC_ID and mc_stats:
        base, grow = mc_stats, mc_growth(mc_stats)
    else:
        base = ROSTER.get(uid, {}).get("stats", {})
        grow = GROWTH.get(uid, GROWTH.get(MC_ID, {}))
    return {k: round(float(base.get(k, 0)) + grow.get(k, 0) * (TITLE_LEVEL - 1)) for k in TITLE_STATS}


def role_for_stats(st):
    vals = [st[k] for k in TITLE_STATS]
    if max(vals) - min(vals) <= 2:
        return "Freelancer"
    order = sorted(TITLE_STATS, key=lambda k: (-st[k], TITLE_STATS.index(k)))
    pair = sorted(order[:2], key=TITLE_STATS.index)
    return ROLE_TITLES.get("+".join(pair), "Freelancer")


def unit_affinity(uid, snap_unit=None):
    base = {} if (uid == MC_ID and snap_unit is not None) else ROSTER.get(uid, {}).get("affinity", {})
    out = Counter({k: float(v) for k, v in base.items()})
    if snap_unit:
        out.update({k: float(v) for k, v in snap_unit.get("aff", {}).items()})
        for item in snap_unit.get("equip", {}).values():
            out.update({k: float(v) for k, v in EQUIPMENT.get(item, {}).get("affinity", {}).items()})
    return out


def unit_title(uid, snap_unit=None, mc_stats=None):
    aff = unit_affinity(uid, snap_unit)
    best, best_v = "", 0.0
    for el in TITLE_ELEMENTS:
        if aff.get(el, 0) > best_v:
            best, best_v = el, aff[el]
    role = role_for_stats(stats_at_100(uid, mc_stats))
    return f"{best.capitalize()} {role}" if best else role


def snap_titles(s):
    return {uid: unit_title(uid, u, s.get("mcStats")) for uid, u in s.get("units", {}).items()}


TARGET_NAMES = {"foe": "one foe", "allFoes": "all foes", "ally": "one ally", "allAllies": "the whole party",
                "self": "self", "deadAlly": "a fallen ally"}


def _signed(v):
    return f"+{v:g}" if v > 0 else f"{v:g}".replace("-", "−")


def _top(counter, label=lambda k: k, n=3):
    return ", ".join(f"{label(k)} ({v:g})" for k, v in counter.most_common(n)) or "none yet"


def tips(rep):
    """Ian: hovering a name shows a card. Actions: their base details. Units:
    name, title, rarity, row, two highest stats and charge action. Everything
    else (conditions, gear, Lore upgrades, titles, archetypes): what it's
    most used with. Keyed by the display name the report prints; each value
    is [heading, line, ...]."""
    acts = CONTENT_DATA.get("ACTIONS", {})
    act = lambda k: rep["acts"].get(k, k)
    unit = lambda k: rep["units"].get(k, k)
    out = {}
    for u in CONTENT_DATA.get("ROSTER", []):
        uid = u["id"]
        held = rep["unit_titles"].get(uid, Counter())
        if uid == MC_ID:
            lines = [MC_LABEL, "Archetypes: " + _top(rep["mc_archetypes"], n=4),
                     f"{str(u.get('rarity', 'common')).capitalize()} · stats picked by each player",
                     "Charge action: " + _top(rep["mc_charge"], act)]
            out[MC_LABEL] = lines
            continue
        title = unit_title(uid)
        st = stats_at_100(uid)
        top2 = sorted(TITLE_STATS, key=lambda k: (-st[k], TITLE_STATS.index(k)))[:2]
        others = Counter({t: n for t, n in held.items() if t != title})
        lines = [u.get("name", uid), f"Title: {title}" + (f"  ·  players also have: {_top(others)}" if others else ""),
                 f"{str(u.get('rarity', 'common')).capitalize()} · {str(u.get('row', 'front')).capitalize()} row",
                 "Highest stats: " + ", ".join(f"{k.upper()} {st[k]}" for k in top2) + " (at level 100)",
                 "Charge action: " + acts.get(u.get("chargeAction") or "", {}).get("name", "–")]
        out[u.get("name", uid)] = lines
    for a in acts.values():
        name = a.get("name", a["id"])
        if name in out:
            continue
        camp = "Magic" if a.get("camp") == "mag" else "Physical"
        kind = "Charge action" if a.get("isCharge") else "Action"
        lines = [name, f"{str(a.get('rarity', 'common')).capitalize()} {kind.lower()} · {camp}" +
                 (f" · {str(a['element']).capitalize()}" if a.get("element") else "") +
                 f" · target: {TARGET_NAMES.get(a.get('tk', 'foe'), a.get('tk'))}"]
        if a.get("power"):
            stat = str(a.get("scaleStat") or ("mag" if a.get("camp") == "mag" else "atk"))
            stat = "avg of ATK and MAG" if stat == "avgAtkMag" else stat.upper()
            lines.append(f"Scales with {stat} · power ×{float(a['power']):.2f}" + (" · heals" if a.get("heal") else ""))
        else:
            lines.append("No stat scaling (fixed effect)")
        cost = f"Cost {round(float(a.get('rank', 1)) * 100)}"
        lines.append(f"{cost} · uses {a.get('chargeCost') or 100} charge" if a.get("isCharge")   # FarroadCore.CHARGE_FULL
                     else f"{cost} · Charge +{a.get('charge') or 0}")
        if a.get("applies"):
            lines.append(f"Applies {str(a['applies']).capitalize()}" + (f" for {a['turns']} turns" if a.get("turns") else ""))
        for k, label in (("defPierce", "Ignores {:.0%} of DEF/RES"), ("critBonus", "+{:.0%} crit chance")):
            if a.get(k):
                lines.append(label.format(float(a[k])))
        out[name] = lines
    # Ian: other sections' names pop up what they're most used with.
    cond = lambda k: rep["conds"].get(k, k)
    for cid, by_act in rep["cond_actions"].items():
        out.setdefault(cond(cid), [cond(cid), "Most paired with: " + _top(by_act, act),
                                   "Most used on: " + _top(rep["cond_units"].get(cid, Counter()), unit)])
    for gid, by_unit in rep["gear_units"].items():
        g = EQUIPMENT.get(gid, {})
        name = g.get("name", gid)
        out.setdefault(name, [name, f"{str(g.get('rarity', 'common')).capitalize()} · {str(g.get('slot', '?')).capitalize()} slot",
                              "Most worn by: " + _top(by_unit, unit)])
    for bid, by_act in rep["bonus_actions"].items():
        name = BONUS_NAMES.get(bid, bid)
        out.setdefault(name, [name, "Most upgraded on: " + _top(by_act, act)])
    for title, by_unit in rep["title_units"].items():
        out.setdefault(title, [title, "Most often: " + _top(by_unit, unit, 4)])
    for arch, d in rep["mc_detail"].items():
        out[arch] = [f"Main Character: {arch}", "Usual stat picks: " + d["stats"],
                     "Charge action: " + _top(d["charge"], act),
                     "Most used actions: " + _top(d["actions"], act),
                     "Usual partners: " + _top(d["partners"], unit)]
    return out


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
    # Reverse lookups for the "most used with" hover cards.
    cond_actions, cond_units, gear_units, bonus_actions = defaultdict(Counter), defaultdict(Counter), defaultdict(Counter), defaultdict(Counter)
    for act_id, conds in action_conds.items():
        for cid, n in conds.items():
            cond_actions[cid][act_id] += n
    for uid, conds in unit_conds.items():
        for cid, n in conds.items():
            cond_units[cid][uid] += n
    for uid, gear in unit_gear.items():
        for gid, n in gear.items():
            gear_units[gid][uid] += n
    for act_id, bs in lore_held.items():
        for bid, n in bs.items():
            bonus_actions[bid][act_id] += n
    a.update(cond_actions=cond_actions, cond_units=cond_units, gear_units=gear_units, bonus_actions=bonus_actions)

    # Titles (Ian: the current affinity + role titles), from each player's latest save.
    unit_titles, title_units = defaultdict(Counter), defaultdict(Counter)
    for s in snaps:
        for uid, t in snap_titles(s).items():
            unit_titles[uid][t] += 1
            title_units[t][uid] += 1
    a.update(unit_titles=unit_titles, title_units=title_units)
    # Reports don't carry title tallies (or carry ones from before the rename),
    # so title win rates come from each report's unit tallies and its own save.
    for k in [k for k in c if k.startswith("fightTitles")]:
        del c[k]
    for r in reports:
        tmap = snap_titles(r.get("snapshot", {}))
        for key, vals in r.get("counters", {}).items():
            if key.startswith("fightUnits_") and isinstance(vals, dict):
                for uid, n in vals.items():
                    if uid in tmap:
                        c["fightTitles_" + key[len("fightUnits_"):]][tmap[uid]] += n

    # Main Character archetypes (title = strongest element + role from its stat picks).
    by_player = defaultdict(list)
    for r in reports:
        by_player[r["id"]].append(r)
    mc_rows, mc_detail = defaultdict(lambda: {"players": 0, "farthest": [], "power": [], "win": 0, "loss": 0,
                                              "stats": defaultdict(list), "charge": Counter(), "actions": Counter(),
                                              "partners": Counter()}), {}
    for pid, r in latest.items():
        s = r["snapshot"]
        mcu = s.get("units", {}).get(MC_ID)
        if mcu is None:
            continue
        arch = unit_title(MC_ID, mcu, s.get("mcStats"))
        d = mc_rows[arch]
        d["players"] += 1
        d["farthest"].append(s.get("farthest", 1))
        d["power"].append(s.get("power", 0))
        for rr in by_player[pid]:
            for k, v in rr.get("counters", {}).get("fights", {}).items():
                d["win" if k.endswith(":win") else "loss"] += v
        for k, v in (s.get("mcStats") or {}).items():
            d["stats"][k].append(v)
        if s.get("mcCharge"):
            d["charge"][s["mcCharge"]] += 1
        for _, act_id in mcu.get("loadout", []):
            d["actions"][act_id] += 1
        for uid in s.get("party", []):
            if uid != MC_ID:
                d["partners"][uid] += 1
    for arch, d in mc_rows.items():
        st = d["stats"]
        mc_detail[arch] = dict(d, stats=", ".join(f"{k.upper()} {statistics.median(st[k]):g}" for k in TITLE_STATS if st.get(k)) or "–")
    a["mc_archetypes"] = Counter({k: d["players"] for k, d in mc_rows.items()})
    a["mc_detail"] = mc_detail
    lore_buys = defaultdict(Counter)
    for k, v in c["loreBuys"].items():
        aid, bid = k.rsplit(":", 1)
        lore_buys[aid][bid] += v
    a["lore_buys"] = lore_buys

    # Win contribution, overall and per kind of fight.
    a["win_actions"] = {ctx: win_table(c, "Actions", ctx) for ctx in [None, "road", "quest", "dungeon", "pvp"]}
    a["win_units"] = {ctx: win_table(c, "Units", ctx) for ctx in [None, "road", "quest", "dungeon", "pvp"]}
    a["win_titles"] = {ctx: win_table(c, "Titles", ctx) for ctx in [None, "road", "quest", "dungeon", "pvp"]}

    # Quests and dungeons vs the Arena (sideBattles keys: "quest_cleared:uid#2").
    side = defaultdict(Counter)
    for k, v in c["sideBattles"].items():
        kind, _, target = k.partition(":")
        side[kind][target or "?"] += v
    a["side"] = side
    a["side_seconds"] = c["sideBattleSeconds"]
    a["quest_stage"] = Counter(st for s in snaps for st in s.get("quests", {}).values())
    # Who has done quests / dungeons (Ian: listed by player id): from the fight
    # counters in any report AND from their save (quest stages, dungeon clears).
    quest_who = defaultdict(lambda: {"cleared": 0, "failed": 0, "abandoned": 0, "stages": 0, "last": ""})
    dungeon_who = defaultdict(lambda: {"cleared": 0, "failed": 0, "unlocked": 0, "clears": 0, "last": ""})
    for r in sorted(reports, key=lambda r: r.get("to", 0)):
        pid, rc, s = r["id"], r.get("counters", {}), r.get("snapshot", {})
        sb = rc.get("sideBattles", {})
        q = {kind: sum(v for k, v in sb.items() if k.startswith("quest_" + kind)) for kind in ("cleared", "failed", "abandoned")}
        d = {kind: sum(v for k, v in sb.items() if k.startswith("dungeon_" + kind)) for kind in ("cleared", "failed")}
        stages = sum(int(v) for v in (s.get("quests") or {}).values())
        dungeons = s.get("dungeons") or []
        if any(q.values()) or stages:
            w = quest_who[pid]
            for kind in q:
                w[kind] += q[kind]
            w["stages"], w["last"] = max(w["stages"], stages), day_of(r)
        if any(d.values()) or any(x[2] for x in dungeons):
            w = dungeon_who[pid]
            for kind in d:
                w[kind] += d[kind]
            w["unlocked"], w["clears"], w["last"] = max(w["unlocked"], len(dungeons)), max(w["clears"], sum(int(x[2]) for x in dungeons)), day_of(r)
    a["quest_who"], a["dungeon_who"] = dict(quest_who), dict(dungeon_who)
    a["quest_players"], a["dungeon_players"] = len(quest_who), len(dungeon_who)
    # Ian: who took part, by player id -- from the counters in any report AND from
    # what their save shows (an Arena record, an expedition out or explored),
    # since a day's counters alone miss people whose activity was in an earlier report.
    arena_who, exped_who = defaultdict(lambda: {"fights": 0, "won": 0, "lost": 0, "last": ""}), defaultdict(lambda: {"sent": 0, "collected": 0, "depth": 0, "last": ""})
    for r in sorted(reports, key=lambda r: r.get("to", 0)):
        rc, s, pid = r.get("counters", {}), r.get("snapshot", {}), r["id"]
        won = sum(v for k, v in rc.get("sideBattles", {}).items() if k.startswith("pvp_won"))
        lost = sum(v for k, v in rc.get("sideBattles", {}).items() if k.startswith("pvp_lost"))
        rec = s.get("pvp") or {}
        if won or lost or rc.get("features", {}).get("pvpSkip") or rec.get("w", 0) + rec.get("l", 0) > 0:
            w = arena_who[pid]
            w["won"], w["lost"] = max(w["won"], rec.get("w", 0)), max(w["lost"], rec.get("l", 0))   # lifetime record from the save
            w["fights"] += won + lost
            w["last"] = day_of(r)
        ex = rc.get("expedition", {})
        depth = max([int(v) for v in (s.get("expeditionDepth") or {}).values()] or [0])
        if ex or s.get("expeditionsOut") or depth:
            w = exped_who[pid]
            w["sent"] += sum(v for k, v in ex.items() if k.startswith("sent:"))
            w["collected"] += ex.get("collected", 0)
            w["depth"] = max(w["depth"], depth)
            w["last"] = day_of(r)
    a["arena_who"], a["exped_who"] = dict(arena_who), dict(exped_who)
    a["expedition_players"], a["pvp_players"] = len(exped_who), len(arena_who)
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
header.top{position:sticky;top:0;z-index:30;background:var(--bg);margin:0 -16px;padding:10px 16px 8px;border-bottom:1px solid var(--line)}
header.top h1{font-size:20px;display:inline-block;margin:0 10px 0 0}header.top .sub{display:inline-block;margin:0}
header.top nav{margin:6px 0}header.top .kpis{grid-template-columns:repeat(auto-fit,minmax(110px,1fr));gap:6px}
header.top .kpi{padding:5px 9px}header.top .kpi b{display:inline;font-size:16px;margin-right:6px}header.top .kpi span{font-size:12px}
h2{scroll-margin-top:var(--top,150px)}
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
.has-tip{text-decoration:underline dotted color-mix(in srgb,var(--dim) 60%,transparent);text-underline-offset:3px;cursor:help}
.tip{position:fixed;z-index:20;max-width:340px;background:var(--card);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:8px 10px;font-size:12px;box-shadow:0 4px 16px rgba(0,0,0,.18);pointer-events:none;display:none}
.tip b{display:block;font-size:13px;margin-bottom:2px}.tip div{color:var(--dim)}
.xh span.s{cursor:pointer;user-select:none}.xh span.s:hover{color:var(--ink)}.xh span.s.on{color:var(--bar)}
.menu{position:absolute;z-index:15;background:var(--card);border:1px solid var(--line);border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.18);padding:4px;display:none;min-width:190px}
.menu button{display:block;width:100%;text-align:left;background:none;border:0;color:var(--ink);font:inherit;font-size:13px;padding:6px 10px;border-radius:6px;cursor:pointer}.menu button:hover{background:color-mix(in srgb,var(--bar) 15%,transparent)}
@media (max-width:640px){details.x>summary,.xh{grid-template-columns:1.5fr 1fr 1fr 70px}details.x>summary span:nth-child(4),details.x>summary span:nth-child(5),.xh span:nth-child(4),.xh span:nth-child(5){display:none}}
"""

SCRIPT = """
const hd=document.getElementById('top'),setTop=()=>document.documentElement.style.setProperty('--top',(hd.offsetHeight+8)+'px');setTop();addEventListener('resize',setTop);
const tip=document.createElement('div');tip.className='tip';document.body.append(tip);
const h=s=>s.replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
// Action and unit names anywhere in a table, row heading or "A + B" pair get a hover card.
for(const el of document.querySelectorAll('td, details.x>summary b')){
  if(el.children.length)continue;
  const t=el.textContent.trim();
  if(TIPS[t]){el.classList.add('has-tip');el.dataset.tip=t;continue;}
  for(const sep of [' + ',', ']){
    const parts=t.split(sep);
    if(parts.length>1&&parts.some(p=>TIPS[p])){
      el.innerHTML=parts.map(p=>TIPS[p]?`<span class="has-tip" data-tip="${h(p)}">${h(p)}</span>`:h(p)).join(h(sep));break;}
  }
}
document.addEventListener('mouseover',e=>{const t=e.target.closest('.has-tip');if(!t)return;
  const L=TIPS[t.dataset.tip];tip.innerHTML='<b>'+h(L[0])+'</b>'+L.slice(1).map(x=>'<div>'+h(x)+'</div>').join('');tip.style.display='block';});
document.addEventListener('mousemove',e=>{if(tip.style.display!=='block')return;
  const x=Math.min(e.clientX+14,innerWidth-tip.offsetWidth-8),y=e.clientY+18+tip.offsetHeight>innerHeight?e.clientY-tip.offsetHeight-10:e.clientY+18;
  tip.style.left=x+'px';tip.style.top=y+'px';});
document.addEventListener('mouseout',e=>{if(e.target.closest('.has-tip'))tip.style.display='none';});
// Ian: Excel-style sorting on the Actions/Units column headings.
const menu=document.createElement('div');menu.className='menu';document.body.append(menu);
const OPTS={t:[['Sort A → Z',1],['Sort Z → A',-1]],n:[['Sort largest to smallest',-1],['Sort smallest to largest',1]],
  g:[['Rising most first',-1],['Falling most first',1]]};
function sortBy(head,c,type,dir){
  const box=head.parentNode.parentNode,rows=[...box.querySelectorAll(':scope>details.x')];
  rows.sort((a,b)=>{
    if(c==='i')return a.dataset.ki-b.dataset.ki;
    const x=a.dataset['k'+c],y=b.dataset['k'+c];
    if(x===''||y==='')return (x==='')-(y==='');
    return type==='t'?dir*x.localeCompare(y):dir*(x-y);});
  for(const r of rows)box.append(r);
  for(const s of head.parentNode.children){s.classList.remove('on');s.textContent=s.textContent.replace(/ [▲▼]$/,'');}
  if(c!=='i'){head.classList.add('on');head.textContent+=dir>0?' ▲':' ▼';}
}
document.addEventListener('click',e=>{
  const head=e.target.closest('.xh span.s');
  if(!head){if(!e.target.closest('.menu'))menu.style.display='none';return;}
  const c=head.dataset.c,type=head.dataset.t;
  menu.innerHTML='';
  for(const [label,dir] of [...OPTS[type],['Original order',0]]){
    const b=document.createElement('button');b.textContent=label;
    b.onclick=()=>{sortBy(head,dir?c:'i',type,dir);menu.style.display='none';};menu.append(b);}
  const r=head.getBoundingClientRect();menu.style.display='block';
  menu.style.left=Math.min(r.left+scrollX,scrollX+innerWidth-menu.offsetWidth-8)+'px';menu.style.top=(r.bottom+scrollY+4)+'px';
});
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


def stat_card(title, rows, note=""):
    """A plain label/value card (values are text, so no bars)."""
    body = "".join(f"<tr><td>{esc(k)}</td><td class='n'>{esc(v)}</td></tr>" for k, v in rows)
    n = f'<div class="note">{esc(note)}</div>' if note else ""
    return f'<div class="card"><h3>{esc(title)}</h3><table>{body}</table>{n}</div>'


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
    rows, base, total = {"Actions": a["win_actions"], "Units": a["win_units"], "Titles": a["win_titles"]}[kind][ctx]
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
    """Click-to-expand rows (native <details>). Ian: clicking a column
    heading offers Excel-style sorting (A-Z, largest first, ...); each row
    carries its sort values as data-k0..k5 (empty = no value, sorted last)."""
    wins = a["win_actions" if kind == "action" else "win_units"]
    days = a["days"]
    heads = [("Action" if kind == "action" else "Unit", "t"), ("Uses" if kind == "action" else "Owners", "n"),
             ("Equipped by" if kind == "action" else "Fielded", "n"), ("Win rate", "n"), ("vs average", "n"), ("Trend", "g")]
    out = [f"<input class='f' placeholder='Filter {kind}s…' oninput=\"for(const d of this.parentNode.querySelectorAll('details.x'))d.style.display=d.dataset.n.includes(this.value.toLowerCase())?'':'none'\">",
           "<div class='xh'>" + "".join(f"<span class='s' data-c='{i}' data-t='{t}' title='Sort'>{esc(h)}</span>"
                                       for i, (h, t) in enumerate(heads)) + "</div>"]
    for i, k in enumerate(keys):
        w = wins[None][0].get(k)
        wr = pct(w[3]) if w and w[2] else "–"
        lift = pct(w[4], True) if w and w[2] >= MIN_FIGHTS else "<span class='note'>few fights</span>"
        if kind == "action":
            n2, n3 = a["c"]["actionUse"].get(k, 0), a["action_equipped"].get(k, 0)
            shares = [a["day_c"][d]["actionUse"].get(k, 0) / max(1, sum(a["day_c"][d]["actionUse"].values())) for d in days]
        else:
            n2, n3 = a["owned"].get(k, 0), a["fielded"].get(k, 0)
            shares = [a["day_c"][d]["partyWaves"].get(k, 0) / max(1, sum(a["day_c"][d]["partyWaves"].values())) for d in days]
        name = label(k)
        sort_vals = [name, n2, n3, w[3] if w and w[2] else "", w[4] if w and w[2] >= MIN_FIGHTS else "",
                     shares[-1] - shares[0] if len(shares) > 1 else ""]
        data = "".join(f" data-k{j}='{esc(v)}'" for j, v in enumerate(sort_vals))
        body = explorer_body(a, kind, k, label)
        out.append(f"<details class='x' data-n='{esc(name.lower())}' data-ki='{i}'{data}><summary><span><b>{esc(name)}</b></span><span>{fmt(n2)}</span>"
                   f"<span>{fmt(n3)}</span><span>{wr}</span><span>{lift}</span><span>{spark(shares)}</span></summary><div class='xb'>{body}</div></details>")
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
        P.append(bar_table("Gear worn", ranked(a["unit_gear"][k], lambda g: EQUIPMENT.get(g, {}).get("name", g)), ("Item", "Players"), limit=10))
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
    names_ = a.get("names", {})
    who = lambda pid: f"{pid} ({names_[pid]})" if pid in names_ else pid   # Arena players' Main Character names
    med = lambda xs: statistics.median(xs) if xs else 0
    c = a["c"]
    days = a["days"]
    P = []
    P.append("<header class='top' id='top'>")
    P.append(f"<h1>Farroad gameplay stats</h1><div class='sub'>{a['n_players']} players · {a['n_reports']} daily reports · "
             f"{esc(days[0]) if days else ''} to {esc(days[-1]) if days else ''} · built {datetime.now():%Y-%m-%d %H:%M}</div>")
    P.append("<nav>" + "".join(f"<a href='#{i}'>{t}</a>" for i, t in [
        ("players", "Players"), ("trends", "Trends"), ("wins", "Wins"), ("actions", "Actions"), ("units", "Units"), ("mc", "Main Character"),
        ("gambits", "Gambits"), ("spending", "Spending"), ("quests", "Quests & dungeons"), ("arena", "Arena"),
        ("expeditions", "Expeditions"), ("fights", "Fights"), ("waves", "Waves"), ("tutorials", "Tutorials")]) + "</nav>")
    hours = a["minutes"] / 60
    P.append("<div class='kpis'>" + "".join(f"<div class='kpi'><b>{v}</b><span>{esc(k)}</span></div>" for k, v in [
        ("players", a["n_players"]), ("hours played", fmt(hours)), ("sessions", fmt(a["sessions"])),
        ("median farthest wave", fmt(med(a["farthest"]))), ("median party Power", fmt(med(a["power"]))),
        ("time at 2x speed", f"{100 * a['fast_minutes'] / max(1, a['minutes']):.0f}%")]) + "</div>")

    P.append("</header>")

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
    # Ian: which player titles win the most battles
    for ctx in [None, "road", "quest", "dungeon", "pvp"]:
        P.append(win_rank_tables(a, "Titles", ctx, lambda t: t))
    P.append("</div>")

    P.append("<h2 id='actions'>Actions</h2><div class='note'>Click an action for its Lore upgrades, trends, win rates and who uses it.</div>")
    keys = sorted(set(c["actionUse"]) | set(a["action_equipped"]) | set(a["lore_held"]), key=lambda k: -c["actionUse"].get(k, 0))
    P.append(f"<div>{explorer(a, 'action', keys, act)}</div>")

    P.append("<h2 id='units'>Units</h2><div class='note'>Click a unit for its win rates, investment, loadouts and trend.</div>")
    keys = sorted(set(a["owned"]) | set(c["partyWaves"]), key=lambda k: -c["partyWaves"].get(k, 0))
    P.append(f"<div>{explorer(a, 'unit', keys, unit)}</div>")
    # Ian: compare Main Character archetypes (strongest element + role from its stat picks).
    P.append("<h2 id='mc'>Main Character archetypes</h2><div class='note'>Each player's Main Character, by title: "
             "its strongest element (base, bought and from gear) plus the role from its two highest stats at level 100. "
             "Hover an archetype for its usual stats, actions and partners.</div><div class='grid'>")
    rows = []
    for arch, d in sorted(a["mc_detail"].items(), key=lambda kv: -kv[1]["players"]):
        n = d["win"] + d["loss"]
        rows.append((arch, d["players"], fmt(med(d["farthest"])), fmt(med(d["power"])),
                     pct(d["win"] / n) if n else "–", fmt(n), act(d["charge"].most_common(1)[0][0]) if d["charge"] else "–"))
    P.append(bar_table("Archetypes", rows, ("Archetype", "Players", "Median farthest wave", "Median Power", "Win rate",
                                            "Fights", "Top charge action"), raw=True, limit=60,
                       note="Win rate covers every fight those players reported, so it also reflects the rest of their party."))
    P.append(bar_table("Main Character's charge action", ranked(a["mc_charge"], act), ("Action", "Players")))
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
    P.append(stat_card("Quest and dungeon participation", [
        ("Players who have done quests", a["quest_players"]),
        ("Share of all players (quests)", f"{100 * a['quest_players'] / np:.0f}%  ({a['quest_players']} of {a['n_players']})"),
        ("Players who have done dungeons", a["dungeon_players"]),
        ("Share of all players (dungeons)", f"{100 * a['dungeon_players'] / np:.0f}%  ({a['dungeon_players']} of {a['n_players']})")]))
    P.append(bar_table("Players who did quests",
                       [(who(pid), int(w["stages"]), int(w["cleared"]), int(w["failed"]), int(w["abandoned"]), w["last"])
                        for pid, w in sorted(a["quest_who"].items(), key=lambda kv: -kv[1]["stages"])],
                       ("Player", "Stages cleared", "Cleared (period)", "Failed (period)", "Gave up (period)", "Last seen"), raw=True,
                       note="Stages cleared is total quest progress from their save; the rest count fights in these reports."))
    P.append(bar_table("Players who did dungeons",
                       [(who(pid), int(w["clears"]), int(w["unlocked"]), int(w["cleared"]), int(w["failed"]), w["last"])
                        for pid, w in sorted(a["dungeon_who"].items(), key=lambda kv: -kv[1]["clears"])],
                       ("Player", "Total clears", "Dungeons unlocked", "Cleared (period)", "Failed (period)", "Last seen"), raw=True,
                       note="Total clears and dungeons unlocked are from their save; the rest count fights in these reports."))
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
    P.append(stat_card("Arena participation", [("Players who have fought", a["pvp_players"]),
                       ("Share of all players", f"{100 * a['pvp_players'] / np:.0f}%  ({a['pvp_players']} of {a['n_players']})")],
                       note=f"Average fight {fight_secs('pvp'):.0f}s · {fmt(c['features'].get('pvpSkip', 0))} fights skipped."))
    P.append(bar_table("Players who fought in the Arena",
                       [(who(pid), w["won"] + w["lost"], w["won"], w["lost"], f"{100 * w['won'] / max(1, w['won'] + w['lost']):.0f}%", w["last"])
                        for pid, w in sorted(a["arena_who"].items(), key=lambda kv: -(kv[1]["won"] + kv[1]["lost"]))],
                       ("Player", "Fights", "Won", "Lost", "Win rate", "Last seen"), raw=True,
                       note="Player ids; the name is the Main Character's name from the Arena server, where there is one. Record is each player's lifetime Arena record from their save."))
    P.append(bar_table("Results by opponent", [(("Shared code" if k == "code" else k.capitalize()), won[k] + lost[k], won[k], lost[k],
                       f"{100 * won[k] / max(1, won[k] + lost[k]):.0f}%") for k in rivals], ("Opponent", "Fights", "Won", "Lost", "Win rate")))
    P.append(win_rank_tables(a, "Units", "pvp", unit))
    P.append(win_rank_tables(a, "Actions", "pvp", act))
    P.append("</div>")

    P.append("<h2 id='expeditions'>Expeditions</h2><div class='grid'>")
    e = c["expedition"]
    P.append(stat_card("Expedition participation", [("Players who have used expeditions", a["expedition_players"]),
                       ("Share of all players", f"{100 * a['expedition_players'] / np:.0f}%  ({a['expedition_players']} of {a['n_players']})")]))
    P.append(bar_table("Players who used expeditions",
                       [(who(pid), int(w["sent"]), int(w["collected"]), w["depth"] or "–", w["last"])
                        for pid, w in sorted(a["exped_who"].items(), key=lambda kv: -kv[1]["sent"])],
                       ("Player", "Sent", "Collected", "Deepest wave", "Last seen"), raw=True,
                       note="Sent and collected count only what the reports in this period recorded; deepest wave is from their save."))
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
    tips_json = json.dumps(tips(a)).replace("</", "<\\/")
    return (f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<title>Farroad Stats</title><style>{CSS}</style></head><body><main>{''.join(P)}</main>"
            f"<script>const TIPS={tips_json};{SCRIPT}</script></body></html>")


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
    # names for Arena players only, from the Arena server (see refresh_arena_names)
    a["names"] = load_arena_names() if (args.no_fetch or args.from_file) else refresh_arena_names(set(a["arena_who"]))
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(build_html(a))
    print(f"{len(reports)} reports from {a['n_players']} players -> {args.out}")


if __name__ == "__main__":
    main()

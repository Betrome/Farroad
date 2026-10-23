class_name Goals
extends RefCounted
## Daily and weekly goals (Ian): a handful of small tasks in each list, each worth 1 Crystal when
## claimed. Daily goals reset at local midnight, weekly goals at local midnight on Monday.
##
## Progress lives in g["goals"] (saved with the game): {"day": N, "week": N,
## "daily": {id: {"n": progress, "claimed": bool}}, "weekly": {...}}. The game reports what happened
## through record(g, event, amount) from the places it happens; a goal lists the events that count.
##
## Events: expedition_sent, aether_spent (Aether spent on levels / Recovery / Evade and crit /
## affinities), pull (a Marks pull), enemies_defeated (Road waves), arena_fight, arena_win,
## quest_stage, dungeon, road_boss (a boss wave won on the Road).

const REWARD_CRYSTAL := 1

const DAILY: Array = [
	{"id": "d_expedition", "text": "Send out an expedition", "events": ["expedition_sent"], "target": 1},
	{"id": "d_aether", "text": "Spend Aether", "events": ["aether_spent"], "target": 5000},
	{"id": "d_pull", "text": "Use Marks on a pull", "events": ["pull"], "target": 1},
	{"id": "d_enemies", "text": "Defeat enemies on the Road", "events": ["enemies_defeated"], "target": 100},
	{"id": "d_arena", "text": "Fight in the Arena", "events": ["arena_fight"], "target": 3},
	{"id": "d_quest", "text": "Complete a quest stage or a dungeon", "events": ["quest_stage", "dungeon"], "target": 1},
]

const WEEKLY: Array = [
	{"id": "w_expedition", "text": "Send out expeditions", "events": ["expedition_sent"], "target": 10},
	{"id": "w_aether", "text": "Spend Aether", "events": ["aether_spent"], "target": 50000},
	{"id": "w_pull", "text": "Use Marks on pulls", "events": ["pull"], "target": 10},
	{"id": "w_enemies", "text": "Defeat enemies on the Road", "events": ["enemies_defeated"], "target": 1500},
	{"id": "w_arena", "text": "Win Arena fights", "events": ["arena_win"], "target": 5},
	{"id": "w_quest", "text": "Complete quest stages", "events": ["quest_stage"], "target": 3},
	{"id": "w_boss", "text": "Defeat a boss on the Road", "events": ["road_boss"], "target": 1},
]

## Tests only: replace the device's offset from UTC (seconds); NAN = use the real one.
static var tz_bias_override := NAN

static func tz_bias_sec() -> float:
	if not is_nan(tz_bias_override):
		return tz_bias_override
	return float(int(Time.get_time_zone_from_system().get("bias", 0))) * 60.0

## The local calendar day number (days since 1970-01-01 on the player's own clock).
static func local_day(ts) -> int:
	return int(floor((float(ts) + tz_bias_sec()) / 86400.0))

## Weeks start on Monday (1970-01-01 was a Thursday, so day 4 was the first Monday).
static func week_of_day(day: int) -> int:
	return int(floor(float(day + 3) / 7.0))

static func lists(kind: String) -> Array:
	return DAILY if kind == "daily" else WEEKLY

## Makes sure g["goals"] exists and starts a fresh list when the day or week has changed.
static func refresh(g: Dictionary, now = null) -> Dictionary:
	var t: float = float(now) if now != null else Time.get_unix_time_from_system()
	var day := local_day(t)
	var week := week_of_day(day)
	var st: Dictionary = g.get("goals") if g.get("goals") is Dictionary else {}
	if int(st.get("day", -1)) != day or not st.has("daily"):
		st["daily"] = {}
		st["day"] = day
	if int(st.get("week", -1)) != week or not st.has("weekly"):
		st["weekly"] = {}
		st["week"] = week
	g["goals"] = st
	return st

static func _entry(st: Dictionary, kind: String, id: String) -> Dictionary:
	var m: Dictionary = st[kind]
	if not m.has(id):
		m[id] = {"n": 0.0, "claimed": false}
	return m[id]

## Something happened: it counts toward every open goal that lists this event.
## set while the offline catch-up replays, so time away doesn't complete goals
static var paused := false

static func record(g: Dictionary, event: String, amount: float = 1.0, now = null) -> void:
	if amount <= 0.0 or paused:
		return
	var st := refresh(g, now)
	for kind in ["daily", "weekly"]:
		for def in lists(kind):
			if (def["events"] as Array).has(event):
				var e := _entry(st, kind, String(def["id"]))
				e["n"] = float(e["n"]) + amount

static func progress(g: Dictionary, kind: String, def: Dictionary) -> float:
	var st := refresh(g)
	return float(_entry(st, kind, String(def["id"]))["n"])

static func is_done(g: Dictionary, kind: String, def: Dictionary) -> bool:
	return progress(g, kind, def) >= float(def["target"])

static func is_claimed(g: Dictionary, kind: String, def: Dictionary) -> bool:
	var st := refresh(g)
	return bool(_entry(st, kind, String(def["id"]))["claimed"])

## Goals finished but not yet claimed (for the button's dot).
static func claimable_count(g: Dictionary) -> int:
	var n := 0
	for kind in ["daily", "weekly"]:
		for def in lists(kind):
			if is_done(g, kind, def) and not is_claimed(g, kind, def):
				n += 1
	return n

## Pays the Crystal for a finished goal, once. Returns whether it paid.
static func claim(g: Dictionary, kind: String, id: String) -> bool:
	var st := refresh(g)
	for def in lists(kind):
		if String(def["id"]) == id:
			var e := _entry(st, kind, id)
			if bool(e["claimed"]) or float(e["n"]) < float(def["target"]):
				return false
			e["claimed"] = true
			g["crystal"] = int(g.get("crystal", 0)) + REWARD_CRYSTAL
			return true
	return false

## Seconds until the next local midnight (daily reset) and the next Monday midnight (weekly reset).
static func seconds_to_reset(kind: String, now = null) -> float:
	var t: float = float(now) if now != null else Time.get_unix_time_from_system()
	var local: float = t + tz_bias_sec()
	var day := int(floor(local / 86400.0))
	var next_day_start := float(day + 1) * 86400.0
	if kind == "daily":
		return next_day_start - local
	var next_week_start := float((week_of_day(day) + 1) * 7 - 3) * 86400.0
	return next_week_start - local

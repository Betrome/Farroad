class_name Raids
extends RefCounted
## Weekly raid boss (Ian), version 1: your own team against one huge boss, no server.
##
## A new boss every week on the Seasons clock (Monday 00:00 UTC), picked from the week number so every
## player sees the same one. Each week the boss is strong against two elements and weak to two others, has
## one high stat and one low stat, and the rotation never repeats the same strong pair two weeks running
## (see spec()), so teams have to change. The week's strengths and weaknesses are shown up front.
##
## You get ATTEMPTS_PER_DAY attempts a day (resetting 00:00 UTC). Each attempt is a normal watched fight; the
## damage you deal comes off the boss's HP for the week, which is yours alone for now. At the end of the week
## the share of the boss you took off sets your tier and its reward, claimed from the Raids tab.
##
## The boss is built once per week from your own strength (its wave follows your furthest wave) and kept for the
## week, so levelling up mid-week doesn't move the goalposts.
##
## State, saved with the game, in g["raid"]:
##   {"week", "damage", "day", "used", "best", "frozen": {"wave", "snap", "pool"}, "pending": [{"week","pct","tier"}]}

const ELEMENTS := ["fire", "water", "earth", "air", "light", "dark"]
const STATS := ["atk", "mag", "def", "res", "spd", "hp"]
const STAT_NAMES := {"atk": "ATK", "mag": "MAG", "def": "DEF", "res": "RES", "spd": "SPD", "hp": "HP"}

const ATTEMPTS_PER_DAY := 3
## Affinity points: a strong element resists (like a Bane's opposite), a weak one takes extra damage.
const AFFINITY_STEP := 25.0
const HIGH_STAT_MUL := 1.5
const LOW_STAT_MUL := 0.6
## The boss's wave is this share of your furthest wave (snapped to a boss wave), never below wave 20.
const WAVE_FRAC := 0.8
## The week's HP pool is the boss's normal HP times this.
const HP_MUL := 50.0

## ===== the community boss (v3): every player's damage fills one shared bar =====
## Each attempt reports the share of the player's own boss it took (their own pool is scaled to their own
## strength), and the shares add up on the server. The community boss has `target` shares of HP: the more
## players, the bigger it is. It is down when the shares reach the target; milestones along the way pay everyone
## who took part (at least a Bronze share of their own boss).
const COMMUNITY_MIN_TARGET := 5.0
const COMMUNITY_PER_PLAYER := 0.25     # target = max(MIN, this x players)
const ACTIVE_WEEKS := 4                # "players" = those with a save upload or a fight in this many weeks
const PLAYER_WEEK_CAP := 1.0           # a player can add at most their own whole boss in a week; bounds cheating
const MILESTONES := [0.25, 0.5, 0.75, 1.0]
## What reaching the first N milestones pays each contributor (cumulative).
const MILESTONE_CRYSTAL := [2, 5, 10, 20]
const MILESTONE_DISTILLED := [0, 0, 1, 2]

static func community_target(players: int) -> float:
	return maxf(COMMUNITY_MIN_TARGET, COMMUNITY_PER_PLAYER * float(players))

static func milestones_reached(shares: float, target: float) -> int:
	var n := 0
	for m in MILESTONES:
		if shares >= float(m) * target:
			n += 1
	return n
## Bump when the boss's build changes: a boss frozen under older rules is rebuilt (keeping the share of its HP already taken).
const RULES_VERSION := 2

## Reward tiers by the share of the boss's HP you took off this week. Marks are paid as pulls' worth (100 each).
const TIERS: Array = [
	{"id": "platinum", "name": "Platinum", "min": 1.0, "crystal": 10, "pulls": 8, "distilled": 2},
	{"id": "gold", "name": "Gold", "min": 0.6, "crystal": 5, "pulls": 4, "distilled": 1},
	{"id": "silver", "name": "Silver", "min": 0.3, "crystal": 3, "pulls": 2, "distilled": 0},
	{"id": "bronze", "name": "Bronze", "min": 0.1, "crystal": 1, "pulls": 1, "distilled": 0},
]

const NAMES := {
	"fire": ["Cinder Tyrant", "Ashen Colossus", "The Pyre King"],
	"water": ["Tidal Leviathan", "The Drowned Matron", "Mistfall Serpent"],
	"earth": ["Stonebound Titan", "The Rootlord", "Gravel Wyrm"],
	"air": ["Storm Roc", "The Gale Sovereign", "Skyrend Wyvern"],
	"light": ["Dawn Seraph", "The Radiant Warden", "Sunlit Archon"],
	"dark": ["Hollow King", "The Umbral Hound", "Dusk Oracle"],
}

## ===== the week's boss =====

static var _order_memo: Dictionary = {}

## The three element pairs of a 3-week block, in the order they come up. A block's pairs are a seeded
## shuffle of the six elements; if its first pair would repeat the previous block's last, the order is rotated.
static func _block_order(block: int) -> Array:
	if _order_memo.has(block):
		return _order_memo[block]
	# a block depends on the one before it, so fill in from the nearest known block upward (a loop, not
	# recursion: this week is block ~1000, and a call chain that deep overflows the stack on a phone)
	var start := block
	while start > 0 and not _order_memo.has(start - 1):
		start -= 1
	for b in range(start, block + 1):
		_order_memo[b] = _make_block(b)
	return _order_memo[block]

static func _make_block(block: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("raid-block-%d" % block).hash()
	var els: Array = ELEMENTS.duplicate()
	for i in range(els.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = els[i]
		els[i] = els[j]
		els[j] = t
	var pairs: Array = [[els[0], els[1]], [els[2], els[3]], [els[4], els[5]]]
	if block > 0:
		var prev: Array = _order_memo[block - 1]
		if _same_pair(pairs[0], prev[2]):
			pairs = [pairs[1], pairs[2], pairs[0]]
	return pairs

static func _same_pair(a: Array, b: Array) -> bool:
	return a.has(b[0]) and a.has(b[1])

## The boss of a week: {week, name, strong: [el, el], weak: [el, el], high, low}.
static func spec(week: int) -> Dictionary:
	var block := int(floor(float(week) / 3.0))
	var idx := ((week % 3) + 3) % 3
	var order := _block_order(block)
	var strong: Array = order[idx]
	var weak: Array = order[(idx + 1) % 3]
	var rng := RandomNumberGenerator.new()
	rng.seed = ("raid-week-%d" % week).hash()
	var high: String = STATS[rng.randi_range(0, STATS.size() - 1)]
	var low: String = high
	while low == high:
		low = STATS[rng.randi_range(0, STATS.size() - 1)]
	var names: Array = NAMES[strong[0]]
	return {"week": week, "name": names[int(floor(float(week) / 6.0)) % names.size()], "strong": strong, "weak": weak, "high": high, "low": low}

## "Strong against Fire and Earth. Weak to Water and Light. High DEF, low SPD."
static func describe(s: Dictionary) -> Array:
	return ["Strong against %s and %s (it takes much less from them)." % [String(s["strong"][0]).capitalize(), String(s["strong"][1]).capitalize()],
		"Weak to %s and %s (it takes much more from them)." % [String(s["weak"][0]).capitalize(), String(s["weak"][1]).capitalize()],
		"High %s, low %s." % [STAT_NAMES[s["high"]], STAT_NAMES[s["low"]]]]

## ===== the player's week =====

static func week_of(now) -> int:
	return Seasons.season_of(now)

static func day_of(now) -> int:
	return int(floor(float(now) / 86400.0))

static func _state(g: Dictionary) -> Dictionary:
	if not (g.get("raid") is Dictionary):
		g["raid"] = {}
	return g["raid"]

## Brings g["raid"] up to date for `now`: a new week closes the old one (leaving its reward to claim) and starts clean.
static func refresh(g: Dictionary, now) -> Dictionary:
	var st := _state(g)
	var week := week_of(now)
	if int(st.get("week", -1)) != week:
		var frozen = st.get("frozen")
		if st.has("week") and frozen is Dictionary and float(st.get("damage", 0.0)) > 0.0:
			var pct: float = float(st["damage"]) / maxf(1.0, float(frozen["pool"]))
			var tier = tier_for(pct)
			if not tier.is_empty():
				var pend: Array = st.get("pending", [])
				pend.append({"week": int(st["week"]), "pct": pct, "tier": tier["id"], "milestones": int(st.get("commReached", 0))})
				st["pending"] = pend.slice(-8)
		st["week"] = week
		st["comm"] = null
		st["commReached"] = 0
		st["unsent"] = (st.get("unsent", []) as Array).filter(func(r): return int(r["week"]) == week)
		st["damage"] = 0.0
		st["best"] = 0.0
		st["used"] = 0
		st["day"] = day_of(now)
		st["frozen"] = null
	if int(st.get("day", -1)) != day_of(now):
		st["day"] = day_of(now)
		st["used"] = 0
	if not st.has("pending"):
		st["pending"] = []
	return st

static func attempts_left(g: Dictionary, now) -> int:
	var st := refresh(g, now)
	return maxi(0, ATTEMPTS_PER_DAY - int(st.get("used", 0)))

## The boss as this player faces it this week (built and frozen on first use): {wave, snap, pool}.
static func frozen_boss(g: Dictionary, now) -> Dictionary:
	var st := refresh(g, now)
	var carried_pct := 0.0
	var carried_best := 0.0
	if st.get("frozen") is Dictionary:
		if int(st["frozen"].get("v", 1)) == RULES_VERSION:
			return st["frozen"]
		# frozen under older rules: rebuild, keeping the share of the boss's HP already taken
		var old_pool: float = maxf(1.0, float(st["frozen"].get("pool", 1.0)))
		carried_pct = float(st.get("damage", 0.0)) / old_pool
		carried_best = float(st.get("best", 0.0)) / old_pool
	var s := spec(week_of(now))
	var wave := raid_wave(g)
	var base: Array = FarroadProgression.build_enemies(g, wave, true, "raid")
	var snap: Dictionary = FarroadProgression.bake_enemy_snapshot(base[0])
	snap["name"] = s["name"]
	var stats: Dictionary = snap["stats"]
	stats[s["high"]] = float(stats[s["high"]]) * HIGH_STAT_MUL
	stats[s["low"]] = float(stats[s["low"]]) * LOW_STAT_MUL
	var base_hp: float = float(stats["hp"])
	stats["hp"] = base_hp * HP_MUL
	var aff: Dictionary = snap["affinity"]
	for el in s["strong"]:
		aff[el] = float(aff.get(el, 0.0)) + AFFINITY_STEP
	for el in s["weak"]:
		aff[el] = float(aff.get(el, 0.0)) - AFFINITY_STEP
	st["frozen"] = {"wave": wave, "snap": snap, "pool": float(stats["hp"]), "baseHp": base_hp, "v": RULES_VERSION}
	if carried_pct > 0.0:
		st["damage"] = minf(1.0, carried_pct) * float(stats["hp"])
		st["best"] = minf(1.0, carried_best) * float(stats["hp"])
	return st["frozen"]

static func raid_wave(g: Dictionary) -> int:
	var w := int(floor(float(g.get("farthest", 1)) * WAVE_FRAC))
	return maxi(FarroadProgression.BOSS_WAVES[0], FarroadProgression.next_boss_wave(w - 1))

static func pool(g: Dictionary, now) -> float:
	return float(frozen_boss(g, now)["pool"])

static func damage_done(g: Dictionary, now) -> float:
	return float(refresh(g, now).get("damage", 0.0))

static func remaining_hp(g: Dictionary, now) -> float:
	return maxf(0.0, pool(g, now) - damage_done(g, now))

static func pct_done(g: Dictionary, now) -> float:
	return damage_done(g, now) / maxf(1.0, pool(g, now))

static func tier_for(pct: float) -> Dictionary:
	for t in TIERS:
		if pct >= float(t["min"]):
			return t
	return {}

static func tier_by_id(id: String) -> Dictionary:
	for t in TIERS:
		if String(t["id"]) == id:
			return t
	return TIERS[TIERS.size() - 1]

## The last community state this device heard of (from the server), if it is for this week: {week, shares, target, mine, reached, contributors}.
static func community(g: Dictionary, now) -> Dictionary:
	var c = refresh(g, now).get("comm")
	return c if c is Dictionary and int(c.get("week", -1)) == week_of(now) else {}

## The community boss is down: no more attempts until the week resets.
static func community_down(g: Dictionary, now) -> bool:
	var c := community(g, now)
	return not c.is_empty() and float(c["shares"]) >= float(c["target"])

## Takes in the server's answer (the community's shares, and how many milestones they've reached).
static func apply_community(g: Dictionary, now, view: Dictionary) -> void:
	var st := refresh(g, now)
	if int(view.get("week", -1)) != week_of(now):
		return
	st["comm"] = view
	st["commReached"] = maxi(int(st.get("commReached", 0)), int(view.get("reached", 0)))

## An attempt's share of your own boss, waiting to be told to the server.
static func queue_report(g: Dictionary, now, share: float) -> void:
	var st := refresh(g, now)
	var q: Array = st.get("unsent", [])
	q.append({"week": week_of(now), "day": day_of(now), "pct": share})   # the day it was played, not the day it syncs
	st["unsent"] = q.slice(-30)

## ===== an attempt =====

## Starts an attempt: uses one of today's, and returns {"enemies", "wave", "meta"} for the side battle
## ({} if there's nothing to fight: no attempts left, the boss is already down, or a side battle is on).
static func start_attempt(g: Dictionary, now) -> Dictionary:
	if g.get("sideBattle") != null or attempts_left(g, now) <= 0 or community_down(g, now):
		return {}
	var left := remaining_hp(g, now)
	if left <= 0.0:
		return {}
	var fz := frozen_boss(g, now)
	var boss: Dictionary = FarroadProgression.units_from_snapshots([fz["snap"]])[0]
	boss["maxHp"] = fz["pool"]
	boss["hp"] = left
	boss["dotBase"] = float(fz["baseHp"])   # burning and poison are a % of its normal HP, not of the whole pool
	var st := refresh(g, now)
	st["used"] = int(st.get("used", 0)) + 1
	return {"enemies": [boss], "wave": int(fz["wave"]),
		"meta": {"kind": "raid", "name": String(fz["snap"]["name"]), "startHp": left, "week": week_of(now)}}

## The HP the boss lost in a finished battle (all of `start_hp` if it fell).
static func damage_from_battle(battle: Dictionary, start_hp: float) -> float:
	for u in battle["units"]:
		if not u["isParty"]:
			return clampf(start_hp - maxf(0.0, float(u["hp"])), 0.0, start_hp)
	return 0.0

## Books an attempt's damage. Returns the result event for the popup.
static func finish(g: Dictionary, dmg: float, now) -> Dictionary:
	var st := refresh(g, now)
	var pool_hp := pool(g, now)
	# the raw numbers of the last attempt, to trace a wrong result
	st["last"] = {"dealt": dmg, "pool": pool_hp, "before": float(st.get("damage", 0.0))}
	st["damage"] = float(st.get("damage", 0.0)) + dmg
	st["best"] = maxf(float(st.get("best", 0.0)), dmg)
	var pct := float(st["damage"]) / maxf(1.0, pool_hp)
	queue_report(g, now, dmg / maxf(1.0, pool_hp))
	return {"kind": "raid_done", "damage": dmg, "pct": pct, "attemptPct": dmg / maxf(1.0, pool_hp),
		"defeated": float(st["damage"]) >= pool_hp, "tier": tier_for(pct).get("id", ""), "left": attempts_left(g, now)}

## ===== rewards =====

## Pays every finished week waiting to be claimed. Returns the totals {crystal, marks, distilled, weeks}.
static func claim_pending(g: Dictionary, now) -> Dictionary:
	var st := refresh(g, now)
	var out := {"crystal": 0, "marks": 0, "distilled": 0, "weeks": 0}
	for p in st.get("pending", []):
		var t := tier_by_id(String(p["tier"]))
		var marks: int = int(t["pulls"]) * FarroadProgression.pull_cost(int(g.get("wave", 1)))
		g["crystal"] = int(g.get("crystal", 0)) + int(t["crystal"])
		g["marks"] = float(g.get("marks", 0)) + float(marks)
		g["distilled"] = int(g.get("distilled", 0)) + int(t["distilled"])
		out["crystal"] += int(t["crystal"])
		out["marks"] += marks
		out["distilled"] += int(t["distilled"])
		# the community boss's milestones pay everyone who took part
		var ms: int = clampi(int(p.get("milestones", 0)), 0, MILESTONES.size())
		if ms > 0:
			g["crystal"] = int(g.get("crystal", 0)) + int(MILESTONE_CRYSTAL[ms - 1])
			g["distilled"] = int(g.get("distilled", 0)) + int(MILESTONE_DISTILLED[ms - 1])
			out["crystal"] += int(MILESTONE_CRYSTAL[ms - 1])
			out["distilled"] += int(MILESTONE_DISTILLED[ms - 1])
		out["weeks"] += 1
	st["pending"] = []
	return out

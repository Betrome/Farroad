class_name Chests
extends RefCounted
## Treasure chests on the Road (Ian): while the app is open, a chest in a magical bubble drifts in every
## 5-10 minutes; tapping it gives one random Gambit, action, piece of gear, Marks or Aether.
##
## The longer it has been since the last chest was opened, the better the prize, in proportion, so
## however often chests turn up the rewards roughly even out over time: a chest after 10 minutes is
## worth about twice one after 5.
##
## State lives in g["chest"]: {"since": app-open seconds since the last chest was opened,
## "next": seconds (of "since") at which the next chest appears, "there": a chest is waiting}.

const MIN_GAP := 300.0
const MAX_GAP := 600.0
## A chest after this many seconds pays its "standard" prize (the mean gap).
const STANDARD_SEC := 450.0
## Currency prizes: this many times the idle income over the waiting time, times the wave of the last boss defeated.
const CURRENCY_MUL := 2.0
const MIN_SINCE := 60.0
const MAX_SINCE := 3600.0
const KINDS := ["cond", "action", "equip", "marks", "aether"]

static func fresh(rng: FarroadCore.RNG) -> Dictionary:
	return {"since": 0.0, "next": roll_gap(rng), "there": false}

static func roll_gap(rng: FarroadCore.RNG) -> float:
	return MIN_GAP + rng.next() * (MAX_GAP - MIN_GAP)

static func state(g: Dictionary) -> Dictionary:
	if not (g.get("chest") is Dictionary) or (g["chest"] as Dictionary).is_empty():
		g["chest"] = fresh(g["rng"])
	return g["chest"]

## Counts app-open time; returns true on the tick the chest appears.
static func tick(g: Dictionary, dt: float) -> bool:
	var c: Dictionary = state(g)
	c["since"] = minf(float(c["since"]) + dt, MAX_SINCE * 2.0)
	if bool(c.get("there", false)):
		return false
	if float(c["since"]) >= float(c["next"]):
		c["there"] = true
		return true
	return false

## The wave of the last boss defeated (the Road's farthest wave is past it), at least 1.
static func boss_multiplier(g: Dictionary) -> int:
	var w: int = int(g.get("farthest", 1)) - 1
	while w >= 1:
		if FarroadProgression.is_boss_wave(w):
			return maxi(1, w / 2)
		w -= 1
	return 1

## 1.0 for a standard (mean-gap) chest, more the longer it has been.
static func quality(since: float) -> float:
	return clampf(since, MIN_SINCE, MAX_SINCE) / STANDARD_SEC

static func _rarity_pool(ids: Array, rarity_of: Callable, q: float, rng: FarroadCore.RNG) -> Array:
	var roll: float = rng.next()
	var want := "common"
	if roll < minf(0.5, 0.04 * q):
		want = "legendary"
	elif roll < minf(0.5, 0.04 * q) + minf(0.8, 0.25 * q):
		want = "rare"
	var pool: Array = ids.filter(func(id): return str(rarity_of.call(id)) == want)
	return pool if not pool.is_empty() else ids

## Opens the waiting chest: mutates g and returns {"kind", "id", "amount", "duplicate", "level", "aetherGain", "loreAction", "q"}.
static func open(g: Dictionary) -> Dictionary:
	var c: Dictionary = state(g)
	var since: float = float(c["since"])
	var q: float = quality(since)
	var rng: FarroadCore.RNG = g["rng"]
	var kind: String = KINDS[rng.next_int(KINDS.size())]
	var out := {"kind": kind, "id": "", "amount": 0, "duplicate": false, "level": 0, "aetherGain": 0, "loreAction": "", "q": q}
	match kind:
		"aether", "marks":
			var per: Dictionary = FarroadProgression.idle_per_sec_g(g)
			var amt: float = float(per[kind]) * clampf(since, MIN_SINCE, MAX_SINCE) * CURRENCY_MUL
			amt = maxf(1.0, floor(amt * float(boss_multiplier(g))))
			g[kind] = float(g.get(kind, 0.0)) + amt
			out["amount"] = int(amt)
		"equip":
			var ids: Array = FarroadProgression.random_equipment_ids()
			var pool: Array = _rarity_pool(ids, func(id): return FarroadCore.EQUIPMENT.get(id, {}).get("rarity", "common"), q, rng)
			var id: String = pool[rng.next_int(pool.size())]
			var got: Dictionary = FarroadProgression.gain_gear(g, id)
			out["id"] = id
			out["duplicate"] = bool(got["duplicate"])
			out["level"] = int(got["level"])
			FarroadProgression.auto_equip(g)
		"action":
			var pool_a: Array = _rarity_pool(FarroadCore.equippable(), func(id): return FarroadCore.ACTIONS.get(id, {}).get("rarity", "common"), q, rng)
			var unowned: Array = pool_a.filter(func(id): return not g["actions"].has(id))
			var pick_from: Array = unowned if not unowned.is_empty() else pool_a
			var aid: String = pick_from[rng.next_int(pick_from.size())]
			g["actionCounts"][aid] = g["actionCounts"].get(aid, 0) + 1
			var dup: bool = g["actions"].has(aid)
			if not dup:
				g["actions"].append(aid)
			else:
				FarroadProgression._credit_lore(g, aid)
			out["id"] = aid
			out["duplicate"] = dup
			FarroadProgression.auto_equip(g)
		_:
			var all_c: Array = FarroadCore.ALL_CONDITION_IDS.filter(func(id): return id != "none")
			var fresh_c: Array = all_c.filter(func(id): return not g["conditions"].has(id))
			var from_c: Array = fresh_c if not fresh_c.is_empty() else all_c
			var cid: String = from_c[rng.next_int(from_c.size())]
			g["condCounts"][cid] = g["condCounts"].get(cid, 0) + 1
			var dup_c: bool = g["conditions"].has(cid)
			if not dup_c:
				g["conditions"].append(cid)
			else:
				out["aetherGain"] = FarroadProgression._credit_dup_gambit(g)
			out["id"] = cid
			out["duplicate"] = dup_c
	c["since"] = 0.0
	c["next"] = roll_gap(rng)
	c["there"] = false
	return out

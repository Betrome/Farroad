class_name FarroadProgression
extends RefCounted
## Ported economy/curves/drops/enemy-building layer -- GDScript counterpart to
## src/farroad-progression.js, PLUS the wave-loop orchestration functions that
## live in src/farroad-ui.js (buildParty/buildEnemies/grantDrops/startWave/
## afterWaveCleared/onWipe/etc) despite not touching the DOM themselves --
## confirmed by reading their real bodies (Milestone 3, Step 3a research).
## Ported as explicit-parameter static functions taking `g` (the game-state
## Dictionary) rather than reading an ambient global, matching the "no hidden
## globals" discipline FarroadCore.gd already established -- unlike the real
## JS, which reads window-scoped G directly.
##
## OUT OF SCOPE for this step (see the plan): everything gated on
## window.FarroadContent.DIRECTION_CONFIG/QUEST_LINES (directions, dungeons,
## expeditions, super-boss quests, companion quest lines) -- those CSV tables
## are deliberately not exported yet (Milestone 1 Step 1e's own note), and
## the MC character-creation screen's own point-buy math (mcLerp/mcBuildStats
## and friends) -- pure UI-screen concerns with no caller anywhere in the
## core wave loop, deferred to Step 3j.
##
## UI-facing text (pushDrop's HTML bodies, sysLog lines) is NOT ported here --
## grant_drops/after_wave_cleared/on_wipe return plain event Dictionaries
## instead, for whatever future UI layer to render however it likes. This
## mirrors the real split exactly: farroad-progression.js itself never builds
## HTML either, that's farroad-ui.js's job.

## ===== wave/difficulty =====

const BOSS_EVERY := 20
const BOSS_WAVES: Array[int] = [20]
const BOSS_LEN := 1.40   # 1.3-1.5x a normal fight
# The wave-20 boss specifically (fought solo, before the 2nd party member
# joins) was a ~2.8x-HP wall -- eased to ~2.3x for THIS ONE boss only
# (build_enemies checks w==BOSS_WAVES[0]), leaving BOSS_LEN itself (and
# every later boss, wave 40 on) untouched. A flat BOSS_LEN cut would also
# have collided with DUNGEON_LEN (kept "clearly short of the boss band"
# per its own real-JS comment) and permanently softened every future boss.
# Round 2 (still too hard even with the eased ~2.3x + cheap tutorial
# retries): cut a further ~20% off THIS boss's HP specifically -- 0.92 is
# 1.15*0.80, so its HP is now ~1.84x a normal enemy's (2 enemy-count-
# equivalents * 0.92), not ~2.3x.
const FIRST_BOSS_LEN := 0.92

static func boss_wave_at(i: int) -> int:
	if i < BOSS_WAVES.size():
		return BOSS_WAVES[i]
	return BOSS_WAVES[BOSS_WAVES.size() - 1] + BOSS_EVERY * (i - BOSS_WAVES.size() + 1)

static func is_boss_wave(w: int) -> bool:
	var last: int = BOSS_WAVES[BOSS_WAVES.size() - 1]
	if w < last:
		return BOSS_WAVES.has(w)
	return (w - last) % BOSS_EVERY == 0

static func next_boss_wave(w: int) -> int:
	for bw in BOSS_WAVES:
		if bw > w:
			return bw
	var last: int = BOSS_WAVES[BOSS_WAVES.size() - 1]
	if w < last:
		return last
	return last + BOSS_EVERY * (int((w - last) / float(BOSS_EVERY)) + 1)

## Before the first boss, a wipe used to always return to wave 1 no matter
## how far the player had gotten -- with waves 1-19 fought solo, that meant
## every failed boss attempt cost a full 19-wave re-clear just to try again.
## TUTORIAL_CHECKPOINT_EVERY snaps `farthest` down to the nearest 5-wave
## boundary (1/6/11/16) instead, so a wipe costs at most 4 waves of replay
## plus the boss attempt. Only the bosses_cleared==0 case changes -- once a
## boss is cleared, checkpoint() is exactly what it always was (the boss
## wave + 1), unaffected by `farthest`.
const TUTORIAL_CHECKPOINT_EVERY := 5

static func checkpoint(bosses_cleared: int, farthest: int = 1) -> int:
	if bosses_cleared > 0:
		return boss_wave_at(bosses_cleared - 1) + 1
	var f: int = farthest if farthest > 0 else 1
	return maxi(1, int((f - 1) / TUTORIAL_CHECKPOINT_EVERY) * TUTORIAL_CHECKPOINT_EVERY + 1)

const VARIETY_FROM := 40
const COUNT_WEIGHTS: Array = [[1, 0.15], [2, 0.30], [3, 0.35], [4, 0.20]]
const ENEMY_CAP := 10
const COUNT_WEIGHTS_HARD: Array = [[1, 0.05], [2, 0.08], [3, 0.12], [4, 0.15], [5, 0.15],
	[6, 0.13], [7, 0.11], [8, 0.09], [9, 0.07], [10, 0.05]]
const HARD_FROM := 100
const HARD_REF := 800.0
const HARD_MAX := 20.0
const BOSS_HARD_EXTRA := 1.20   # additional boss-only ATK/MAG multiplier
# Same "wave-20 boss only" scoping as FIRST_BOSS_LEN above -- combined with
# the flat 1.10 boss ATK bonus in build_enemies, the wave-20 boss's damage
# output drops from ~1.32x to ~1.16x a normal enemy's, without touching
# BOSS_HARD_EXTRA itself (which also feeds every later boss's damage past
# HARD_FROM=100 -- cutting it globally would have quietly nerfed every
# boss forever, not just the tutorial one).
const FIRST_BOSS_HARD_EXTRA := 1.05
# Round 2: the eased boss (~1.16x a normal enemy's damage via the two
# constants above) was still knocking out a solo character too fast --
# cut the wave-20 boss's actual ATK/MAG output by a further ~30%, scoped
# the same way (only w==BOSS_WAVES[0], applied directly to the final
# atk/mag stat values below rather than folded into hard_atk_mul, so it
# touches damage only -- not HP, crit, spd, or anything else BOSS_HARD_EXTRA
# also feeds).
const FIRST_BOSS_DMG_MUL := 0.70
const BOSS_SPD_FROM := 20.0
const BOSS_SPD_REF := 800.0
const BOSS_SPD_MAX_MUL := 2.2
const DIFFICULTY := 1.00

static func party_size_at(w: int) -> int:
	for i in range(UNIT_WAVES.size() - 1, -1, -1):
		if w >= UNIT_WAVES[i]:
			return mini(PARTY_CAP, i + 2)
	return 1

static func enemy_count(w: int) -> int:
	return party_size_at(w)

static func roll_count(rng: FarroadCore.RNG, w: int) -> int:
	var table: Array = COUNT_WEIGHTS_HARD if w > HARD_FROM else COUNT_WEIGHTS
	var r := rng.next()
	var acc := 0.0
	for row in table:
		acc += row[1]
		if r <= acc:
			return row[0]
	return table[table.size() - 1][0]

static func count_strength(n: int) -> float:
	match n:
		1: return 1.85
		2: return 1.30
		3: return 0.96
		4: return 0.72
		_: return 2.9 / n

static func band_roll(rng: FarroadCore.RNG) -> float:
	return 0.85 + rng.next() * 0.35

static func hard_mul(w: float) -> float:
	if w <= HARD_FROM:
		return 1.0
	var t: float = minf(1.0, sqrt((w - HARD_FROM) / (HARD_REF - HARD_FROM)))
	return 1.0 + (HARD_MAX - 1.0) * t

static func boss_spd_mul(w: float) -> float:
	var t: float = minf(1.0, sqrt(maxf(0.0, w - BOSS_SPD_FROM) / (BOSS_SPD_REF - BOSS_SPD_FROM)))
	return 1.0 + (BOSS_SPD_MAX_MUL - 1.0) * t

const WAVE_ARCH: Array[String] = ["wolf", "wolf", "wolf", "wolf", "priest", "priest", "priest",
	"hound", "hound", "hound", "shrike", "shrike", "shrike", "ox", "ox", "ox",
	"knight", "knight", "knight"]

static func archetype_for(w: int, i: int) -> String:
	if w <= 19:
		return WAVE_ARCH[w - 1]
	return FarroadCore.ROT[(w - 1 + i) % FarroadCore.ROT.size()]

## ===== economy =====

const AETHER_RATE := 0.18
const MARKS_RATE := 0.13
const PRE_UNLOCK_MARKS_MUL := 0.45
const MARKS_UNLOCK_WAVE := 40
## Display-only ("X pulls waiting" on the locked screen); pull_cost's own
## flat 100 is the real gate, this just happens to share the same number.
const MARKS_PER_PULL := 100
const BOSS_AETHER_WAVES := 12.5
const DUP_UNIT_WAVES := 3
const NOMINAL_WAVE_SEC := 40.0
const IDLE_FLOOR_PER_5MIN := 1.0
const IDLE_AETHER_GROWTH_MUL := 0.5
const IDLE_MARKS_GROWTH_MUL := 2.0

static func pulls_unlocked(g: Dictionary) -> bool:
	return g.get("farthest", 1) >= MARKS_UNLOCK_WAVE

static func marks_mul(g: Dictionary) -> float:
	return 1.0 if pulls_unlocked(g) else PRE_UNLOCK_MARKS_MUL

static func kill_reward(w: float, n: int) -> Dictionary:
	var s: float = FarroadCore.wave_scale(w)
	return {"aether": 14.0 * s * AETHER_RATE * n, "marks": 3.0 * s * MARKS_RATE * n}

static func idle_growth(w: float) -> float:
	return sqrt(FarroadCore.wave_scale(w))

static func idle_per_sec(farthest: float) -> Dictionary:
	var gr := idle_growth(farthest)
	var aether5: float = IDLE_FLOOR_PER_5MIN + (gr - 1.0) * IDLE_AETHER_GROWTH_MUL
	var marks5: float = IDLE_FLOOR_PER_5MIN + (gr - 1.0) * IDLE_MARKS_GROWTH_MUL
	return {"aether": aether5 / 300.0, "marks": marks5 / 300.0}

static func boss_aether(w: float) -> int:
	var kr: float = kill_reward(w, enemy_count(int(w)))["aether"]
	var idle: float = idle_per_sec(w)["aether"] * NOMINAL_WAVE_SEC
	return int(round(BOSS_AETHER_WAVES * (kr + idle)))

static func dup_unit_aether(w: float) -> int:
	var kr: float = kill_reward(w, enemy_count(int(w)))["aether"]
	var idle: float = idle_per_sec(w)["aether"] * NOMINAL_WAVE_SEC
	return int(round(DUP_UNIT_WAVES * (kr + idle)))

## Mirrors pullCostAt/pullCost (farroad-progression.js:59, :787) -- a flat
## cost, deliberately non-scaling (v2.3). There is only ONE pull tier in
## the real game -- no premium/bulk variant exists.
static func pull_cost_at(_w: float) -> int:
	return 100

static func pull_cost(w: float) -> int:
	return pull_cost_at(w if w else 1.0)

## ===== MARKS tab: gacha pulls (Step 3g) =====

## Mirrors P.PULL_ODDS (farroad-ui.js:2286) -- equip is "about as rare as
## units" (Ian's own call in the real game's v2.14 changelog).
const PULL_ODDS := {"unit": 0.10, "equip": 0.10, "action": 0.40, "cond": 0.40}
## Mirrors P.PULL_PITY_AT (farroad-ui.js:2294) -- a companion is guaranteed
## at least every 30 pulls regardless of the roll.
const PULL_PITY_AT := 30

## Mirrors doPull (farroad-ui.js:2295-2367). Returns {} if locked or
## unaffordable (mirrors the real function's own silent early `return` --
## the UI's disabled button is the only real gate a player ever hits).
## Otherwise returns a small event Dictionary describing what happened
## ({"kind":..., "id":..., "duplicate":..., "pity":..., ...}) -- there is
## no drop-banner/toast system in this port yet (wave drops already
## return this same shape of event and nothing renders them either), so
## this is what MarksPanel.gd shows as a plain "Last pull" result line
## rather than the real game's pushDrop() card; a real UI subsystem for
## that is out of this step's scope. Pure g-mutation only, no live-sync
## side effects -- see MarksPanel.gd for why that stays the caller's job.
static func do_pull(g: Dictionary) -> Dictionary:
	var cost := pull_cost(g.get("wave", 1))
	if not pulls_unlocked(g):
		return {}
	if g["marks"] < cost:
		return {}
	g["marks"] -= cost
	g["pullsSinceUnit"] = int(g.get("pullsSinceUnit", 0)) + 1
	var pity: bool = g["pullsSinceUnit"] >= PULL_PITY_AT
	# The roll is ALWAYS consumed, even under pity -- pity overrides the
	# roll's RESULT, it doesn't skip drawing it (a real RNG-consumption
	# detail confirmed from the source, needed for parity).
	var roll: float = g["rng"].next()
	var o = PULL_ODDS
	var kind: String
	if pity:
		kind = "unit"
	elif roll < o["unit"]:
		kind = "unit"
	elif roll < o["unit"] + o["equip"]:
		kind = "equip"
	elif roll < o["unit"] + o["equip"] + o["action"]:
		kind = "action"
	else:
		kind = "cond"

	if kind == "unit":
		# Nothing more this pity cycle could grant, hit or not.
		g["pullsSinceUnit"] = 0
		# v2.8 bugfix kept: filter on OWNED, not party -- a benched unit is
		# still a real acquisition.
		var avail: Array = FarroadCore.ROSTER.filter(func(r): return not g["owned"].get(r["id"], false))
		if avail.is_empty():
			var dup := dup_unit_aether(g.get("wave", 1))
			g["aether"] += dup
			return {"kind": "unit_dup", "pity": pity, "aetherGain": dup}
		var pick: Dictionary = weighted_roster_pick(g["rng"], avail)
		var fielded: bool = join_companion(g, pick["id"])
		return {"kind": "unit", "pity": pity, "id": pick["id"], "name": pick["name"], "fielded": fielded}
	elif kind == "equip":
		# Same rule as random_drop's own equip branch: a dupe is never
		# converted -- extra copies are genuinely useful (dual-wielding a
		# hand item, the same armor on two units).
		var equip_ids := random_equipment_ids()
		var eid: String = weighted_equipment_pick(g["rng"], equip_ids)
		g["equipInv"][eid] = int(g["equipInv"].get(eid, 0)) + 1
		return {"kind": "equip", "id": eid, "duplicate": g["equipInv"][eid] > 1, "ownedCount": g["equipInv"][eid]}
	elif kind == "action":
		var aid: String = weighted_action_pick(g["rng"], FarroadCore.equippable())
		g["actionCounts"][aid] = int(g["actionCounts"].get(aid, 0)) + 1
		var dup_a: bool = g["actions"].has(aid)
		if not dup_a:
			g["actions"].append(aid)
		else:
			g["lore"] = g.get("lore", 0) + 1
		return {"kind": "action", "id": aid, "duplicate": dup_a}
	else:
		var cp: Array = FarroadCore.ALL_CONDITION_IDS.filter(func(id): return id != "none")
		var cid: String = cp[g["rng"].next_int(cp.size())]
		g["condCounts"][cid] = int(g["condCounts"].get(cid, 0)) + 1
		var dup_c: bool = g["conditions"].has(cid)
		if not dup_c:
			g["conditions"].append(cid)
		else:
			g["lore"] = g.get("lore", 0) + 1
		return {"kind": "cond", "id": cid, "duplicate": dup_c}

static func travel_sec(w: float) -> float:
	return 8.0 + 0.08 * w

static func waves_per_hour(w: float) -> float:
	return 3600.0 / (20.0 + travel_sec(w))

const OFFLINE_CAP_SEC := 12 * 3600

## ===== recovery (between-wave HP carry) =====

const REST := 0.00
const REST_CAP := 0.50
const REST_STEP := 0.03

static func recovery_of(g: Dictionary, uid: String) -> float:
	var steps: int = g.get("recovery", {}).get(uid, 0)
	return minf(REST_CAP, REST + REST_STEP * steps)

## Mirrors recoveryCost (farroad-ui.js:195).
static func recovery_cost(g: Dictionary, uid: String) -> int:
	var steps: int = g.get("recovery", {}).get(uid, 0)
	return int(round(10.0 * pow(1.45, steps)))

static func recovery_maxed(g: Dictionary, uid: String) -> bool:
	return recovery_of(g, uid) >= REST_CAP - 1e-9

## ===== curated onboarding =====

const STARTER_ACTIONS: Array[String] = ["strike", "ember"]
const CURATED: Array = [
	{"w": 2, "kind": "action", "id": "sear", "why": "first magic tool — takes reach-wave-8 from 3/10 to 10/10"},
	{"w": 3, "kind": "cond", "id": "foe_lacks_debuff", "why": "gates Sear — Burning is wasted if reapplied"},
	{"w": 4, "kind": "action", "id": "hex", "why": "Frail cuts RES before the armoured foe arrives"},
	{"w": 5, "kind": "cond", "id": "foe_armoured", "why": "Barrow Knight arrives — DEF 34, physical stalls"},
	{"w": 6, "kind": "action", "id": "bulwark", "why": "Warded ×0.60; holds the 10th-percentile at wave 9"},
	{"w": 7, "kind": "cond", "id": "ally_lacks_buff", "why": "gates Bulwark — do not overwrite a running buff"},
	{"w": 8, "kind": "action", "id": "mend", "why": "THE survival lesson, worth +277%"},
	{"w": 9, "kind": "cond", "id": "self_hp_lte_50", "why": "gates Mend — the highest-value rule in the game"},
	{"w": 10, "kind": "action", "id": "cripple", "why": "Slowed ×1.50 turn cost = 33% fewer enemy turns"},
	{"w": 11, "kind": "cond", "id": "foe_fast", "why": "gates Cripple — relative, so it survives stat scaling"},
	{"w": 12, "kind": "action", "id": "smother", "why": "Dulled cuts the Fen Priest's healing"},
	{"w": 13, "kind": "cond", "id": "ally_hp_lte_60", "why": "party-scale healing, ready for character 2"},
	{"w": 14, "kind": "action", "id": "daunt", "why": "Enfeebled ×0.75 ATK as the count rises"},
	{"w": 15, "kind": "cond", "id": "foe_lowest_hp", "why": "2 enemies begin — focus fire stops being degenerate"},
	{"w": 16, "kind": "action", "id": "gale", "why": "magic AoE first — Shrike thorns punish PHYSICAL AoE"},
	{"w": 17, "kind": "cond", "id": "foe_highest_hp", "why": "gates Gale and Daunt"},
	{"w": 18, "kind": "action", "id": "cleave", "why": "physical AoE, once you know when not to use it"},
	{"w": 19, "kind": "cond", "id": "foe_hp_gte_70", "why": "gates Cleave/Gale — AoE early, single-target once hurt"},
	{"w": 20, "kind": "action", "id": "execute", "why": "BOSS — always crits below 30%"}]

static func drops_at(w: int) -> Array:
	var out := []
	for d in CURATED:
		if d["w"] == w:
			out.append(d)
	return out

static func is_curated(w: int) -> bool:
	return w <= BOSS_EVERY

## ===== gacha-adjacent math (weighted picks, used by random_drop now and by
## the future MARKS pull screen, Step 3g) =====

const RARITY_PULL_WEIGHT := {"common": 3, "rare": 1, "legendary": 1}

static func weighted_roster_pick(rng: FarroadCore.RNG, list: Array) -> Dictionary:
	var weights: Array = list.map(func(r): return RARITY_PULL_WEIGHT.get(r.get("rarity", "common"), 1))
	var total: float = 0.0
	for wgt in weights:
		total += wgt
	var roll := rng.next() * total
	var acc := 0.0
	for i in range(list.size()):
		acc += weights[i]
		if roll < acc:
			return list[i]
	return list[list.size() - 1]

static func weighted_action_pick(rng: FarroadCore.RNG, ids: Array) -> String:
	var weights: Array = ids.map(func(id): return RARITY_PULL_WEIGHT.get(
		FarroadCore.ACTIONS.get(id, {}).get("rarity", "common"), 1))
	var total: float = 0.0
	for wgt in weights:
		total += wgt
	var roll := rng.next() * total
	var acc := 0.0
	for i in range(ids.size()):
		acc += weights[i]
		if roll < acc:
			return ids[i]
	return ids[ids.size() - 1]

static func weighted_equipment_pick(rng: FarroadCore.RNG, ids: Array) -> String:
	var weights: Array = ids.map(func(id): return RARITY_PULL_WEIGHT.get(
		FarroadCore.EQUIPMENT.get(id, {}).get("rarity", "common"), 1))
	var total: float = 0.0
	for wgt in weights:
		total += wgt
	var roll := rng.next() * total
	var acc := 0.0
	for i in range(ids.size()):
		acc += weights[i]
		if roll < acc:
			return ids[i]
	return ids[ids.size() - 1]

## ===== roster cadence =====

const PARTY_CAP := 5
const POOL_SIZE := 25
const BOSS_UNIT_ORDER: Array[String] = ["ansa", "dorrek", "vey", "mirel"]
const UNIT_WAVES: Array[int] = [20, 150, 500, 1500]

static func unit_due_at(w: int) -> Variant:
	var i := UNIT_WAVES.find(w)
	return BOSS_UNIT_ORDER[i] if i >= 0 else null

## ===== rare charge-action / equipment drop pools (random_drop, MC-gated
## pieces correctly no-op while g.mc is null -- pre-Step-3j) =====

const MC_CHARGE_DROP_POOL: Array[String] = ["tideturn", "lastlight", "sunder", "gravewind",
	"reckoning", "bulwarkoath", "emberglut", "hollowtoll",
	"atk_reckless", "mag_lance", "def_slam", "res_strike", "spd_flurry",
	"atk_cry", "mag_font", "def_bulwark", "res_ward", "spd_fleet"]
const MC_CHARGE_DROP_CHANCE := 0.10
const MC_LEGENDARY_CHARGE_CHANCE := 0.15
const EQUIP_DROP_CHANCE := 0.10

## ===== leveling =====

const GROWTH := {
	"kesh": {"hp": 34, "atk": 2.1, "mag": 1.0, "def": 1.4, "res": 1.0, "spd": 2.2},
	"ansa": {"hp": 22, "atk": 0.8, "mag": 2.3, "def": 0.9, "res": 1.7, "spd": 2.0},
	"dorrek": {"hp": 48, "atk": 1.6, "mag": 0.5, "def": 2.4, "res": 1.4, "spd": 1.4},
	"vey": {"hp": 21, "atk": 2.0, "mag": 0.7, "def": 0.9, "res": 0.8, "spd": 3.2},
	"mirel": {"hp": 18, "atk": 0.6, "mag": 2.7, "def": 0.8, "res": 1.5, "spd": 1.9},
	"skarn": {"hp": 24, "atk": 2.1, "mag": 0.9, "def": 1.6, "res": 1.5, "spd": 3.3},
	"sorin": {"hp": 38, "atk": 2.0, "mag": 2.0, "def": 1.6, "res": 1.5, "spd": 2.3},
	"nyra": {"hp": 25, "atk": 1.1, "mag": 2.1, "def": 2.0, "res": 2.0, "spd": 2.1},
	"brenn": {"hp": 48, "atk": 1.4, "mag": 1.3, "def": 1.9, "res": 1.9, "spd": 3.0},
	"sael": {"hp": 24, "atk": 0.8, "mag": 2.5, "def": 1.1, "res": 1.6, "spd": 3.4}}

static func exp_for(l: int) -> int:
	return int(round(0.8 * pow(l, 2.8)))

const DISCOUNT_FLOOR := 0.15

static func marginal(l: int) -> int:
	return maxi(1, exp_for(l) - exp_for(l - 1))

static func discount(l: int, r: int) -> float:
	if r <= 1:
		return 1.0
	return maxf(DISCOUNT_FLOOR, minf(1.0, float(l) / float(r)))

static func cost_to_next(l: int, r: int) -> int:
	return maxi(1, int(round(marginal(l + 1) * discount(l + 1, r))))

static func level_from_exp(x: float) -> int:
	var l := 1
	while exp_for(l + 1) <= x:
		l += 1
	return l

static func stats_at(uid: String, base: Dictionary, base_hp: float, l: int) -> Dictionary:
	var g: Dictionary = GROWTH.get(uid, GROWTH["kesh"])
	var n := l - 1
	var o := {}
	for s in ["atk", "mag", "def", "res", "spd"]:
		o[s] = int(round(float(base[s]) + g[s] * n))
	o["hp"] = int(round(base_hp + g["hp"] * n))
	for k in ["atkCrit", "magCrit", "chargeRate", "evade"]:
		o[k] = base[k]
	return o

const SLOT_LEVELS: Array[int] = [1, 1, 10, 100, 500, 1000]

static func slots_at(l: int) -> int:
	var n := 0
	for lvl in SLOT_LEVELS:
		if l >= lvl:
			n += 1
	return maxi(2, n)

static func next_slot_at(l: int) -> Variant:
	for lvl in SLOT_LEVELS:
		if l < lvl:
			return lvl
	return null

static func rarity_cost_mul(uid: String) -> float:
	var def = FarroadCore.roster_by_id(uid)
	return FarroadCore.RARITY_COST_MUL.get(def["rarity"] if def else "common", 1.0)

static func level_of(g: Dictionary, uid: String) -> int:
	return g.get("lvl", {}).get(uid, 1)

## Mirrors expOf (farroad-ui.js:199) -- unspent Aether sitting in a unit's bank.
static func exp_of(g: Dictionary, uid: String) -> float:
	return g.get("bank", {}).get(uid, 0)

static func ratchet_r(g: Dictionary) -> int:
	return g.get("maxLevelEver", 1)

static func cost_next(g: Dictionary, uid: String) -> int:
	return int(round(cost_to_next(level_of(g, uid), ratchet_r(g)) * rarity_cost_mul(uid)))

## Mutates g["bank"]/g["lvl"]/g["maxLevelEver"] in place; returns levels gained.
static func feed_unit(g: Dictionary, uid: String, amount: int) -> int:
	g["bank"][uid] = g["bank"].get(uid, 0) + amount
	var gained := 0
	var guard := 0
	var mul := rarity_cost_mul(uid)
	while guard < 100000:
		guard += 1
		var c := int(round(cost_to_next(level_of(g, uid), ratchet_r(g)) * mul))
		if g["bank"][uid] < c:
			break
		g["bank"][uid] -= c
		g["lvl"][uid] = level_of(g, uid) + 1
		gained += 1
		if g["lvl"][uid] > g.get("maxLevelEver", 1):
			g["maxLevelEver"] = g["lvl"][uid]
	return gained

## ===== AETHER tab purchases (Step 3d) -- each mirrors one of
## renderAether()'s 4 purchase handlers (farroad-ui.js:1899-1938) exactly:
## refuse if unaffordable or already maxed, else deduct g["aether"] and
## mutate. NOT ported: refreshLiveStats()'s push onto a unit's LIVE
## mid-fight stats -- a purchase still fully applies, just starting next
## wave's build_party() (which already recomputes every one of these from
## g["lvl"]/g["statInvest"]/g["affinities"] fresh every time) rather than
## instantly mid-fight. Flagged, not silently skipped -- same class of
## deliberate trim as GAMBITS' deferred conflict modal. =====

static func spend_feed(g: Dictionary, uid: String, amount: int) -> bool:
	if g.get("aether", 0) < amount:
		return false
	g["aether"] -= amount
	feed_unit(g, uid, amount)
	return true

static func spend_recovery(g: Dictionary, uid: String) -> bool:
	var c := recovery_cost(g, uid)
	if g.get("aether", 0) < c or recovery_maxed(g, uid):
		return false
	g["aether"] -= c
	g["recovery"][uid] = g["recovery"].get(uid, 0) + 1
	return true

static func spend_affinity(g: Dictionary, uid: String, axis: String) -> bool:
	var c := affinity_cost_to_next(affinity_purchased(g, uid).get(axis, 0))
	if g.get("aether", 0) < c or affinity_maxed(g, uid, axis):
		return false
	g["aether"] -= c
	if not g["affinities"].has(uid):
		g["affinities"][uid] = {}
	g["affinities"][uid][axis] = g["affinities"][uid].get(axis, 0) + 1
	return true

static func spend_pct_stat(g: Dictionary, uid: String, stat: String) -> bool:
	var c := pct_stat_cost(stat, pct_stat_purchased(g, uid, stat))
	if g.get("aether", 0) < c or pct_stat_maxed(g, uid, stat):
		return false
	g["aether"] -= c
	if not g["statInvest"].has(uid):
		g["statInvest"][uid] = {}
	g["statInvest"][uid][stat] = g["statInvest"][uid].get(stat, 0) + 1
	return true

## ===== elemental affinity (baseline + purchased points + equipped gear) =====

const AFFINITY_AXES: Array[String] = ["fire", "water", "earth", "air", "light", "dark", "body", "spirit"]

static func affinity_baseline(uid: String) -> Dictionary:
	var def = FarroadCore.roster_by_id(uid)
	return def["affinity"] if (def and def.get("affinity")) else {}

static func affinity_purchased(g: Dictionary, uid: String) -> Dictionary:
	return g.get("affinities", {}).get(uid, {})

static func equipment_affinity(g: Dictionary, uid: String) -> Dictionary:
	var out := {}
	for ax in AFFINITY_AXES:
		out[ax] = 0.0
	var equipped: Dictionary = g.get("equipped", {}).get(uid, {})
	for slot in FarroadCore.EQUIPMENT_SLOTS:
		var id = equipped.get(slot)
		var item = FarroadCore.EQUIPMENT.get(id) if id else null
		if item:
			for ax in AFFINITY_AXES:
				out[ax] += item.get("affinity", {}).get(ax, 0.0)
	return out

static func effective_affinity(g: Dictionary, uid: String) -> Dictionary:
	var base := affinity_baseline(uid)
	var purchased := affinity_purchased(g, uid)
	var equip := equipment_affinity(g, uid)
	var out := {}
	for ax in AFFINITY_AXES:
		out[ax] = base.get(ax, 0.0) + purchased.get(ax, 0.0) + equip[ax]
	return out

## Mirrors affinityRaw (farroad-ui.js:261) -- baseline + purchased only,
## no equipment (equipment isn't a purchase, doesn't count toward "how much
## has the player actually bought").
static func affinity_raw(g: Dictionary, uid: String, axis: String) -> float:
	return affinity_baseline(uid).get(axis, 0.0) + affinity_purchased(g, uid).get(axis, 0.0)

static func affinity_maxed(g: Dictionary, uid: String, axis: String) -> bool:
	return affinity_raw(g, uid, axis) >= FarroadCore.AFFINITY_CAP

## Mirrors P.AFFINITY_COST_BASE/affinityCostToNext (farroad-progression.js) --
## linear escalation, the Nth point bought on one axis on one unit costs
## N*AFFINITY_COST_BASE.
const AFFINITY_COST_BASE := 4.0976

static func affinity_cost_to_next(invested_points: int) -> int:
	return int(round(AFFINITY_COST_BASE * (invested_points + 1)))

## ===== evade/crit investment (Aether-purchased steps on top of baseline) =====

const PCT_STAT := {
	"evade": {"step": 0.015, "cap": FarroadCore.CAP_EVADE, "cost_base": 8, "cost_growth": 1.144},
	"atkCrit": {"step": 0.04, "cap": FarroadCore.CAP_CRIT, "cost_base": 15, "cost_growth": 1.167},
	"magCrit": {"step": 0.04, "cap": FarroadCore.CAP_CRIT, "cost_base": 15, "cost_growth": 1.167}}
const PCT_STAT_KEYS: Array[String] = ["evade", "atkCrit", "magCrit"]

static func pct_stat_baseline(uid: String, stat: String) -> float:
	var def = FarroadCore.roster_by_id(uid)
	return def["stats"].get(stat, 0.0) if (def and def.get("stats")) else 0.0

static func pct_stat_purchased(g: Dictionary, uid: String, stat: String) -> int:
	return g.get("statInvest", {}).get(uid, {}).get(stat, 0)

static func pct_stat_value(g: Dictionary, uid: String, stat: String) -> float:
	var s: Dictionary = PCT_STAT[stat]
	var baseline := pct_stat_baseline(uid, stat)
	var steps := pct_stat_purchased(g, uid, stat)
	return minf(s["cap"], baseline + steps * s["step"])

## Mirrors P.pctStatCost (farroad-progression.js) -- geometric escalation.
static func pct_stat_cost(stat: String, steps: int) -> int:
	var s: Dictionary = PCT_STAT[stat]
	return int(round(s["cost_base"] * pow(s["cost_growth"], steps)))

static func pct_stat_maxed(g: Dictionary, uid: String, stat: String) -> bool:
	return pct_stat_value(g, uid, stat) >= PCT_STAT[stat]["cap"] - 1e-9

static func apply_pct_stat_investment(g: Dictionary, uid: String, st: Dictionary) -> Dictionary:
	for stat in PCT_STAT_KEYS:
		st[stat] = pct_stat_value(g, uid, stat)
	return st

## ===== equipment (stat/spd-penalty application, Milestone 1/3a; equip/
## unequip mutation + query helpers, Step 3f's EQUIPMENT tab) =====

static func apply_equipment_stats(g: Dictionary, uid: String, st: Dictionary) -> Dictionary:
	var equipped: Dictionary = g.get("equipped", {}).get(uid, {})
	var spd_penalty := 0.0
	for slot in FarroadCore.EQUIPMENT_SLOTS:
		var id = equipped.get(slot)
		var item = FarroadCore.EQUIPMENT.get(id) if id else null
		if not item:
			continue
		for k in ["atk", "mag", "def", "res", "spd"]:
			if item.get(k):
				st[k] += item[k]
		if item.get("evade"):
			st["evade"] += item["evade"]
		if slot != "legs":
			spd_penalty += FarroadCore.EQUIP_SPD_PENALTY_BASE * FarroadCore.RARITY_POWER_MUL.get(item.get("rarity", "common"), 1.0)
	if spd_penalty:
		st["spd"] = int(round(st["spd"] - spd_penalty))
	return st

## Mirrors equipKindForSlot (farroad-ui.js:327) -- hand1/hand2 (the two
## fixed POSITIONS) both collapse to the single 'hand' item KIND for
## compatibility checks; every other slot name already matches its kind.
static func equip_kind_for_slot(slot: String) -> String:
	return "hand" if slot.begins_with("hand") else slot

## Mirrors equipOwnedCount (farroad-ui.js:307).
static func equip_owned_count(g: Dictionary, item_id: String) -> int:
	return int(g.get("equipInv", {}).get(item_id, 0))

## Mirrors equipInUseCount (farroad-ui.js:308-312) -- how many copies of
## item_id are currently sitting in ANY unit's equipped slots.
static func equip_in_use_count(g: Dictionary, item_id: String) -> int:
	var n := 0
	for uid in g.get("equipped", {}).keys():
		for slot in g["equipped"][uid].keys():
			if g["equipped"][uid][slot] == item_id:
				n += 1
	return n

## Mirrors equipAvailableCount (farroad-ui.js:313).
static func equip_available_count(g: Dictionary, item_id: String) -> int:
	return equip_owned_count(g, item_id) - equip_in_use_count(g, item_id)

## Mirrors equipItem (farroad-ui.js:344-351) -- rejects a slot/kind
## mismatch, no-ops (returns true) if already worn in that exact slot,
## rejects if no free copy is available, else equips. No cost/currency --
## equipping is free once owned, the only constraint is copy count.
static func equip_item(g: Dictionary, uid: String, slot: String, item_id: String) -> bool:
	var item = FarroadCore.EQUIPMENT.get(item_id)
	if item == null or item["slot"] != equip_kind_for_slot(slot):
		return false
	if not g.has("equipped"):
		g["equipped"] = {}
	if not g["equipped"].has(uid):
		g["equipped"][uid] = {}
	if g["equipped"][uid].get(slot) == item_id:
		return true
	if equip_available_count(g, item_id) <= 0:
		return false
	g["equipped"][uid][slot] = item_id
	return true

## Mirrors unequipItem (farroad-ui.js:352-354).
static func unequip_item(g: Dictionary, uid: String, slot: String) -> void:
	if not g.has("equipped"):
		g["equipped"] = {}
	if not g["equipped"].has(uid):
		g["equipped"][uid] = {}
	g["equipped"][uid].erase(slot)

## ===== gambit loadout defaults (GAMBITS tab, Step 3c, edits G.loadout after
## this -- ensure_loadout only guarantees a sane STARTING shape exists) =====

static func slots_for(g: Dictionary, uid: String) -> int:
	return slots_at(level_of(g, uid))

static func ensure_loadout(g: Dictionary, uid: String) -> Array:
	var want := slots_for(g, uid)
	if not g["loadout"].has(uid):
		g["loadout"][uid] = [{"cond": "none", "action": "strike"}, {"cond": "none", "action": "strike"}]
	var slots: Array = g["loadout"][uid]
	while slots.size() < want:
		slots.append({"cond": "none", "action": "strike"})
	if slots.size() > want:
		slots = slots.slice(0, want)
		g["loadout"][uid] = slots
	for s in slots:
		if not g["actions"].has(s["action"]):
			s["action"] = "strike"
		if not g["conditions"].has(s["cond"]):
			s["cond"] = "none"
	return slots

## ===== auto-equip (a curated drop installs itself into a default rule, so
## a player who never opens GAMBITS still survives the tutorial) =====

const GATE_FOR := {
	"foe_lacks_debuff": ["sear", "hex", "cripple", "smother", "daunt"],
	"foe_armoured": ["pierce", "hex", "ember"],
	"ally_lacks_buff": ["bulwark"],
	"self_hp_lte_50": ["mend", "bulwark"],
	"foe_fast": ["cripple", "daunt"],
	"ally_hp_lte_60": ["mend"],
	"foe_lowest_hp": ["execute", "strike"],
	"foe_highest_hp": ["gale", "cleave", "daunt"],
	"foe_hp_gte_70": ["gale", "cleave", "sear", "hex"]}
const PRI: Array[String] = ["self_hp_lte_50", "ally_hp_lte_60", "ally_lacks_buff", "foe_fast",
	"foe_lacks_debuff", "foe_armoured", "foe_highest_hp", "foe_hp_gte_70", "foe_lowest_hp"]

static func auto_equip(g: Dictionary) -> void:
	for uid in g["party"]:
		if g.get("touched", {}).get(uid):
			continue
		var s1 = null
		for cd in PRI:
			if s1:
				break
			if not g["conditions"].has(cd):
				continue
			for a in GATE_FOR.get(cd, []):
				if g["actions"].has(a):
					s1 = {"cond": cd, "action": a}
					break
		g["loadout"][uid] = [s1, {"cond": "none", "action": "strike"}] if s1 else \
			[{"cond": "none", "action": "strike"}, {"cond": "none", "action": "strike"}]

## ===== GAMBITS tab: loadout editing + party bench/field (Step 3c) =====

## Mirrors syncLoadout (farroad-ui.js:2892-2895) -- pushes a just-edited
## g["loadout"][uid] onto the matching LIVE unit, so an edit made mid-fight
## takes effect immediately rather than waiting for the next wave's
## build_party(). g["units"][i] and g["battle"]["units"][i] are the SAME
## Dictionary (make_battle never copies its input array's elements, same as
## the real b={units:units,...} in farroad-core.js), so mutating the one
## found here is already enough -- no separate g["battle"] touch needed.
static func sync_loadout(g: Dictionary, uid: String) -> void:
	if g.get("units") == null:
		return
	for u in g["units"]:
		if u["id"] == uid:
			u["slots"] = g["loadout"][uid].map(func(s): return {"cond": s["cond"], "action": s["action"]})

## Mirrors benchUnit (farroad-ui.js:2648-2652) -- refuses to empty the
## party. Deliberately does NOT touch g["loadout"][uid] -- a benched
## unit's loadout is preserved as-is, same as the real game.
static func bench_unit(g: Dictionary, uid: String) -> bool:
	if g["party"].size() <= 1:
		return false
	var idx: int = g["party"].find(uid)
	if idx < 0:
		return false
	g["party"].remove_at(idx)
	return true

## Mirrors fieldUnit (farroad-ui.js:2653-2659), minus the isOnExpedition
## guard (no expeditions yet, Step 3h) -- refuses if not owned, already
## fielded, or the party is full; else appends and runs auto_equip(g),
## same as the real call -- a no-op for this unit if g["touched"][uid] is
## already set, otherwise it installs the default curated rule.
static func field_unit(g: Dictionary, uid: String) -> bool:
	if not g["owned"].get(uid):
		return false
	if g["party"].has(uid):
		return false
	if g["party"].size() >= PARTY_CAP:
		return false
	g["party"].append(uid)
	auto_equip(g)
	return true

## Mirrors availableForParty (farroad-ui.js:2646-2647), minus the same
## isOnExpedition filter -- every owned-and-unfielded unit is available.
static func available_for_party(g: Dictionary) -> Array:
	var out := []
	for uid in g["owned"].keys():
		if not g["party"].has(uid):
			out.append(uid)
	return out

## Mirrors actionHolderInParty (farroad-ui.js:2903-2911) -- who (if anyone)
## already holds a non-starter action elsewhere in the FIELDED party, for
## the action dropdown's disable+tooltip. Starter actions (Strike/Ember)
## are exempt, same as the engine's own action_held_by_earlier_fielded
## (FarroadCore.gd) this UI-level check exists to keep the player from
## even creating a conflict that function would otherwise just silently
## resolve in favor of the earlier-fielded unit at combat time.
static func action_holder_in_party(g: Dictionary, action_id: String, exclude_uid: String) -> Variant:
	if STARTER_ACTIONS.has(action_id):
		return null
	for uid in g["party"]:
		if uid == exclude_uid:
			continue
		var sl = g["loadout"].get(uid)
		if sl == null:
			continue
		for s in sl:
			if s["action"] == action_id:
				var def = FarroadCore.roster_by_id(uid)
				return def["name"] if def else uid
	return null

## ===== LORE (mirrors farroad-ui.js's renderLore() and its supporting
## functions usedActions/actionHolders/unitActiveActions, :1995-2220) =====

## Mirrors usedActions (farroad-ui.js:2003-2010) -- every OWNED unit's (not
## just fielded) loadout actions + roster chargeAction, as a lookup set --
## the refund button's own eligibility check. The G.mc-gated
## acquiredCharges branch naturally no-ops while g["mc"] is null (Step 3j),
## same pattern as everywhere else this has come up.
static func used_actions(g: Dictionary) -> Dictionary:
	var used := {}
	for uid in g["owned"].keys():
		for s in g["loadout"].get(uid, []):
			used[s["action"]] = 1
		var rd = FarroadCore.roster_by_id(uid)
		if rd and rd.get("chargeAction"):
			used[rd["chargeAction"]] = 1
	return used

## Mirrors actionHolders (farroad-ui.js:2018-2029) -- who currently equips
## action `aid`, split active (a loadout slot or the unit's live
## chargeAction) from banked (sitting unequipped in the MC's
## acquiredCharges pool). The `banked` case is unreachable while g["mc"]
## is null (mcOwns is always false), matching the same no-op pattern.
static func action_holders(g: Dictionary, aid: String) -> Dictionary:
	var active := []
	var banked := false
	for uid in g["owned"].keys():
		var holds := false
		for s in g["loadout"].get(uid, []):
			if s["action"] == aid:
				holds = true
		var rd = FarroadCore.roster_by_id(uid)
		var ca = rd.get("chargeAction") if rd else null
		if ca == aid:
			holds = true
		if holds:
			active.append(rd["name"] if rd else uid)
	return {"active": active, "banked": banked}

## Mirrors unitActiveActions (farroad-ui.js:2035-2042) -- a unit's own
## loadout-slot actions, deduped, plus its live charge action.
static func unit_active_actions(g: Dictionary, uid: String) -> Array:
	var ids := []
	for s in g["loadout"].get(uid, []):
		if not ids.has(s["action"]):
			ids.append(s["action"])
	var rd = FarroadCore.roster_by_id(uid)
	var ca = rd.get("chargeAction") if rd else null
	if ca and not ids.has(ca):
		ids.append(ca)
	return ids

## Mirrors renderLore()'s own actionIds construction (farroad-ui.js:2066-2068)
## -- every loadout-slot basic the player has unlocked (g["actions"],
## already tracked and already used directly by GambitsPanel.gd) PLUS any
## charge action currently in play (from used_actions, filtered to
## FarroadCore.ACTIONS[id]["isCharge"]) that isn't already in that list --
## a companion's chargeAction (a fixed roster property) and the MC's
## acquired charges never go through the drop/pull unlock path g["actions"]
## tracks, so without this they'd be silently unselectable on LORE.
static func lore_action_ids(g: Dictionary) -> Array:
	var ids: Array = g["actions"].duplicate()
	for id in used_actions(g).keys():
		if not ids.has(id) and FarroadCore.ACTIONS.get(id) and FarroadCore.ACTIONS[id].get("isCharge"):
			ids.append(id)
	return ids

## Mirrors renderLore()'s own free-Lore line (farroad-ui.js:2045) -- Lore is
## NOT a spendable balance decremented on purchase, g["lore"] is a
## cumulative EARNED total (only ever incremented, by grant_drops's
## duplicate-drop path) -- "free Lore to spend" is always DERIVED live as
## earned-minus-spent.
static func free_lore(g: Dictionary) -> float:
	var spent: int = FarroadCore.bonus_spend(g["bonuses"])
	return maxf(0.0, float(g["lore"]) - float(spent))

## Mirrors the inline unusedIds/refundTotal computation (farroad-ui.js:2051-2056)
## -- read-only preview, no mutation. Iterates g["bonuses"].keys() (every
## action id the player has EVER spent Lore on), not lore_action_ids(g) --
## an action can fall out of the current tab pool (e.g. a dropped/unpulled
## action) while still holding a refundable Lore investment.
static func unused_lore_refund(g: Dictionary) -> Dictionary:
	var used := used_actions(g)
	var unused_ids := []
	for aid in g["bonuses"].keys():
		if not used.has(aid) and g["bonuses"][aid] and not g["bonuses"][aid].is_empty():
			unused_ids.append(aid)
	var refund_total := 0
	for aid in unused_ids:
		var b: Dictionary = g["bonuses"][aid]
		var total: int = FarroadCore.action_bonus_total(b)
		refund_total += total * (total + 1) / 2 + int(b.get("broad", 0)) * FarroadCore.BONUS_COST_BROAD
	return {"ids": unused_ids, "total": refund_total}

## Mirrors the bulk refund handler (farroad-ui.js:2216-2220) -- deletes each
## given action's ENTIRE bonus entry (typically unused_lore_refund(g)["ids"]).
## Never touches g["lore"] -- free_lore(g) rises on its own once bonus_spend
## drops. No re-validation inside (the real JS doesn't either -- the button
## itself only exists when unused_lore_refund(g)["ids"] is non-empty).
static func claim_lore_refund(g: Dictionary, ids: Array) -> void:
	for aid in ids:
		g["bonuses"].erase(aid)
	FarroadCore.apply_bonuses(g["bonuses"])

## Mirrors the "+" purchase handler (farroad-ui.js:2208-2210) -- buys ONE
## stack of bonus `bid` on action `aid`. No re-validation inside (gating is
## structural, the button only exists when applicable/affordable -- the UI
## layer's responsibility, same discipline as GAMBITS' own mutation
## functions above).
static func buy_bonus(g: Dictionary, aid: String, bid: String) -> void:
	if not g["bonuses"].has(aid):
		g["bonuses"][aid] = {}
	g["bonuses"][aid][bid] = int(g["bonuses"][aid].get(bid, 0)) + 1
	FarroadCore.apply_bonuses(g["bonuses"])

## Mirrors the "−" handler (farroad-ui.js:2211-2214) -- removes ONE stack of
## bonus `bid` from action `aid` (distinct from the bulk claim_lore_refund
## above), deleting the bid entry once it hits 0.
static func remove_bonus(g: Dictionary, aid: String, bid: String) -> void:
	if not g["bonuses"].has(aid):
		return
	var count: int = maxi(0, int(g["bonuses"][aid].get(bid, 0)) - 1)
	if count == 0:
		g["bonuses"][aid].erase(bid)
	else:
		g["bonuses"][aid][bid] = count
	FarroadCore.apply_bonuses(g["bonuses"])

## ===== party/enemy construction (mirrors buildParty/buildEnemies,
## farroad-ui.js:366/388) =====

## Mirrors refreshLiveStats (farroad-ui.js:1991-2003) -- pushes a fresh
## AETHER purchase (feed/level, Recovery, Evade/Crit, Affinity) onto every
## unit already mid-fight, the same way sync_loadout does for a GAMBITS
## slot edit. g["units"][i] is the SAME Dictionary as g["battle"]["units"][i]
## (make_battle never copies its input array's elements), so mutating the
## one found here already reaches the live fight. HP is rescaled to keep
## the unit's CURRENT hp fraction, not reset to full, exactly like the
## real function.
static func refresh_live_stats(g: Dictionary) -> void:
	if g.get("units") == null:
		return
	for u in g["units"]:
		var def = FarroadCore.roster_by_id(u["id"])
		if def == null:
			continue
		var st := stats_at(u["id"], def["stats"], def["hp"], level_of(g, u["id"]))
		apply_pct_stat_investment(g, u["id"], st)
		apply_equipment_stats(g, u["id"], st)
		u["base"]["atk"] = st["atk"]; u["base"]["mag"] = st["mag"]
		u["base"]["def"] = st["def"]; u["base"]["res"] = st["res"]; u["base"]["spd"] = st["spd"]
		u["base"]["evade"] = st["evade"]; u["base"]["atkCrit"] = st["atkCrit"]; u["base"]["magCrit"] = st["magCrit"]
		var fr: float = float(u["hp"]) / float(u["maxHp"])
		u["maxHp"] = st["hp"]
		u["hp"] = maxf(1.0, round(st["hp"] * fr))
		u["affinity"] = effective_affinity(g, u["id"])
		u["slots"] = ensure_loadout(g, u["id"]).map(func(s): return {"cond": s["cond"], "action": s["action"]})

## One party member's fresh unit dict -- factored out of build_party() so
## refresh_live_party() (below) can build a single newly-fielded unit the
## same way, without re-running the whole party's construction.
static func build_party_unit(g: Dictionary, uid: String, slot_index: int) -> Dictionary:
	var def = FarroadCore.roster_by_id(uid)
	var st := stats_at(uid, def["stats"], def["hp"], level_of(g, uid))
	apply_pct_stat_investment(g, uid, st)
	apply_equipment_stats(g, uid, st)
	var mh: float = st["hp"]
	var carry = g["hpCarry"].get(uid)
	if carry != null:
		carry = minf(1.0, carry + recovery_of(g, uid))
	var hp: float = mh if carry == null else maxf(1.0, round(mh * carry))
	return FarroadCore.make_unit({"id": uid, "name": def["name"], "isParty": true, "level": 1,
		"slotIndex": slot_index, "stats": st, "maxHp": mh, "hp": minf(hp, mh), "row": def.get("row"),
		"chargeAction": def.get("chargeAction"), "affinity": effective_affinity(g, uid),
		"slots": ensure_loadout(g, uid).map(func(s): return {"cond": s["cond"], "action": s["action"]})})

static func build_party(g: Dictionary) -> Array:
	var out := []
	for i in range(g["party"].size()):
		out.append(build_party_unit(g, g["party"][i], i))
	return out

## Godot-only enhancement, not a JS port -- confirmed the real benchUnit/
## fieldUnit (farroad-ui.js) don't sync a live fight either, so this isn't a
## parity gap, and nothing here consumes RNG or touches a bit-exact formula
## (no parity-test implications). Called right after bench_unit/field_unit
## so a party-roster change reaches a fight already in progress, the same
## immediacy sync_loadout already gives a GAMBITS slot edit.
##
## Benching a currently-fielded unit marks it dead (hp=0) in THIS fight
## rather than removing its entry from g["battle"]["units"] outright --
## removing an array entry mid-fight risks invariants the engine was never
## built to handle (turn-order scans, threat lists), where a 0-HP unit is
## already correctly ignored everywhere (living()/choose()/etc.) and reads
## visually as "fallen", the same treatment a real combat death gets.
##
## Fielding a new companion builds a fresh unit (build_party_unit) and
## appends it to BOTH g["units"] and g["battle"]["units"] -- two separate
## Array objects sharing element references, not one Array (see
## start_wave's own `party + enemies` concatenation) -- with its turn
## schedule seeded from the battle's CURRENT time (`battle["t"]`), not a
## fresh-battle-relative 0, so it takes its first turn in due course
## instead of jumping the queue. Returns the newly-added unit dicts so the
## presentation layer can build matching UnitViews for them.
static func refresh_live_party(g: Dictionary) -> Array:
	if g.get("units") == null:
		return []
	var present_ids := {}
	for u in g["units"]:
		present_ids[u["id"]] = true
	for u in g["units"]:
		if u["isParty"] and not g["party"].has(u["id"]):
			u["hp"] = 0.0
	var added := []
	for i in range(g["party"].size()):
		var uid: String = g["party"][i]
		if not present_ids.has(uid):
			var nu := build_party_unit(g, uid, g["units"].size())
			nu["nextActAt"] = g["battle"]["t"] + FarroadCore.tc_of(nu, 1.00)
			g["units"].append(nu)
			g["battle"]["units"].append(nu)
			added.append(nu)
	return added

## @param quiet caller-side hook for a future variety-roll log line -- no log
## is built here (that's a UI concern), kept only so callers match the real
## JS signature exactly.
static func build_enemies(g: Dictionary, w: int, _quiet: bool = false, super_boss_key: String = "") -> Array:
	var boss: bool = is_boss_wave(w) or super_boss_key != ""
	var variety: bool = (not boss) and w > VARIETY_FROM
	var n: int = 1 if boss else (roll_count(g["rng"], w) if variety else enemy_count(w))
	var v_mul: float = (count_strength(n) * band_roll(g["rng"])) if variety else 1.0
	FarroadCore.set_wave(w)
	var s: float = FarroadCore.wave_scale(w)
	var out := []
	for j in range(n):
		var key: String = "ox" if boss else archetype_for(w, j)
		var a: Dictionary = FarroadCore.ARCH[key]
		# The very first boss (wave 20, BOSS_WAVES[0]) is fought solo, before
		# the 2nd party member joins -- it alone uses the eased
		# FIRST_BOSS_LEN/FIRST_BOSS_HARD_EXTRA; every later boss keeps the
		# full BOSS_LEN/BOSS_HARD_EXTRA unchanged.
		var is_first_boss: bool = boss and w == BOSS_WAVES[0]
		var hp_base: float
		if boss:
			var ref: Dictionary = FarroadCore.ARCH["wolf"]
			var len_mul: float = 3.0 if super_boss_key != "" else (FIRST_BOSS_LEN if is_first_boss else BOSS_LEN)
			hp_base = 200.0 * ref["hpMul"] * FarroadCore.dmg_taken_mul(ref) * s * \
				maxf(1, enemy_count(w)) * len_mul
		else:
			hp_base = 200.0 * a["hpMul"] * FarroadCore.dmg_taken_mul(a) * s
		hp_base *= DIFFICULTY * v_mul * sqrt(hard_mul(w))
		var hard_atk_mul: float = hard_mul(w) * ((FIRST_BOSS_HARD_EXTRA if is_first_boss else BOSS_HARD_EXTRA) if boss else 1.0)
		var atk_mul: float = (1.10 if boss else 1.0) * DIFFICULTY * v_mul * hard_atk_mul
		var dmg_mul: float = FIRST_BOSS_DMG_MUL if is_first_boss else 1.0
		out.append(FarroadCore.make_unit({
			"id": "e%d" % j,
			"name": ("ROADWARDEN" if boss else a["name"]) + (" %d" % (j + 1) if n > 1 else ""),
			"isParty": false, "level": 1, "slotIndex": 10 + j, "arch": key,
			"thorns": a.get("thorns", 0), "isBoss": boss, "row": "front" if j < 5 else "back",
			"stats": {
				"hp": maxf(8, round(hp_base)),
				"atk": maxf(1, round(a["atk"] * s * atk_mul * dmg_mul)),
				"mag": round(a.get("mag", 8) * s * DIFFICULTY * hard_atk_mul * dmg_mul),
				"def": round(a["def"] * s), "res": round(a["res"] * s),
				"spd": round(a["spd"] * boss_spd_mul(w)) if boss else a["spd"],
				"atkCrit": minf(FarroadCore.CAP_CRIT, a["atkCrit"] * sqrt(s)),
				"magCrit": minf(FarroadCore.CAP_CRIT, a.get("magCrit", 0.04) * sqrt(s)),
				"chargeRate": 1.15 if boss else 1.0, "evade": a["evade"]},
			"chargeAction": "wardensmaul" if boss else a.get("chargeAction"),
			"affinity": a["affinity"],
			"slots": a["slots"].map(func(sl): return {"cond": sl["cond"], "action": sl["action"]})}))
	return out

## ===== random post-curated drops (mirrors randomDrop, farroad-ui.js:735) =====

static func random_equipment_ids() -> Array:
	return FarroadCore.EQUIPMENT.keys()

static func random_drop(g: Dictionary, w: int) -> Array:
	if w % 2 != 0 and w % 2 != 1:
		return []
	if g.get("mc") and g["rng"].next() < MC_CHARGE_DROP_CHANCE:
		var legendary_pool: Array = MC_CHARGE_DROP_POOL.filter(func(id):
			return FarroadCore.ACTIONS.get(id, {}).get("rarity") == "legendary")
		var rare_pool: Array = MC_CHARGE_DROP_POOL.filter(func(id):
			return FarroadCore.ACTIONS.get(id, {}).get("rarity") != "legendary")
		var want_legendary: bool = legendary_pool.size() > 0 and g["rng"].next() < MC_LEGENDARY_CHARGE_CHANCE
		var pool: Array = legendary_pool if want_legendary else rare_pool
		if pool.is_empty():
			pool = MC_CHARGE_DROP_POOL
		return [{"kind": "charge", "id": pool[g["rng"].next_int(pool.size())],
			"why": ("legendary" if want_legendary else "rare") + " charge-action drop"}]
	if g["rng"].next() < EQUIP_DROP_CHANCE:
		var equip_ids := random_equipment_ids()
		return [{"kind": "equip", "id": weighted_equipment_pick(g["rng"], equip_ids), "why": "equipment drop"}]
	if w % 2 == 0:
		var pool := FarroadCore.equippable()
		return [{"kind": "action", "id": weighted_action_pick(g["rng"], pool), "why": "random drop"}]
	var cp: Array = FarroadCore.ALL_CONDITION_IDS.filter(func(id): return id != "none")
	return [{"kind": "cond", "id": cp[g["rng"].next_int(cp.size())], "why": "random drop"}]

## ===== drop granting (mirrors grantDrops, farroad-ui.js:639) =====
## Mutates g in place (actions/conditions/lore/equipInv unlocked or bumped);
## returns a list of plain event Dictionaries describing what happened, for
## a future UI layer to log/notify however it likes.

static func grant_drops(g: Dictionary, w: int) -> Array:
	if g["dropsGranted"].get(w):
		return [{"kind": "already_attempted", "wave": w}]
	g["dropsGranted"][w] = 1
	var curated := is_curated(w)
	var drops: Array = drops_at(w) if curated else random_drop(g, w)
	var events := []
	for d in drops:
		var kind: String = d["kind"]
		if kind == "action":
			g["actionCounts"][d["id"]] = g["actionCounts"].get(d["id"], 0) + 1
			var dup: bool = g["actions"].has(d["id"])
			if not dup:
				g["actions"].append(d["id"])
			else:
				g["lore"] = g.get("lore", 0) + 1
			events.append({"kind": "action", "id": d["id"], "wave": w, "duplicate": dup,
				"why": d.get("why") if curated else null})
		elif kind == "charge":
			g["mc"]["acquiredCharges"] = g["mc"].get("acquiredCharges", [])
			var dup_c: bool = g["mc"]["acquiredCharges"].has(d["id"])
			if not dup_c:
				g["mc"]["acquiredCharges"].append(d["id"])
			else:
				g["lore"] = g.get("lore", 0) + 1
			events.append({"kind": "charge", "id": d["id"], "wave": w, "duplicate": dup_c})
		elif kind == "equip":
			g["equipInv"][d["id"]] = g["equipInv"].get(d["id"], 0) + 1
			events.append({"kind": "equip", "id": d["id"], "wave": w,
				"ownedCount": g["equipInv"][d["id"]], "why": d.get("why") if curated else null})
		else:
			g["condCounts"][d["id"]] = g["condCounts"].get(d["id"], 0) + 1
			var dup2: bool = g["conditions"].has(d["id"])
			if not dup2:
				g["conditions"].append(d["id"])
			else:
				g["lore"] = g.get("lore", 0) + 1
			events.append({"kind": "cond", "id": d["id"], "wave": w, "duplicate": dup2,
				"why": d.get("why") if curated else null})
	if not drops.is_empty():
		auto_equip(g)
	return events

## ===== companion acquisition (mirrors joinCompanion, farroad-ui.js:794) =====

static func join_companion(g: Dictionary, uid: String) -> bool:
	if not g["owned"].get(uid):
		g["quests"][uid] = {"stage": 0, "frozen": []}
	g["lvl"][uid] = 1
	g["bank"][uid] = 0
	g["owned"][uid] = 1
	if not g["affinities"].has(uid):
		g["affinities"][uid] = {}
	if not g["statInvest"].has(uid):
		g["statInvest"][uid] = {}
	if not g["equipped"].has(uid):
		g["equipped"][uid] = {}
	var fielded: bool = g["party"].size() < PARTY_CAP
	if fielded:
		g["party"].append(uid)
	return fielded

## ===== wave loop (mirrors startWave/afterWaveCleared/onWipe, farroad-ui.js) =====

static func start_wave(g: Dictionary, w: int, skip_drops: bool = false) -> Array:
	g["wave"] = w
	if w > g.get("farthest", 1):
		g["farthest"] = w
	var events := [] if skip_drops else grant_drops(g, w)
	FarroadCore.apply_bonuses(g["bonuses"])
	var party := build_party(g)
	var enemies := build_enemies(g, w)
	g["units"] = party
	g["enemies"] = enemies
	g["battle"] = FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": g.get("enrage", true)})
	g["over"] = null
	return events

static func after_wave_cleared(g: Dictionary) -> Array:
	var events := []
	var first_clear: bool = not g["clearedWaves"].get(g["wave"])
	g["clearedWaves"][g["wave"]] = 1
	for u in g["units"]:
		g["hpCarry"][u["id"]] = u["hp"] / u["maxHp"]
	var r := kill_reward(g["wave"], g["enemies"].size())
	g["aether"] = g.get("aether", 0) + r["aether"]
	g["marks"] = g.get("marks", 0) + r["marks"] * marks_mul(g)
	if is_boss_wave(g["wave"]) and first_clear:
		g["bossesCleared"] = g.get("bossesCleared", 0) + 1
		var hoard := boss_aether(g["wave"])
		g["aether"] += hoard
		events.append({"kind": "boss_hoard", "wave": g["wave"], "amount": hoard})
		var next = unit_due_at(g["wave"])
		if next and g["party"].has(next):
			next = null
		if not next:
			var dup := dup_unit_aether(g["wave"])
			g["aether"] += dup
			events.append({"kind": "boss_no_companion", "wave": g["wave"], "amount": dup})
		elif g["party"].size() < PARTY_CAP:
			join_companion(g, next)
			events.append({"kind": "boss_companion", "wave": g["wave"], "id": next})
		events.append({"kind": "checkpoint", "wave": g["bossesCleared"] * BOSS_EVERY})
	if is_boss_wave(g["wave"]) and g["rng"].next() < 0.10:
		var boss_avail: Array = FarroadCore.ROSTER.filter(func(r): return not g["owned"].get(r["id"]))
		if not boss_avail.is_empty():
			var pick: Dictionary = boss_avail[g["rng"].next_int(boss_avail.size())]
			var fielded := join_companion(g, pick["id"])
			events.append({"kind": "boss_companion_roll", "wave": g["wave"], "id": pick["id"], "fielded": fielded})
	return events

static func on_wipe(g: Dictionary) -> Array:
	g["wipes"] = g.get("wipes", 0) + 1
	var back := checkpoint(g.get("bossesCleared", 0), g.get("farthest", 1))
	g["hpCarry"] = {}
	var events: Array = [{"kind": "wipe", "backTo": back}]
	events.append_array(start_wave(g, back))
	return events

## ===== new game / new save (mirrors newGame/newDirections, farroad-ui.js:45) =====

## The 8 directions are hardcoded here (not derived from
## window.FarroadContent.DIRECTION_CONFIG, not exported yet) -- same
## precedent farroad-save.js's own deserialize() already established for
## exactly this reason.
const DIRECTION_IDS: Array[String] = ["west", "northwest", "southwest", "north", "south",
	"northeast", "southeast", "east"]

static func new_directions() -> Dictionary:
	var d := {}
	for dir in DIRECTION_IDS:
		d[dir] = {"maxDepth": 0, "dungeonsUnlocked": 0}
	return d

static func new_game(seed: int, mc) -> Dictionary:
	return {
		"seed": seed if seed else 7, "rng": FarroadCore.make_rng(seed if seed else 7),
		"wave": 0, "farthest": 1, "bossesCleared": 0,
		"aether": 0, "lore": 0, "marks": 0, "wipes": 0,
		"party": ["kesh"], "actions": STARTER_ACTIONS.duplicate(), "conditions": ["none"],
		"actionCounts": {}, "condCounts": {}, "bonuses": {}, "recovery": {}, "loadout": {},
		"hpCarry": {}, "touched": {}, "clearedWaves": {}, "dropsGranted": {},
		"lvl": {"kesh": 1}, "bank": {"kesh": 0}, "maxLevelEver": 1, "owned": {"kesh": 1},
		"affinities": {"kesh": {}}, "statInvest": {"kesh": {}},
		"equipInv": {}, "equipped": {"kesh": {}},
		"battle": null, "units": null, "enemies": null, "over": null, "enrage": true, "idleAcc": 0,
		"sideBattle": null, "roadBattle": null,
		"mc": mc, "expeditions": [], "pullsSinceUnit": 0,
		"dungeons": [], "quests": {"kesh": {"stage": 0, "frozen": []}},
		"superBossQuests": [], "superBossesUnlocked": 0, "superBossesCleared": {},
		"directions": new_directions()}

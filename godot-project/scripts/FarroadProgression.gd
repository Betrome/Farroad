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
## Step 3j (character creation) is now ported too -- mc_lerp/mc_build_stats/
## apply_custom_mc and friends, see the "Step 3j" section further down.
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
## 20-item batch, Group F: a flat addition to a boss's own affinity.spirit
## (base archetypes all sit at spirit=0 today) -- makes a boss concretely
## resist incoming debuffs harder AND land its own debuffs harder, per the
## new caster-boost/target-resist debuff formula. +18 puts affinity_mul(18)
## at 0.36 (24-item-batch Group B6's flat AFFINITY_FLAT_RATE=0.02 formula,
## post-dating this constant's own original log-curve-based math), so
## (1-0.36)=0.64x a debuff's usual magnitude when landed on a boss by a
## spirit-neutral caster -- softened, not negated (a high-Spirit party
## caster can still claw some of it back, and affinity is uncapped on
## both sides now, so there's no fixed ceiling either party caster or
## boss can "max out" at).
const BOSS_SPIRIT_BONUS := 18.0
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
# Ian: "add a flat 50% atk and mag debuff to the first 20 waves for
# tutorial purposes" -- a blanket ease across the WHOLE solo pre-second-
# companion stretch (waves 1-20 inclusive), distinct from and stacking
# with the wave-20-boss-only softening above (FIRST_BOSS_LEN/
# FIRST_BOSS_HARD_EXTRA/FIRST_BOSS_DMG_MUL, which only ever applied to
# w==BOSS_WAVES[0]). Applied the same way FIRST_BOSS_DMG_MUL already is --
# directly on the final atk/mag stat values, so it touches damage output
# only, not HP/crit/spd/anything else hard_mul also feeds.
const TUTORIAL_ATK_MAG_MUL := 0.5
# Ian follow-up: "halve enemy levels through level 20... from 20-100,
# slowly increase the difficulty to normal levels." Was a flat 0.5x for
# w<=20 then an abrupt cliff straight back to 1.0x at w==21 -- now a
# smooth linear ramp from 0.5x (w<=20) back up to 1.0x (w>=100), so
# difficulty eases back in gradually across the wave 20-100 stretch
# instead of snapping back all at once.
## Ian (post-24-item-batch balance pass): "soften the damage cut but keep
## Enrage." Simulated across 8 MC builds: the wall at wave 21 was never the
## cut ending (it was already ~50% there) -- it was enrage switching on,
## which slow/low-damage builds (tank, support) can't outrun with fights
## of 120+ beats. So the cut now DIPS right after the tutorial to
## TUTORIAL_POST_DIP (enemies weaker than in waves 1-20, easing players
## into enrage) and fades back up to full strength by wave 120 instead of
## 100. Tested: tank/hybrid builds that used to hard-stall at wave 21 now
## clear 21-30 with a handful of wipes; fast builds see almost none.
const TUTORIAL_POST_DIP := 0.30
## First Road wave whose fights can enrage (see start_wave).
const ENRAGE_FROM_WAVE := 31
const TUTORIAL_RAMP_END_WAVE := 120

static func tutorial_atk_mag_mul(w: int) -> float:
	if w <= 20:
		return TUTORIAL_ATK_MAG_MUL
	if w >= TUTORIAL_RAMP_END_WAVE:
		return 1.0
	var t: float = float(w - 20) / float(TUTORIAL_RAMP_END_WAVE - 20)
	return lerpf(TUTORIAL_POST_DIP, 1.0, t)

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

# Ian (24-item batch, Group B5): "triple idle income rates, halve wave
# reward scaling. I'm getting too strong too quickly." Root cause of the
# ~40k-Aether-for-a-few-hours report investigated directly, NOT a bug in
# these rates: idle's own flat trickle is architecturally incapable of
# anywhere near that (even at an extreme wave, under ~400 Aether across
# the full 12h cap) -- the real source is simulate_offline_progress's own
# combat-replay loop, which silently auto-clears many real waves during a
# long absence and pays each one full kill_reward, same as live play.
# That replay is a deliberate, existing design choice ("full fidelity
# over offline-never-wipes"), not touched here. AETHER_RATE/MARKS_RATE
# halved (below) shrinks every wave-clear payout, live or replayed alike;
# the IDLE_* trio tripled shifts more of the economy toward the (now much
# smaller, still fully capped) background trickle instead.
const AETHER_RATE := 0.09
const MARKS_RATE := 0.065
const PRE_UNLOCK_MARKS_MUL := 0.45
const MARKS_UNLOCK_WAVE := 40
## Display-only ("X pulls waiting" on the locked screen); pull_cost's own
## flat 100 is the real gate, this just happens to share the same number.
const MARKS_PER_PULL := 100
const BOSS_AETHER_WAVES := 12.5
const DUP_UNIT_WAVES := 3
const NOMINAL_WAVE_SEC := 40.0
const IDLE_FLOOR_PER_5MIN := 3.0
const IDLE_AETHER_GROWTH_MUL := 1.5
const IDLE_MARKS_GROWTH_MUL := 6.0

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
		# v2.13: ALL charge actions are now pullable too, not just the
		# ATK_CAMP+MAG_CAMP pool -- the pool grows, the outcome branch
		# dispatches on ACTIONS[id]["isCharge"].
		var pool: Array = FarroadCore.equippable() + FarroadCore.CHARGE_ACTIONS
		var aid: String = weighted_action_pick(g["rng"], pool)
		g["actionCounts"][aid] = int(g["actionCounts"].get(aid, 0)) + 1
		var is_charge: bool = bool(FarroadCore.ACTIONS.get(aid, {}).get("isCharge", false))
		if is_charge:
			# A pulled charge action credits the MC's own acquiredCharges
			# list -- same destination a rare charge DROP already uses
			# (grant_drops' "charge" branch). g["mc"] is always set by the
			# time pulls unlock (wave 20+, well past mandatory character
			# creation) -- defensive no-op rather than crashing if somehow
			# null (the RNG draw above is still consumed either way).
			if g["mc"] == null:
				return {"kind": "action", "id": aid, "duplicate": false, "isCharge": true}
			g["mc"]["acquiredCharges"] = g["mc"].get("acquiredCharges", [])
			var dup_mc: bool = g["mc"]["acquiredCharges"].has(aid)
			if not dup_mc:
				g["mc"]["acquiredCharges"].append(aid)
			else:
				_credit_lore(g, aid)
			return {"kind": "action", "id": aid, "duplicate": dup_mc, "isCharge": true}
		var dup_a: bool = g["actions"].has(aid)
		if not dup_a:
			g["actions"].append(aid)
		else:
			_credit_lore(g, aid)
		return {"kind": "action", "id": aid, "duplicate": dup_a}
	else:
		var cp: Array = FarroadCore.ALL_CONDITION_IDS.filter(func(id): return id != "none")
		var cid: String = cp[g["rng"].next_int(cp.size())]
		g["condCounts"][cid] = int(g["condCounts"].get(cid, 0)) + 1
		var dup_c: bool = g["conditions"].has(cid)
		var lore_aid: String = ""
		if not dup_c:
			g["conditions"].append(cid)
		else:
			lore_aid = _credit_random_lore(g)
		return {"kind": "cond", "id": cid, "duplicate": dup_c, "loreActionId": lore_aid}

## ===== SHOP tab: fixed-price purchases with Crystal (24-item batch,
## Group C6) =====
## Ian's own fixed prices, verbatim: gambits 10 flat; actions 20/50/100 by
## rarity; units 100/200/500; equipment 10/30/90. Same "afford check ->
## deduct -> mutate -> return bool" shape every other purchase function in
## this file already uses (spend_affinity/spend_feed/etc.) -- no
## re-validation beyond what's shown, gating is structural (a Shop row
## only exists for an actually-purchasable entry).
const SHOP_GAMBIT_PRICE := 10
const SHOP_ACTION_PRICE := {"common": 20, "rare": 50, "legendary": 100}
const SHOP_UNIT_PRICE := {"common": 100, "rare": 200, "legendary": 500}
const SHOP_EQUIPMENT_PRICE := {"common": 10, "rare": 30, "legendary": 90}

static func buy_shop_gambit(g: Dictionary, cond_id: String) -> bool:
	if cond_id == "none" or g["conditions"].has(cond_id):
		return false
	if int(g.get("crystal", 0)) < SHOP_GAMBIT_PRICE:
		return false
	g["crystal"] = int(g["crystal"]) - SHOP_GAMBIT_PRICE
	g["conditions"].append(cond_id)
	return true

## A charge action buys into g["mc"]["acquiredCharges"] (mirrors do_pull's
## own action branch); a regular action buys into g["actions"]. Refuses if
## already owned in the relevant pool, unaffordable, or (charge case) no
## MC exists yet -- pulls/Shop both only unlock well past mandatory
## character creation in practice, but this stays a real, not just
## theoretical, guard.
static func buy_shop_action(g: Dictionary, action_id: String) -> bool:
	var act = FarroadCore.ACTIONS.get(action_id)
	if act == null:
		return false
	var is_charge: bool = bool(act.get("isCharge", false))
	if is_charge:
		if g["mc"] == null:
			return false
		if (g["mc"].get("acquiredCharges", []) as Array).has(action_id):
			return false
	elif g["actions"].has(action_id):
		return false
	var price: int = int(SHOP_ACTION_PRICE.get(act.get("rarity", "common"), 20))
	if int(g.get("crystal", 0)) < price:
		return false
	g["crystal"] = int(g["crystal"]) - price
	if is_charge:
		g["mc"]["acquiredCharges"] = g["mc"].get("acquiredCharges", [])
		g["mc"]["acquiredCharges"].append(action_id)
	else:
		g["actions"].append(action_id)
	return true

static func buy_shop_unit(g: Dictionary, uid: String) -> bool:
	if g["owned"].get(uid, false):
		return false
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return false
	var price: int = int(SHOP_UNIT_PRICE.get(def.get("rarity", "common"), 100))
	if int(g.get("crystal", 0)) < price:
		return false
	g["crystal"] = int(g["crystal"]) - price
	join_companion(g, uid)
	return true

## Equipment is always purchasable, even if already owned -- extra copies
## stack (same "dupes are genuinely useful" rule do_pull's own equip
## branch and random_drop already establish), so there's no ownership
## gate here at all, only affordability.
static func buy_shop_equipment(g: Dictionary, item_id: String) -> bool:
	var item = FarroadCore.EQUIPMENT.get(item_id)
	if item == null:
		return false
	var price: int = int(SHOP_EQUIPMENT_PRICE.get(item.get("rarity", "common"), 10))
	if int(g.get("crystal", 0)) < price:
		return false
	g["crystal"] = int(g["crystal"]) - price
	g["equipInv"][item_id] = int(g["equipInv"].get(item_id, 0)) + 1
	return true

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
	{"w": 4, "kind": "action", "id": "smother", "why": "Dulled cuts the Fen Priest's healing — ready before it (wave 5-7) arrives"},
	{"w": 5, "kind": "cond", "id": "foe_armoured", "why": "Barrow Knight arrives — DEF 34, physical stalls"},
	{"w": 6, "kind": "action", "id": "bulwark", "why": "Warded ×0.60; holds the 10th-percentile at wave 9"},
	{"w": 7, "kind": "cond", "id": "ally_lacks_buff", "why": "gates Bulwark — do not overwrite a running buff"},
	{"w": 8, "kind": "action", "id": "mend", "why": "THE survival lesson, worth +277%"},
	{"w": 9, "kind": "cond", "id": "self_hp_lte_50", "why": "gates Mend — the highest-value rule in the game"},
	{"w": 10, "kind": "action", "id": "cripple", "why": "Slowed ×1.50 turn cost = 33% fewer enemy turns"},
	{"w": 11, "kind": "cond", "id": "foe_fast", "why": "gates Cripple — relative, so it survives stat scaling"},
	{"w": 12, "kind": "action", "id": "hex", "why": "Frail cuts RES on the tougher foes ahead"},
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
## Ian: "add Ansa at wave 10, not 20" -- confirmed via direct simulation
## (multiple builds that walled hard on the solo wave-20 boss all cleared
## the whole tutorial with ZERO wipes once a 2nd body joins before it: a
## real ally splits enemy turns/damage AND brings actual in-combat healing,
## directly countering the "arrives at the boss nearly dead" attrition
## problem). Was [20, ...] -- note this ALSO surfaces and fixes a real,
## separate, previously-unnoticed bug: 150 was never actually a boss wave
## under BOSS_EVERY=20's own math ((150-20)%20=10, not 0), so Dorrek could
## never have been granted at all under the old is_boss_wave-gated code --
## see after_wave_cleared's own comment on the fix.
const UNIT_WAVES: Array[int] = [10, 150, 500, 1500]

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

## static var, not const -- Step 3j's apply_custom_mc() reassigns
## GROWTH["kesh"] at runtime for a custom MC, mirroring the real
## P.GROWTH.kesh=... reassignment exactly. GDScript's `const` Dictionary
## literals are frozen (mutating one is a compile error, caught directly
## by trying it), unlike a plain JS object literal -- static var is the
## same mutable-content idiom FarroadCore.ROSTER/ARCH/etc. already use.
## Ian: "universally reduce HP growths by 30% and speed growths by 50% to
## make fights faster and bring speed more in line with other stats."
## Follow-up: "rather than have a multiplier, let's reduce the growths
## directly. I don't want to make the math more complicated than needed."
## Every hp/spd value below is the original design value x 0.7 (hp) or
## x0.5 (spd), computed once and written in directly -- no runtime
## multiplier. MC_GROWTH_RANGE's own hp/spd bounds below got the same
## reduction, computed the same way (that range was originally calibrated
## to match this table's own min/max spread).
static var GROWTH := {
	"kesh": {"hp": 23.8, "atk": 2.1, "mag": 1.0, "def": 1.4, "res": 1.0, "spd": 1.1},
	"ansa": {"hp": 15.4, "atk": 0.8, "mag": 2.3, "def": 0.9, "res": 1.7, "spd": 1.0},
	"dorrek": {"hp": 33.6, "atk": 1.6, "mag": 0.5, "def": 2.4, "res": 1.4, "spd": 0.7},
	"vey": {"hp": 14.7, "atk": 2.0, "mag": 0.7, "def": 0.9, "res": 0.8, "spd": 1.6},
	"mirel": {"hp": 12.6, "atk": 0.6, "mag": 2.7, "def": 0.8, "res": 1.5, "spd": 0.95},
	"skarn": {"hp": 16.8, "atk": 2.1, "mag": 0.9, "def": 1.6, "res": 1.5, "spd": 1.65},
	"sorin": {"hp": 26.6, "atk": 2.0, "mag": 2.0, "def": 1.6, "res": 1.5, "spd": 1.15},
	"nyra": {"hp": 17.5, "atk": 1.1, "mag": 2.1, "def": 2.0, "res": 2.0, "spd": 1.05},
	"brenn": {"hp": 33.6, "atk": 1.4, "mag": 1.3, "def": 1.9, "res": 1.9, "spd": 1.5},
	"sael": {"hp": 16.8, "atk": 0.8, "mag": 2.5, "def": 1.1, "res": 1.6, "spd": 1.7}}

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

## Ian (24-item batch, Group B6): "no max on affinities." Always false now
## -- affinity_raw is genuinely uncapped, so there's no threshold left to
## gate a purchase on. Kept as a function (not deleted) since both call
## sites (spend_affinity's own refusal gate, AetherPanel's "MAXED" display)
## still read it; they now just always see "never maxed," which is
## exactly the desired behavior with zero changes needed at either site.
static func affinity_maxed(g: Dictionary, uid: String, axis: String) -> bool:
	return false

## Mirrors P.AFFINITY_COST_BASE/affinityCostToNext (farroad-progression.js).
## Ian (Group B6): "increased cost scaling" to balance the newly-uncapped
## affinity above -- was linear (N*AFFINITY_COST_BASE), now quadratic
## ((N+1)^2*AFFINITY_COST_BASE) so pushing deep into one axis gets
## meaningfully steeper rather than a flat per-point rate forever. First
## point still costs the same (round(4.0976*1)=4) as before; the 10th
## point was 41, is now round(4.0976*100)=410.
const AFFINITY_COST_BASE := 4.0976

static func affinity_cost_to_next(invested_points: int) -> int:
	var n: int = invested_points + 1
	return int(round(AFFINITY_COST_BASE * float(n * n)))

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

## Group J (20-item batch): a first-pass heuristic auto-builder for a
## unit's loadout, new Godot-only feature (no real-JS equivalent to
## mirror). NOT a true optimizer -- ranks the unit's own owned actions
## (g["actions"], the exact same eligible pool the real action picker
## itself offers -- see GambitsPanel._populate_action_picker) toward
## whichever camp (ATK/MAG) the unit's own CURRENT stats favor (via
## build_party_unit, which already applies level/pct-stat/equipment
## investment -- works for a benched unit too, no fielded requirement)
## and higher rank/power, then pairs each slot with an owned condition
## that fits the action's own target type where one exists (slot 0 always
## "none", matching the real game's own convention that a unit's first
## slot has no condition gate). Overwrites every slot -- an explicit,
## all-at-once rebuild, not a partial fill.
static func auto_assign_loadout(g: Dictionary, uid: String) -> void:
	var slots: Array = ensure_loadout(g, uid)
	var probe := build_party_unit(g, uid, 0)
	var dominant_camp: String = "mag" if float(probe["base"]["mag"]) > float(probe["base"]["atk"]) else "atk"

	var candidates: Array = g["actions"].duplicate()
	# Ian: "auto-set needs to account for actions other units have
	# equipped" -- exclude anything already held by ANOTHER fielded party
	# member (action_holder_in_party already exempts starter actions,
	# which every unit can freely share), the exact same exclusivity rule
	# the manual action picker (GambitsPanel._populate_action_picker)
	# already enforces.
	candidates = candidates.filter(func(aid): return action_holder_in_party(g, aid, uid) == null)
	candidates.sort_custom(func(a, b):
		var act_a = FarroadCore.ACTIONS.get(a)
		var act_b = FarroadCore.ACTIONS.get(b)
		if act_a == null or act_b == null:
			return act_a != null
		return _auto_assign_score(act_a, dominant_camp) > _auto_assign_score(act_b, dominant_camp))
	if candidates.is_empty():
		candidates = ["strike"]

	for i in range(slots.size()):
		var action_id: String = candidates[i % candidates.size()]
		var act = FarroadCore.ACTIONS.get(action_id)
		slots[i]["action"] = action_id
		slots[i]["cond"] = ("none" if i == 0 or act == null else _auto_assign_condition(act, g["conditions"]))
	g["touched"][uid] = true
	sync_loadout(g, uid)

static func _auto_assign_score(act: Dictionary, dominant_camp: String) -> float:
	var camp_bonus: float = 10.0 if act.get("camp") == dominant_camp else 0.0
	return camp_bonus + float(act.get("rank", 0.0)) + float(act.get("power", 0.0))

## Best-fit owned condition for this action's own target type, else
## "none" -- a heal/ally-targeting action prefers an HP-threshold ally
## condition, a self-targeting action a self HP-threshold, everything
## else (foe-targeting) a foe-focused condition, each list ordered
## tightest-fit first.
static func _auto_assign_condition(act: Dictionary, owned_conditions: Array) -> String:
	var tk = act.get("tk", "foe")
	var preferred: Array
	if act.get("heal", false) or tk == "ally" or tk == "allAllies":
		preferred = ["ally_hp_lte_50", "ally_hp_lte_60", "ally_hp_lte_80"]
	elif tk == "self":
		preferred = ["self_hp_lte_50", "self_hp_lte_60", "self_hp_lte_80"]
	elif tk == "deadAlly":
		preferred = []
	else:
		preferred = ["foe_lowest_hp", "foe_lacks_debuff", "foe_armoured"]
	for cid in preferred:
		if owned_conditions.has(cid):
			return cid
	return "none"

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

## Mirrors fieldUnit (farroad-ui.js:2653-2659), now including the
## isOnExpedition guard (Step 3h) -- refuses if not owned, already
## fielded, on an active expedition, or the party is full; else appends
## and runs auto_equip(g), same as the real call -- a no-op for this unit
## if g["touched"][uid] is already set, otherwise it installs the default
## curated rule.
static func field_unit(g: Dictionary, uid: String) -> bool:
	if not g["owned"].get(uid):
		return false
	if g["party"].has(uid):
		return false
	if is_on_expedition(g, uid):
		return false
	if g["party"].size() >= PARTY_CAP:
		return false
	g["party"].append(uid)
	auto_equip(g)
	return true

## Mirrors availableForParty (farroad-ui.js:2646-2647), now including the
## isOnExpedition filter (Step 3h) -- every owned, unfielded, not-away
## unit is available.
static func available_for_party(g: Dictionary) -> Array:
	var out := []
	for uid in g["owned"].keys():
		if not g["party"].has(uid) and not is_on_expedition(g, uid):
			out.append(uid)
	return out

## ===== party presets (24-item batch, Group E1) =====
## Ian: "save current party as a default party you name. Have up to 10."
## g["partyPresets"] is an Array of {"name": String, "party": Array[uid]}.
## Godot-originating (no real-JS precedent), mirrored to farroad-ui.js for
## parity the same way the Shop was.
const PARTY_PRESET_CAP := 10

static func save_party_preset(g: Dictionary, preset_name: String) -> bool:
	var trimmed: String = preset_name.strip_edges()
	if trimmed == "" or (g["party"] as Array).is_empty():
		return false
	if (g["partyPresets"] as Array).size() >= PARTY_PRESET_CAP:
		return false
	g["partyPresets"].append({"name": trimmed.substr(0, 24), "party": (g["party"] as Array).duplicate()})
	return true

## Fields exactly the preset's members that are still valid right now --
## owned, and not away on an expedition -- capped at PARTY_CAP, in the
## preset's own order. A member that's since been sent out is silently
## skipped rather than failing the whole load. Refuses (leaving the
## current party untouched) if that would leave nobody fielded.
static func preset_members_available(g: Dictionary, index: int) -> Array:
	var presets: Array = g["partyPresets"]
	if index < 0 or index >= presets.size():
		return []
	var out := []
	for uid in presets[index]["party"]:
		if out.size() >= PARTY_CAP:
			break
		if g["owned"].get(uid) and not is_on_expedition(g, uid) and not out.has(uid):
			out.append(uid)
	return out

static func load_party_preset(g: Dictionary, index: int) -> bool:
	var members := preset_members_available(g, index)
	if members.is_empty():
		return false
	g["party"] = members
	auto_equip(g)
	return true

static func delete_party_preset(g: Dictionary, index: int) -> bool:
	var presets: Array = g["partyPresets"]
	if index < 0 or index >= presets.size():
		return false
	presets.remove_at(index)
	return true

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

## v2.13: Lore became PER-ACTION -- g["loreByAction"][aid] is a cumulative
## EARNED total for that one action specifically (replacing the single
## global g["lore"]), only ever incremented (by grant_drops'/do_pull's
## duplicate-drop routing below). "Free Lore to spend ON THIS ACTION" is
## still always DERIVED live as that action's own earned-minus-spent --
## bonus_spend already works on a single-action map (`{aid: b}`), matching
## the same idiom FarroadSave.gd's refund-diff already used.
static func free_lore(g: Dictionary, action_id: String) -> float:
	var earned: float = float(g["loreByAction"].get(action_id, 0.0))
	var spent: int = FarroadCore.bonus_spend({action_id: g["bonuses"].get(action_id, {})})
	return maxf(0.0, earned - float(spent))

## Sum of every action's own Lore pool -- the simple aggregate the top HUD
## shows (GameController._refresh_hud), distinct from any one action's own
## detail-view pool (free_lore above).
static func total_lore(g: Dictionary) -> float:
	var t := 0.0
	for aid in g["loreByAction"].keys():
		t += float(g["loreByAction"][aid])
	return t

## The "Lv%d" tag shown next to an action's name wherever a level makes
## sense to show (originally LorePanel's own card only; post-batch
## feedback asked for it on the GAMBITS action picker and Catalogue too,
## so this moved here as the single shared source both now call) --
## always equal to that action's own TOTAL LORE EARNED
## (g["loreByAction"][aid], not just what's been spent on it), e.g. Lv. 4
## once 4 total Lore has been earned for it, regardless of how many
## upgrade stacks that Lore has actually bought.
static func action_level(g: Dictionary, action_id: String) -> int:
	return floori(g["loreByAction"].get(action_id, 0.0))

## Mirrors the inline unusedIds/refundTotal computation (farroad-ui.js:2051-2056)
## -- read-only preview, no mutation. Iterates g["bonuses"].keys() (every
## action id the player has EVER spent Lore on), not lore_action_ids(g) --
## an action can fall out of the current tab pool (e.g. a dropped/unpulled
## action) while still holding a refundable Lore investment. v2.13: flat
## per-stack cost, no more triangular total*(total+1)/2 reconstruction --
## reuses bonus_spend directly, same as free_lore above.
static func unused_lore_refund(g: Dictionary) -> Dictionary:
	var used := used_actions(g)
	var unused_ids := []
	for aid in g["bonuses"].keys():
		if not used.has(aid) and g["bonuses"][aid] and not g["bonuses"][aid].is_empty():
			unused_ids.append(aid)
	var refund_total := 0
	for aid in unused_ids:
		refund_total += FarroadCore.bonus_spend({aid: g["bonuses"][aid]})
	return {"ids": unused_ids, "total": refund_total}

## Mirrors the bulk refund handler (farroad-ui.js:2216-2220) -- deletes each
## given action's ENTIRE bonus entry (typically unused_lore_refund(g)["ids"]).
## Never touches g["loreByAction"] -- free_lore(g, aid) rises on its own once
## bonus_spend drops. No re-validation inside (the real JS doesn't either -- the button
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
		u["level"] = level_of(g, u["id"])
		u["affinity"] = effective_affinity(g, u["id"])
		u["slots"] = ensure_loadout(g, u["id"]).map(func(s): return {"cond": s["cond"], "action": s["action"]})

## One party member's fresh unit dict -- factored out of build_party() so
## refresh_live_party() (below) can build a single newly-fielded unit the
## same way, without re-running the whole party's construction.
static func build_party_unit(g: Dictionary, uid: String, slot_index: int) -> Dictionary:
	var def = FarroadCore.roster_by_id(uid)
	var lvl: int = level_of(g, uid)
	var st := stats_at(uid, def["stats"], def["hp"], lvl)
	apply_pct_stat_investment(g, uid, st)
	apply_equipment_stats(g, uid, st)
	var mh: float = st["hp"]
	var carry = g["hpCarry"].get(uid)
	# Ian: "the player currently heals between waves by default. Remove
	# that. I want players to have to opt in." -- the earlier free
	# tutorial-only top-up is gone; recovery_of(g, uid) (real AETHER
	# Recovery investment, opt-in by spending) is the only thing that ever
	# tops up hpCarry now, tutorial or not.
	if carry != null:
		carry = minf(1.0, carry + recovery_of(g, uid))
	var hp: float = mh if carry == null else maxf(1.0, round(mh * carry))
	# Charge persists between Road waves too, same shape as hpCarry above --
	# carries forward as-is (no recovery-style decay/regen), 0 if this unit
	# was never fielded before (a fresh join, or a legacy pre-chargeCarry
	# save). Scoped to build_party_unit only -- build_expedition_party
	# deliberately keeps its own fresh-start-each-time convention, a
	# separate system.
	# Ian: "the status log is not updating unit levels" -- this was
	# hardcoded to 1 (matching a real hardcode the JS reference itself
	# has -- combat math never reads u.level, only stats_at's OWN level
	# param above does), but the Status popup's own level line DOES read
	# u["level"] for a party unit. The real JS's equivalent card sidesteps
	# this by reading levelOf(u.id) live instead of u.level -- simpler
	# here to just make u["level"] itself correct at construction.
	return FarroadCore.make_unit({"id": uid, "name": def["name"], "isParty": true, "level": lvl,
		"slotIndex": slot_index, "stats": st, "maxHp": mh, "hp": minf(hp, mh), "row": def.get("row"),
		"chargeAction": def.get("chargeAction"), "charge": g["chargeCarry"].get(uid, 0.0),
		"affinity": effective_affinity(g, uid),
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
## instead of jumping the queue. A benched party member is REMOVED from
## both arrays outright (not just zeroed) -- Godot-only behavior, no real-
## JS equivalent to mirror (benchUnit/fieldUnit, farroad-ui.js:2680-2691,
## only ever touch G.party; the real game has no mid-fight live-sync at
## all, this whole mechanism is a Godot-side enhancement, confirmed
## untested by any parity mode). Removing outright (rather than the
## earlier hp=0-in-place convention) is what lets the presentation layer
## actually hop the sprite offscreen and free it, instead of leaving a
## permanently-dimmed corpse standing in a slot that unit no longer
## occupies. Safe against FarroadCore.step()'s own battle["units"]
## iteration -- pick_next()/check_end() already skip/ignore anything not
## found by id, nothing there assumes a fixed array length or indexes
## positionally. Returns {"added": [unit dicts...], "removed": [uid
## strings...]} so the presentation layer can build matching UnitViews
## for additions and animate/free the ones removed.
static func refresh_live_party(g: Dictionary) -> Dictionary:
	if g.get("units") == null:
		return {"added": [], "removed": []}
	var present_ids := {}
	for u in g["units"]:
		present_ids[u["id"]] = true
	var removed := []
	for u in g["units"]:
		if u["isParty"] and not g["party"].has(u["id"]):
			removed.append(u["id"])
	if not removed.is_empty():
		g["units"] = (g["units"] as Array).filter(func(u): return not removed.has(u["id"]))
		g["battle"]["units"] = (g["battle"]["units"] as Array).filter(func(u): return not removed.has(u["id"]))
	var added := []
	for i in range(g["party"].size()):
		var uid: String = g["party"][i]
		if not present_ids.has(uid):
			var nu := build_party_unit(g, uid, g["units"].size())
			nu["nextActAt"] = g["battle"]["t"] + FarroadCore.tc_of(nu, 1.00)
			g["units"].append(nu)
			g["battle"]["units"].append(nu)
			added.append(nu)
	return {"added": added, "removed": removed}

## @param quiet caller-side hook for a future variety-roll log line -- no log
## is built here (that's a UI concern), kept only so callers match the real
## JS signature exactly.
static func build_enemies(g: Dictionary, w: int, _quiet: bool = false, super_boss_key: String = "") -> Array:
	var boss: bool = is_boss_wave(w) or super_boss_key != ""
	var variety: bool = (not boss) and w > VARIETY_FROM
	var n: int = 1 if boss else (roll_count(g["rng"], w) if variety else enemy_count(w))
	# The very first boss (wave 20, BOSS_WAVES[0]) -- the tutorial's own
	# climax fight, still worth its own dedicated softening (FIRST_BOSS_LEN/
	# HARD_EXTRA/DMG_MUL below) regardless of party size, unlike count_mul's
	# own solo-vs-party check just below this.
	var is_first_boss: bool = boss and w == BOSS_WAVES[0]
	# Ian: "make waves with fewer enemies stronger." count_strength(n) was
	# already exactly this compensation curve (n=1 -> x1.85 per enemy down
	# to n=10 -> x0.29) -- the "fewer enemies than a full party" reasoning
	# it exists for only makes sense once the player HAS a real party bigger
	# than 1, so it's gated on actual live party size, not a wave-number
	# proxy (a wave-number gate like the old "w>=UNIT_WAVES[0]" would need
	# re-deriving by hand every time UNIT_WAVES[0] itself changes -- it
	# already did once, see UNIT_WAVES' own comment). A genuinely solo
	# player (party size 1, true through wave 9 and the wave-20 boss alike
	# unless/until a real 2nd body has actually joined) never gets
	# compensated against; the instant party size exceeds 1 -- whether
	# that's the wave-20 boss (now a real 2-vs-1 fight since Ansa joins at
	# wave 10) or any later wave -- it correctly does.
	var is_solo: bool = g["party"].size() <= 1
	var count_mul: float = count_strength(n) if not is_solo else 1.0
	var v_mul: float = (count_mul * band_roll(g["rng"])) if variety else count_mul
	FarroadCore.set_wave(w)
	var s: float = FarroadCore.wave_scale(w)
	var out := []
	var priest_used := false   # 1 healer max per wave -- see below
	for j in range(n):
		var key: String = "ox" if boss else archetype_for(w, j)
		# archetype_for can hand back "priest" more than once in the same
		# wave -- every WAVE_ARCH wave 1-19 uses ONE archetype for every
		# slot (so a multi-enemy wave 5-7 was previously all-healer), and
		# post-19 ROT (length 6) repeats once a wave rolls more than 6
		# enemies (possible post-wave-100 via COUNT_WEIGHTS_HARD, up to
		# 10). A wave full of simultaneous healers can stall the fight
		# indefinitely (the CSV's own design note: "Only enemy that
		# heals... Kill first or the fight stalls") -- cap it at 1,
		# deterministically, no extra RNG draw: the first priest slot
		# stays a priest, every later one falls back to "wolf" (always
		# defined, the safest/plainest archetype).
		if key == "priest":
			if priest_used:
				key = "wolf"
			else:
				priest_used = true
		var a: Dictionary = FarroadCore.ARCH[key]
		# Post-Milestone-3 APK feedback (Group C1): pure bookkeeping for the
		# new Catalogue tab's Enemies list -- marks this archetype as
		# encountered. Zero RNG consumption, so this is safe to write
		# unconditionally with no parity impact (verified via the full
		# 60-wave progression-mode battle trace staying bit-exact). Godot-only
		# -- Catalogue has no real-JS equivalent, so g["seenArch"] is
		# deliberately NOT mirrored to src/farroad-save.js/parity-reference.js.
		if g.has("seenArch"):
			g["seenArch"][key] = true
		# is_first_boss computed above (before count_mul) -- it alone uses the
		# eased FIRST_BOSS_LEN/FIRST_BOSS_HARD_EXTRA/FIRST_BOSS_DMG_MUL below;
		# every later boss keeps the full BOSS_LEN/BOSS_HARD_EXTRA unchanged.
		var hp_base: float
		if boss:
			var ref: Dictionary = FarroadCore.ARCH["wolf"]
			var len_mul: float = 3.0 if super_boss_key != "" else (FIRST_BOSS_LEN if is_first_boss else BOSS_LEN)
			hp_base = 200.0 * ref["hpMul"] * FarroadCore.dmg_taken_mul(ref) * s * \
				maxf(1, enemy_count(w)) * len_mul
		else:
			hp_base = 200.0 * a["hpMul"] * FarroadCore.dmg_taken_mul(a) * s
		# Ian: waves 1-20 still wiping way too often even after the earlier
		# tutorial ATK/MAG halving -- tutorial_atk_mag_mul(w) was ALREADY the
		# right shape (flat 0.5x through wave 20, ramping back to 1.0x by
		# wave 100), it just never touched HP, only atk/mag below. A
		# high-hpMul archetype (Stone Ox, wave 14-16, hpMul 1.60 -- the
		# tutorial's biggest single spike, confirmed via direct simulation:
		# every build tested wiped 200+ times specifically at this wave)
		# dragged fights on long enough to trigger runaway enrage on top of
		# its own inflated HP. Reused here (same function, same ramp) for
		# every tutorial enemy uniformly -- boss and non-boss alike, matching
		# how dmg_mul below already applies to atk/mag on both regardless of
		# boss status, not a new one-off HP-only constant.
		hp_base *= DIFFICULTY * v_mul * sqrt(hard_mul(w)) * tutorial_atk_mag_mul(w)
		var hard_atk_mul: float = hard_mul(w) * ((FIRST_BOSS_HARD_EXTRA if is_first_boss else BOSS_HARD_EXTRA) if boss else 1.0)
		var atk_mul: float = (1.10 if boss else 1.0) * DIFFICULTY * v_mul * hard_atk_mul
		var dmg_mul: float = (FIRST_BOSS_DMG_MUL if is_first_boss else 1.0) * tutorial_atk_mag_mul(w)
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
		# 20-item batch, Group F: bosses get a flat Spirit bonus (own,
		# freshly-constructed affinity dict -- make_unit already copies
		# a["affinity"]'s values out into a NEW dict per unit, so this never
		# touches the shared ARCH data) so their own debuffs land harder and
		# incoming debuffs from the party resist harder, per the new
		# caster-boost/target-resist debuff formula (apply_status/
		# aff_boost_resist above).
		if boss:
			var boss_unit: Dictionary = out[out.size() - 1]
			boss_unit["affinity"]["spirit"] = float(boss_unit["affinity"]["spirit"]) + BOSS_SPIRIT_BONUS
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

## Credits ONE Lore to a specific action's own pool -- duplicate REGULAR
## actions and duplicate CHARGE actions both route here (v2.13: charge
## actions are no longer special-cased to random routing, per the confirmed
## design -- a charge-action duplicate is "specific to itself," same as a
## regular action).
static func _credit_lore(g: Dictionary, action_id: String) -> void:
	g["loreByAction"][action_id] = float(g["loreByAction"].get(action_id, 0.0)) + 1.0

## Credits ONE Lore to a RANDOM action's pool, chosen from lore_action_ids(g)
## via g["rng"] -- the only remaining "random" routing case (a duplicate
## CONDITION has no action of its own to credit). A no-op if the player
## somehow owns zero lore-eligible actions (shouldn't happen in practice --
## starter actions always exist by the time drops/pulls are reachable).
## Returns the credited action id ("" on the no-op path) -- 24-item batch,
## Group D6: MarksPanel names which action a duplicate gambit's Lore went
## to, which it couldn't before since this used to return nothing.
static func _credit_random_lore(g: Dictionary) -> String:
	var ids: Array = lore_action_ids(g)
	if ids.is_empty():
		return ""
	var aid: String = ids[g["rng"].next_int(ids.size())]
	_credit_lore(g, aid)
	return aid

## ===== drop granting (mirrors grantDrops, farroad-ui.js:639) =====
## Mutates g in place (actions/conditions/loreByAction/equipInv unlocked or
## bumped); returns a list of plain event Dictionaries describing what
## happened, for a future UI layer to log/notify however it likes.

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
				_credit_lore(g, d["id"])
			events.append({"kind": "action", "id": d["id"], "wave": w, "duplicate": dup,
				"why": d.get("why") if curated else null})
		elif kind == "charge":
			g["mc"]["acquiredCharges"] = g["mc"].get("acquiredCharges", [])
			var dup_c: bool = g["mc"]["acquiredCharges"].has(d["id"])
			if not dup_c:
				g["mc"]["acquiredCharges"].append(d["id"])
			else:
				_credit_lore(g, d["id"])
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
				_credit_random_lore(g)
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
	# Ian: "when units join, only give them strike and ember as their
	# actions so they don't start with actions others have." Without this,
	# a joining unit's loadout was populated lazily -- either
	# ensure_loadout's own strike+strike default, or (if fielded when the
	# NEXT drop happened to grant) auto_equip silently upgrading slot 0 to
	# whatever action the account had already unlocked, which could be
	# anything, not necessarily Ember. Seeding the loadout explicitly here
	# AND marking the unit as already-touched short-circuits auto_equip's
	# own per-unit gate (already keyed off g["touched"]) from ever
	# revisiting this unit -- strike+ember, permanently, until the player
	# edits it via GAMBITS themselves.
	if not g["loadout"].has(uid):
		g["loadout"][uid] = [{"cond": "none", "action": "strike"}, {"cond": "none", "action": "ember"}]
	g["touched"][uid] = true
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
	# Ian: waves 1-20 wiping too often -- enrage (ENRAGE_AFTER=20 beats, now
	# compounding EVERY beat, not just an enemy's own turn, since the earlier
	# "enrage every turn" change) was found to be a major hidden driver: a
	# solo tutorial character's fights are inherently slower than a full
	# party's (no one to split turns/damage with), so a merely-average-length
	# solo fight routinely runs past 20 beats and starts stacking -- directly
	# confirmed via simulation (Stone Ox's own attack nearly doubled, 21->42,
	# over one fight). Enrage exists to punish deliberate late-game
	# stalling, not to punish a tutorial character for being early-game
	# weak, so it's off entirely for the Road's own solo tutorial stretch --
	# same w<=20 boundary every other tutorial exception in this project
	# already uses (tutorial_atk_mag_mul, TUTORIAL_CHECKPOINT_EVERY).
	# Post-24-item-batch balance pass: pushed back from wave 21 to wave 31
	# (ENRAGE_FROM_WAVE) -- simulated across 8 MC builds, enrage at 21 was
	# the actual wall slow/support builds hit right after the tutorial;
	# with this plus tutorial_atk_mag_mul's post-tutorial dip, no tested
	# build stalls anywhere in waves 21-40.
	var enrage_on: bool = g.get("enrage", true) and w >= ENRAGE_FROM_WAVE
	g["battle"] = FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": enrage_on})
	g["over"] = null
	return events

## Waves 1-20 (the solo tutorial stretch, same boundary the earlier
## checkpoint/boss-difficulty rounds used) grant double Aether from
## clearing a wave -- scoped to the after_wave_cleared call site, not
## folded into kill_reward itself, since kill_reward is shared with
## expeditions/bonus fights (their own ew counters, unrelated to the
## Road's actual wave number) and the engine's other math must stay
## untouched, same discipline as every prior scoped balance change.
const TUTORIAL_AETHER_WAVES := 20
const TUTORIAL_AETHER_MUL := 2.0
## Ian: "have a new unit be guaranteed acquired at wave 60 if you don't
## have one by then" -- see after_wave_cleared's own comment.
const GUARANTEED_THIRD_WAVE := 60

static func after_wave_cleared(g: Dictionary) -> Array:
	var events := []
	var first_clear: bool = not g["clearedWaves"].get(g["wave"])
	g["clearedWaves"][g["wave"]] = 1
	for u in g["units"]:
		g["hpCarry"][u["id"]] = u["hp"] / u["maxHp"]
		g["chargeCarry"][u["id"]] = u["charge"]
	# 24-item batch, Stats page: "enemies defeated" -- a win means every
	# enemy in the wave went down. Same counter is bumped by every other
	# win path (side battles, expedition fights, bonus fights).
	g["enemiesDefeated"] = int(g.get("enemiesDefeated", 0)) + g["enemies"].size()
	var r := kill_reward(g["wave"], g["enemies"].size())
	var aether_mul: float = TUTORIAL_AETHER_MUL if g["wave"] <= TUTORIAL_AETHER_WAVES else 1.0
	# Ian (24-item batch, Group B5): "perhaps we need to have half rewards
	# for clearing waves you've already cleared." first_clear was already
	# computed above (line 1590) for the one-time boss events below, but
	# never applied to the base reward itself until now -- a checkpoint
	# replay (or a deliberate low-wave farm) now pays half. Live-play
	# forward progress (first_clear==true, the overwhelmingly common case)
	# is completely unaffected.
	var reclear_mul: float = 1.0 if first_clear else 0.5
	g["aether"] = g.get("aether", 0) + r["aether"] * aether_mul * reclear_mul
	g["marks"] = g.get("marks", 0) + r["marks"] * marks_mul(g) * reclear_mul
	if is_boss_wave(g["wave"]) and first_clear:
		g["bossesCleared"] = g.get("bossesCleared", 0) + 1
		var hoard := boss_aether(g["wave"]) * aether_mul
		g["aether"] += hoard
		events.append({"kind": "boss_hoard", "wave": g["wave"], "amount": hoard})
		# Ian: a popup congratulating the player on finishing the tutorial
		# and warning the road only gets harder -- shown exactly once, on the
		# FIRST boss's first clear. Its enrage explanation moved to its own
		# "enrage_intro" event below, now that enrage starts at wave 31.
		if g["wave"] == BOSS_WAVES[0]:
			events.append({"kind": "tutorial_complete", "wave": g["wave"]})
		events.append({"kind": "checkpoint", "wave": g["bossesCleared"] * BOSS_EVERY})
	# Ian: the enrage explanation shows "on the wave that enrage begins as
	# a mechanic" -- first clear of the wave right before ENRAGE_FROM_WAVE,
	# so it lands just before the first fight that can actually enrage.
	# Godot-only UI trigger (same as tutorial_complete).
	if first_clear and g["wave"] == ENRAGE_FROM_WAVE - 1:
		events.append({"kind": "enrage_intro", "wave": g["wave"]})
	# Ian: "add Ansa at wave 10, not 20" -- a companion join needs to fire on
	# ANY wave clear matching UNIT_WAVES, not just boss clears. Genuinely
	# fixes a real, separate, previously-unnoticed bug along the way: this
	# used to live INSIDE the is_boss_wave branch above, but UNIT_WAVES[1]
	# (150, dorrek) was never actually a boss wave under BOSS_EVERY=20's own
	# math ((150-20)%20=10, not 0) -- Dorrek could never have been granted
	# at all under the old code, boss wave or not. Kept event kind names
	# ("boss_companion"/"boss_no_companion") as-is despite no longer being
	# boss-exclusive, to avoid touching every consumer (GameController's
	# reward-flyer target lookup, parity coverage) for a rename with no
	# behavior change.
	if first_clear:
		var next = unit_due_at(g["wave"])
		if next and g["party"].has(next):
			next = null
		if next:
			if g["party"].size() < PARTY_CAP:
				join_companion(g, next)
				events.append({"kind": "boss_companion", "wave": g["wave"], "id": next})
		elif g["wave"] == BOSS_WAVES[0]:
			# Ian: "after wave 20, instead of a new unit, get a piece of
			# equipment and show a pop-up about equipment." Wave 20 no
			# longer has a companion due at all (Ansa moved to wave 10), so
			# this replaces what would otherwise be the generic
			# dup_unit_aether consolation -- specifically for the tutorial
			# boss, not any later "no companion due" boss clear (those keep
			# the plain Aether consolation, same as before). Same
			# weighted-pick + equipInv grant shape do_pull's own 'equip'
			# branch already uses.
			var equip_ids := random_equipment_ids()
			var eid: String = weighted_equipment_pick(g["rng"], equip_ids)
			g["equipInv"][eid] = int(g["equipInv"].get(eid, 0)) + 1
			events.append({"kind": "tutorial_equip", "wave": g["wave"], "id": eid})
		elif is_boss_wave(g["wave"]):
			# The "have some Aether instead" consolation stays scoped to boss
			# clears specifically (its original spot) -- a regular wave clear
			# never had a companion due in the first place, so it shouldn't
			# start granting a phantom consolation prize just because this
			# check moved out of the old is_boss_wave gate.
			var dup := dup_unit_aether(g["wave"])
			g["aether"] += dup
			events.append({"kind": "boss_no_companion", "wave": g["wave"], "amount": dup})
	# Ian: "wave 20: getting equipment and a unit, should just be
	# equipment." Root cause: this 10% roll used to fire on EVERY boss
	# wave clear independently of the tutorial-equip branch above, so
	# 10% of the time wave 20 handed out the guaranteed equipment AND a
	# bonus companion on top. Excluded BOSS_WAVES[0] specifically -- every
	# later boss keeps the roll untouched.
	if is_boss_wave(g["wave"]) and g["wave"] != BOSS_WAVES[0] and g["rng"].next() < 0.10:
		var boss_avail: Array = FarroadCore.ROSTER.filter(func(r): return not g["owned"].get(r["id"]))
		if not boss_avail.is_empty():
			var pick: Dictionary = boss_avail[g["rng"].next_int(boss_avail.size())]
			var fielded := join_companion(g, pick["id"])
			events.append({"kind": "boss_companion_roll", "wave": g["wave"], "id": pick["id"], "fielded": fielded})
	# Ian: "have a new unit be guaranteed acquired at wave 60 if you don't
	# have one by then" -- a backstop on top of the 10% boss_companion_roll
	# above (already possible at waves 20/40/60 by this point), for the
	# unlucky case where none of those hit. Scoped to first_clear of wave
	# 60 specifically, and only if the roster is still stuck at just
	# kesh+Ansa (owned<3) -- if the roll (or an earlier lucky roll) already
	# got a 3rd companion, this is a no-op.
	if g["wave"] == GUARANTEED_THIRD_WAVE and first_clear and g["owned"].size() < 3:
		var avail: Array = FarroadCore.ROSTER.filter(func(r): return not g["owned"].get(r["id"]))
		if not avail.is_empty():
			var pick2: Dictionary = avail[g["rng"].next_int(avail.size())]
			var fielded2 := join_companion(g, pick2["id"])
			events.append({"kind": "boss_companion_roll", "wave": g["wave"], "id": pick2["id"], "fielded": fielded2})
	return events

static func on_wipe(g: Dictionary) -> Array:
	g["wipes"] = g.get("wipes", 0) + 1
	var back := checkpoint(g.get("bossesCleared", 0), g.get("farthest", 1))
	g["hpCarry"] = {}
	g["chargeCarry"] = {}
	var events: Array = [{"kind": "wipe", "backTo": back}]
	events.append_array(start_wave(g, back))
	return events

## ===== new game / new save (mirrors newGame/newDirections, farroad-ui.js:45) =====

## Step 3h: DIRECTION_CONFIG is now exported (export-content.js) and
## loaded into FarroadCore.DIRECTION_CONFIG -- direction_ids() derives the
## 8 ids from it directly, mirroring the real P.DIRECTIONS=
## Object.keys(P.DIRECTION_CONFIG) exactly, no more hardcoded fallback list.
static func direction_ids() -> Array:
	return FarroadCore.DIRECTION_CONFIG.keys()

static func new_directions() -> Dictionary:
	var d := {}
	for dir in direction_ids():
		d[dir] = {"maxDepth": 0, "dungeonsUnlocked": 0}
	return d

static func new_game(seed: int, mc) -> Dictionary:
	return {
		"seed": seed if seed else 7, "rng": FarroadCore.make_rng(seed if seed else 7),
		"wave": 0, "farthest": 1, "bossesCleared": 0,
		"aether": 0, "loreByAction": {}, "marks": 0, "crystal": 0, "wipes": 0, "enemiesDefeated": 0,
		"pendingIdleAether": 0.0, "pendingIdleMarks": 0.0,
		"party": ["kesh"], "partyPresets": [], "actions": STARTER_ACTIONS.duplicate(), "conditions": ["none"],
		"actionCounts": {}, "condCounts": {}, "bonuses": {}, "recovery": {}, "loadout": {},
		"hpCarry": {}, "chargeCarry": {}, "touched": {}, "clearedWaves": {}, "dropsGranted": {},
		"lvl": {"kesh": 1}, "bank": {"kesh": 0}, "maxLevelEver": 1, "owned": {"kesh": 1},
		"affinities": {"kesh": {}}, "statInvest": {"kesh": {}},
		"equipInv": {}, "equipped": {"kesh": {}},
		"battle": null, "units": null, "enemies": null, "over": null, "enrage": true, "idleAcc": 0,
		"sideBattle": null, "roadBattle": null,
		"mc": mc, "expeditions": [], "pullsSinceUnit": 0,
		"dungeons": [], "quests": {"kesh": {"stage": 0, "frozen": []}},
		"superBossQuests": [], "superBossesUnlocked": 0, "superBossesCleared": {},
		"directions": new_directions(),
		"seenArch": {},
		# Ian: "add tutorial pop-ups the first time each page/tab is opened."
		# Godot-only, same as seenArch above (no real-JS equivalent -- these
		# popups only exist in the Godot UI) -- tab id -> true once its
		# first-open popup has been shown, checked by GameController's own
		# _maybe_show_tab_tutorial.
		"seenTabTutorial": {}}

## ===== EXPEDITIONS (Step 3h) =====
## Mirrors farroad-ui.js:947-1352 (simulateOfflineProgress through
## recallExpedition) -- the real JS reads Date.now() internally throughout;
## every time-touching function here instead takes `now` (Unix SECONDS,
## not the real JS's milliseconds -- matches FarroadSave.serialize's own
## established `now: int` convention) as an explicit parameter, so a
## parity test can inject a fixed fake time and get reproducible RNG-call
## counts. The real caller (GameController.gd) reads the clock once via
## Time.get_unix_time_from_system() and passes it down.
##
## Step 3i: resolveExpedition's dungeon-unlock side effect
## (unlockDirectionDungeon, see the DUNGEONS/QUESTS section below) is now
## wired in -- dp["maxDepth"] tracking (already ported here since 3h) is
## what feeds it.
##
## A pushDrop()-based game-wide banner (arrival notice, "Welcome back")
## is also not ported -- no drop-banner/toast system exists anywhere in
## this port yet (the same trim MARKS' pull-result display already made);
## push_expedition_log's own per-expedition log covers the same
## information for this panel's own display.

const EXPED_RETURN_HP_FRAC := 0.25
const EXPED_CAP_SEC := OFFLINE_CAP_SEC
const EXPED_DISCOVERY_CHANCE := 0.08
## 24-item batch, Group E4: non-combat road events. EXPED_EVENT_CHANCE is
## the per-node chance a stretch of road is one of these instead of a
## fight (first-pass value, easily retuned). Each entry's aether/marks is a
## multiple of that node's own normal kill_reward (so the payout scales
## with depth exactly the way fights do); heal restores a fraction of the
## party's shared HP pool. {names} is filled with the party's names.
## Mirrored verbatim in farroad-ui.js (EXPED_EVENTS) and parity-reference.js.
const EXPED_EVENT_CHANCE := 0.10
const EXPED_EVENTS: Array = [
	{"text": "{names} passed through a roadside town and traded stories for supplies.", "aether": 0.5, "marks": 0.0, "heal": 0.0},
	{"text": "{names} sold salvaged gear at a market stall.", "aether": 0.0, "marks": 1.0, "heal": 0.0},
	{"text": "{names} rescued a stranded traveler, who pressed a pouch of coin into their hands.", "aether": 1.0, "marks": 0.0, "heal": 0.0},
	{"text": "{names} escorted a merchant caravan past a bad stretch of road.", "aether": 0.75, "marks": 0.5, "heal": 0.0},
	{"text": "{names} rested at a quiet inn and patched up their wounds.", "aether": 0.0, "marks": 0.0, "heal": 0.2},
	{"text": "{names} found an abandoned camp with a few useful scraps.", "aether": 0.0, "marks": 0.5, "heal": 0.0},
	{"text": "{names} helped a farmer haul a cart out of a ditch and got a hot meal for it.", "aether": 0.0, "marks": 0.0, "heal": 0.1},
	{"text": "{names} traded tales with a wandering bard -- no coin, but good company.", "aether": 0.0, "marks": 0.0, "heal": 0.0},
	{"text": "{names} guided a band of lost pilgrims back to the road.", "aether": 0.5, "marks": 0.5, "heal": 0.0},
	{"text": "{names} left an offering at a wayside shrine and felt lighter for it.", "aether": 0.0, "marks": 0.0, "heal": 0.15},
	{"text": "{names} bartered spare rations at a crossroads trading post.", "aether": 0.0, "marks": 0.75, "heal": 0.0},
	{"text": "{names} cut a traveler loose from a bandit camp -- the bandits had already fled.", "aether": 1.25, "marks": 0.0, "heal": 0.0},
]
const DIRECTION_AFFINITY_BONUS := 6.0

static func direction_label(dir: String) -> String:
	return FarroadCore.DIRECTION_CONFIG.get(dir, {}).get("label", dir)

static func direction_mul(dir: String) -> float:
	return FarroadCore.DIRECTION_CONFIG.get(dir, {}).get("mul", 1.0)

## Mirrors isOnExpedition (farroad-ui.js:1012-1013).
static func is_on_expedition(g: Dictionary, uid: String) -> bool:
	for exp in g.get("expeditions", []):
		if exp["partyIds"].has(uid):
			return true
	return false

static func _expedition_names(party_ids: Array) -> String:
	var names: Array = []
	for uid in party_ids:
		var def = FarroadCore.roster_by_id(uid)
		names.append(def["name"] if def else uid)
	return ", ".join(names)

## Mirrors pushExpeditionLog (farroad-ui.js:1014-1017) -- newest first,
## capped at 40 entries.
static func push_expedition_log(exp: Dictionary, text: String, now) -> void:
	if not exp.has("log"):
		exp["log"] = []
	exp["log"].push_front({"at": now, "text": text})
	while exp["log"].size() > 40:
		exp["log"].pop_back()

## Mirrors applyStatMul (farroad-ui.js:1116-1122) -- asymmetric scaling:
## HP via sqrt(mul), ATK/MAG via mul directly. Mutates `enemies` in place
## (same as the real function) and returns it too, for chaining.
static func apply_stat_mul(enemies: Array, mul: float) -> Array:
	var hp_mul: float = sqrt(mul)
	for u in enemies:
		u["base"]["hp"] = maxf(1.0, round(u["base"]["hp"] * hp_mul))
		u["maxHp"] = u["base"]["hp"]
		u["hp"] = u["base"]["hp"]
		u["base"]["atk"] = maxf(1.0, round(u["base"]["atk"] * mul))
		u["base"]["mag"] = round(u["base"]["mag"] * mul)
	return enemies

## Mirrors applyDirectionAffinity (farroad-ui.js:1131-1135) -- a flat
## additive bonus on top of an enemy's own archetype-authored affinity,
## never replacing it.
static func apply_direction_affinity(enemies: Array, dir: String) -> Array:
	var ax = FarroadCore.DIRECTION_CONFIG.get(dir, {}).get("affinity")
	if not ax:
		return enemies
	for u in enemies:
		u["affinity"][ax] = float(u["affinity"].get(ax, 0.0)) + DIRECTION_AFFINITY_BONUS
	return enemies

## Mirrors buildExpeditionParty (farroad-ui.js:1018-1032) -- close to
## build_party_unit (Step 3f) but genuinely different HP math: ONE shared
## hp_frac across the whole party (not per-unit g["hpCarry"]), so it's its
## own function rather than a build_party_unit reuse.
static func build_expedition_party(g: Dictionary, party_ids: Array, hp_frac) -> Array:
	var out := []
	for i in range(party_ids.size()):
		var uid: String = party_ids[i]
		var def = FarroadCore.roster_by_id(uid)
		var lvl: int = level_of(g, uid)
		var st := stats_at(uid, def["stats"], def["hp"], lvl)
		apply_pct_stat_investment(g, uid, st)
		apply_equipment_stats(g, uid, st)
		var mh: float = st["hp"]
		var frac: float = 1.0 if hp_frac == null else minf(1.0, float(hp_frac) + recovery_of(g, uid))
		var hp: float = maxf(1.0, round(mh * frac))
		out.append(FarroadCore.make_unit({"id": uid, "name": def["name"], "isParty": true, "level": lvl,
			"slotIndex": i, "stats": st, "maxHp": mh, "hp": minf(hp, mh), "row": def.get("row"),
			"chargeAction": def.get("chargeAction"), "affinity": effective_affinity(g, uid),
			"slots": ensure_loadout(g, uid).map(func(s): return {"cond": s["cond"], "action": s["action"]})}))
	return out

## Mirrors sendExpedition (farroad-ui.js:1084-1102) -- party-size/
## direction-validity/one-expedition-per-direction/ownership/not-already-
## fielded/not-already-out/no-duplicate-uid checks, then starts a fresh
## expedition. The id's random component deliberately uses Godot's own
## randi(), NOT g["rng"] -- mirrors the real 'exp'+Date.now()+'_'+
## Math.random() exactly, which is itself deliberately outside the seeded
## RNG stream (an id just needs to be unique, not reproducible) -- so
## expedition ids are never bit-exact between JS and GD, by design.
static func send_expedition(g: Dictionary, party_ids: Array, direction: String, now) -> bool:
	if party_ids.is_empty() or party_ids.size() > PARTY_CAP:
		return false
	if not direction_ids().has(direction):
		return false
	for exp in g["expeditions"]:
		if exp["direction"] == direction:
			return false
	var seen := {}
	for uid in party_ids:
		if seen.has(uid):
			return false
		seen[uid] = true
		if not g["owned"].get(uid) or g["party"].has(uid) or is_on_expedition(g, uid):
			return false
	var exp := {"id": "exp%d_%d" % [int(now), randi() % 1000000], "partyIds": party_ids.duplicate(),
		"direction": direction, "startedAt": now, "lastResolvedAt": now,
		"ew": 1, "hpFrac": 1.0, "bank": {"aether": 0.0, "marks": 0.0},
		"homeAt": null, "arrivedAt": null, "log": []}
	g["expeditions"].append(exp)
	var names := _expedition_names(party_ids)
	push_expedition_log(exp, "%s set out to explore %s." % [names, direction_label(direction)], now)
	return true

## Mirrors beginReturnTrip (farroad-ui.js:1069-1076) -- the trip home costs
## HALF the real time the party has been out, measured from startedAt to
## decision_moment (NOT `now` -- a big catch-up pass can cross the turn-
## back threshold mid-simulation, so the return-trip clock starts from
## THAT point, same reasoning the real comment gives).
static func begin_return_trip(exp: Dictionary, decision_moment, reason: String, now) -> void:
	if exp.get("homeAt") != null:
		return
	var away_sec: float = maxf(0.0, float(decision_moment) - float(exp["startedAt"]))
	exp["homeAt"] = float(decision_moment) + away_sec / 2.0
	var names := _expedition_names(exp["partyIds"])
	push_expedition_log(exp, "%s — %s Heading home now." % [names, reason], now)
	check_arrival(exp, now)

## Mirrors checkArrival (farroad-ui.js:1151-1159) -- first-observation-only
## arrival flag; does NOT bank the reward (collect_expedition does that).
static func check_arrival(exp: Dictionary, now) -> void:
	if exp.get("arrivedAt") != null or exp.get("homeAt") == null or float(now) < float(exp["homeAt"]):
		return
	exp["arrivedAt"] = now
	var names := _expedition_names(exp["partyIds"])
	push_expedition_log(exp, "%s arrived home — awaiting collection." % names, now)

## Mirrors resolveExpedition (farroad-ui.js:1160-1206) -- the real-time
## resolution loop for ONE expedition. 5s no-op floor, 12h cap, a
## cost=20+travel_sec(ew)-second-per-node loop building a fresh
## expedition party + direction-scaled/-themed enemies each node, banking
## kill_reward*mul (+boss_aether*mul on a boss node), tracking average-
## alive-HP-fraction, auto-turning-back below EXPED_RETURN_HP_FRAC.
## Restores FarroadCore's global current-wave via set_wave(saved_wave)
## before returning -- build_enemies's own set_wave call would otherwise
## leave the Road's wave-scaling state pointed at the expedition's ew, the
## same real, easy-to-miss fix-up the JS source itself flags in a comment.
static func resolve_expedition(g: Dictionary, exp: Dictionary, now) -> void:
	if exp.get("homeAt") != null:
		check_arrival(exp, now)
		return
	var elapsed_sec: float = maxf(0.0, float(now) - float(exp["lastResolvedAt"]))
	if elapsed_sec < 5.0:
		return
	var resolve_started_at: float = exp["lastResolvedAt"]
	var capped: float = minf(elapsed_sec, EXPED_CAP_SEC)
	var mul: float = direction_mul(exp["direction"])
	var remaining: float = capped
	var guard := 0
	var saved_wave: int = g["wave"]
	var turned_back := false
	while remaining > 0.0 and guard < 200000:
		guard += 1
		var cost: float = 20.0 + travel_sec(exp["ew"])
		if cost > remaining:
			break
		# Ian: expedition log entries "tend to be grouped together... should
		# be based on how long the party has been out, not the time of
		# day." Root cause: every push_expedition_log call inside this loop
		# used to pass the outer, real-wall-clock `now` -- so a catch-up
		# pass resolving 1 node or 50 nodes stamped every entry with the
		# EXACT same real moment. sim_now is this node's own simulated
		# elapsed-away offset instead (mirrors how begin_return_trip's own
		# decision_moment is already computed below), spreading entries
		# across the party's simulated time away rather than clustering at
		# real time.
		var sim_now: float = resolve_started_at + (capped - remaining) + cost
		# Ian (24-item batch, Group E4): "more variety in expedition events:
		# visiting towns, selling goods, rescuing other travelers." A flat
		# per-node chance that this stretch of road is a non-combat event
		# instead of a fight -- the party still advances a node (ew+1,
		# maxDepth/dungeon schedule as normal), just without a battle. The
		# roll is drawn every node, event or not, so both engines consume
		# RNG identically.
		if g["rng"].next() < EXPED_EVENT_CHANCE:
			roll_expedition_event(g, exp, mul, sim_now)
			exp["ew"] += 1
			_advance_direction_depth(g, exp, now, sim_now)
		else:
			var party := build_expedition_party(g, exp["partyIds"], exp["hpFrac"])
			var enemies: Array = apply_direction_affinity(
				apply_stat_mul(build_enemies(g, exp["ew"], true), mul), exp["direction"])
			var battle := FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": g.get("enrage", true)})
			var beat_guard := 0
			while battle["over"] == null and beat_guard < 4000:
				beat_guard += 1
				if FarroadCore.step(battle) == null:
					break
			if battle["over"] == "party":
				g["enemiesDefeated"] = int(g.get("enemiesDefeated", 0)) + enemies.size()
				var r := kill_reward(exp["ew"], enemies.size())
				exp["bank"]["aether"] = float(exp["bank"]["aether"]) + r["aether"] * mul
				exp["bank"]["marks"] = float(exp["bank"]["marks"]) + r["marks"] * marks_mul(g) * mul
				if is_boss_wave(exp["ew"]):
					exp["bank"]["aether"] = float(exp["bank"]["aether"]) + boss_aether(exp["ew"]) * mul
				var alive: Array = party.filter(func(u): return u["hp"] > 0)
				if alive.is_empty():
					exp["hpFrac"] = 0.0
				else:
					var sum_frac := 0.0
					for u in alive:
						sum_frac += float(u["hp"]) / float(u["maxHp"])
					exp["hpFrac"] = sum_frac / alive.size()
				exp["ew"] += 1
				roll_expedition_discovery(g, exp, mul, sim_now)
				_advance_direction_depth(g, exp, now, sim_now)
			else:
				exp["hpFrac"] = 0.0
		remaining -= cost
		if exp["hpFrac"] < EXPED_RETURN_HP_FRAC:
			turned_back = true
			break
	FarroadCore.set_wave(saved_wave)
	exp["lastResolvedAt"] = now
	if turned_back:
		begin_return_trip(exp, resolve_started_at + (capped - remaining), "injuries mounted and the party turned back.", now)

## Shared by both node kinds (fight won / road event) -- extracted from
## resolve_expedition's own win branch unchanged. A while, not if -- a big
## catch-up pass crossing more than one unlockEvery multiple in one go must
## unlock every intervening dungeon, not just one.
static func _advance_direction_depth(g: Dictionary, exp: Dictionary, now, sim_now: float) -> void:
	var dp: Dictionary = g["directions"][exp["direction"]]
	dp["maxDepth"] = maxi(dp["maxDepth"], exp["ew"])
	var target_tier: int = int(floor(float(dp["maxDepth"]) / float(FarroadCore.DIRECTION_CONFIG[exp["direction"]]["unlockEvery"])))
	while target_tier > dp["dungeonsUnlocked"]:
		dp["dungeonsUnlocked"] += 1
		var new_dungeon: Dictionary = unlock_direction_dungeon(g, exp["direction"], dp["dungeonsUnlocked"], now)
		push_expedition_log(exp, "Found the way into %s — enter it from the QUESTS tab." % new_dungeon["name"], sim_now)

## 24-item batch, Group E4 -- one non-combat road event (see EXPED_EVENTS).
## Picks via g["rng"], banks any reward into exp["bank"] like a won fight
## would, restores any heal onto the party's shared hpFrac, and logs it at
## the node's own simulated timestamp.
static func roll_expedition_event(g: Dictionary, exp: Dictionary, mul: float, sim_now: float) -> void:
	var ev: Dictionary = EXPED_EVENTS[g["rng"].next_int(EXPED_EVENTS.size())]
	var names := _expedition_names(exp["partyIds"])
	var r := kill_reward(exp["ew"], enemy_count(int(exp["ew"])))
	var a_gain: float = r["aether"] * mul * float(ev["aether"])
	var m_gain: float = r["marks"] * marks_mul(g) * mul * float(ev["marks"])
	exp["bank"]["aether"] = float(exp["bank"]["aether"]) + a_gain
	exp["bank"]["marks"] = float(exp["bank"]["marks"]) + m_gain
	if float(ev["heal"]) > 0.0:
		exp["hpFrac"] = minf(1.0, float(exp["hpFrac"]) + float(ev["heal"]))
	var bits: Array = []
	if roundi(a_gain) >= 1:
		bits.append("+%d Aether" % roundi(a_gain))
	if floori(m_gain) >= 1:
		bits.append("+%d Marks" % floori(m_gain))
	if float(ev["heal"]) > 0.0:
		bits.append("recovered some HP")
	var text: String = String(ev["text"]).replace("{names}", names)
	if not bits.is_empty():
		text += " (%s)" % ", ".join(bits)
	push_expedition_log(exp, text, sim_now)

## Mirrors rollExpeditionDiscovery (farroad-ui.js:1250-1266) -- a flat 8%
## chance per won node, a full one-off bonus fight against the SAME
## party/ew, banked or logged as a miss. Never a dungeon (v2.9 correction,
## already the real behavior -- dungeons come from the deterministic
## per-direction schedule this step deliberately doesn't port).
static func roll_expedition_discovery(g: Dictionary, exp: Dictionary, mul: float, now) -> void:
	if g["rng"].next() >= EXPED_DISCOVERY_CHANCE:
		return
	var names := _expedition_names(exp["partyIds"])
	var b_enemies: Array = apply_direction_affinity(
		apply_stat_mul(build_enemies(g, exp["ew"], true), mul), exp["direction"])
	var b_party := build_expedition_party(g, exp["partyIds"], exp["hpFrac"])
	var b_battle := FarroadCore.make_battle(b_party + b_enemies, {"rng": g["rng"], "enrage": g.get("enrage", true)})
	var b_guard := 0
	while b_battle["over"] == null and b_guard < 4000:
		b_guard += 1
		if FarroadCore.step(b_battle) == null:
			break
	if b_battle["over"] == "party":
		g["enemiesDefeated"] = int(g.get("enemiesDefeated", 0)) + b_enemies.size()
		var br := kill_reward(exp["ew"], b_enemies.size())
		var b_aether: float = br["aether"] * mul
		var b_marks: float = br["marks"] * marks_mul(g) * mul
		exp["bank"]["aether"] = float(exp["bank"]["aether"]) + b_aether
		exp["bank"]["marks"] = float(exp["bank"]["marks"]) + b_marks
		push_expedition_log(exp, "%s won a bonus fight along the way — +%d Aether, +%d Marks." % [
			names, roundi(b_aether), floori(b_marks)], now)
	else:
		push_expedition_log(exp, "%s were ambushed in a bonus fight and had to disengage — no reward." % names, now)

## Mirrors resolveAllExpeditions (farroad-ui.js:1339-1340).
static func resolve_all_expeditions(g: Dictionary, now) -> void:
	for exp in g["expeditions"]:
		resolve_expedition(g, exp, now)

## Mirrors recallExpedition (farroad-ui.js:1348-1352) -- catches up first
## (may itself trigger a full or partial auto turn-back), then forces a
## turn-back right now if still out. No reward penalty -- nothing banked
## is lost, only the standard half-time trip delay applies. Returns false
## only if `id` doesn't match any active expedition (the real JS is void
## here; this port returns bool for consistency with every other mutation
## function's own "did this succeed" convention).
static func recall_expedition(g: Dictionary, id: String, now) -> bool:
	var exp = null
	for e in g["expeditions"]:
		if e["id"] == id:
			exp = e
	if exp == null:
		return false
	resolve_expedition(g, exp, now)
	if g["expeditions"].has(exp) and exp.get("homeAt") == null:
		begin_return_trip(exp, now, "recalled.", now)
	return true

## Mirrors collectExpedition (farroad-ui.js:1046-1056) -- only reachable
## once arrivedAt is set; grants bank into the real economy and removes
## the expedition.
static func collect_expedition(g: Dictionary, id: String) -> bool:
	var exp = null
	for e in g["expeditions"]:
		if e["id"] == id:
			exp = e
	if exp == null or exp.get("arrivedAt") == null:
		return false
	g["aether"] = float(g["aether"]) + float(exp["bank"]["aether"])
	g["marks"] = float(g["marks"]) + float(exp["bank"]["marks"])
	g["expeditions"] = g["expeditions"].filter(func(e2): return e2["id"] != exp["id"])
	return true

## Mirrors simulateOfflineProgress (farroad-ui.js:947-984) -- 5s no-op
## floor, 12h cap, credits the FULL idle trickle unconditionally for the
## capped duration, then replays real Road combat for as many
## cost=20+travel_sec(wave)-second waves as fit. A genuine wipe can happen
## while away, matching the real game's own "full fidelity over offline-
## never-wipes" choice. `saved_at` is the save envelope's own top-level
## timestamp (sibling to the FIELDS-derived g content), not anything
## inside `g` itself.
##
## Godot-only signature change (Group J, post-Milestone-3 batch): returns a
## summary Dictionary instead of void -- {} when the 5s floor wasn't met
## (a real caller distinguishes "nothing happened" from "elapsed_sec: 0.0"
## by checking is_empty(), same convention used elsewhere in this port),
## else the same waveBefore/wipesBefore/aetherBefore/marksBefore locals the
## real JS already computes via closure (it never needed a return value,
## since pushDrop() is called from inside the same function) -- no
## src/*.js edit needed, this is purely a Godot-side plumbing change so
## GameController can show its own "welcome back" popup instead.
static func simulate_offline_progress(g: Dictionary, saved_at, now) -> Dictionary:
	var elapsed_sec: float = maxf(0.0, float(now) - float(saved_at if saved_at != null else now))
	if elapsed_sec < 5.0:
		return {}
	var wave_before: int = int(g["wave"])
	var wipes_before: int = int(g.get("wipes", 0))
	var aether_before: float = float(g["aether"])
	var marks_before: float = float(g["marks"])
	var capped: float = minf(elapsed_sec, OFFLINE_CAP_SEC)
	var r := idle_per_sec(g.get("farthest", 1))
	# Ian: "don't add rewards from... idle until collected." Only the FLAT
	# idle-trickle gain is held back here -- banked into pendingIdleAether/
	# pendingIdleMarks (accumulates across multiple uncollected resumes,
	# same as the quest/dungeon pending pools) until the welcome-back
	# popup's own Collect button credits it. The REPLAYED COMBAT below
	# (after_wave_cleared's own real per-wave kill_reward) is a different
	# kind of event -- a wave clear, mechanically identical to one that
	# happens while actively playing -- and stays auto-applied exactly as
	# it always has, never gated.
	var idle_aether_this_time: float = r["aether"] * capped
	var idle_marks_this_time: float = r["marks"] * marks_mul(g) * capped
	g["pendingIdleAether"] = float(g.get("pendingIdleAether", 0.0)) + idle_aether_this_time
	g["pendingIdleMarks"] = float(g.get("pendingIdleMarks", 0.0)) + idle_marks_this_time
	var remaining: float = capped
	var guard := 0
	while remaining > 0.0 and guard < 200000:
		guard += 1
		if g.get("battle") == null:
			break
		var cost: float = 20.0 + travel_sec(g["wave"])
		if cost > remaining:
			break
		var beat_guard := 0
		while g["battle"]["over"] == null and beat_guard < 4000:
			beat_guard += 1
			if FarroadCore.step(g["battle"]) == null:
				break
		if g["battle"]["over"] == "party":
			after_wave_cleared(g)
			start_wave(g, g["wave"] + 1)
		elif g["battle"]["over"] == "enemy":
			on_wipe(g)
		else:
			break
		remaining -= cost
	return {
		"elapsed_sec": elapsed_sec,
		"wave_before": wave_before,
		"wave_after": int(g["wave"]),
		# aether_gained/marks_gained now cover ONLY what the replayed
		# combat itself already credited (kill_reward, never gated) --
		# idle_aether_pending/idle_marks_pending is the flat trickle this
		# call just banked, awaiting the welcome-back popup's Collect tap.
		"aether_gained": g["aether"] - aether_before,
		"marks_gained": g["marks"] - marks_before,
		"idle_aether_pending": idle_aether_this_time,
		"idle_marks_pending": idle_marks_this_time,
		"wipes_gained": int(g.get("wipes", 0)) - wipes_before,
	}

## Credits the accumulated-but-uncollected idle trickle to
## g["aether"]/g["marks"], zeroing both pending pools -- same bank-then-
## collect shape as collect_expedition. Quest/dungeon rewards used to
## follow this same pattern too (collect_quest_reward/
## collect_dungeon_reward) but were reverted to auto-credit per the
## 24-item batch's Group A/C5 ("have quest rewards be automatically
## attributed") -- idle income's own Collect button is unaffected, that
## question was never asked about idle.
static func collect_idle_reward(g: Dictionary) -> Dictionary:
	var aether: float = float(g.get("pendingIdleAether", 0.0))
	var marks: float = float(g.get("pendingIdleMarks", 0.0))
	if aether <= 0.0 and marks <= 0.0:
		return {"aether": 0.0, "marks": 0.0}
	g["aether"] = float(g["aether"]) + aether
	g["marks"] = float(g["marks"]) + marks
	g["pendingIdleAether"] = 0.0
	g["pendingIdleMarks"] = 0.0
	return {"aether": aether, "marks": marks}

## ===== POWER LEVEL (Step 3i, re-established + rescaled per later feedback) =====
## Displayed in the HUD next to Aether/Marks (GameController._refresh_hud),
## and also used to scale companion quest difficulty (questStageWave below)
## rather than reading G.wave directly, so a late-acquired companion's quest
## line doesn't face the "wall" a fixed wave-equivalent would create (the
## v2.9 correction the real source comment describes).
##
## Ian: "have it scale with combined units stats, total lore levels, and
## furthest wave reached." Replaced the old unit-level/-count-based rollup
## with each owned unit's own level-scaled combat stats (atk/mag/def/res/
## spd/hp via stats_at -- the same pure, already-ported curve build_party_unit
## itself starts from, before any equipment/pct-stat overlay, which this
## display metric doesn't need for a "how strong is my roster" readout),
## summed across every owned unit (fielded or benched) and divided down to a
## scale comparable to the other two terms. Lore term unchanged (already
## matched "total lore levels" exactly). Wave term now reads g.farthest (the
## deepest wave ever reached) instead of g.wave (the current one), so a
## checkpoint-triggered retreat after a wipe doesn't make POWER LEVEL itself
## go backwards.
const POWER_STAT_DIVISOR := 20.0
const POWER_PER_LORE := 1.0

static func power_level(g: Dictionary) -> int:
	var unit_stat_total := 0.0
	for uid in g.get("owned", {}).keys():
		var def = FarroadCore.roster_by_id(uid)
		var st: Dictionary = stats_at(uid, def["stats"], def["hp"], level_of(g, uid))
		unit_stat_total += st["atk"] + st["mag"] + st["def"] + st["res"] + st["spd"] + st["hp"]
	var lore_levels := 0.0
	for aid in g.get("bonuses", {}).keys():
		var b: Dictionary = g["bonuses"][aid]
		lore_levels += float(FarroadCore.action_bonus_total(b) + int(b.get("broad", 0)))
	var wave_level: float = FarroadCore.level_curve(g.get("farthest", 1))
	return maxi(1, roundi(unit_stat_total / POWER_STAT_DIVISOR + lore_levels * POWER_PER_LORE + wave_level))

## ===== DUNGEONS/QUESTS (Step 3i) =====
## Mirrors farroad-ui.js:1213-1236/1284-1313/2505-2634 and
## farroad-progression.js:1168-1203 -- companion quest lines (a 5-stage
## frozen fight per roster unit, difficulty scaled off power_level above,
## not the Road's own wave) and direction dungeons (multi-wave frozen
## fights auto-discovered from EXPEDITION's dp["maxDepth"] tracking, wired
## in above). Both resolve as a REAL interactive battle -- see
## start_side_battle/finish_side_battle below -- not a headless
## instant-resolve like expeditions.
##
## Super Boss Quests (G.superBossQuests/superBossesUnlocked/
## superBossesCleared, enterSuperBoss) stay out of scope -- a genuinely
## separate third system, already has full save-field parity (FarroadSave.gd),
## zero gameplay logic. Deferred the same way GAMBITS' conflict modal and
## AETHER's live-sync trim were.

const DUNGEON_LEN := 1.15   # 1 < DUNGEON_LEN < BOSS_LEN(1.40) -- "slightly harder", not boss-tier
const QUEST_STAGE_AETHER_MIN := 100
const QUEST_STAGE_AETHER_MAX := 500

## Mirrors bakeEnemySnapshot/unitsFromSnapshots (farroad-ui.js:1213-1236).
## Serializes a live enemy into a plain, JSON-safe cfg (base stats/
## affinity/archetype/slots only, never per-battle runtime fields like hp/
## status/charge) so it can be repeatedly rebuilt at a FROZEN difficulty
## instead of rescaling with Road progress the way a freshly-built enemy
## would. A real v2.17 bug the real JS shipped and later had to fix is
## avoided from day one here: affinity is included unconditionally (the
## real snapshot originally omitted it, silently losing a dungeon enemy's
## themed direction-affinity bonus on first bake).
static func bake_enemy_snapshot(u: Dictionary) -> Dictionary:
	return {
		"name": u["name"], "arch": u["arch"], "thorns": u.get("thorns", 0.0),
		"isBoss": u.get("isBoss", false), "row": u.get("row"), "chargeAction": u.get("chargeAction"),
		"slots": (u["slots"] as Array).map(func(s): return {"cond": s["cond"], "action": s["action"]}),
		"stats": {"hp": u["base"]["hp"], "atk": u["base"]["atk"], "mag": u["base"]["mag"],
			"def": u["base"]["def"], "res": u["base"]["res"], "spd": u["base"]["spd"],
			"atkCrit": u["base"]["atkCrit"], "magCrit": u["base"]["magCrit"],
			"chargeRate": u["base"]["chargeRate"], "evade": u["base"]["evade"]},
		"affinity": (u["affinity"] as Dictionary).duplicate()}

static func units_from_snapshots(snapshots: Array) -> Array:
	var out := []
	for j in range(snapshots.size()):
		var snap: Dictionary = snapshots[j]
		out.append(FarroadCore.make_unit({"id": "e%d" % j, "name": snap["name"], "isParty": false,
			"level": 1, "slotIndex": 10 + j, "arch": snap["arch"], "thorns": snap.get("thorns", 0.0),
			"isBoss": snap.get("isBoss", false), "row": snap.get("row"), "stats": snap["stats"],
			"chargeAction": snap.get("chargeAction"), "slots": snap["slots"], "affinity": snap["affinity"]}))
	return out

## Mirrors unlockDirectionDungeon (farroad-ui.js:1284-1313). Dungeon ids
## use Godot's own randi(), not g["rng"] -- same established reasoning as
## send_expedition's own id (unique, not reproducible; never bit-exact
## between JS/GD by design).
static func unlock_direction_dungeon(g: Dictionary, dir: String, tier: int, now) -> Dictionary:
	var cfg: Dictionary = FarroadCore.DIRECTION_CONFIG[dir]
	var mul: float = cfg["mul"]
	var base_wave: int = tier * int(cfg["unlockEvery"])
	var regular_wave: int = (base_wave - 1) if is_boss_wave(base_wave) else base_wave
	var waves := []
	for i in range(int(cfg["waveCount"]) - 1):
		var enemies: Array = apply_direction_affinity(
			apply_stat_mul(build_enemies(g, regular_wave, true), mul), dir)
		waves.append({"wave": regular_wave, "enemies": enemies.map(bake_enemy_snapshot)})
	var boss_wave: int = next_boss_wave(base_wave - 1)
	var boss_enemies: Array = apply_direction_affinity(
		apply_stat_mul(build_enemies(g, boss_wave, true), mul * DUNGEON_LEN), dir)
	if cfg.get("bossName"):
		for u in boss_enemies:
			u["name"] = cfg["bossName"]
	waves.append({"wave": boss_wave, "enemies": boss_enemies.map(bake_enemy_snapshot)})
	var dungeon := {"id": "dgn%d_%d" % [int(now), randi() % 1000000],
		"name": "%s Dungeon (depth %d)" % [cfg["label"], base_wave], "direction": dir, "tier": tier,
		"waves": waves, "clears": 0}
	g["dungeons"].append(dungeon)
	return dungeon

## 20-item batch, Group G: "dungeons can only be completed once per day."
## Real-world calendar-DAY boundary (UTC, since `now` is a plain unix
## timestamp with no timezone anywhere in this project) -- "YYYY-MM-DD"
## string comparison rather than a fixed 24h cooldown, so a dungeon
## reliably resets at midnight UTC regardless of what time of day it was
## first cleared, matching how a real daily-reset feature is normally
## expected to behave (not "24h after your last clear, whenever that was").
static func _calendar_day(ts) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	return "%04d-%02d-%02d" % [int(dt["year"]), int(dt["month"]), int(dt["day"])]

static func dungeon_available(dungeon: Dictionary, now) -> bool:
	var last = dungeon.get("lastClearedAt")
	if last == null:
		return true
	return _calendar_day(now) != _calendar_day(last)

## Mirrors questStageWave/questStageAether (farroad-progression.js:1168-1203).
## Ian: "reduce new unit quests difficulty to about 50% of current." A
## companion quest's frozen fight was scaled to the player's FULL current
## power_level -- halved so a freshly-acquired companion's own quest line
## reads as approachable rather than as hard as the player's actual
## current build.
const QUEST_DIFFICULTY_MUL := 0.5

static func quest_stage_wave(g: Dictionary, uid: String, stage_idx: int) -> int:
	var frac: float = FarroadCore.QUEST_LINES[uid][stage_idx]["powerFraction"]
	return maxi(1, roundi(frac * QUEST_DIFFICULTY_MUL * power_level(g)))

static func quest_stage_aether(stage_idx: int) -> int:
	return roundi(QUEST_STAGE_AETHER_MIN + stage_idx * (QUEST_STAGE_AETHER_MAX - QUEST_STAGE_AETHER_MIN) / 4.0)

## Mirrors attemptQuestStage's validation+freeze half (farroad-ui.js:2540-2562).
## The pure-state half only -- returns a plain {enemies, wave, meta} bundle
## for GameController.gd to hand to start_side_battle, splitting "prepare
## the fight" (pure) from "actually drive it visually" (Node-owning), the
## same split every Progression/GameController boundary in this project
## already uses. Freezes q["frozen"][stage] lazily on first call (win-or-
## lose-durable) so a companion acquired early and quested late still gets
## an approachable stage 1, not whatever the Road's current wave/power
## implies at attempt time. Story text has its {{name}} token substituted
## via with_mc_name (Step 3j) -- falls back to "Kesh" if g["mc"] is null.
static func prep_quest_attempt(g: Dictionary, uid: String) -> Dictionary:
	if g.get("sideBattle") != null:
		return {}
	var q: Dictionary = g["quests"].get(uid, {})
	if q.is_empty() or int(q["stage"]) >= 5 or not (g["party"] as Array).has(uid):
		return {}
	var line: Array = FarroadCore.QUEST_LINES.get(uid, [])
	if line.is_empty():
		return {}
	var stage: int = q["stage"]
	var step: Dictionary = line[stage]
	q["frozen"] = q.get("frozen", [])
	while (q["frozen"] as Array).size() <= stage:
		(q["frozen"] as Array).append(null)
	if q["frozen"][stage] == null:
		var raw_wave: int = quest_stage_wave(g, uid, stage)
		var wave: int = next_boss_wave(raw_wave - 1) if step.get("isBoss", false) else raw_wave
		q["frozen"][stage] = {"wave": wave, "enemies": build_enemies(g, wave, true).map(bake_enemy_snapshot)}
	var def = FarroadCore.roster_by_id(uid)
	var frozen: Dictionary = q["frozen"][stage]
	return {"enemies": units_from_snapshots(frozen["enemies"]), "wave": frozen["wave"],
		"meta": {"kind": "quest", "uid": uid, "stage": stage,
			"name": (def["name"] if def else uid), "story": with_mc_name(step["story"])}}

## Mirrors enterDungeon (farroad-ui.js:2505-2513).
## `now` (20-item batch, Group G): structural enforcement of the once-per-
## day gate, not just QuestsPanel's own disable+tooltip UI polish on top --
## a real game rule, not merely a UX nicety, so it's checked here too.
static func prep_dungeon_attempt(g: Dictionary, id: String, now) -> Dictionary:
	if g.get("sideBattle") != null:
		return {}
	var dungeon = null
	for d in g["dungeons"]:
		if d["id"] == id:
			dungeon = d
	if dungeon == null or not dungeon_available(dungeon, now):
		return {}
	var wave0: Dictionary = dungeon["waves"][0]
	return {"enemies": units_from_snapshots(wave0["enemies"]), "wave": wave0["wave"],
		"meta": {"kind": "dungeon", "dungeonId": id, "name": dungeon["name"], "direction": dungeon["direction"],
			"tier": dungeon["tier"], "waveIndex": 0, "totalWaves": (dungeon["waves"] as Array).size()}}

## Mirrors startSideBattle (farroad-ui.js:1455-1466), state only -- no
## play()/stop()/wasPlaying: this port has no player-facing play/pause/
## speed control for the Road to preserve in the first place (the Road
## always auto-plays), so that half of the real function has nothing to
## mirror. GameController.gd's own pause/hide of current_presenter is the
## Godot-side equivalent of "stop the Road while this runs."
static func start_side_battle(g: Dictionary, enemies: Array, wave: int, meta: Dictionary) -> bool:
	if g.get("sideBattle") != null:
		return false
	g["roadBattle"] = g["battle"]
	var saved_wave: int = g["wave"]
	FarroadCore.set_wave(wave)
	var party := build_expedition_party(g, g["party"], 1)
	g["battle"] = FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": g.get("enrage", true)})
	g["sideBattle"] = {"savedWave": saved_wave, "wave": wave, "meta": meta}
	return true

## Mirrors finishSideBattle (farroad-ui.js:1476-1618), minus the superboss
## branch (out of scope) and all pushDrop/sysLog text -- returns a plain
## event Dictionary for QuestsPanel to render however it likes, same split
## every other progression event function (grant_drops, after_wave_cleared)
## already uses.
## @return {"kind":"dungeon_wave_advance",...} if a multi-wave dungeon just
##   advanced IN PLACE (g["sideBattle"] still active -- same fight
##   continues); otherwise one of "quest_cleared"/"quest_failed"/
##   "quest_abandoned"/"dungeon_cleared"/"dungeon_failed" once fully
##   resolved (g["sideBattle"]/g["roadBattle"] cleared, g["battle"]
##   restored to the Road's own battle).
## `now` (20-item batch, Group G): a real timestamp, always caller-supplied
## rather than read internally -- same discipline every other time-touching
## function in this file already follows (see the EXPEDITIONS section's own
## comment for why). Only consumed by the dungeon-clear branch below, to
## stamp dungeon["lastClearedAt"] for the new once-per-day gate.
static func finish_side_battle(g: Dictionary, result: String, gave_up: bool, now) -> Dictionary:
	var sb: Dictionary = g["sideBattle"]
	var meta: Dictionary = sb["meta"]
	# Stats page: counted here, before g["battle"] is swapped back to the
	# Road -- covers every dungeon wave (each one resolves through this
	# function) and a quest stage's single fight alike.
	if result == "party" and not gave_up:
		var foes: int = 0
		for u in g["battle"]["units"]:
			if not u["isParty"]:
				foes += 1
		g["enemiesDefeated"] = int(g.get("enemiesDefeated", 0)) + foes
	if meta["kind"] == "dungeon" and result == "party" and int(meta["waveIndex"]) < int(meta["totalWaves"]) - 1:
		var cur_dungeon = null
		for d in g["dungeons"]:
			if d["id"] == meta["dungeonId"]:
				cur_dungeon = d
		var survivors: Array = (g["battle"]["units"] as Array).filter(func(u): return u["isParty"])
		meta["waveIndex"] = int(meta["waveIndex"]) + 1
		var next_wave: Dictionary = cur_dungeon["waves"][meta["waveIndex"]]
		FarroadCore.set_wave(next_wave["wave"])
		sb["wave"] = next_wave["wave"]
		g["battle"] = FarroadCore.make_battle(survivors + units_from_snapshots(next_wave["enemies"]),
			{"rng": g["rng"], "enrage": g.get("enrage", true)})
		return {"kind": "dungeon_wave_advance", "waveIndex": meta["waveIndex"], "totalWaves": meta["totalWaves"]}

	FarroadCore.set_wave(sb["savedWave"])
	g["battle"] = g["roadBattle"]
	g["roadBattle"] = null
	g["sideBattle"] = null

	if meta["kind"] == "quest":
		var q: Dictionary = g["quests"][meta["uid"]]
		if result == "party":
			q["stage"] = int(q["stage"]) + 1
			var reward: int = quest_stage_aether(meta["stage"])
			# Ian (24-item batch, Group A/C5): "have quest rewards be
			# automatically attributed" -- reverses the earlier pending/
			# Collect-button pattern (banked on q["pendingAether"]) back to
			# an immediate credit, same shape after_wave_cleared's own
			# Road-wave rewards already use. Group C3: "unit quests reward 1
			# Crystal per stage cleared" -- a flat grant alongside Aether,
			# also immediate.
			g["aether"] = float(g["aether"]) + float(reward)
			g["crystal"] = int(g.get("crystal", 0)) + 1
			return {"kind": "quest_cleared", "name": meta["name"], "story": meta["story"],
				"stageNum": int(meta["stage"]) + 1, "questComplete": int(q["stage"]) >= 5, "aether": reward, "crystal": 1}
		elif gave_up:
			return {"kind": "quest_abandoned", "name": meta["name"], "stageNum": int(meta["stage"]) + 1}
		else:
			return {"kind": "quest_failed", "name": meta["name"], "stageNum": int(meta["stage"]) + 1}
	else:   # dungeon
		var dungeon = null
		for d in g["dungeons"]:
			if d["id"] == meta["dungeonId"]:
				dungeon = d
		if result == "party" and dungeon != null:
			dungeon["clears"] = int(dungeon["clears"]) + 1
			# 20-item batch, Group G: "dungeons can only be completed once
			# per day" -- stamped on every real clear; dungeon_available()
			# below is the actual gate (checked by QuestsPanel before
			# offering Enter).
			dungeon["lastClearedAt"] = now
			var reward_wave: float = float(meta["tier"]) * float(FarroadCore.DIRECTION_CONFIG[meta["direction"]]["unlockEvery"])
			var mul: float = direction_mul(meta["direction"])
			var r := kill_reward(reward_wave, meta["totalWaves"])
			var d_aether: float = r["aether"] * mul
			var d_marks: float = r["marks"] * marks_mul(g) * mul
			# Ian (Group A/C5): auto-credit, same reversal as the quest
			# branch above. Group C2: "dungeons drop 10 Crystal."
			g["aether"] = float(g["aether"]) + d_aether
			g["marks"] = float(g["marks"]) + d_marks
			g["crystal"] = int(g.get("crystal", 0)) + 10
			return {"kind": "dungeon_cleared", "name": dungeon["name"], "aether": d_aether, "marks": d_marks, "crystal": 10}
		else:
			return {"kind": "dungeon_failed", "name": (dungeon["name"] if dungeon else "Dungeon")}

## ===== Step 3j: character creation (MC point-buy + charge picker) =====
## Mirrors P.MC_STAT_RANGE/MC_GROWTH_RANGE/MC_STAT_KEYS/MC_POINT_MIN/MAX/
## MC_POINTS_TOTAL/MC_STARTER_CHARGES (farroad-progression.js:925-944) --
## hand-transcribed constants, not CSV-exported (never were on the JS side
## either -- content-pipeline.js has nothing MC-creation-specific).
## mcSanitizeName/renderMcStats/updateMcConfirm/showMcCreate stay UI-layer
## orchestration (McCreatePanel.gd), same split every other step already
## draws between this file and its own *Panel.gd.

const MC_STAT_RANGE := {
	"atk": [8.0, 28.0], "mag": [7.0, 30.0], "def": [8.0, 45.0],
	"res": [8.0, 40.0], "spd": [11.0, 26.0], "hp": [180.0, 840.0]}
## hp/spd bounds carry the same reduction the roster's own GROWTH table
## gets above (x0.7 hp, x0.5 spd growth, written in directly -- see its
## own comment); spd's STARTING range separately carries the x0.2
## starting-SPD cut applied across the whole roster/enemy/equipment
## tables (was [56,131], now that x0.2) -- this range was originally
## calibrated to match GROWTH's own min/max spread, so a custom MC's
## own point-bought growth stays consistent with the rest of the roster.
const MC_GROWTH_RANGE := {
	"atk": [0.6, 2.1], "mag": [0.5, 2.7], "def": [0.8, 2.4],
	"res": [0.8, 1.7], "spd": [0.7, 1.6], "hp": [12.6, 33.6]}
const MC_STAT_KEYS: Array[String] = ["atk", "mag", "def", "res", "spd", "hp"]
const MC_POINT_MIN := 0
const MC_POINT_MAX := 15
## = MC_STAT_KEYS.size() * MC_POINT_MAX / 2 (hardcoded, not computed --
## GDScript const-expressions can't call .size() at parse time; matches
## P.MC_POINTS_TOTAL=(P.MC_STAT_KEYS.length*P.MC_POINT_MAX)/2 = 6*15/2 = 45).
const MC_POINTS_TOTAL := 45
## Mirrors P.MC_STARTER_CHARGES -- the generic starters offered at
## creation; the 18-entry MC_CHARGE_DROP_POOL above is deliberately
## withheld (a rare post-wave-20 drop instead). 20-item batch, Group D:
## added wearingdown (debuff) and ironresolve (buff), both scaling off
## avgAtkMag. Tank-build fix: added bastion_strike (DEF) and aegis_strike
## (RES), both true-damage and tutorial-front-loaded (FarroadCore.gd's
## tutorial_tank_charge_mul) -- a 7-entry pool now, was 5.
const MC_STARTER_CHARGES: Array[String] = ["heavystrike", "wildfire", "greatheal", "wearingdown", "ironresolve", "bastion_strike", "aegis_strike"]

## Mirrors P.mcLerp (farroad-progression.js:981-983).
static func mc_lerp(range: Array, point: float) -> float:
	return range[0] + (point - MC_POINT_MIN) / float(MC_POINT_MAX - MC_POINT_MIN) * (range[1] - range[0])

## Mirrors P.mcPointsSpent (farroad-progression.js:984-987).
static func mc_points_spent(points: Dictionary) -> int:
	var sum := 0
	for k in MC_STAT_KEYS:
		sum += int(points.get(k, 0))
	return sum

## Mirrors P.mcBuildStats (farroad-progression.js:988-996). `points` is a
## {atk,mag,def,res,spd,hp: int 0..15} Dictionary. Returns {stats: 5-key
## Dict, hp: int, growth: 6-key Dict} -- hp is pulled OUT of stats
## (erased), same as JS's `delete stats.hp`. Deliberately does NOT enforce
## the MC_POINTS_TOTAL budget itself -- only the UI's Confirm-button gate
## does, matching the real JS exactly (an all-MC_POINT_MAX allocation
## legally sums to 90, over budget, and this function still returns a
## result without complaint).
static func mc_build_stats(points: Dictionary) -> Dictionary:
	var stats := {}
	var growth := {}
	for k in MC_STAT_KEYS:
		var v: float = mc_lerp(MC_STAT_RANGE[k], float(points[k]))
		stats[k] = roundi(v)
		if MC_GROWTH_RANGE.has(k):
			growth[k] = roundi(mc_lerp(MC_GROWTH_RANGE[k], float(points[k])) * 10.0) / 10.0
	var hp = stats["hp"]
	stats.erase("hp")
	return {"stats": stats, "hp": hp, "growth": growth}

## Mirrors applyCustomMC (farroad-ui.js:125-161) -- mutates the shared
## FarroadCore.ROSTER "kesh" entry IN PLACE so every existing unit-
## construction call site (roster_by_id/make_unit/build_party_unit) picks
## up the custom MC for free; internal roster id stays "kesh" always (no
## new roster row, matches new_game()'s own g["party"]=["kesh"] hardcode).
## A no-op when g["mc"] is null, which is why it's safe to call
## unconditionally on BOTH boot paths -- see GameController's
## _try_resume_save (resumed game) and _on_mc_confirmed (fresh game),
## exactly matching the real applyCustomMC's own two call sites
## (tryResumeSave() and boot()).
static func apply_custom_mc(g: Dictionary) -> void:
	var mc = g.get("mc")
	if mc == null:
		return
	if not mc.get("acquiredCharges"):
		mc["acquiredCharges"] = [mc["chargeAction"]]
	var kesh_def = FarroadCore.roster_by_id("kesh")
	if kesh_def == null:
		return
	kesh_def["name"] = mc["name"]
	kesh_def["hp"] = mc["hp"]
	kesh_def["chargeAction"] = mc["chargeAction"]
	kesh_def["affinity"] = FarroadCore.default_affinity()
	kesh_def["stats"] = {
		"atk": mc["stats"]["atk"], "mag": mc["stats"]["mag"], "def": mc["stats"]["def"],
		"res": mc["stats"]["res"], "spd": mc["stats"]["spd"],
		"atkCrit": 0, "magCrit": 0, "chargeRate": 1, "evade": 0}
	GROWTH["kesh"] = {
		"hp": mc["growth"]["hp"], "atk": mc["growth"]["atk"], "mag": mc["growth"]["mag"],
		"def": mc["growth"]["def"], "res": mc["growth"]["res"], "spd": mc["growth"]["spd"]}

## Post-Milestone-3 APK feedback (Group A4): "there's currently no way to
## change charge actions." Mirrors the real JS's own mcc-swap <select>
## onchange handler (farroad-ui.js:2914-2922) -- sets the MC's ACTIVE
## charge action, re-applies it onto the shared roster def via
## apply_custom_mc (already correct/idempotent), then patches any matching
## LIVE unit's own chargeAction field too, same shared-dict-reference
## reasoning sync_loadout already relies on (Step 3c), so a swap mid-fight
## takes effect immediately rather than waiting for the next wave. Only
## meaningful when `action_id` is already in mc["acquiredCharges"] -- the
## UI only ever offers already-acquired ids (mirrors mcOwns/swappable), so
## no re-validation here, same discipline every other mutation function in
## this file already follows.
static func set_mc_charge_action(g: Dictionary, action_id: String) -> void:
	var mc = g.get("mc")
	if mc == null:
		return
	mc["chargeAction"] = action_id
	apply_custom_mc(g)
	for u in g.get("units", []):
		if u["id"] == "kesh":
			u["chargeAction"] = action_id

## Post-batch feedback: "add a button to change our main character's
## name." Same shape as set_mc_charge_action above -- mutate g["mc"],
## re-apply onto the shared roster def via apply_custom_mc (already
## correct/idempotent), then patch any matching live unit's own field
## directly so a rename mid-fight takes effect immediately, not just next
## wave. GameController is responsible for the on-field UnitView/
## unit_views_by_name sync (BattlePresenter.sync_mc_name) -- this
## function only touches g-level state, matching every other
## FarroadProgression mutation's own scope.
static func set_mc_name(g: Dictionary, new_name: String) -> void:
	var mc = g.get("mc")
	if mc == null:
		return
	mc["name"] = new_name
	apply_custom_mc(g)
	for u in g.get("units", []):
		if u["id"] == "kesh":
			u["name"] = new_name

## Mirrors mcName/withMcName (farroad-ui.js:178-181) -- reads the CURRENT
## FarroadCore.ROSTER "kesh" entry's name directly (not g["mc"]["name"]),
## exactly like the real mcName(), falling back to "Kesh" if that entry
## is somehow absent. Takes no `g` -- the real functions don't either,
## since apply_custom_mc() is what keeps ROSTER's kesh entry in sync with
## g["mc"] in the first place; this just reads the result.
static func with_mc_name(text: String) -> String:
	if text == null or text == "":
		return text
	var kesh_def = FarroadCore.roster_by_id("kesh")
	var mc_name: String = (kesh_def["name"] if kesh_def else "Kesh")
	return text.replace("{{name}}", mc_name)

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

## Elemental batch: the wave-20 tutorial boss stays the Roadwarden (Stone
## Ox body, Warden's Maul). Every later boss wave cycles through six named
## elemental bosses, one per element -- 40 Pyre Tyrant, 60 Drowned
## Matriarch, ... 140 Hollow King, then the Body and Spirit bosses (160 Iron
## Sovereign, 180 Hollow Oracle), and round again from 200.
const TUTORIAL_BOSS_ARCH := "ox"
const BOSS_ROTATION: Array[String] = ["pyretyrant", "drownedmatriarch", "mountaincolossus",
	"stormroc", "dawnseraph", "hollowking", "ironsovereign", "holloworacle"]

static func boss_arch_for(w: int) -> String:
	if w <= BOSS_WAVES[0]:
		return TUTORIAL_BOSS_ARCH
	var idx: int = maxi(0, int((w - BOSS_WAVES[0] - 1) / float(BOSS_EVERY)))
	return BOSS_ROTATION[idx % BOSS_ROTATION.size()]

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
## Ian: "a spike in difficulty after wave 100 -- extend and smooth out the
## early game help so it reaches wave 200." Waves up to 100 keep exactly
## the easing they had; from 100 it carries on, fading out by wave 200
## (HELP_END_WAVE) instead of 120, alongside the eased-in hard multiplier
## and enemy-count blend below. From 200 on nothing changes.
const HELP_KNEE_WAVE := 100
const HELP_END_WAVE := 200

static func tutorial_atk_mag_mul(w: int) -> float:
	if w <= 20:
		return TUTORIAL_ATK_MAG_MUL
	if w >= HELP_END_WAVE:
		return 1.0
	var knee: float = lerpf(TUTORIAL_POST_DIP, 1.0, float(HELP_KNEE_WAVE - 20) / float(TUTORIAL_RAMP_END_WAVE - 20))
	if w <= HELP_KNEE_WAVE:
		return lerpf(TUTORIAL_POST_DIP, 1.0, float(w - 20) / float(TUTORIAL_RAMP_END_WAVE - 20))
	return lerpf(knee, 1.0, float(w - HELP_KNEE_WAVE) / float(HELP_END_WAVE - HELP_KNEE_WAVE))

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
	var table: Array = count_table(w)
	var r := rng.next()
	var acc := 0.0
	for row in table:
		acc += row[1]
		if r <= acc:
			return row[0]
	return table[table.size() - 1][0]

## Ian (smoothing the wave-100 spike): the bigger hard-mode groups used to
## arrive all at once at wave 101; now the odds blend from the normal table
## to the hard one across waves 100-200.
static func count_table(w: int) -> Array:
	if w <= HARD_FROM:
		return COUNT_WEIGHTS
	if w >= HELP_END_WAVE:
		return COUNT_WEIGHTS_HARD
	var t: float = float(w - HARD_FROM) / float(HELP_END_WAVE - HARD_FROM)
	var out: Array = []
	for n in range(1, ENEMY_CAP + 1):
		var a: float = 0.0
		var b: float = 0.0
		for row in COUNT_WEIGHTS:
			if row[0] == n:
				a = row[1]
		for row in COUNT_WEIGHTS_HARD:
			if row[0] == n:
				b = row[1]
		out.append([n, lerpf(a, b, t)])
	return out

static func count_strength(n: int) -> float:
	match n:
		1: return 1.85
		2: return 1.30
		3: return 0.96
		4: return 0.72
		_: return 2.9 / n

static func band_roll(rng: FarroadCore.RNG) -> float:
	return 0.85 + rng.next() * 0.35

const HARD_ATK_EXP := 0.7
const HARD_DEF_EXP := 0.35

static func _hard_mul_raw(w: float) -> float:
	if w <= HARD_FROM:
		return 1.0
	var t: float = minf(1.0, sqrt((w - HARD_FROM) / (HARD_REF - HARD_FROM)))
	return 1.0 + (HARD_MAX - 1.0) * t

## The raw curve is a square root -- steepest right at wave 101, the spike
## Ian hit. Between 100 and HELP_END_WAVE it's now an ease-in curve (flat at
## 100) that meets the raw curve, and its slope, exactly at 200; past 200
## it's unchanged.
static func hard_mul(w: float) -> float:
	if w <= HARD_FROM:
		return 1.0
	var w1: float = float(HELP_END_WAVE)
	if w >= w1:
		return _hard_mul_raw(w)
	var span: float = w1 - HARD_FROM
	var t: float = (w - HARD_FROM) / span
	var p1: float = _hard_mul_raw(w1)
	var m1: float = (_hard_mul_raw(w1 + 0.5) - _hard_mul_raw(w1 - 0.5)) * span   # slope at 200, per unit t
	# cubic Hermite: value 1 & slope 0 at t=0, value p1 & slope m1 at t=1
	var t2 := t * t
	var t3 := t2 * t
	return (2 * t3 - 3 * t2 + 1) * 1.0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1

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
## Marks open with their tutorial (wave 8, where Mend used to drop).
const MARKS_UNLOCK_WAVE := 8
## Display-only ("X pulls waiting" on the locked screen); pull_cost's own
## flat 100 is the real gate, this just happens to share the same number.
const MARKS_PER_PULL := 100
const BOSS_AETHER_WAVES := 12.5
const DUP_UNIT_WAVES := 3
const NOMINAL_WAVE_SEC := 40.0
const IDLE_FLOOR_PER_5MIN := 3.0
const IDLE_AETHER_GROWTH_MUL := 3.0
const IDLE_MARKS_GROWTH_MUL := 4.5

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

## Ian: "Duplicate gambits become aether, not lore." Worth about one wave's
## kill reward plus idle trickle at the player's furthest wave.
const DUP_GAMBIT_WAVES := 1

static func dup_gambit_aether(w: float) -> int:
	var kr: float = kill_reward(w, enemy_count(int(w)))["aether"]
	var idle: float = idle_per_sec(w)["aether"] * NOMINAL_WAVE_SEC
	return maxi(1, int(round(DUP_GAMBIT_WAVES * (kr + idle))))

static func _credit_dup_gambit(g: Dictionary) -> int:
	var amt := dup_gambit_aether(float(g.get("farthest", g.get("wave", 1))))
	g["aether"] = float(g.get("aether", 0.0)) + amt
	return amt

static func dup_unit_aether(w: float) -> int:
	var kr: float = kill_reward(w, enemy_count(int(w)))["aether"]
	var idle: float = idle_per_sec(w)["aether"] * NOMINAL_WAVE_SEC
	return int(round(DUP_UNIT_WAVES * (kr + idle)))

## Duplicate units pay more the rarer they are.
const DUP_UNIT_RARITY_MUL := {"common": 1.0, "rare": 2.0, "legendary": 4.0}

static func dup_unit_reward(w: float, unit_def: Dictionary) -> int:
	return int(round(dup_unit_aether(w) * float(DUP_UNIT_RARITY_MUL.get(unit_def.get("rarity", "common"), 1.0))))

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
const PULL_ODDS := {"unit": 0.05, "equip": 0.10, "action": 0.45, "cond": 0.40}
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
	var r := _do_pull(g)
	if not r.is_empty():
		Analytics.add("pulls", r["kind"] + ("_dup" if r.get("duplicate", false) else ""))
		Analytics.add("pulledIds", "%s:%s" % [r["kind"], r.get("id", "")])
		Analytics.add("spend", "marks:pull", pull_cost(g.get("wave", 1)))
	return r

static func _do_pull(g: Dictionary) -> Dictionary:
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
	elif g.get("forcedPull"):
		kind = "action"
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
			# Ian: a duplicate unit pays Aether by rarity, plus one Lore on
			# its charge action (drawn from the whole roster, same rarity
			# weights as any unit pull).
			var dup_pick: Dictionary = weighted_roster_pick(g["rng"], FarroadCore.ROSTER)
			var dup := dup_unit_reward(float(g.get("farthest", g.get("wave", 1))), dup_pick)
			g["aether"] += dup
			var dup_lore: String = str(dup_pick.get("chargeAction", "")) if dup_pick.get("chargeAction") else ""
			if dup_lore != "":
				_credit_lore(g, dup_lore)
			return {"kind": "unit_dup", "pity": pity, "aetherGain": dup, "id": dup_pick["id"],
				"name": dup_pick["name"], "rarity": dup_pick.get("rarity", "common"), "loreActionId": dup_lore}
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
		# the Marks tutorial's first pull is a guaranteed Mend
		var aid: String = str(g["forcedPull"]) if g.get("forcedPull") else weighted_action_pick(g["rng"], pool)
		g["forcedPull"] = null
		g["actionCounts"][aid] = int(g["actionCounts"].get(aid, 0)) + 1
		var is_charge: bool = bool(FarroadCore.ACTIONS.get(aid, {}).get("isCharge", false))
		if is_charge:
			# A pulled charge action credits the MC's own acquiredCharges
			# list -- same destination a rare charge DROP already uses
			# (grant_drops' "charge" branch). g["mc"] is always set by the
			# time pulls unlock (wave 20+, well past mandatory character
			# creation) -- defensive no-op rather than crashing if somehow
			# null (the RNG draw above is still consumed either way).
			# Ian: charge actions are pulled for the Lore -- every pull banks
			# one Lore on the action (even for a unit you don't own yet);
			# the first copy also becomes available to the MC.
			_credit_lore(g, aid)
			if g["mc"] == null:
				return {"kind": "action", "id": aid, "duplicate": false, "isCharge": true}
			g["mc"]["acquiredCharges"] = g["mc"].get("acquiredCharges", [])
			var dup_mc: bool = g["mc"]["acquiredCharges"].has(aid)
			if not dup_mc:
				g["mc"]["acquiredCharges"].append(aid)
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
		var gain := 0
		if not dup_c:
			g["conditions"].append(cid)
		else:
			gain = _credit_dup_gambit(g)
		return {"kind": "cond", "id": cid, "duplicate": dup_c, "aetherGain": gain}

## ===== SHOP tab: fixed-price purchases with Crystal (24-item batch,
## Group C6) =====
## Ian's own fixed prices, verbatim: gambits 10 flat; actions 20/50/100 by
## rarity; units 100/200/500; equipment 10/30/90. Same "afford check ->
## deduct -> mutate -> return bool" shape every other purchase function in
## this file already uses (spend_affinity/spend_feed/etc.) -- no
## re-validation beyond what's shown, gating is structural (a Shop row
## only exists for an actually-purchasable entry).
## Crystal sources -- dungeons and companion quest stages pay ONLY Crystal
## (no Aether/Marks), per Ian's follow-up to the Crystal/Shop batch.
const DUNGEON_CRYSTAL := 1
const QUEST_STAGE_CRYSTAL := 1
const SHOP_GAMBIT_PRICE := 5
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
	Analytics.add("shop", "gambit:" + cond_id)
	Analytics.add("spend", "crystal:gambit", SHOP_GAMBIT_PRICE)
	return true

## A charge action buys into g["mc"]["acquiredCharges"] (mirrors do_pull's
## own action branch); a regular action buys into g["actions"]. Refuses if
## already owned in the relevant pool, unaffordable, or (charge case) no
## MC exists yet -- pulls/Shop both only unlock well past mandatory
## character creation in practice, but this stays a real, not just
## theoretical, guard.
## Ian: actions the player already has stay on sale; buying one again turns
## into one Lore for that action (the same as a duplicate drop or pull).
## The unit whose signature charge action this is ("" if none). Ian: a
## unit's charge action isn't on sale until you own that unit, and since
## the unit already has it, buying it counts as a duplicate (+1 Lore).
static func signature_owner(action_id: String) -> String:
	for r in FarroadCore.ROSTER:
		if r.get("chargeAction") == action_id:
			return r["id"]
	return ""

static func shop_action_available(g: Dictionary, action_id: String) -> bool:
	var owner := signature_owner(action_id)
	return owner == "" or g["owned"].has(owner)

static func shop_action_owned(g: Dictionary, action_id: String) -> bool:
	var act = FarroadCore.ACTIONS.get(action_id)
	if act == null:
		return false
	var owner := signature_owner(action_id)
	if owner != "" and g["owned"].has(owner):
		return true
	if bool(act.get("isCharge", false)):
		return g.get("mc") != null and (g["mc"].get("acquiredCharges", []) as Array).has(action_id)
	return (g["actions"] as Array).has(action_id)

static func buy_shop_action(g: Dictionary, action_id: String) -> bool:
	var act = FarroadCore.ACTIONS.get(action_id)
	if act == null:
		return false
	var is_charge: bool = bool(act.get("isCharge", false))
	if is_charge and g["mc"] == null:
		return false
	if not shop_action_available(g, action_id):
		return false
	var price: int = int(SHOP_ACTION_PRICE.get(act.get("rarity", "common"), 20))
	if int(g.get("crystal", 0)) < price:
		return false
	g["crystal"] = int(g["crystal"]) - price
	Analytics.add("shop", "action:" + action_id)
	Analytics.add("spend", "crystal:action", price)
	if shop_action_owned(g, action_id):
		_credit_lore(g, action_id)
	elif is_charge:
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
	Analytics.add("shop", "unit:" + uid)
	Analytics.add("spend", "crystal:unit", price)
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
	Analytics.add("shop", "equip:" + item_id)
	Analytics.add("spend", "crystal:equipment", price)
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

const STARTER_ACTIONS: Array[String] = ["strike", "magibolt"]
const CURATED: Array = [
	{"w": 2, "kind": "action", "id": "sear", "why": "first magic tool — takes reach-wave-8 from 3/10 to 10/10"},
	{"w": 3, "kind": "cond", "id": "foe_lacks_debuff", "why": "gates Sear — Burning is wasted if reapplied"},
	{"w": 4, "kind": "action", "id": "smother", "why": "Dulled cuts the Fen Priest's healing — ready before it (wave 5-7) arrives"},
	{"w": 5, "kind": "cond", "id": "foe_armoured", "why": "Barrow Knight arrives — DEF 34, physical stalls"},
	{"w": 6, "kind": "action", "id": "bulwark", "why": "Warded ×0.60; holds the 10th-percentile at wave 9"},
	{"w": 7, "kind": "cond", "id": "ally_lacks_buff", "why": "gates Bulwark — do not overwrite a running buff"},
	# (waves 8-9's Mend and Self: HP <= 50% now come from the Marks and Shop
	# tutorials: a guaranteed first pull, then buying the gambit -- Tutorial.gd)
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

## Ian: "Marks: list breakdown of unit/action/gambit/equipment chances plus
## rarity chances in each." The real per-pull odds right now: each kind's
## share (PULL_ODDS) and, inside it, each rarity's share of that kind's
## weighted pool (the same weights the picks use). Gambit conditions have
## no rarity. Returns [{kind, label, chance, rarities: {rarity: share}}].
static func pull_odds_breakdown(g: Dictionary) -> Array:
	var out := []
	# once every unit is owned, pulls still land on units (as duplicates), so
	# the odds keep showing the whole roster
	var unit_src: Array = FarroadCore.ROSTER.filter(func(r): return not g["owned"].get(r["id"], false))
	if unit_src.is_empty():
		unit_src = FarroadCore.ROSTER
	var unit_pool: Array = unit_src.map(func(r): return r.get("rarity", "common"))
	var action_pool: Array = (FarroadCore.equippable() + FarroadCore.CHARGE_ACTIONS).map(func(id): return FarroadCore.ACTIONS.get(id, {}).get("rarity", "common"))
	var equip_pool: Array = random_equipment_ids().map(func(id): return FarroadCore.EQUIPMENT.get(id, {}).get("rarity", "common"))
	for spec in [["unit", "Unit", unit_pool], ["action", "Action", action_pool], ["cond", "Gambit", []], ["equip", "Gear", equip_pool]]:
		var shares := {}
		var total := 0.0
		for r in spec[2]:
			total += RARITY_PULL_WEIGHT.get(r, 1)
		for r in spec[2]:
			shares[r] = float(shares.get(r, 0.0)) + RARITY_PULL_WEIGHT.get(r, 1) / total
		out.append({"kind": spec[0], "label": spec[1], "chance": float(PULL_ODDS[spec[0]]), "rarities": shares})
	return out

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
## Ian: the healer (Ansa) is the 2nd unit; the 3rd is the tank (Dorrek), at
## a fixed wave so the Expedition tutorial can follow it.
const UNIT_WAVES: Array[int] = [10, 30, 500, 1500]

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
	"sael": {"hp": 16.8, "atk": 0.8, "mag": 2.5, "def": 1.1, "res": 1.6, "spd": 1.7},
	# Elemental batch allies.
	"tovan": {"hp": 22.0, "atk": 2.1, "mag": 0.8, "def": 1.4, "res": 1.0, "spd": 1.0},
	"ilse": {"hp": 15.4, "atk": 0.7, "mag": 2.3, "def": 0.9, "res": 1.7, "spd": 1.0},
	"garrow": {"hp": 35.0, "atk": 1.6, "mag": 0.6, "def": 2.5, "res": 1.8, "spd": 0.9},
	"wren": {"hp": 14.7, "atk": 2.0, "mag": 0.7, "def": 0.9, "res": 0.9, "spd": 1.6},
	"lumen": {"hp": 17.5, "atk": 0.8, "mag": 2.5, "def": 1.2, "res": 2.0, "spd": 1.2},
	"vesh": {"hp": 16.8, "atk": 2.3, "mag": 1.0, "def": 1.2, "res": 1.2, "spd": 1.7},
	# Legendary round (Ian): one unit excelling in each of ATK/MAG/SPD/DEF/RES.
	"kaldor": {"hp": 24.0, "atk": 3.0, "mag": 0.8, "def": 1.5, "res": 1.0, "spd": 1.4},
	"seraphine": {"hp": 15.0, "atk": 0.7, "mag": 3.0, "def": 0.9, "res": 1.8, "spd": 1.3},
	"zephyra": {"hp": 16.0, "atk": 2.1, "mag": 0.8, "def": 1.0, "res": 1.0, "spd": 2.4},
	"bastian": {"hp": 38.0, "atk": 1.4, "mag": 0.8, "def": 3.0, "res": 2.0, "spd": 0.8},
	"morwen": {"hp": 20.0, "atk": 0.7, "mag": 2.0, "def": 1.3, "res": 3.0, "spd": 1.1},
	# Ian: a legendary Spirit mage.
	"lyrael": {"hp": 16.0, "atk": 0.6, "mag": 2.8, "def": 1.0, "res": 2.0, "spd": 1.2}}

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

## Ian: extra slots at levels 50 and 250.
const SLOT_LEVELS: Array[int] = [1, 1, 10, 50, 100, 250, 500, 1000]

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
	Analytics.add("spend", "aether:level", amount)
	Analytics.add("aetherByUnit", uid, amount)
	return true

static func spend_recovery(g: Dictionary, uid: String) -> bool:
	var c := recovery_cost(g, uid)
	if g.get("aether", 0) < c or recovery_maxed(g, uid):
		return false
	g["aether"] -= c
	g["recovery"][uid] = g["recovery"].get(uid, 0) + 1
	Analytics.add("spend", "aether:recovery", c)
	Analytics.add("aetherByUnit", uid, c)
	return true

static func spend_affinity(g: Dictionary, uid: String, axis: String) -> bool:
	var c := affinity_cost_to_next(affinity_purchased(g, uid).get(axis, 0))
	if g.get("aether", 0) < c or affinity_maxed(g, uid, axis):
		return false
	g["aether"] -= c
	if not g["affinities"].has(uid):
		g["affinities"][uid] = {}
	g["affinities"][uid][axis] = g["affinities"][uid].get(axis, 0) + 1
	Analytics.add("spend", "aether:affinity:" + axis, c)
	Analytics.add("affinityBuys", axis)
	Analytics.add("aetherByUnit", uid, c)
	return true

static func spend_pct_stat(g: Dictionary, uid: String, stat: String) -> bool:
	var c := pct_stat_cost(stat, pct_stat_purchased(g, uid, stat))
	if g.get("aether", 0) < c or pct_stat_maxed(g, uid, stat):
		return false
	g["aether"] -= c
	if not g["statInvest"].has(uid):
		g["statInvest"][uid] = {}
	g["statInvest"][uid][stat] = g["statInvest"][uid].get(stat, 0) + 1
	Analytics.add("spend", "aether:stat:" + stat, c)
	Analytics.add("aetherByUnit", uid, c)
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

## Ian: a unit's title is its role from its two highest non-HP stats as
## they'd be at level 100 (so it doesn't change as it levels), led by its
## strongest elemental affinity if it has one -- e.g. "Fire Warden". All
## five within 2: Freelancer.
const TITLE_LEVEL := 100
const ROLE_TITLES := {"atk+mag": "Duelist", "atk+def": "Fighter", "atk+res": "Paladin", "atk+spd": "Rogue",
	"mag+def": "Warden", "mag+res": "Mage", "mag+spd": "Sorcerer", "def+res": "Tank", "def+spd": "Bruiser",
	"res+spd": "Warlock"}
const TITLE_STATS: Array[String] = ["atk", "mag", "def", "res", "spd"]
const TITLE_ELEMENTS: Array[String] = ["fire", "water", "earth", "air", "light", "dark", "spirit"]

static func role_for_stats(st: Dictionary) -> String:
	var vals: Array = TITLE_STATS.map(func(k): return float(st.get(k, 0)))
	if vals.max() - vals.min() <= 2.0:
		return "Freelancer"
	var order: Array = TITLE_STATS.duplicate()
	order.sort_custom(func(a, b): return float(st.get(a, 0)) > float(st.get(b, 0)) or 		(float(st.get(a, 0)) == float(st.get(b, 0)) and TITLE_STATS.find(a) < TITLE_STATS.find(b)))
	var pair: Array = [order[0], order[1]]
	pair.sort_custom(func(a, b): return TITLE_STATS.find(a) < TITLE_STATS.find(b))
	return ROLE_TITLES.get("%s+%s" % pair, "Freelancer")

static func role_at_100(uid: String) -> String:
	var d = FarroadCore.roster_by_id(uid)
	if d == null:
		return "Freelancer"
	return role_for_stats(stats_at(uid, d["stats"], d["hp"], TITLE_LEVEL))

static func element_prefix(aff: Dictionary) -> String:
	var best := ""
	var best_v := 0.0
	for el in TITLE_ELEMENTS:
		var v := float(aff.get(el, 0.0))
		if v > best_v:
			best_v = v
			best = el
	return best.capitalize()

static func unit_title(g: Dictionary, uid: String) -> String:
	var role := role_at_100(uid)
	var el := element_prefix(effective_affinity(g, uid))
	return (el + " " + role) if el != "" else role

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
				if g["actions"].has(a) and action_holder_in_party(g, a, uid) == null:
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
	if g.get("units") != null:
		for u in g["units"]:
			if u["id"] == uid:
				u["slots"] = g["loadout"][uid].map(func(s): return {"cond": s["cond"], "action": s["action"]})
	# Ian: edit a gambit while training and see it take effect -- a side fight
	# (training, quest...) has its own copies of the party's units.
	if g.get("sideBattle") != null and g.get("battle") != null:
		for u in g["battle"]["units"]:
			if u["id"] == uid and u["isParty"]:
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
	Analytics.add("features", "autoGambits")
	var slots: Array = ensure_loadout(g, uid)
	var probe := build_party_unit(g, uid, 0)
	var dominant_camp: String = "mag" if float(probe["base"]["mag"]) > float(probe["base"]["atk"]) else "atk"
	var aff: Dictionary = probe.get("affinity", {})

	# Ian: "Auto-Set: Not assign actions already assigned" -- nothing another
	# owned unit holds (benched included), and no action twice in this
	# unit's own slots; "assign actions based on elemental attributes as
	# well" -- the unit's affinity for an action's element (Body for
	# physical) weighs into its score.
	var candidates: Array = g["actions"].filter(func(aid):
		return FarroadCore.ACTIONS.has(aid) and action_holder_in_party(g, aid, uid) == null)
	candidates.sort_custom(func(x, y):
		return _auto_assign_score(FarroadCore.ACTIONS[x], dominant_camp, aff) > _auto_assign_score(FarroadCore.ACTIONS[y], dominant_camp, aff))
	var fallback: String = "magibolt" if dominant_camp == "mag" else "strike"
	for i in range(slots.size()):
		var action_id: String = candidates[i] if i < candidates.size() else fallback
		var act = FarroadCore.ACTIONS.get(action_id)
		slots[i]["action"] = action_id
		slots[i]["cond"] = ("none" if i == slots.size() - 1 or act == null else _auto_assign_condition(act, g["conditions"]))
	# the last slot stays unconditional so the unit always has something to do
	g["touched"][uid] = true
	sync_loadout(g, uid)

static func _auto_assign_score(act: Dictionary, dominant_camp: String, aff: Dictionary = {}) -> float:
	var camp_bonus: float = 10.0 if act.get("camp") == dominant_camp else 0.0
	var ax = act.get("element")
	if ax == null and act.get("camp") == "atk" and not act.get("heal", false):
		ax = "body"
	var aff_bonus: float = 0.0
	if ax != null:
		aff_bonus = FarroadCore.affinity_mul(float(aff.get(ax, 0.0))) * 10.0
	return camp_bonus + aff_bonus + float(act.get("rank", 0.0)) + float(act.get("power", 0.0))

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
		# an elemental attack goes first at a foe weak to its element
		preferred = (["foe_weak_%s" % act["element"]] if act.get("element") else []) + 			["foe_lowest_hp", "foe_lacks_debuff", "foe_armoured"]
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
## Ian: "the MC should always be at the top of the list." Owned unit ids,
## the MC ("kesh") first, the rest in the order they joined.
static func mc_first(ids: Array) -> Array:
	var out: Array = ids.filter(func(u): return u == "kesh")
	out.append_array(ids.filter(func(u): return u != "kesh"))
	return out

static func owned_ids(g: Dictionary) -> Array:
	return mc_first((g.get("owned", {}) as Dictionary).keys())

static func available_for_party(g: Dictionary) -> Array:
	var out := []
	for uid in owned_ids(g):
		if not g["party"].has(uid) and not is_on_expedition(g, uid):
			out.append(uid)
	return out

## ===== per-unit gambit sets and gear sets (Ian: "5 per unit gambit and gear
## sets in their tabs that can be saved and loaded similar to parties") =====
## g["loadoutSets"][uid] = [{name, slots:[{cond, action}]}], at most
## UNIT_SET_CAP per unit; g["gearSets"][uid] = [{name, items:{slot: item_id}}].
const UNIT_SET_CAP := 5

static func _sets_of(g: Dictionary, key: String, uid: String) -> Array:
	if not g.has(key) or g[key] == null:
		g[key] = {}
	if not g[key].has(uid):
		g[key][uid] = []
	return g[key][uid]

static func loadout_sets(g: Dictionary, uid: String) -> Array:
	return _sets_of(g, "loadoutSets", uid)

static func gear_sets(g: Dictionary, uid: String) -> Array:
	return _sets_of(g, "gearSets", uid)

static func save_loadout_set(g: Dictionary, uid: String, set_name: String) -> bool:
	var trimmed := set_name.strip_edges()
	var sets := loadout_sets(g, uid)
	if trimmed == "" or sets.size() >= UNIT_SET_CAP:
		return false
	var slots: Array = ensure_loadout(g, uid)
	sets.append({"name": trimmed.substr(0, 24), "slots": slots.map(func(s): return {"cond": s["cond"], "action": s["action"]})})
	Analytics.add("features", "saveGambitSet")
	return true

## Puts a saved gambit set on the unit. Actions or gambits it no longer has,
## or that another unit already uses (units can't share non-starter actions),
## fall back to Strike / always. Returns how many slots had to change.
static func load_loadout_set(g: Dictionary, uid: String, index: int) -> int:
	var sets := loadout_sets(g, uid)
	if index < 0 or index >= sets.size():
		return -1
	var changed := 0
	var slots: Array = ensure_loadout(g, uid)
	var saved: Array = sets[index]["slots"]
	for i in range(slots.size()):
		var src: Dictionary = saved[i] if i < saved.size() else {"cond": "none", "action": "strike"}
		var act: String = str(src["action"])
		var cond: String = str(src["cond"])
		if not g["actions"].has(act) or action_holder_in_party(g, act, uid) != null:
			act = "strike"
			changed += 1
		if not g["conditions"].has(cond):
			cond = "none"
			changed += 1
		slots[i] = {"cond": cond, "action": act}
	g["loadout"][uid] = slots
	g["touched"][uid] = true
	sync_loadout(g, uid)
	Analytics.add("features", "loadGambitSet")
	return changed

static func delete_loadout_set(g: Dictionary, uid: String, index: int) -> bool:
	var sets := loadout_sets(g, uid)
	if index < 0 or index >= sets.size():
		return false
	sets.remove_at(index)
	return true

static func save_gear_set(g: Dictionary, uid: String, set_name: String) -> bool:
	var trimmed := set_name.strip_edges()
	var sets := gear_sets(g, uid)
	if trimmed == "" or sets.size() >= UNIT_SET_CAP:
		return false
	var items: Dictionary = (g.get("equipped", {}).get(uid, {}) as Dictionary).duplicate()
	sets.append({"name": trimmed.substr(0, 24), "items": items})
	Analytics.add("features", "saveGearSet")
	return true

## Puts a saved gear set on the unit. A piece you no longer own, or whose
## every copy is on someone else, is left empty. Returns how many were missed.
static func load_gear_set(g: Dictionary, uid: String, index: int) -> int:
	var sets := gear_sets(g, uid)
	if index < 0 or index >= sets.size():
		return -1
	for slot in FarroadCore.EQUIPMENT_SLOTS:
		unequip_item(g, uid, slot)
	var missed := 0
	var items: Dictionary = sets[index]["items"]
	for slot in items.keys():
		if not equip_item(g, uid, str(slot), str(items[slot])):
			missed += 1
	refresh_live_stats(g)
	Analytics.add("features", "loadGearSet")
	return missed

static func delete_gear_set(g: Dictionary, uid: String, index: int) -> bool:
	var sets := gear_sets(g, uid)
	if index < 0 or index >= sets.size():
		return false
	sets.remove_at(index)
	return true

## ===== party presets (24-item batch, Group E1) =====
## Ian: "save current party as a default party you name. Have up to 10."
## g["partyPresets"] is an Array of {"name": String, "party": Array[uid]}.
## Godot-originating (no real-JS precedent), mirrored to farroad-ui.js for
## parity the same way the Shop was.
const PARTY_PRESET_CAP := 10

static func save_party_preset(g: Dictionary, preset_name: String) -> bool:
	Analytics.add("features", "savePreset")
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
	Analytics.add("features", "loadPreset")
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
## Ian: "Each unit has to have unique actions, even if they're benched. Not
## counting Strike or Magibolt." Checks every owned unit, not just the
## fielded party (the name is kept for its many callers).
static func action_holder_in_party(g: Dictionary, action_id: String, exclude_uid: String) -> Variant:
	if STARTER_ACTIONS.has(action_id):
		return null
	for uid in owned_ids(g):
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

## Every Lore upgrade bought on an action as plain text ("Swift ×2, Broad"),
## in the order the Lore page lists them -- includes the ones whose effect
## isn't a stat change (Broad, Cleansing, Deepening) that the numeric summary
## can't show. "" when there are none.
static func lore_stacks_text(g: Dictionary, action_id: String) -> String:
	var b: Dictionary = g["bonuses"].get(action_id, {})
	var bits: Array = []
	for bid in FarroadCore.BONUSES.keys():
		var n: int = int(b.get(bid, 0))
		if n > 0:
			bits.append("%s ×%d" % [FarroadCore.BONUSES[bid]["n"], n] if n > 1 else str(FarroadCore.BONUSES[bid]["n"]))
	return ", ".join(bits)

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
	Analytics.add("features", "loreRefund")
	for aid in ids:
		g["bonuses"].erase(aid)
	FarroadCore.apply_bonuses(g["bonuses"])

## Mirrors the "+" purchase handler (farroad-ui.js:2208-2210) -- buys ONE
## stack of bonus `bid` on action `aid`. No re-validation inside (gating is
## structural, the button only exists when applicable/affordable -- the UI
## layer's responsibility, same discipline as GAMBITS' own mutation
## functions above).
static func buy_bonus(g: Dictionary, aid: String, bid: String) -> void:
	Analytics.add("loreBonus", bid)
	Analytics.add("loreAction", aid)
	Analytics.add("loreBuys", aid + ":" + bid)
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
		# a fallen ally stays fallen -- the old max(1, ...) stood dead units
		# back up at 1 HP (alive in the numbers, but with no animation and
		# stuck out of the turn order) whenever anything was bought or
		# equipped mid-fight
		u["hp"] = 0.0 if float(u["hp"]) <= 0.0 else maxf(1.0, round(st["hp"] * fr))
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
		var key: String = (TUTORIAL_BOSS_ARCH if super_boss_key != "" else boss_arch_for(w)) if boss else archetype_for(w, j)
		# archetype_for can hand back "priest" more than once in the same
		# wave -- every WAVE_ARCH wave 1-19 uses ONE archetype for every
		# slot (so a multi-enemy wave 5-7 was previously all-healer), and
		# post-19 ROT repeats once a wave rolls more enemies than ROT has
		# entries (unlikely since the elemental batch grew it to 12). A wave full of simultaneous healers can stall the fight
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
			# boss variants of normal enemies get their own Catalogue entry
			if boss and key == TUTORIAL_BOSS_ARCH and super_boss_key == "":
				g["seenArch"]["roadwarden"] = true
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
		# Ian: past wave 100 the hard multiplier went entirely into ATK/MAG
		# (x20 by wave 800) while DEF/RES grew only with the wave and SPD not
		# at all. Now it's spread: ATK/MAG take hard^0.7, DEF/RES/SPD hard^0.35,
		# and SPD also grows with the wave (sqrt of the wave scale).
		var hard: float = hard_mul(w)
		var hard_atk_mul: float = pow(hard, HARD_ATK_EXP) * ((FIRST_BOSS_HARD_EXTRA if is_first_boss else BOSS_HARD_EXTRA) if boss else 1.0)
		var hard_def_mul: float = pow(hard, HARD_DEF_EXP)
		var atk_mul: float = (1.10 if boss else 1.0) * DIFFICULTY * v_mul * hard_atk_mul
		var dmg_mul: float = (FIRST_BOSS_DMG_MUL if is_first_boss else 1.0) * tutorial_atk_mag_mul(w)
		out.append(FarroadCore.make_unit({
			"id": "e%d" % j,
			"name": ("ROADWARDEN" if boss and key == TUTORIAL_BOSS_ARCH else a["name"]) + (" %d" % (j + 1) if n > 1 else ""),
			"isParty": false, "level": 1, "slotIndex": 10 + j, "arch": key,
			"thorns": a.get("thorns", 0), "isBoss": boss, "row": "front" if j < 5 else "back",
			"stats": {
				"hp": maxf(8, round(hp_base)),
				"atk": maxf(1, round(a["atk"] * s * atk_mul * dmg_mul)),
				"mag": round(a.get("mag", 8) * s * DIFFICULTY * hard_atk_mul * dmg_mul),
				"def": round(a["def"] * s * hard_def_mul), "res": round(a["res"] * s * hard_def_mul),
				"spd": round(a["spd"] * sqrt(s) * hard_def_mul * (boss_spd_mul(w) if boss else 1.0)),
				"atkCrit": minf(FarroadCore.CAP_CRIT, a["atkCrit"] * sqrt(s)),
				"magCrit": minf(FarroadCore.CAP_CRIT, a.get("magCrit", 0.04) * sqrt(s)),
				"chargeRate": 1.15 if boss else 1.0, "evade": a["evade"]},
			"chargeAction": "wardensmaul" if boss and key == TUTORIAL_BOSS_ARCH else a.get("chargeAction"),
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
			var gain2 := 0
			if not dup2:
				g["conditions"].append(d["id"])
			else:
				gain2 = _credit_dup_gambit(g)
			events.append({"kind": "cond", "id": d["id"], "wave": w, "duplicate": dup2, "aetherGain": gain2,
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
		g["loadout"][uid] = [{"cond": "none", "action": "strike"}, {"cond": "none", "action": "magibolt"}]
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
		"pendingIdleAether": 0.0, "pendingIdleMarks": 0.0, "mcRespecs": 0, "mcRespecGranted": false,
		"party": ["kesh"], "partyPresets": [], "loadoutSets": {}, "gearSets": {}, "wipeLog": [], "appearance": {}, "approach": {}, "actions": STARTER_ACTIONS.duplicate(), "conditions": ["none"],
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
		# seenTabTutorial: the retired first-open menu pop-ups (kept so old
		# saves round-trip; nothing reads it now).
		"seenTabTutorial": {}, "tutorials": {}, "tutorialSkip": false, "forcedPull": null,
		"pvp": {"wins": 0, "losses": 0, "history": []}}

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

## Ian: parties push on until 10% HP (was 25%).
const EXPED_RETURN_HP_FRAC := 0.10
## Ian: a hurt party can stop and rest, healing by its members' Recovery,
## instead of turning back. It starts resting below REST_BELOW and keeps going
## until REST_UNTIL, each rest taking REST_WAVES waves' worth of time. A party
## with no Recovery can't rest and turns back as before.
static var EXPED_REST: bool = true
static var EXPED_REST_BELOW: float = 0.35
static var EXPED_REST_UNTIL: float = 0.70
static var EXPED_REST_WAVES: float = 2.0
const EXPED_CAP_SEC := OFFLINE_CAP_SEC
const EXPED_DISCOVERY_CHANCE := 0.08
## 24-item batch, Group E4: non-combat road events. EXPED_EVENT_CHANCE is
## the per-node chance a stretch of road is one of these instead of a
## fight (first-pass value, easily retuned). Each entry's aether/marks is a
## multiple of that node's own normal kill_reward (so the payout scales
## with depth exactly the way fights do); heal restores a fraction of the
## party's shared HP pool. {names} is filled with the party's names.
## Mirrored verbatim in farroad-ui.js (EXPED_EVENTS) and parity-reference.js.
## Ian: more road events (no fight) so parties get further (was 10%).
const EXPED_EVENT_CHANCE := 0.25
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

## What an expedition's party is called: the saved party's name when it was
## sent as one (Ian), else the members' names.
static func expedition_label(exp: Dictionary) -> String:
	var nm: String = str(exp.get("partyName", ""))
	return nm if nm != "" else _expedition_names(exp["partyIds"])

## The saved party (preset) whose members are exactly these, or "".
static func preset_name_for(g: Dictionary, party_ids: Array) -> String:
	var want: Array = party_ids.duplicate()
	want.sort()
	for p in g.get("partyPresets", []):
		var have: Array = (p["party"] as Array).duplicate()
		have.sort()
		if have == want:
			return str(p["name"])
	return ""

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
## Ian: waves take twice as long (parties stay out longer) and each wave
## won pays twice as much to compensate.
const EXPED_BASE_SEC := 120.0
const EXPED_SEC_PER_WAVE := 0.16
const EXPED_REWARD_MUL := 2.0
## Ian: no enrage on expeditions (testing how it plays). A fight that runs
## to the turn limit counts as a loss and is recorded as a stall.
const EXPED_ENRAGE := false
const EXPED_MAX_SPEEDUP := 0.5   # at most half the time

## Average of (higher of ATK and MAG) + SPD over living units.
static func offence_of(units: Array) -> float:
	var t := 0.0
	var n := 0
	for u in units:
		if u["hp"] > 0:
			t += maxf(float(u["base"]["atk"]), float(u["base"]["mag"])) + float(u["base"]["spd"])
			n += 1
	return t / n if n > 0 else 0.0

## Seconds an expedition spends on one wave: 60 + 0.08 per wave, cut by
## 1 - enemy offence / party offence when the party's is higher (twice the
## enemies' halves it), capped at EXPED_MAX_SPEEDUP.
static func expedition_wave_sec(ew: int, party: Array, enemies: Array) -> float:
	var base := EXPED_BASE_SEC + EXPED_SEC_PER_WAVE * ew
	var po := offence_of(party)
	var eo := offence_of(enemies)
	var cut := 0.0
	if po > 0.0 and eo > 0.0 and po > eo:
		cut = minf(EXPED_MAX_SPEEDUP, 1.0 - eo / po)
	return base * (1.0 - cut)

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
	var preset_nm := preset_name_for(g, party_ids)
	if preset_nm != "":
		exp["partyName"] = preset_nm
	g["expeditions"].append(exp)
	Analytics.add("expedition", "sent:" + direction)
	Analytics.add("expedition", "size:%d" % party_ids.size())
	for uid in party_ids:
		Analytics.add("expeditionUnits", uid)
	var names := expedition_label(exp)
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
	var names := expedition_label(exp)
	push_expedition_log(exp, "%s — %s Heading home now." % [names, reason], now)
	check_arrival(exp, now)

## Mirrors checkArrival (farroad-ui.js:1151-1159) -- first-observation-only
## arrival flag; does NOT bank the reward (collect_expedition does that).
static func check_arrival(exp: Dictionary, now) -> void:
	if exp.get("arrivedAt") != null or exp.get("homeAt") == null or float(now) < float(exp["homeAt"]):
		return
	exp["arrivedAt"] = now
	var names := expedition_label(exp)
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
	# Ian: "an expedition notification triggered ~8 minutes too soon." The
	# notification time is worked out by playing the trip forward, which only
	# matches what really happens if the trip always plays out the same. So
	# each expedition has its OWN random stream (rngA, seeded from its id),
	# advanced only by the nodes it actually resolves -- it no longer depends
	# on what the Road did meanwhile, or on how the catch-up was chunked.
	var saved_rng = g["rng"]
	var xr := FarroadCore.make_rng(0)
	xr.a = int(exp["rngA"]) if exp.get("rngA") != null else (str(exp["id"]).hash() & 0xFFFFFFFF)
	g["rng"] = xr
	while remaining > 0.0 and guard < 200000:
		guard += 1
		var stream_a: int = xr.a
		var stream_calls: int = xr.calls
		# Ian: a wave takes 60s (+0.08s per wave), cut by how much the
		# party's offence beats this wave's enemies -- glass cannons move
		# faster but don't get as far.
		var party := build_expedition_party(g, exp["partyIds"], exp["hpFrac"])
		var enemies: Array = apply_direction_affinity(
			apply_stat_mul(build_enemies(g, exp["ew"], true), mul), exp["direction"])
		var cost: float = expedition_wave_sec(exp["ew"], party, enemies)
		exp["waveSec"] = cost
		if cost > remaining:
			# not enough time left for this node: put back what building it
			# drew, so the next pass starts the node from the same place
			xr.a = stream_a
			xr.calls = stream_calls
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
			roll_expedition_pickup(g, exp, sim_now)
			_advance_direction_depth(g, exp, now, sim_now)
		else:
			var battle := FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": EXPED_ENRAGE})
			var beat_guard := 0
			while battle["over"] == null and beat_guard < 4000:
				beat_guard += 1
				if FarroadCore.step(battle) == null:
					break
			if battle["over"] == null:
				exp["stalls"] = int(exp.get("stalls", 0)) + 1
				if not g.get("_dryRun", false):
					Analytics.add("expedition", "stall")
			if battle["over"] == "party":
				g["enemiesDefeated"] = int(g.get("enemiesDefeated", 0)) + enemies.size()
				var r := kill_reward(exp["ew"], enemies.size())
				var rm: float = mul * EXPED_REWARD_MUL
				exp["bank"]["aether"] = float(exp["bank"]["aether"]) + r["aether"] * rm
				exp["bank"]["marks"] = float(exp["bank"]["marks"]) + r["marks"] * marks_mul(g) * rm
				if is_boss_wave(exp["ew"]):
					exp["bank"]["aether"] = float(exp["bank"]["aether"]) + boss_aether(exp["ew"]) * rm
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
				roll_expedition_pickup(g, exp, sim_now)
				_advance_direction_depth(g, exp, now, sim_now)
			else:
				exp["hpFrac"] = 0.0
		remaining -= cost
		remaining = _expedition_rest(g, exp, remaining, cost, resolve_started_at + (capped - remaining))
		if exp["hpFrac"] < EXPED_RETURN_HP_FRAC:
			turned_back = true
			break
	exp["rngA"] = xr.a
	g["rng"] = saved_rng
	FarroadCore.set_wave(saved_wave)
	# Ian: parties sat at wave 2 for 30 minutes. A step costs ~28s but the
	# game checks every 15s; this used to set lastResolvedAt = now, throwing
	# away the part-step each time, so nothing ever advanced while playing.
	# Keep the unspent time (time past the 12h cap is still dropped).
	exp["lastResolvedAt"] = float(now) - remaining
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
	var names := expedition_label(exp)
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
	if ev.has("find"):
		var f := _roll_find(g, str(ev["find"]))
		if not f.is_empty():
			var bank: Dictionary = exp["bank"]
			if not bank.has("finds"):
				bank["finds"] = []
			(bank["finds"] as Array).append(f)
			bits.append("found " + find_name(f))
	var text: String = String(ev["text"]).replace("{names}", names)
	if not bits.is_empty():
		text += " (%s)" % ", ".join(bits)
	push_expedition_log(exp, text, sim_now)

## Ian: pickups (gear, actions, gambits) start at 0% and gain 0.3% for every
## wave the party clears; the chance goes back to 0 whenever the party picks
## something up. Kept per expedition (exp["pickupChance"]).
const EXPED_PICKUP_STEP := 0.003
const EXPED_PICKUP_TEXT := {
	"equip": ["{names} found a dented chest by the roadside with gear inside.", "{names} pried open a sealed crate in a ruined watchtower."],
	"action": ["{names} learned a technique from a retired duelist.", "{names} found a battered tome of combat arts."],
	"cond": ["{names} studied the tactics of a veteran caravan guard.", "{names} copied battle plans from an abandoned war camp."]}

static func roll_expedition_pickup(g: Dictionary, exp: Dictionary, sim_now: float) -> void:
	var chance: float = float(exp.get("pickupChance", 0.0))
	if g["rng"].next() < chance:
		var kinds := ["equip", "action", "cond"]
		var kind: String = kinds[g["rng"].next_int(kinds.size())]
		var f := _roll_find(g, kind)
		if not f.is_empty():
			var bank: Dictionary = exp["bank"]
			if not bank.has("finds"):
				bank["finds"] = []
			(bank["finds"] as Array).append(f)
			var texts: Array = EXPED_PICKUP_TEXT[kind]
			var line: String = String(texts[g["rng"].next_int(texts.size())]).replace("{names}", expedition_label(exp))
			push_expedition_log(exp, "%s (found %s)" % [line, find_name(f)], sim_now)
		exp["pickupChance"] = 0.0
	else:
		exp["pickupChance"] = chance + EXPED_PICKUP_STEP

## Rests a hurt party in place (see EXPED_REST). Returns the time left after
## the rests it took.
static func _expedition_rest(g: Dictionary, exp: Dictionary, remaining: float, wave_sec: float, sim_now: float) -> float:
	var hp_frac: float = float(exp["hpFrac"])
	if not EXPED_REST or hp_frac <= 0.0 or hp_frac >= EXPED_REST_BELOW:
		return remaining
	var rec := 0.0
	for uid in exp["partyIds"]:
		rec += recovery_of(g, uid)
	rec /= maxf(1.0, float((exp["partyIds"] as Array).size()))
	if rec <= 0.0:
		return remaining
	var rest_sec: float = wave_sec * EXPED_REST_WAVES
	var rests := 0
	while hp_frac < EXPED_REST_UNTIL and remaining >= rest_sec:
		hp_frac = minf(1.0, hp_frac + rec)
		remaining -= rest_sec
		rests += 1
	if rests > 0:
		exp["hpFrac"] = hp_frac
		exp["rests"] = int(exp.get("rests", 0)) + rests
		push_expedition_log(exp, "%s stopped to rest%s and recovered some HP." % [expedition_label(exp), "" if rests == 1 else " (%d times)" % rests], sim_now)
	return remaining

## Mirrors rollExpeditionDiscovery (farroad-ui.js:1250-1266) -- a flat 8%
## chance per won node, a full one-off bonus fight against the SAME
## party/ew, banked or logged as a miss. Never a dungeon (v2.9 correction,
## already the real behavior -- dungeons come from the deterministic
## per-direction schedule this step deliberately doesn't port).
## Ian: "change 'won a bonus fight' to 'defeated some bandits'. Also add
## other enemy variants that could be fought." Who the party ran into.
const EXPED_FOES := ["some bandits", "a wolf pack", "a band of highwaymen", "a rogue knight",
	"a cult's lookouts", "some grave robbers", "a raiding party", "a nest of wild beasts",
	"a smuggler crew", "a deserter patrol"]

static func roll_expedition_discovery(g: Dictionary, exp: Dictionary, mul: float, now) -> void:
	if g["rng"].next() >= EXPED_DISCOVERY_CHANCE:
		return
	var names := expedition_label(exp)
	var foe: String = EXPED_FOES[g["rng"].next_int(EXPED_FOES.size())]
	var b_enemies: Array = apply_direction_affinity(
		apply_stat_mul(build_enemies(g, exp["ew"], true), mul), exp["direction"])
	var b_party := build_expedition_party(g, exp["partyIds"], exp["hpFrac"])
	var b_battle := FarroadCore.make_battle(b_party + b_enemies, {"rng": g["rng"], "enrage": EXPED_ENRAGE})
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
		push_expedition_log(exp, "%s defeated %s — +%d Aether, +%d Marks." % [
			names, foe, roundi(b_aether), floori(b_marks)], now)
	else:
		push_expedition_log(exp, "%s were ambushed by %s and had to fall back — no reward." % [names, foe], now)

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
		exp["recalled"] = true
		Analytics.add("expedition", "recalled")
	return true

## Ian: a recalled party heading home can be sent back out ("Explore"):
## it turns around and carries on from the wave it had reached.
static func resume_expedition(g: Dictionary, id: String, now) -> bool:
	for exp in g["expeditions"]:
		if exp["id"] == id and exp.get("homeAt") != null and exp.get("arrivedAt") == null and exp.get("recalled", false):
			exp["homeAt"] = null
			exp["recalled"] = false
			exp["lastResolvedAt"] = float(now)
			push_expedition_log(exp, "%s turned around and headed back out." % expedition_label(exp), now)
			Analytics.add("expedition", "resumed")
			return true
	return false

## ---- expedition finds (Ian) ----
## Picked when found (so the log can name it), handed over on Collect by
## the same rules as a Marks pull: new actions/gambits unlock, a repeat
## action becomes Lore for it, a repeat gambit becomes Aether, gear stacks.
static func _roll_find(g: Dictionary, kind: String) -> Dictionary:
	match kind:
		"equip":
			return {"kind": "equip", "id": weighted_equipment_pick(g["rng"], random_equipment_ids())}
		"action":
			return {"kind": "action", "id": weighted_action_pick(g["rng"], FarroadCore.equippable() + FarroadCore.CHARGE_ACTIONS)}
		"cond":
			var cp: Array = FarroadCore.ALL_CONDITION_IDS.filter(func(id): return id != "none")
			return {"kind": "cond", "id": cp[g["rng"].next_int(cp.size())]}
	return {}

static func find_name(f: Dictionary) -> String:
	match str(f.get("kind", "")):
		"equip":
			return str(FarroadCore.EQUIPMENT.get(f["id"], {}).get("name", f["id"]))
		"action":
			var a = FarroadCore.ACTIONS.get(f["id"])
			return ("⚡ " if a != null and a.get("isCharge", false) else "") + (str(a["name"]) if a != null else str(f["id"]))
		"cond":
			return "gambit: " + FarroadCore.cond_label(f["id"])
	return "?"

static func grant_find(g: Dictionary, f: Dictionary) -> void:
	var id: String = str(f.get("id", ""))
	match str(f.get("kind", "")):
		"equip":
			g["equipInv"][id] = int(g["equipInv"].get(id, 0)) + 1
		"action":
			g["actionCounts"][id] = int(g["actionCounts"].get(id, 0)) + 1
			if bool(FarroadCore.ACTIONS.get(id, {}).get("isCharge", false)) and g.get("mc") != null:
				g["mc"]["acquiredCharges"] = g["mc"].get("acquiredCharges", [])
				if g["mc"]["acquiredCharges"].has(id):
					_credit_lore(g, id)
				else:
					g["mc"]["acquiredCharges"].append(id)
			elif (g["actions"] as Array).has(id):
				_credit_lore(g, id)
			else:
				g["actions"].append(id)
		"cond":
			g["condCounts"][id] = int(g["condCounts"].get(id, 0)) + 1
			if (g["conditions"] as Array).has(id):
				_credit_dup_gambit(g)
			else:
				g["conditions"].append(id)
	Analytics.add("expeditionFinds", "%s:%s" % [f.get("kind", ""), id])

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
	for f in exp["bank"].get("finds", []):
		grant_find(g, f)
	Analytics.add("expedition", "collected")
	Analytics.add("expedition", "aetherCollected", float(exp["bank"]["aether"]))
	Analytics.add("expedition", "marksCollected", float(exp["bank"]["marks"]))
	Analytics.add("expeditionDepths", str(int(exp.get("ew", 0)) / 10 * 10))
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
	# wave -> [clears, wipes] fought while away (for the gameplay stats)
	var wave_results: Dictionary = {}
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
		var fought: int = int(g["wave"])
		if not wave_results.has(fought):
			wave_results[fought] = [0, 0]
		if g["battle"]["over"] == "party":
			wave_results[fought][0] += 1
			after_wave_cleared(g)
			start_wave(g, g["wave"] + 1)
		elif g["battle"]["over"] == "enemy":
			wave_results[fought][1] += 1
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
		"wave_results": wave_results,
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

## Ian: "Dungeons should be unique, with affinities just like their
## expeditions." Each dungeon gets its own element: the first in a
## direction uses that direction's own element (as its expeditions do), the
## next ones step round the other elements, so no two dungeons in a line
## fight alike. Its foes are strong in that element (+DIRECTION_AFFINITY_BONUS)
## and weak to the opposite one, so the element also tells you how to beat it.
const DUNGEON_AXES: Array = ["fire", "water", "earth", "air", "light", "dark"]
const DUNGEON_OPPOSITE := {"fire": "water", "water": "fire", "earth": "air", "air": "earth", "light": "dark", "dark": "light"}
const DUNGEON_PLACES := {"fire": ["Cinder Hollow", "Ashen Forge", "Emberdeep"],
	"water": ["Drowned Vault", "Tidecaller Grotto", "Mistfall Cavern"],
	"earth": ["Stonebound Deep", "Rootlock Barrow", "Gravel Mine"],
	"air": ["Stormspire", "Skyreach Ruins", "Whisperwind Pass"],
	"light": ["Sunlit Chapel", "Dawnglass Keep", "Halo Vault"],
	"dark": ["Gloam Crypt", "Duskmire Pit", "Hollow Sepulchre"]}

static func _dungeon_place(axis: String, dir: String, tier: int) -> String:
	var names: Array = DUNGEON_PLACES.get(axis, ["Dungeon"])
	return names[(int(abs(dir.hash())) + tier) % names.size()]

static func dungeon_axis(dir: String, tier: int) -> String:
	var own = FarroadCore.DIRECTION_CONFIG.get(dir, {}).get("affinity")
	var start: int = DUNGEON_AXES.find(own) if own else int(abs(dir.hash())) % DUNGEON_AXES.size()
	if start < 0:
		start = 0
	return DUNGEON_AXES[(start + maxi(0, tier - 1)) % DUNGEON_AXES.size()]

static func _apply_dungeon_affinity(enemies: Array, axis: String) -> Array:
	var weak: String = DUNGEON_OPPOSITE.get(axis, "")
	for u in enemies:
		u["affinity"][axis] = float(u["affinity"].get(axis, 0.0)) + DIRECTION_AFFINITY_BONUS
		if weak != "":
			u["affinity"][weak] = float(u["affinity"].get(weak, 0.0)) - DUNGEON_WEAKNESS
	return enemies

const DUNGEON_WEAKNESS := 4

## Mirrors unlockDirectionDungeon (farroad-ui.js:1284-1313). Dungeon ids
## use Godot's own randi(), not g["rng"] -- same established reasoning as
## send_expedition's own id (unique, not reproducible; never bit-exact
## between JS/GD by design).
static func unlock_direction_dungeon(g: Dictionary, dir: String, tier: int, now) -> Dictionary:
	var cfg: Dictionary = FarroadCore.DIRECTION_CONFIG[dir]
	var mul: float = cfg["mul"]
	var base_wave: int = tier * int(cfg["unlockEvery"])
	var regular_wave: int = (base_wave - 1) if is_boss_wave(base_wave) else base_wave
	var axis: String = dungeon_axis(dir, tier)
	var waves := []
	for i in range(int(cfg["waveCount"]) - 1):
		var enemies: Array = _apply_dungeon_affinity(
			apply_stat_mul(build_enemies(g, regular_wave, true), mul), axis)
		waves.append({"wave": regular_wave, "enemies": enemies.map(bake_enemy_snapshot)})
	var boss_wave: int = next_boss_wave(base_wave - 1)
	var boss_enemies: Array = _apply_dungeon_affinity(
		apply_stat_mul(build_enemies(g, boss_wave, true), mul * DUNGEON_LEN), axis)
	if cfg.get("bossName"):
		for u in boss_enemies:
			u["name"] = cfg["bossName"]
	waves.append({"wave": boss_wave, "enemies": boss_enemies.map(bake_enemy_snapshot)})
	var dungeon := {"id": "dgn%d_%d" % [int(now), randi() % 1000000],
		"name": "%s (%s, depth %d)" % [_dungeon_place(axis, dir, tier), cfg["label"], base_wave],
		"element": axis, "direction": dir, "tier": tier,
		"waves": waves, "clears": 0, "charges": DUNGEON_START_CHARGES, "chargeDay": _utc_day(now)}
	g["dungeons"].append(dungeon)
	return dungeon

## Dungeon charges (Ian): "completing the dungeon consumes one, but at
## midnight one more is added for each dungeon", max DUNGEON_MAX_CHARGES --
## so a player who misses a day can catch up later. Days are UTC calendar
## days (unix time has no timezone anywhere in this project). Each dungeon
## keeps its own `charges` and the UTC day number they were last topped up
## on (`chargeDay`); refilling is lazy, done whenever charges are read.
const DUNGEON_MAX_CHARGES := 3
const DUNGEON_START_CHARGES := 1

static func _utc_day(ts) -> int:
	return int(floor(float(ts) / 86400.0))

## Kept for callers that still compare calendar days.
static func _calendar_day(ts) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	return "%04d-%02d-%02d" % [int(dt["year"]), int(dt["month"]), int(dt["day"])]

## Tops up (in place) and returns the dungeon's charges at `now`.
static func dungeon_charges(dungeon: Dictionary, now) -> int:
	var today := _utc_day(now)
	if not dungeon.has("charges"):
		# older saves had a once-per-day flag: available today = 1 charge
		var last = dungeon.get("lastClearedAt")
		dungeon["charges"] = 0 if (last != null and _utc_day(last) == today) else DUNGEON_START_CHARGES
		dungeon["chargeDay"] = today
	var days: int = today - int(dungeon.get("chargeDay", today))
	if days > 0:
		dungeon["charges"] = mini(DUNGEON_MAX_CHARGES, int(dungeon["charges"]) + days)
	dungeon["chargeDay"] = maxi(today, int(dungeon.get("chargeDay", today)))
	return int(dungeon["charges"])

static func dungeon_available(dungeon: Dictionary, now) -> bool:
	return dungeon_charges(dungeon, now) > 0

## Mirrors questStageWave/questStageAether (farroad-progression.js:1168-1203).
## Ian: "reduce new unit quests difficulty to about 50% of current." A
## companion quest's frozen fight was scaled to the player's FULL current
## power_level -- halved so a freshly-acquired companion's own quest line
## reads as approachable rather than as hard as the player's actual
## current build.
const QUEST_DIFFICULTY_MUL := 0.5

## Ian: quests are a fixed, fairly easy difficulty -- the same Road waves
## for everyone, not scaled to the party's Power. Stage 5 (the boss) is the
## softened wave-20 boss.
const QUEST_STAGE_WAVES: Array[int] = [6, 10, 14, 17, 20]
## Bumped when quest difficulty changes: stages saved under an older rule
## are rebuilt the next time they're attempted.
const QUEST_RULES_VERSION := 3
## Ian: rare units' quests at 2x those waves, legendary at 4x.
const QUEST_RARITY_MUL := {"common": 1, "rare": 2, "legendary": 4}

static func quest_stage_wave(_g: Dictionary, uid: String, stage_idx: int) -> int:
	var d = FarroadCore.roster_by_id(uid)
	var mul: int = int(QUEST_RARITY_MUL.get(d.get("rarity", "common") if d != null else "common", 1))
	var idx := clampi(stage_idx, 0, QUEST_STAGE_WAVES.size() - 1)
	var w: int = QUEST_STAGE_WAVES[idx] * mul
	# a non-boss stage never lands on a boss wave (e.g. rare stage 2 = 20)
	if idx < QUEST_STAGE_WAVES.size() - 1 and is_boss_wave(w):
		w -= 1
	return w

static func _refresh_quest_rules(q: Dictionary) -> void:
	if int(q.get("rulesV", 1)) < QUEST_RULES_VERSION:
		q["frozen"] = []
		q["rulesV"] = QUEST_RULES_VERSION

## Ian: "Have quests/dungeons show their power level (the recommended power
## level players should be to complete them)." The fight's enemy stats
## through the same formula as power_level (stat total / POWER_STAT_DIVISOR
## plus the wave's level), for its toughest wave.
static func snapshot_power(snaps: Array, _wave: int) -> int:
	var total := 0.0
	for e in snaps:
		var st: Dictionary = e["stats"]
		total += float(st["hp"]) + float(st["atk"]) + float(st["mag"]) + float(st["def"]) + float(st["res"]) + float(st["spd"])
	return maxi(1, roundi(total / POWER_STAT_DIVISOR))   # stats only, like party Power

## The fielded party's power on the same scale (what a quest or dungeon
## fight is actually up against).
static func party_power(g: Dictionary) -> int:
	return party_power_of(g, g["party"])

## The same Power for any group of units (a saved party, an expedition
## pick), so parties can be compared before they're fielded or sent.
static func party_power_of(g: Dictionary, uids: Array) -> int:
	var total := 0.0
	for uid in uids:
		var def = FarroadCore.roster_by_id(uid)
		if def == null:
			continue
		total += unit_power_stats(g, uid)
	return maxi(1, roundi(total / POWER_STAT_DIVISOR))

## A unit's stat total for Power, gear and Aether investments included (Ian:
## gear didn't count). The Arena's ranked Power (Ranked.power_of) uses the
## same sum, so Power reads the same on the Road and in the Arena.
static func unit_power_stats(g: Dictionary, uid: String) -> float:
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return 0.0
	var st := stats_at(uid, def["stats"], def["hp"], level_of(g, uid))
	apply_pct_stat_investment(g, uid, st)
	apply_equipment_stats(g, uid, st)
	return float(st["atk"] + st["mag"] + st["def"] + st["res"] + st["spd"] + st["hp"])

static func dungeon_power(dungeon: Dictionary) -> int:
	var best := 1
	for wv in dungeon["waves"]:
		best = maxi(best, snapshot_power(wv["enemies"], int(wv["wave"])))
	return best

## For a stage not yet frozen, previews its fight on a throwaway RNG (the
## real stream and the live wave are left untouched).
static func quest_stage_power(g: Dictionary, uid: String, stage: int) -> int:
	var q: Dictionary = g["quests"].get(uid, {})
	var frozen: Array = q.get("frozen", []) if int(q.get("rulesV", 1)) >= QUEST_RULES_VERSION else []
	if stage < frozen.size() and frozen[stage] != null:
		return snapshot_power(frozen[stage]["enemies"], int(frozen[stage]["wave"]))
	var step: Dictionary = FarroadCore.QUEST_LINES[uid][stage]
	var raw_wave: int = quest_stage_wave(g, uid, stage)
	var wave: int = next_boss_wave(raw_wave - 1) if step.get("isBoss", false) else raw_wave
	var saved_wave: int = FarroadCore.current_wave
	var temp := {"rng": FarroadCore.RNG.new(wave * 7919 + stage), "party": g["party"]}
	var snaps: Array = build_enemies(temp, wave, true).map(bake_enemy_snapshot)
	FarroadCore.set_wave(saved_wave)
	return snapshot_power(snaps, wave)

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
	_refresh_quest_rules(q)
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
## `prebuilt`: a ranked PvP fight arrives already built (Ranked.build_battle,
## from the server's teams and seed) and is used as it is.
static func start_side_battle(g: Dictionary, enemies: Array, wave: int, meta: Dictionary, prebuilt: Dictionary = {}) -> bool:
	if g.get("sideBattle") != null:
		return false
	g["roadBattle"] = g["battle"]
	var saved_wave: int = g["wave"]
	FarroadCore.set_wave(wave)
	if not prebuilt.is_empty():
		g["battle"] = prebuilt
		g["sideBattle"] = {"savedWave": saved_wave, "wave": wave, "meta": meta}
		return true
	var party := build_expedition_party(g, g["party"], 1)
	g["battle"] = FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": g.get("enrage", true)})
	if meta.get("kind") == "pvp":   # both teams enrage, so long fights still end evenly
		g["battle"]["enrage"] = true
		g["battle"]["enrageAll"] = true
		g["battle"]["healDecay"] = PvP.HEAL_DECAY   # healing shrinks as enrage rises
		g["battle"]["enrageAfter"] = PvP.ENRAGE_AFTER
		g["battle"]["enragePct"] = PvP.ENRAGE_PCT
	if meta.get("kind") == "training":   # no enrage, and the loop has no beat cap
		g["battle"]["enrage"] = false
		g["battle"]["training"] = true
	g["sideBattle"] = {"savedWave": saved_wave, "wave": wave, "meta": meta}
	return true

## ===== Training (Ian): test gambits on dummies =====
## Up to 10 dummies, each its own settings: which enemy it is (the plain
## dummy, or any enemy the player has met), a level (it is scaled like that
## wave), a multiplier per stat, an affinity per element, statuses held for
## the whole fight, whether it fights back, whether it can be defeated and
## what share of HP it starts with. Nothing from a training fight counts
## (no rewards, no stats, no effect on the Road).
const TRAINING_MAX := 10
const TRAINING_STATS: Array[String] = ["hp", "atk", "mag", "def", "res", "spd"]
const TRAINING_STATUSES: Array[String] = ["poisoned", "burning", "blinded", "slowed", "confused",
	"sundered", "frail", "enfeebled", "dulled", "exposed", "hasted", "warded", "regen", "taunted"]
const TRAINING_AFFINITY_STEP := 15.0   # "weak" / "strong" on an affinity = -15 / +15, like the elemental enemies

static func training_new_dummy(level: int) -> Dictionary:
	var mods := {}
	for k in TRAINING_STATS:
		mods[k] = 1.0
	return {"arch": "", "level": maxi(1, level), "mods": mods, "affinity": {}, "statuses": [],
		"immortal": true, "passive": true, "hpPct": 100}

## The saved setup (kept in the save so it is the same next time).
static func training_setup(g: Dictionary) -> Dictionary:
	var t = g.get("trainingSetup")
	if not (t is Dictionary) or not (t.get("dummies") is Array) or (t["dummies"] as Array).size() != TRAINING_MAX:
		var ds: Array = []
		for i in TRAINING_MAX:
			ds.append(training_new_dummy(int(g.get("wave", 1))))
		t = {"count": 1, "selected": 0, "dummies": ds}
		g["trainingSetup"] = t
	return t

## Enemies the player has met, as [key, name] sorted by name.
static func training_met_enemies(g: Dictionary) -> Array:
	var out: Array = []
	for key in (g.get("seenArch", {}) as Dictionary).keys():
		if FarroadCore.ARCH.has(key):
			out.append([key, str(FarroadCore.ARCH[key]["name"])])
	out.sort_custom(func(a, b): return a[1] < b[1])
	return out

static func build_training_unit(g: Dictionary, spec: Dictionary, i: int) -> Dictionary:
	var key: String = str(spec.get("arch", ""))
	if key == "" or not FarroadCore.ARCH.has(key):
		key = "wolf"
	var a: Dictionary = FarroadCore.ARCH[key]
	var w: int = clampi(int(spec.get("level", 1)), 1, 5000)
	var saved_wave: int = FarroadCore.current_wave
	FarroadCore.set_wave(w)
	var s: float = FarroadCore.wave_scale(w)
	var hard: float = hard_mul(w)
	var tut: float = tutorial_atk_mag_mul(w)
	var hard_atk: float = pow(hard, HARD_ATK_EXP)
	var hard_def: float = pow(hard, HARD_DEF_EXP)
	var m: Dictionary = spec.get("mods", {})
	var hp_base: float = 200.0 * a["hpMul"] * FarroadCore.dmg_taken_mul(a) * s * DIFFICULTY * sqrt(hard) * tut
	var passive: bool = bool(spec.get("passive", true))
	var dummy: bool = str(spec.get("arch", "")) == ""
	var u := FarroadCore.make_unit({
		"id": "e%d" % i,
		"name": ("Training Dummy" if dummy else str(a["name"])) + " %d" % (i + 1),
		"isParty": false, "level": 1, "slotIndex": 10 + i, "arch": key,
		"thorns": 0 if dummy else a.get("thorns", 0), "isBoss": false, "row": "front" if i < 5 else "back",
		"stats": {
			"hp": maxf(8, round(hp_base * float(m.get("hp", 1.0)))),
			"atk": maxf(1, round(a["atk"] * s * DIFFICULTY * hard_atk * tut * float(m.get("atk", 1.0)))),
			"mag": maxf(1, round(a.get("mag", 8) * s * DIFFICULTY * hard_atk * tut * float(m.get("mag", 1.0)))),
			"def": maxf(0, round(a["def"] * s * hard_def * float(m.get("def", 1.0)))),
			"res": maxf(0, round(a["res"] * s * hard_def * float(m.get("res", 1.0)))),
			"spd": maxf(1, round(a["spd"] * sqrt(s) * hard_def * float(m.get("spd", 1.0)))),
			"atkCrit": minf(FarroadCore.CAP_CRIT, a["atkCrit"] * sqrt(s)),
			"magCrit": minf(FarroadCore.CAP_CRIT, a.get("magCrit", 0.04) * sqrt(s)),
			"chargeRate": 1.0, "evade": 0.0 if dummy else a["evade"]},
		"chargeAction": null if passive else a.get("chargeAction"),
		"affinity": FarroadCore.default_affinity() if dummy else a["affinity"],
		"slots": [{"cond": "none", "action": "wait"}, {"cond": "none", "action": "wait"}] if passive \
			else a["slots"].map(func(sl): return {"cond": sl["cond"], "action": sl["action"]})})
	FarroadCore.set_wave(saved_wave)
	for ax in (spec.get("affinity", {}) as Dictionary).keys():
		u["affinity"][ax] = float(spec["affinity"][ax])
	for st in spec.get("statuses", []):
		FarroadCore.apply_status(u, str(st), 999, 0.0)
	if bool(spec.get("immortal", true)):
		u["immortal"] = true
	u["hp"] = maxf(1.0, round(float(u["maxHp"]) * float(spec.get("hpPct", 100)) / 100.0))
	return u

## Starts the training fight (the party at full HP against the dummies).
static func training_enemies(g: Dictionary) -> Array:
	var t := training_setup(g)
	var out: Array = []
	for i in int(t["count"]):
		out.append(build_training_unit(g, t["dummies"][i], i))
	return out

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
	if result == "party" and not gave_up and meta["kind"] != "pvp" and meta["kind"] != "training":
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

	var turns: int = int(g["battle"].get("beat", 0))
	FarroadCore.set_wave(sb["savedWave"])
	g["battle"] = g["roadBattle"]
	g["roadBattle"] = null
	g["sideBattle"] = null

	if meta["kind"] == "training":
		return {"kind": "training_done"}
	if meta["kind"] == "pvp" and meta.get("ranked", false):
		# the server already decided this fight; the replay just showed it
		Ranked.end_battle(g.get("bonuses", {}))
		var s_won: bool = bool(meta.get("serverWon", false))
		var rk: Dictionary = g.get_or_add("ranked", {})
		rk["rating"] = int(meta.get("rating", 0))
		return {"kind": "pvp_won" if s_won else "pvp_lost", "owner": meta["owner"], "power": meta["power"],
			"turns": int(meta.get("serverTurns", turns)), "gaveUp": gave_up, "team": meta.get("team", ""),
			"ranked": true, "rating": int(meta.get("rating", 0)), "delta": int(meta.get("delta", 0)),
			"replayDiffered": (not gave_up) and ((result == "party") != s_won)}
	if meta["kind"] == "pvp":
		PvP.clear_actions()
		var won: bool = result == "party" and not gave_up
		PvP.record(g, won, meta["owner"], int(meta["power"]), turns, int(now), str(meta.get("rival", "")))
		if won and str(meta.get("rival", "")) != "":
			(g["pvp"] as Dictionary).get_or_add("rivals", {})[meta["rival"]] = true
		return {"kind": "pvp_won" if won else "pvp_lost", "owner": meta["owner"], "power": meta["power"],
			"turns": turns, "gaveUp": gave_up, "team": meta.get("team", "")}
	if meta["kind"] == "quest":
		var q: Dictionary = g["quests"][meta["uid"]]
		if result == "party":
			q["stage"] = int(q["stage"]) + 1
			# Ian: "the dungeons and new unit quests should no longer give
			# aether or marks, just crystals." Auto-credited on clear (no
			# Collect step), QUEST_STAGE_CRYSTAL per stage.
			g["crystal"] = int(g.get("crystal", 0)) + QUEST_STAGE_CRYSTAL
			return {"kind": "quest_cleared", "name": meta["name"], "story": meta["story"],
				"stageNum": int(meta["stage"]) + 1, "questComplete": int(q["stage"]) >= 5, "crystal": QUEST_STAGE_CRYSTAL}
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
			# a completed run uses one charge (failing costs nothing)
			dungeon["charges"] = maxi(0, dungeon_charges(dungeon, now) - 1)
			dungeon["lastClearedAt"] = now
			# Ian: dungeons give Crystal only now -- no Aether/Marks.
			g["crystal"] = int(g.get("crystal", 0)) + DUNGEON_CRYSTAL
			return {"kind": "dungeon_cleared", "name": dungeon["name"], "crystal": DUNGEON_CRYSTAL}
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
	"atk": [8.0, 30.0], "mag": [7.0, 30.0], "def": [8.0, 45.0],   # Ian: ATK tops out like MAG
	"res": [8.0, 40.0], "spd": [11.0, 26.0], "hp": [180.0, 840.0]}
## hp/spd bounds carry the same reduction the roster's own GROWTH table
## gets above (x0.7 hp, x0.5 spd growth, written in directly -- see its
## own comment); spd's STARTING range separately carries the x0.2
## starting-SPD cut applied across the whole roster/enemy/equipment
## tables (was [56,131], now that x0.2) -- this range was originally
## calibrated to match GROWTH's own min/max spread, so a custom MC's
## own point-bought growth stays consistent with the rest of the roster.
## Ian: "have the mc growths be legendary level." The non-HP ranges are the old
## ones x1.066, so a character with its points spread evenly grows 7.73 stats
## a level -- the average of the legendary roster (7.3-8.1). HP is unchanged
## (a balanced build already gets 23 a level against the legendaries' 21.5).
const MC_GROWTH_RANGE := {
	"atk": [0.64, 2.88], "mag": [0.53, 2.88], "def": [0.85, 2.56],
	"res": [0.85, 1.81], "spd": [0.75, 1.70], "hp": [12.6, 33.6]}
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
## A character's growth is worked out from its creation points, so when the
## growth ranges change, existing characters follow (otherwise the Arena would
## reject them for not matching). Characters from before points were kept are
## given them back if their stats rebuild exactly; ones that don't ("legacy")
## keep what they have.
static func _migrate_mc_growth(mc: Dictionary) -> void:
	var pts: Dictionary = Ranked.mc_points_of(mc)
	var built: Dictionary = mc_build_stats(pts)
	if not (mc.get("points") is Dictionary):
		if float(built["hp"]) != float(mc.get("hp", -1)):
			return
		for k in built["stats"]:
			if float(built["stats"][k]) != float((mc.get("stats", {}) as Dictionary).get(k, -1)):
				return
		mc["points"] = pts
	mc["growth"] = built["growth"]

## Puts each unit's saved front/back row onto its roster entry (rows used to
## live only in memory and reset on restart).
static func apply_rows(g: Dictionary) -> void:
	var rows = g.get("rows", {})
	if not (rows is Dictionary):
		return
	for uid in rows:
		var def = FarroadCore.roster_by_id(str(uid))
		if def != null and str(rows[uid]) in ["front", "back"]:
			def["row"] = str(rows[uid])

static func apply_custom_mc(g: Dictionary) -> void:
	var mc = g.get("mc")
	if mc == null:
		return
	_migrate_mc_growth(mc)
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

class_name FarroadCore
extends RefCounted
## Ported combat engine -- GDScript counterpart to src/farroad-core.js.
## A global class_name (not an autoload singleton -- there's no per-instance
## state to own here, just static functions/factories, mirroring how the JS
## build exposes window.FarroadCore as one shared table of functions) so any
## script can call FarroadCore.xxx() without an explicit preload/instance.
## Ported incrementally per the plan's staged steps; each step is proven
## bit/behavior-identical to the JS original via parity_test.gd before
## the next step is added.

## ===== Step 1a: RNG (mirrors makeRNG, farroad-core.js:8-10) =====
## mulberry32-family PRNG. Every op in the original is addition, XOR, or
## an UNSIGNED right shift (`>>>`) -- never sign-extending -- so keeping
## the state as a canonical value in 0..0xFFFFFFFF (masking after every
## write) and using GDScript's plain >>/^/& on that non-negative 64-bit
## int reproduces the identical bit pattern JS's 32-bit ops produce at
## every step, with no need to emulate JS's |0/>>>0 sign gymnastics.
class RNG:
	var a: int
	var calls: int = 0

	func _init(seed: int) -> void:
		a = seed & 0xFFFFFFFF

	static func _imul32(x: int, y: int) -> int:
		# Math.imul(x,y): 32-bit multiply, low 32 bits of the result.
		# x,y are already kept in 0..0xFFFFFFFF, so x*y fits in 64 bits
		# before masking -- no precision loss.
		return (x * y) & 0xFFFFFFFF

	func next() -> float:
		calls += 1
		a = (a + 0x6D2B79F5) & 0xFFFFFFFF
		var t: int = _imul32(a ^ (a >> 15), 1 | a)
		# JS: t=(t+Math.imul(t^(t>>>7),61|t))^t -- the trailing ^t uses the
		# PRE-statement t (JS evaluates the whole RHS before assigning), so
		# it must be captured before t is reassigned below.
		var t_before_mix: int = t
		t = ((t + _imul32(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t_before_mix
		t = t ^ (t >> 14)
		return float(t & 0xFFFFFFFF) / 4294967296.0

	func next_int(n: int) -> int:
		return int(floor(next() * n))


static func make_rng(seed: int) -> RNG:
	return RNG.new(seed)


## ===== Step 1b: constants (mirrors the top-of-file constants block,
## farroad-core.js:16-141) ===== only what resolveHit/healFor/step/
## targeting actually read; rarity/equipment/Lore constants are Step 1d.
const CRIT_MUL := 1.75
const CAP_EVADE := 0.40
const CAP_CRIT := 1.00
const CHARGE_FULL := 100
const BURN_PCT := 0.05
const REGEN_PCT := 0.06
const AFFINITY_CAP := 40.0
const AFFINITY_BOOST_CAP := 2.0
const ROW_PHYS := 0.70
const ROW_SPD := 0.10
const ROWMUL := {"front": 1.35, "back": 0.75}
const ENRAGE_AFTER := 20
const ENRAGE_PCT := 0.05
const TICK_K := 10000.0
const GAIN_RATIO := 12.5
const K_BASE := 25.0
const ST: Array[String] = ["sundered", "frail", "enfeebled", "dulled", "slowed",
	"blinded", "burning", "hasted", "warded", "taunted", "surging", "bracing",
	"regen", "blurred"]
const DEBUFFS: Array[String] = ["sundered", "frail", "enfeebled", "dulled",
	"slowed", "blinded", "burning"]
const STATUS_BASE_MAG := {"enfeebled": -0.25, "dulled": -0.25, "bracing": 0.40,
	"sundered": -0.25, "frail": -0.25, "blurred": 0.20, "warded": -0.40,
	"slowed": 0.50, "hasted": -0.40, "surging": 1.00, "burning": BURN_PCT,
	"regen": REGEN_PCT}
const STARTER_ACTIONS: Array[String] = ["strike", "ember"]

## Test-only module state (mirrors CURRENT_WAVE/ACTIONS being plain
## module-level vars in the JS closure). register_actions() stands in for
## the real CSV content pipeline, deferred to a later milestone -- see plan.
static var current_wave: int = 1
static var ACTIONS: Dictionary = {}

static func set_wave(w: int) -> void:
	current_wave = w

## Mirrors A() (farroad-core.js:271-272) -- fills the same defaults every
## CSV-authored action gets before use.
static func a_defaults(o: Dictionary) -> Dictionary:
	o["rank"] = o.get("rank", 1.0)
	if o["rank"] == null:
		o["rank"] = 1.0
	o["charge"] = o.get("charge", 0.0) if o.get("charge") != null else 0.0
	o["hits"] = o.get("hits", 1) if o.get("hits") != null else 1
	o["defPierce"] = o.get("defPierce", 0.0) if o.get("defPierce") != null else 0.0
	o["critBonus"] = o.get("critBonus", 0.0) if o.get("critBonus") != null else 0.0
	o["power"] = o.get("power", 0.0) if o.get("power") != null else 0.0
	if o.get("isCharge"):
		o["chargeCost"] = o.get("chargeCost", CHARGE_FULL) if o.get("chargeCost") != null else CHARGE_FULL
	return o

static func register_actions(actions: Dictionary) -> void:
	ACTIONS = {}
	for id in actions.keys():
		ACTIONS[id] = a_defaults(actions[id].duplicate(true))

static func cost_of_charge(act) -> float:
	if act != null and act.get("chargeCost") != null:
		return act["chargeCost"]
	return CHARGE_FULL

## ===== Step 1e: real-content wiring (mirrors farroad-core.js:299-320,
## 284-294) =====
## ATK_CAMP+MAG_CAMP (-> EQUIPPABLE) and CHARGE_ACTIONS are hardcoded
## whitelists in the real engine, not CSV-generated -- ported here verbatim
## rather than exported alongside the CSV content, since they're genuinely
## part of core.js's own source.
const ATK_CAMP: Array[String] = ["strike", "pierce", "cleave", "flurry", "execute", "guardbreak",
	"daunt", "cripple", "brace", "vengeance", "onslaught", "rally",
	"cinderstrike", "riptideblow", "stoneshatter", "squallstrike", "radiantblow", "shadowrend"]
const MAG_CAMP: Array[String] = ["ember", "gale", "sear", "hex", "smother", "dazzle", "siphon",
	"mend", "renew", "recall", "bulwark", "blur", "quicken",
	"firebrand", "tidalsurge", "quakebolt", "zephyrbolt", "solarflare", "umbralbolt"]
const CHARGE_ACTIONS: Array[String] = ["oath", "ninefold", "hearthlight", "vowofstone", "ashfall",
	"bloodfury", "spellbrand", "wardcurse", "aegisstep", "quicksilver",
	"heavystrike", "wildfire", "greatheal", "wearingdown", "ironresolve",
	"tideturn", "lastlight", "sunder", "gravewind", "reckoning", "bulwarkoath", "emberglut", "hollowtoll",
	"atk_reckless", "mag_lance", "def_slam", "res_strike", "spd_flurry",
	"atk_cry", "mag_font", "def_bulwark", "res_ward", "spd_fleet",
	"colossusslam", "reapersharvest"]

static func equippable() -> Array:
	return ATK_CAMP + MAG_CAMP

## Mirrors ACTION_DYNAMIC (farroad-core.js:284-292). powerFn/critFn are
## closures in JS; GDScript can't hold those in a plain-data Dictionary the
## same way, so each gets a string marker instead, dispatched by
## eval_power_fn/eval_crit_fn below. ninefold's randomPerHit is already a
## plain flag -- no marker needed, register_actions()/a_defaults() pass it
## through as-is.
static func merge_action_dynamic() -> void:
	if ACTIONS.has("execute"): ACTIONS["execute"]["critFnId"] = "execute"
	if ACTIONS.has("vengeance"): ACTIONS["vengeance"]["powerFnId"] = "vengeance"
	if ACTIONS.has("onslaught"): ACTIONS["onslaught"]["powerFnId"] = "onslaught"
	if ACTIONS.has("reckoning"): ACTIONS["reckoning"]["powerFnId"] = "reckoning"
	if ACTIONS.has("ninefold"): ACTIONS["ninefold"]["randomPerHit"] = true

## Mirrors ACTION_DYNAMIC.vengeance/onslaught/reckoning's powerFn closures.
static func eval_power_fn(action: Dictionary, src: Dictionary, tgt) -> float:
	match action.get("powerFnId"):
		"vengeance": return 0.55 + 1.55 * (1 - float(src["hp"]) / float(src["maxHp"]))
		"onslaught": return 2.20 if src["turnsTaken"] == 0 else 0.65
		"reckoning": return (3.1 + 6.975 * (1 - float(tgt["hp"]) / float(tgt["maxHp"]))) if tgt != null else 3.1
	return action["power"]

## Mirrors ACTION_DYNAMIC.execute's critFn closure.
static func eval_crit_fn(action: Dictionary, tgt) -> float:
	if action.get("critFnId") == "execute":
		return 0.65 if (tgt != null and float(tgt["hp"]) / float(tgt["maxHp"]) <= 0.30) else -1.0
	return 0.0

## Real ROSTER/ARCH/EQUIPMENT storage -- core.js itself only passes these
## through (nothing in the combat loop reads them directly; that's
## buildParty/buildEnemies, farroad-ui.js, a later milestone), but a parity
## test needs them to build units from genuine content instead of inventing
## stat blocks.
static var ROSTER: Array = []
static var ARCH: Dictionary = {}
static var EQUIPMENT: Dictionary = {}
## The 8-direction {label, mul, waveCount, unlockEvery, bossName, affinity}
## table (Step 3h, EXPEDITION) -- exported alongside the other content
## tables by export-content.js, same source (content-pipeline.js's
## compileDirectionConfig) the real JS reads via
## window.FarroadContent.DIRECTION_CONFIG.
static var DIRECTION_CONFIG: Dictionary = {}
## The per-companion 5-stage {story, powerFraction, isBoss} quest table
## (Step 3i, QUESTS/dungeons) -- same export-content.js/content-pipeline.js
## source as DIRECTION_CONFIG, just not previously selected.
static var QUEST_LINES: Dictionary = {}

## Loads godot-project/data/content.json (export-content.js's output) --
## the Godot-side counterpart to core.js reading window.FarroadContent.
static func load_real_content(path: String = "res://data/content.json") -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null:
		return false
	register_actions(parsed.get("ACTIONS", {}))
	merge_action_dynamic()
	ARCH = parsed.get("ARCH", {})
	ROSTER = parsed.get("ROSTER", [])
	EQUIPMENT = parsed.get("EQUIPMENT", {})
	DIRECTION_CONFIG = parsed.get("DIRECTION_CONFIG", {})
	QUEST_LINES = parsed.get("QUEST_LINES", {})
	register_bonus_eligible(equippable() + CHARGE_ACTIONS)
	return true

## Finds a ROSTER entry by id -- mirrors the small inline
## `C.ROSTER.forEach(function(r){if(r.id===uid)def=r;})` lookup pattern used
## throughout farroad-ui.js.
static func roster_by_id(id: String) -> Variant:
	for r in ROSTER:
		if r["id"] == id:
			return r
	return null

## ===== Milestone 3 prep: a handful of small farroad-core.js pieces Milestone 1
## never needed (combat-resolution didn't touch enemy-building/equipment) but
## FarroadProgression.gd's build_enemies/build_party (mirroring buildEnemies/
## buildParty, farroad-ui.js) do. =====

## Post-wave-19 enemy archetype rotation (farroad-core.js:878, `var ROT=...`).
const ROT: Array[String] = ["wolf", "knight", "hound", "ox", "priest", "shrike"]

## Mirrors dmgTakenMul (farroad-core.js:887-888) -- the DEF/evade-vs-reference
## multiplier buildEnemies sizes a body's HP pool against.
static func dmg_taken_mul(a: Dictionary) -> float:
	var k := 25.0
	var ref_def := 12.0
	var ref_evade := 0.05
	return ((k / (k + a["def"])) / (k / (k + ref_def))) * ((1.0 - a["evade"]) / (1.0 - ref_evade))

## Mirrors EQUIPMENT_SLOTS/EQUIP_SPD_PENALTY_BASE (farroad-core.js:54,65).
const EQUIPMENT_SLOTS: Array[String] = ["head", "body", "legs", "hand1", "hand2"]
const EQUIP_SPD_PENALTY_BASE := 1.5

## The full 79-id gambit condition catalog (Step 1c already ported every
## resolve_condition/cond_label case; this is just the enumerable id LIST
## mirroring C.CONDITIONS.map(c=>c.id), needed by FarroadProgression's
## random-drop pool -- extracted programmatically from the real
## farroad-core.js's own CONDITIONS array, not hand-typed, to guarantee it
## matches exactly). "none" excluded from drop pools by callers, same as
## the real JS's own `CONDITIONS.filter(c=>c.id!=='none')`.
const ALL_CONDITION_IDS: Array[String] = ["none", "foe_any", "foe_lowest_hp", "foe_highest_hp",
	"foe_hp_gte_70", "foe_hp_lte_30", "foe_armoured", "foe_warded",
	"foe_weak_fire", "foe_weak_water", "foe_weak_earth", "foe_weak_air", "foe_weak_light", "foe_weak_dark",
	"foe_fast", "foe_3plus",
	"foe_charging", "foe_softest_def", "foe_softest_res", "foe_most_dangerous", "foe_acts_next",
	"foe_healer_present", "foe_pack_hurt", "foe_pack_healthy", "foe_mostly_weakened",
	"foe_isolated", "foe_2plus", "foe_lacks_debuff", "foe_not_weakened", "ally_hp_lte_60",
	"ally_hp_lte_30", "ally_lowest_hp", "ally_is_dead", "ally_lacks_buff", "self_hp_lte_50",
	"self_first_turn", "foe_hp_gte_10", "foe_hp_lte_10", "ally_hp_gte_10", "ally_hp_lte_10",
	"self_hp_gte_10", "self_hp_lte_10", "foe_hp_gte_20", "foe_hp_lte_20", "ally_hp_gte_20",
	"ally_hp_lte_20", "self_hp_gte_20", "self_hp_lte_20", "foe_hp_gte_30", "ally_hp_gte_30",
	"self_hp_gte_30", "self_hp_lte_30", "foe_hp_gte_40", "foe_hp_lte_40", "ally_hp_gte_40",
	"ally_hp_lte_40", "self_hp_gte_40", "self_hp_lte_40", "foe_hp_gte_50", "foe_hp_lte_50",
	"ally_hp_gte_50", "ally_hp_lte_50", "self_hp_gte_50", "foe_hp_gte_60", "foe_hp_lte_60",
	"ally_hp_gte_60", "self_hp_gte_60", "self_hp_lte_60", "foe_hp_lte_70", "ally_hp_gte_70",
	"ally_hp_lte_70", "self_hp_gte_70", "self_hp_lte_70", "foe_hp_gte_80", "foe_hp_lte_80",
	"ally_hp_gte_80", "ally_hp_lte_80", "self_hp_gte_80", "self_hp_lte_80", "foe_hp_gte_90",
	"foe_hp_lte_90", "ally_hp_gte_90", "ally_hp_lte_90", "self_hp_gte_90", "self_hp_lte_90"]

## ===== Step 1d: rarity + Lore-bonus system (mirrors farroad-core.js:18-41,
## 321-519) =====
const RARITY_POWER_MUL := {"common": 1.00, "rare": 1.25, "legendary": 1.55}
const RARITY_COST_MUL := {"common": 1.00, "rare": 1.60, "legendary": 2.40}
const SWIFT_CEIL := 3.0
const SWIFT_DECAY := 0.88
const BONUS_COST_BROAD := 10
const CHARGE_UP_COST := 12
const CHARGE_THRIFT := 15
const CHARGE_COST_MIN := 40
const CHARGE_COST_MAX := 400
const BUFFS: Array[String] = ["hasted", "warded", "taunted", "surging", "bracing", "regen", "blurred"]

static func is_buff_status(s) -> bool:
	return BUFFS.has(s)

## Mirrors BONUSES (farroad-core.js:388-409) -- 9 display entries (name `n`,
## description `d`; `potent` also carries `mag: true`, unused by any real UI
## logic -- confirmed via grep of farroad-ui.js -- kept anyway for an exact
## port). `bonus_applies`/`apply_bonuses` (below) already have the real
## match-statement LOGIC ported since Milestone 1 Step 1d; this is only the
## LORE screen's display table, extracted programmatically (a throwaway node
## script loading the real farroad-core.js via the same vm-sandbox technique
## parity-reference.js uses, then JSON.stringify(C.BONUSES)) to guarantee an
## exact match rather than hand-typed copy risk -- same discipline
## ALL_CONDITION_IDS used. `weighty` is correctly absent from both this
## table and `bonus_applies` below -- it was merged into `potent` in v2.4
## (farroad-core.js:368-376); `apply_bonuses` still honors old stacks for
## backward compatibility, it just isn't newly purchasable.
const BONUSES := {
	"swift": {"n": "Swift", "d": "corrective — big gains below ×1.00 initiative, little above it"},
	"potent": {"n": "Potent", "d": "+15% to whatever it does — damage or healing", "mag": true},
	"lasting": {"n": "Lasting", "d": "+1 turn on the status it applies — nothing if it applies none"},
	"deepening": {"n": "Deepening", "d": "debuff bites 25% harder — dead on buffs and on damage"},
	"surge": {"n": "Surge", "d": "+10 charge gain — dead on charge actions themselves"},
	"piercing": {"n": "Piercing", "d": "+0.15 pierce — DEF for a physical action, RES for a magic one; worth most vs a target strong in that stat"},
	"broad": {"n": "Broad", "d": "single target → full AoE (whole party or whole enemy side) — dead on a self or already-multi action"},
	"cleansing": {"n": "Cleansing", "d": "the heal also strips one debuff — dead if it does not heal"},
	"thrifty": {"n": "Thrifty", "d": "−15 charge cost — CHARGE ACTIONS ONLY, fires more often"},
}

## Mirrors actionBonusTotal (farroad-core.js:341-343).
static func action_bonus_total(b: Dictionary) -> int:
	var t := 0
	for bid in b.keys():
		if bid != "broad":
			t += int(b.get(bid, 0))
	return t

## Mirrors bonusPrice (farroad-core.js:356-359). v2.13: flat cost -- no more
## rarity multiplier (RARITY_COST_MUL is kept defined, just unreferenced
## here, for any other reader) and no more triangular per-stack scaling
## (total_on_action is kept as a parameter for call-site compatibility, but
## no longer read) -- every non-broad stack costs a flat 1 Lore, matching
## what the OLD formula's own very first purchase already cost (0+1=1).
static func bonus_price(a, bid: String, total_on_action: int) -> int:
	if bid == "broad":
		return BONUS_COST_BROAD
	return 1

## Mirrors bonusApplies (farroad-core.js:423-451).
static func bonus_applies(a, bid: String) -> bool:
	if a == null:
		return false
	# NOTE: GDScript's bool(x) constructor throws on x == null (a real
	# runtime gap vs JS's !!x, which is always safe) -- "x else false"
	# below relies on `if`'s native truthy/falsy coercion instead, which
	# handles null (and 0/""/empty) the same way JS's falsy values do.
	match bid:
		"swift": return true
		"potent": return true if a.get("power") else false
		"lasting": return true if a.get("applies") else false
		"deepening": return (true if a.get("applies") else false) and not is_buff_status(a.get("applies"))
		"surge": return false if a.get("isCharge") else true
		"piercing": return (true if a.get("power") else false) and not (true if a.get("heal") else false)
		"broad": return a.get("tk") == "foe" or a.get("tk") == "ally"
		"cleansing": return true if a.get("heal") else false
		"thrifty": return true if a.get("isCharge") else false
	return false

## PRISTINE/snapshot (farroad-core.js:454-457) is normally keyed off the
## hardcoded EQUIPPABLE.concat(CHARGE_ACTIONS) whitelist -- that whitelist
## isn't ported yet (it comes from the real CSV roster, deferred per the
## plan), so register_bonus_eligible() stands in for it: the test harness
## explicitly names which registered ids are Lore-eligible, the same role
## the whitelist plays for real content later.
static var PRISTINE = null
static var BONUS_ELIGIBLE: Array = []

static func register_bonus_eligible(ids: Array) -> void:
	BONUS_ELIGIBLE = ids.duplicate()
	PRISTINE = null

static func snapshot() -> void:
	if PRISTINE != null:
		return
	PRISTINE = {}
	for id in BONUS_ELIGIBLE:
		if ACTIONS.has(id):
			var a = ACTIONS[id]
			PRISTINE[id] = {"power": a.get("power"), "rank": a.get("rank"), "charge": a.get("charge"),
				"defPierce": a.get("defPierce"), "critBonus": a.get("critBonus"),
				"turns": a.get("turns"), "chargeCost": a.get("chargeCost")}

static func pristine_of(id: String):
	snapshot()
	return PRISTINE.get(id)

## Mirrors applyBonuses (farroad-core.js:458-496) -- resets every eligible
## action to PRISTINE, then re-applies `map` on top, exactly like the JS:
## a full replay from baseline every call, never a compounding mutation.
static func apply_bonuses(map: Dictionary) -> void:
	snapshot()
	for id in PRISTINE.keys():
		var a = ACTIONS[id]
		var p = PRISTINE[id]
		for k in p.keys():
			a[k] = p[k]
	for aid in map.keys():
		var b = map[aid]
		var a = ACTIONS.get(aid)
		if a == null or b == null:
			continue
		if b.get("swift"):
			var ini: float = 1.0 / a["rank"]
			ini = SWIFT_CEIL - (SWIFT_CEIL - ini) * pow(SWIFT_DECAY, b["swift"])
			a["rank"] = 1.0 / ini
		if b.get("weighty"):
			a["power"] = a["power"] * (1 + 0.12 * b["weighty"])
		if b.get("piercing"):
			a["defPierce"] = min(0.85, a.get("defPierce", 0.0) + 0.15 * b["piercing"])
		if b.get("surge") and not a.get("isCharge"):
			a["charge"] = a.get("charge", 0.0) + 10 * b["surge"]
		if b.get("lasting") and a.get("applies"):
			a["turns"] = a.get("turns", 3) + b["lasting"]
		if b.get("potent") and a.get("power"):
			a["power"] = a["power"] * (1 + 0.15 * b["potent"])
		if b.get("cleansing") and a.get("heal"):
			a["cleanse"] = a.get("cleanse", 0) + b["cleansing"]
		if b.get("broad"):
			if a.get("tk") == "ally": a["tk"] = "allAllies"
			elif a.get("tk") == "foe": a["tk"] = "allFoes"
		if b.get("deepening") and a.get("applies") and not is_buff_status(a.get("applies")):
			a["deepen"] = a.get("deepen", 0.0) + 0.25 * b["deepening"]
		if a.get("isCharge"):
			var ups := 0
			for k in b.keys():
				if k != "thrifty":
					ups += int(b[k])
			var computed: int = CHARGE_FULL + CHARGE_UP_COST * ups - CHARGE_THRIFT * int(b.get("thrifty", 0))
			a["chargeCost"] = max(CHARGE_COST_MIN, min(CHARGE_COST_MAX, computed))

## Mirrors bonusSpend (farroad-core.js:513-519). v2.13: flat cost -- no
## rarity multiplier, no triangular per-stack scaling (see bonus_price) --
## a non-broad stack now costs a flat 1 Lore regardless of the action's own
## rarity, so this no longer needs to look up ACTIONS[aid] at all. `map` can
## hold one action (`{aid: b}`, the per-action-pool idiom FarroadSave.gd's
## refund-diff and free_lore below already use) or several summed together.
static func bonus_spend(map: Dictionary) -> int:
	var n := 0
	for aid in map.keys():
		var b = map[aid]
		n += action_bonus_total(b) + int(b.get("broad", 0)) * BONUS_COST_BROAD
	return n

## ===== affinity system (mirrors farroad-core.js:88-139) =====
static func affinity_mul(raw: float) -> float:
	var s: float = -1.0 if raw < 0 else 1.0
	var a: float = min(abs(raw), AFFINITY_CAP)
	return s * 0.80 * log(1 + a) / log(1 + AFFINITY_CAP)

static func aff_term(atk_raw: float, def_raw: float) -> float:
	return (1 + affinity_mul(atk_raw)) * (1 - affinity_mul(def_raw))

static func aff_boost(a: float, b: float) -> float:
	return min(AFFINITY_BOOST_CAP, (1 + affinity_mul(a)) * (1 + affinity_mul(b)))

## 20-item batch, Group F: Ian's confirmed intent for spirit affinity is
## an ASYMMETRIC formula, not aff_boost's symmetric one -- the CASTER's
## own spirit still scales potency UP (unchanged direction), but the
## TARGET's own spirit should now scale potency DOWN (more spirit-
## resistant units shrug debuffs off more; more spirit-potent casters
## land them harder on others). Same caster-boost/target-resist SHAPE
## `aff_term` (below) already establishes for damage's own affinity
## factor -- not a new pattern, applied here to status potency for
## DEBUFFS specifically (apply_status branches on is_buff_status; buffs
## keep the original symmetric aff_boost unchanged, since an ally
## buffing a high-spirit teammate isn't what this ask was about).
static func aff_boost_resist(caster_spirit: float, target_spirit: float) -> float:
	return min(AFFINITY_BOOST_CAP, (1 + affinity_mul(caster_spirit)) * (1 - affinity_mul(target_spirit)))

static func affinity_factor(src: Dictionary, tgt: Dictionary, act: Dictionary) -> float:
	var m: float = 1.0
	if act.get("camp") == "atk":
		m *= aff_term(src["affinity"]["body"], tgt["affinity"]["body"])
	if act.get("element"):
		m *= aff_term(src["affinity"][act["element"]], tgt["affinity"][act["element"]])
	return m

## ===== status system (mirrors farroad-core.js:196-267) =====
static func new_st() -> Dictionary:
	var s := {}
	for id in ST:
		s[id] = 0
	return s

static func has(u: Dictionary, id: String) -> bool:
	return u["st"][id] > 0

static func mag_of(u: Dictionary, id: String) -> float:
	var st_mag: Dictionary = u.get("stMag", {})
	if st_mag.has(id) and st_mag[id] != null:
		return st_mag[id]
	return STATUS_BASE_MAG.get(id, 0.0)

static func apply_status(u: Dictionary, id: String, t: int, caster_spirit) -> void:
	u["st"][id] = t
	if not STATUS_BASE_MAG.has(id):
		return
	var base: float = STATUS_BASE_MAG[id]
	var caster_spirit_f: float = 0.0 if caster_spirit == null else caster_spirit
	var mul: float
	if is_buff_status(id):
		mul = aff_boost(caster_spirit_f, u["affinity"]["spirit"])
	else:
		mul = aff_boost_resist(caster_spirit_f, u["affinity"]["spirit"])
	if not u.has("stMag") or u["stMag"] == null:
		u["stMag"] = {}
	u["stMag"][id] = base * mul

static func eff_atk(u: Dictionary) -> float:
	return u["base"]["atk"] * (1 + (mag_of(u, "enfeebled") if has(u, "enfeebled") else 0.0))
static func eff_mag(u: Dictionary) -> float:
	return u["base"]["mag"] * (1 + (mag_of(u, "dulled") if has(u, "dulled") else 0.0))
static func eff_def(u: Dictionary) -> float:
	return u["base"]["def"] * (1 + (mag_of(u, "bracing") if has(u, "bracing") else 0.0)) * (1 + (mag_of(u, "sundered") if has(u, "sundered") else 0.0))
static func eff_res(u: Dictionary) -> float:
	return u["base"]["res"] * (1 + (mag_of(u, "frail") if has(u, "frail") else 0.0))
static func eff_evade(u: Dictionary) -> float:
	return u["base"]["evade"] + (mag_of(u, "blurred") if has(u, "blurred") else 0.0)
static func eff_charge_rate(u: Dictionary) -> float:
	return u["base"]["chargeRate"] * (1 + (mag_of(u, "surging") if has(u, "surging") else 0.0))

static func stat_by_key(u: Dictionary, key) -> float:
	if key == "mag": return eff_mag(u)
	if key == "def": return eff_def(u)
	if key == "res": return eff_res(u)
	if key == "spd": return u["base"]["spd"]
	# Group D (20-item batch): the 2 new starter charge actions scale off
	# the average of ATK and MAG, for a unit whose build doesn't lean
	# hard into either camp.
	if key == "avgAtkMag": return (eff_atk(u) + eff_mag(u)) / 2.0
	return eff_atk(u)

## ===== tick cost / mitigation (mirrors farroad-core.js:152-186) =====
static func clamp_f(x: float, lo: float, hi: float) -> float:
	return lo if x < lo else (hi if x > hi else x)

static func tc_raw(spd: float, rank: float) -> int:
	return max(1, int(round(TICK_K * rank / spd)))

static func row_spd_mul(u: Dictionary) -> float:
	return (1 + ROW_SPD) if u.get("row") == "front" else 1.0

static func row_out(u: Dictionary, p: bool) -> float:
	return ROW_PHYS if (u["isParty"] and p and u.get("row") == "back") else 1.0
static func row_in(u: Dictionary, p: bool) -> float:
	return ROW_PHYS if (u["isParty"] and p and u.get("row") == "back") else 1.0

static func tc_of(u: Dictionary, rank: float) -> int:
	var hasted_mul: float = (1 + mag_of(u, "hasted")) if has(u, "hasted") else 1.0
	var slowed_mul: float = (1 + mag_of(u, "slowed")) if has(u, "slowed") else 1.0
	return tc_raw(u["base"]["spd"] * row_spd_mul(u), rank * hasted_mul * slowed_mul)

static func level_curve(w: float) -> float:
	return max(1.0, 3.2 * sqrt(max(1.0, w)) - 2.2)
static func wave_scale(w: float) -> float:
	return 1 + (level_curve(w) - 1) / GAIN_RATIO
static func k_of(_level: int) -> float:
	return K_BASE * wave_scale(current_wave)
static func beat_ms(n: int) -> int:
	return 900 if n <= 14 else (700 if n <= 28 else (520 if n <= 44 else 400))
static func incoming_mul(u: Dictionary) -> float:
	return (1 + mag_of(u, "warded")) if has(u, "warded") else 1.0

## ===== unit/battle construction (mirrors farroad-core.js:666-680) =====
static func default_affinity() -> Dictionary:
	return {"fire": 0.0, "water": 0.0, "earth": 0.0, "air": 0.0, "light": 0.0,
		"dark": 0.0, "body": 0.0, "spirit": 0.0}

static func make_unit(cfg: Dictionary) -> Dictionary:
	var d := {"hp": 100.0, "atk": 10.0, "mag": 10.0, "def": 10.0, "res": 10.0,
		"spd": 100.0, "atkCrit": 0.05, "magCrit": 0.05, "chargeRate": 1.0, "evade": 0.03}
	for k in cfg.get("stats", {}).keys():
		d[k] = cfg["stats"][k]
	var aff := default_affinity()
	for ak in cfg.get("affinity", {}).keys():
		aff[ak] = cfg["affinity"][ak]
	var max_hp = cfg["maxHp"] if cfg.get("maxHp") != null else d["hp"]
	var hp = cfg["hp"] if cfg.get("hp") != null else d["hp"]
	return {
		"id": cfg["id"], "name": cfg["name"], "isParty": bool(cfg.get("isParty", false)),
		"level": cfg.get("level", 1), "slotIndex": cfg.get("slotIndex", 0), "base": d,
		"maxHp": max_hp, "hp": hp, "charge": cfg.get("charge", 0.0),
		"chargeAction": cfg.get("chargeAction"),
		"slots": cfg.get("slots", [{"cond": "none", "action": "strike"}, {"cond": "none", "action": "strike"}]),
		"st": new_st(), "stMag": {}, "affinity": aff, "nextActAt": 0, "alternateFlag": 0,
		"turnsTaken": 0, "enrageApplied": 0, "row": cfg.get("row"), "arch": cfg.get("arch"),
		"thorns": cfg.get("thorns", 0.0), "isBoss": bool(cfg.get("isBoss", false))}

static func make_battle(units: Array, opts: Dictionary = {}) -> Dictionary:
	var b := {"units": units, "t": 0, "beat": 0, "elapsedMs": 0, "log": [], "over": null,
		"rng": opts.get("rng") if opts.get("rng") != null else make_rng(1),
		"det": bool(opts.get("deterministic", false)), "gambitMode": "topdown",
		"smartHeal": true, "enrage": bool(opts.get("enrage", false)), "enrageN": 0}
	for u in units:
		u["st"] = new_st(); u["stMag"] = {}
		u["nextActAt"] = tc_of(u, 1.00); u["turnsTaken"] = 0; u["enrageApplied"] = 0; u["alternateFlag"] = 0
	return b

## ===== targeting / threat (mirrors farroad-core.js:520-545, 660-665) =====
static func living(b: Dictionary, is_party: bool, want_same: bool) -> Array:
	var o := []
	for u in b["units"]:
		if u["hp"] > 0 and (u["isParty"] == is_party) == want_same:
			o.append(u)
	return o
static func foes(b: Dictionary, u: Dictionary) -> Array:
	return living(b, u["isParty"], false)
static func allies(b: Dictionary, u: Dictionary) -> Array:
	return living(b, u["isParty"], true)
static func dead_allies(b: Dictionary, u: Dictionary) -> Array:
	var o := []
	for x in b["units"]:
		if x["hp"] <= 0 and x["isParty"] == u["isParty"]:
			o.append(x)
	return o
static func hp_pct(u: Dictionary) -> float:
	return float(u["hp"]) / float(u["maxHp"])
static func by_lowest_hp(l: Array) -> Variant:
	var best = null
	for u in l:
		if best == null or hp_pct(u) < hp_pct(best):
			best = u
	return best
static func by_highest_hp(l: Array) -> Variant:
	var best = null
	for u in l:
		if best == null or hp_pct(u) > hp_pct(best):
			best = u
	return best

## PREF (farroad-core.js:528-530) as a match, not a dict-of-lambdas --
## same per-archetype weighting, simpler in GDScript.
static func pref_weight(arch, u: Dictionary, hp: float) -> float:
	match arch:
		"wolf": return 1 + 1.5 * (1 - hp)
		"knight": return 2.5 if u.get("row") == "front" else 0.4
		"hound": return 2.2 if u.get("row") == "back" else 0.6
		"ox": return 1.0
		"priest": return 1 + 1.0 * (1 - hp)
		"shrike": return 1.0
	return 1.0
static func has_pref(arch) -> bool:
	return arch in ["wolf", "knight", "hound", "ox", "priest", "shrike"]

static func threat_of(src: Dictionary, u: Dictionary) -> float:
	var w: float = ROWMUL.get(u.get("row", "front"), 1.0)
	if has(u, "taunted"):
		w *= 8
	if has_pref(src.get("arch")):
		w *= pref_weight(src.get("arch"), u, hp_pct(u))
	return max(0.01, w)

static func threat_table(b: Dictionary, src: Dictionary) -> Array:
	var f := foes(b, src)
	var o := []
	var tot: float = 0.0
	for u in f:
		var w: float = threat_of(src, u)
		o.append({"u": u, "w": w})
		tot += w
	for entry in o:
		entry["p"] = entry["w"] / tot
	return o

static func def_foe(b: Dictionary, u: Dictionary) -> Variant:
	var f := foes(b, u)
	if f.is_empty():
		return null
	if not u["isParty"]:
		var t := threat_table(b, u)
		if b["det"]:
			var bi := 0
			for i in range(1, t.size()):
				if t[i]["w"] > t[bi]["w"]:
					bi = i
			return t[bi]["u"]
		var r: float = b["rng"].next()
		var acc: float = 0.0
		for entry in t:
			acc += entry["p"]
			if r <= acc:
				return entry["u"]
		return t[t.size() - 1]["u"]
	for x in f:
		if has(x, "taunted"):
			return x
	if b["det"] or f.size() == 1:
		return f[0]
	return f[b["rng"].next_int(f.size())]

static func resolve_target(act: Dictionary, ct, u: Dictionary, b: Dictionary) -> Variant:
	var k = act.get("tk")
	if k == "self":
		return u
	if k == "foe" or k == "allFoes":
		if ct != null and ct["isParty"] != u["isParty"] and ct["hp"] > 0:
			return ct
		return def_foe(b, u)
	if k == "ally" or k == "allAllies":
		if ct != null and ct["isParty"] == u["isParty"] and ct["hp"] > 0:
			return ct
		return by_lowest_hp(allies(b, u))
	if k == "deadAlly":
		if ct != null and ct["isParty"] == u["isParty"] and ct["hp"] <= 0:
			return ct
		var d := dead_allies(b, u)
		return d[0] if not d.is_empty() else null
	return null

## ===== action selection (mirrors farroad-core.js:696-730) =====
## Condition list reduced to just 'none' for this step -- full ~40-condition
## catalog is Step 1c (see plan). needs_heal/action_held_by_earlier_fielded
## are the real logic (not stubs), since even 'none'-only content exercises
## chooseFrom's allNone branch, which uses both.
static func needs_heal(b: Dictionary, u: Dictionary) -> bool:
	for a in allies(b, u):
		if a["hp"] < a["maxHp"]:
			return true
	return false

static func action_held_by_earlier_fielded(b: Dictionary, u: Dictionary, action_id: String) -> bool:
	if not u["isParty"] or STARTER_ACTIONS.has(action_id):
		return false
	for o in b["units"]:
		if o == u or not o["isParty"] or o["slotIndex"] >= u["slotIndex"]:
			continue
		for slot in o["slots"]:
			if slot["action"] == action_id:
				return true
	return false

## ===== Step 1c: gambit conditions (mirrors CONDITIONS/condById,
## farroad-core.js:546-658) =====
## 30 explicit conditions + a generated 10%-ladder (10-90, both directions,
## for foe/ally/self) = 79 total. 5 of the 30 explicit ones (foe_hp_gte_70,
## foe_hp_lte_30, ally_hp_lte_60/30, self_hp_lte_50) are IDENTICALLY SHAPED
## to what the generated ladder would produce for the same group/cmp/pct
## (confirmed against the JS source -- the ladder generator's own
## existing-id guard exists specifically because they'd be exact
## duplicates otherwise), so this port handles all 54 percentile-shaped
## ids (5 legacy + 49 generated) through ONE generic path instead of
## hand-duplicating them, and only the 25 genuinely bespoke ids get their
## own match branch -- the same DRY structure the JS source itself uses.
static func any_debuff(u: Dictionary) -> bool:
	for d in DEBUFFS:
		if has(u, d):
			return true
	return false

## Parses e.g. "foe_hp_gte_70" -> {matched:true, group:"foe", cmp:"gte", pct:70}.
## String-parsed rather than regex -- simpler and just as robust for this
## fixed, small set of prefixes.
static func _parse_pct_condition(cond_id: String) -> Dictionary:
	for group in ["foe", "ally", "self"]:
		for cmp in ["gte", "lte"]:
			var prefix: String = group + "_hp_" + cmp + "_"
			if cond_id.begins_with(prefix):
				var suffix: String = cond_id.substr(prefix.length())
				if suffix.is_valid_int():
					return {"matched": true, "group": group, "cmp": cmp, "pct": suffix.to_int()}
	return {"matched": false}

static func _pct_cmp(x: float, cmp: String, v: float) -> bool:
	return x >= v if cmp == "gte" else x <= v

## Mirrors foeTest (farroad-core.js:642-644).
static func cond_foe_pct(b: Dictionary, u: Dictionary, cmp: String, v: float) -> Dictionary:
	for x in foes(b, u):
		if _pct_cmp(hp_pct(x), cmp, v):
			return {"ok": true, "target": x}
	return {"ok": false, "target": null}
## Mirrors allyTest (farroad-core.js:645-647).
static func cond_ally_pct(b: Dictionary, u: Dictionary, cmp: String, v: float) -> Dictionary:
	var c := []
	for x in allies(b, u):
		if _pct_cmp(hp_pct(x), cmp, v):
			c.append(x)
	var t = by_lowest_hp(c)
	return {"ok": t != null, "target": t}
## Mirrors selfTest (farroad-core.js:648).
static func cond_self_pct(u: Dictionary, cmp: String, v: float) -> Dictionary:
	return {"ok": _pct_cmp(hp_pct(u), cmp, v), "target": u}

## Mirrors condById(id).resolve(u,b,act) -- the unknown-id fallback matches
## condById's own fallback (CONDITIONS[0], i.e. 'none': always true, no
## target).
static func resolve_condition(cond_id: String, u: Dictionary, b: Dictionary, act) -> Dictionary:
	if cond_id == "none":
		return {"ok": true, "target": null}
	var pct := _parse_pct_condition(cond_id)
	if pct["matched"]:
		var v: float = float(pct["pct"]) / 100.0
		match pct["group"]:
			"foe": return cond_foe_pct(b, u, pct["cmp"], v)
			"ally": return cond_ally_pct(b, u, pct["cmp"], v)
			"self": return cond_self_pct(u, pct["cmp"], v)
	match cond_id:
		"foe_any":
			var t = def_foe(b, u)
			return {"ok": t != null, "target": t}
		"foe_lowest_hp":
			var t = by_lowest_hp(foes(b, u))
			return {"ok": t != null, "target": t}
		"foe_highest_hp":
			var t = by_highest_hp(foes(b, u))
			return {"ok": t != null, "target": t}
		"foe_armoured":
			# Reworded from a caster-relative 1.4x-margin threshold to a
			# plain self-relative comparison -- a foe whose own DEF simply
			# outweighs its own RES, no margin, same shape as the
			# Status-popup-only _def_res_hint (BattlePresenter.gd) just
			# applied to the target instead of the caster.
			for x in foes(b, u):
				if eff_def(x) > eff_res(x):
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_warded":
			for x in foes(b, u):
				if eff_res(x) > eff_def(x):
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		# "Weak to <element>" -- a NEGATIVE raw affinity on the TARGET's
		# own affinity[element] is exactly what aff_term's
		# (1-affinity_mul(def_raw)) factor reads as "takes more damage
		# from this element" (a negative raw -> a negative affinity_mul
		# -> defender factor > 1), so raw<0 is the correct, already-
		# established sign convention for "weak to X", not a new one
		# invented for this condition. Scoped to the 6 THEMED elemental
		# axes (fire/water/earth/air/light/dark, the same set
		# DIRECTION_CONFIG's own per-direction affinity theming already
		# uses) -- body/spirit are generic physical/healing modifiers,
		# not an elemental "weakness" in the same legible sense.
		"foe_weak_fire":
			for x in foes(b, u):
				if x["affinity"]["fire"] < 0:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_weak_water":
			for x in foes(b, u):
				if x["affinity"]["water"] < 0:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_weak_earth":
			for x in foes(b, u):
				if x["affinity"]["earth"] < 0:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_weak_air":
			for x in foes(b, u):
				if x["affinity"]["air"] < 0:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_weak_light":
			for x in foes(b, u):
				if x["affinity"]["light"] < 0:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_weak_dark":
			for x in foes(b, u):
				if x["affinity"]["dark"] < 0:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_fast":
			for x in foes(b, u):
				if x["base"]["spd"] > u["base"]["spd"]:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_3plus":
			var f := foes(b, u)
			return {"ok": f.size() >= 3, "target": def_foe(b, u)}
		"foe_charging":
			for x in foes(b, u):
				if x.get("chargeAction") and x["charge"] >= 70:
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_softest_def":
			var f := foes(b, u)
			if f.size() < 2: return {"ok": false, "target": null}
			var t = f[0]
			for i in range(1, f.size()):
				if eff_def(f[i]) < eff_def(t): t = f[i]
			return {"ok": true, "target": t}
		"foe_softest_res":
			var f := foes(b, u)
			if f.size() < 2: return {"ok": false, "target": null}
			var t = f[0]
			for i in range(1, f.size()):
				if eff_res(f[i]) < eff_res(t): t = f[i]
			return {"ok": true, "target": t}
		"foe_most_dangerous":
			var f := foes(b, u)
			if f.is_empty(): return {"ok": false, "target": null}
			var t = f[0]
			for i in range(1, f.size()):
				if eff_atk(f[i]) > eff_atk(t): t = f[i]
			return {"ok": true, "target": t}
		"foe_acts_next":
			var f := foes(b, u)
			if f.is_empty(): return {"ok": false, "target": null}
			var t = f[0]
			for i in range(1, f.size()):
				if f[i]["nextActAt"] < t["nextActAt"]: t = f[i]
			return {"ok": true, "target": t}
		"foe_healer_present":
			for x in foes(b, u):
				for slot in x.get("slots", []):
					var a = ACTIONS.get(slot["action"])
					if a != null and a.get("heal"):
						return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_pack_hurt":
			var f := foes(b, u)
			if f.size() < 2: return {"ok": false, "target": null}
			for x in f:
				if hp_pct(x) >= 0.50: return {"ok": false, "target": null}
			return {"ok": true, "target": by_lowest_hp(f)}
		"foe_pack_healthy":
			var f := foes(b, u)
			if f.size() < 2: return {"ok": false, "target": null}
			for x in f:
				if hp_pct(x) < 0.70: return {"ok": false, "target": null}
			return {"ok": true, "target": by_highest_hp(f)}
		"foe_mostly_weakened":
			var f := foes(b, u)
			if f.size() < 2: return {"ok": false, "target": null}
			var n := 0
			for x in f:
				if any_debuff(x): n += 1
			if n * 2 <= f.size(): return {"ok": false, "target": null}
			for x in f:
				if not any_debuff(x): return {"ok": true, "target": x}
			return {"ok": true, "target": def_foe(b, u)}
		"foe_isolated":
			var f := foes(b, u)
			return {"ok": f.size() == 1, "target": (f[0] if not f.is_empty() else null)}
		"foe_2plus":
			var f := foes(b, u)
			return {"ok": f.size() >= 2, "target": def_foe(b, u)}
		"foe_lacks_debuff":
			var f := foes(b, u)
			if act == null or not act.get("applies"):
				var t = def_foe(b, u)
				return {"ok": t != null, "target": t}
			for x in f:
				if not has(x, act["applies"]):
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"foe_not_weakened":
			for x in foes(b, u):
				if not any_debuff(x):
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"ally_lowest_hp":
			var t = by_lowest_hp(allies(b, u))
			return {"ok": t != null, "target": t}
		"ally_is_dead":
			var d := dead_allies(b, u)
			return {"ok": not d.is_empty(), "target": (d[0] if not d.is_empty() else null)}
		"ally_lacks_buff":
			var a := allies(b, u)
			if act == null or not act.get("applies"):
				var t = by_lowest_hp(a)
				return {"ok": t != null, "target": t}
			for x in a:
				if not has(x, act["applies"]):
					return {"ok": true, "target": x}
			return {"ok": false, "target": null}
		"self_first_turn":
			return {"ok": u["turnsTaken"] == 0, "target": u}
	# Unknown id -- mirror condById's fallback to CONDITIONS[0] ('none').
	return {"ok": true, "target": null}

## Mirrors each C(id,label,...)'s label text, for the 'via' log string.
static func cond_label(cond_id: String) -> String:
	var pct := _parse_pct_condition(cond_id)
	if pct["matched"]:
		var group_display: String = {"foe": "Foe", "ally": "Ally", "self": "Self"}[pct["group"]]
		var symbol: String = "≥" if pct["cmp"] == "gte" else "≤"
		return "%s: HP %s %d%%" % [group_display, symbol, pct["pct"]]
	match cond_id:
		"none": return "— always —"
		"foe_any": return "Foe: any"
		"foe_lowest_hp": return "Foe: lowest HP"
		"foe_highest_hp": return "Foe: highest HP"
		"foe_armoured": return "Foe: armoured (DEF > RES)"
		"foe_warded": return "Foe: resistant (RES > DEF)"
		"foe_weak_fire": return "Foe: weak to Fire"
		"foe_weak_water": return "Foe: weak to Water"
		"foe_weak_earth": return "Foe: weak to Earth"
		"foe_weak_air": return "Foe: weak to Air"
		"foe_weak_light": return "Foe: weak to Light"
		"foe_weak_dark": return "Foe: weak to Dark"
		"foe_fast": return "Foe: faster than you"
		"foe_3plus": return "Foe: 3+ present"
		"foe_charging": return "Foe: charge ≥ 70%"
		"foe_softest_def": return "Foe: softest DEF of the group"
		"foe_softest_res": return "Foe: softest RES of the group"
		"foe_most_dangerous": return "Foe: hardest hitter"
		"foe_acts_next": return "Foe: acts next"
		"foe_healer_present": return "Foes: a healer among them"
		"foe_pack_hurt": return "Foes: ALL below 50% HP"
		"foe_pack_healthy": return "Foes: NONE below 70% HP"
		"foe_mostly_weakened": return "Foes: most already weakened"
		"foe_isolated": return "Foe: last one standing"
		"foe_2plus": return "Foe: 2+ present"
		"foe_lacks_debuff": return "Foe: lacks this debuff"
		"foe_not_weakened": return "Foe: not weakened"
		"ally_lowest_hp": return "Ally: lowest HP"
		"ally_is_dead": return "Ally: is down"
		"ally_lacks_buff": return "Ally: lacks this buff"
		"self_first_turn": return "Self: first turn"
	return "— always —"

static func choose_from(u: Dictionary, b: Dictionary, state: Dictionary) -> Dictionary:
	if u.get("chargeAction") and state["charge"] >= cost_of_charge(ACTIONS.get(u["chargeAction"])):
		return {"actionId": u["chargeAction"], "target": null, "via": "charge full -> override"}
	var s: Array = u["slots"]
	var n: int = s.size()
	var all_none := true
	for slot in s:
		if slot["cond"] != "none":
			all_none = false
	if all_none:
		var idx: int = state["alternateFlag"] % n
		state["alternateFlag"] = (state["alternateFlag"] + 1) % n
		var a0 = ACTIONS.get(s[idx]["action"])
		if b["smartHeal"] and a0 != null and a0.get("heal") and not needs_heal(b, u):
			return {"actionId": "strike", "target": null, "via": "alternate (heal skipped)"}
		if b["smartHeal"] and a0 != null and a0.get("tk") == "deadAlly" and dead_allies(b, u).is_empty():
			return {"actionId": "strike", "target": null, "via": "alternate (nobody down)"}
		if action_held_by_earlier_fielded(b, u, s[idx]["action"]):
			return {"actionId": "strike", "target": null, "via": "alternate (shared with an earlier-fielded unit)"}
		return {"actionId": s[idx]["action"], "target": null, "via": "alternate -> slot %d" % (idx + 1)}
	for i in range(n):
		var act = ACTIONS.get(s[i]["action"])
		if action_held_by_earlier_fielded(b, u, s[i]["action"]):
			continue
		var r := resolve_condition(s[i]["cond"], u, b, act)
		if r["ok"]:
			return {"actionId": s[i]["action"], "target": r["target"],
				"via": "slot %d [%s] ✓" % [i + 1, cond_label(s[i]["cond"])]}
	return {"actionId": "strike", "target": null, "via": "all false -> implicit Strike"}

static func choose(u: Dictionary, b: Dictionary) -> Dictionary:
	var st := {"charge": u["charge"], "alternateFlag": u["alternateFlag"]}
	var r := choose_from(u, b, st)
	u["alternateFlag"] = st["alternateFlag"]
	return r

## ===== damage/heal resolution (mirrors farroad-core.js:731-767) =====
static func resolve_hit(src: Dictionary, tgt: Dictionary, act: Dictionary, b: Dictionary, pv: float) -> Dictionary:
	var det: bool = b["det"]
	var rng = b["rng"]
	var is_phys: bool = act.get("camp") == "atk"
	var o := {"isPhys": is_phys, "evaded": false, "crit": false,
		"actionName": act["name"], "targetName": tgt["name"]}
	o["evadeChance"] = clamp_f(eff_evade(tgt) + (0.30 if has(src, "blinded") else 0.0), 0, CAP_EVADE + 0.30)
	o["evadeRoll"] = 1.0 if det else rng.next()
	if o["evadeRoll"] < o["evadeChance"]:
		o["evaded"] = true
		o["damage"] = 0
		return o
	var cb: float = act.get("critBonus", 0.0) + (eval_crit_fn(act, tgt) if act.get("critFnId") else 0.0)
	o["critChance"] = clamp_f((src["base"]["atkCrit"] if is_phys else src["base"]["magCrit"]) + cb, 0, CAP_CRIT)
	o["critRoll"] = 1.0 if det else rng.next()
	o["crit"] = o["critRoll"] < o["critChance"]
	o["K"] = k_of(src["level"])
	o["off"] = stat_by_key(src, act["scaleStat"]) if act.get("scaleStat") else (eff_atk(src) if is_phys else eff_mag(src))
	o["defRaw"] = eff_def(tgt) if is_phys else eff_res(tgt)
	o["defEff"] = o["defRaw"] * (1 - act.get("defPierce", 0.0))
	o["mit"] = o["K"] / (o["K"] + o["defEff"])
	o["affMul"] = affinity_factor(src, tgt, act)
	o["power"] = pv
	o["base"] = pv * o["off"] * o["mit"] * o["affMul"]
	var d: float = o["base"]
	o["afterVariance"] = d
	if o["crit"]:
		d *= CRIT_MUL
	o["wardMul"] = incoming_mul(tgt)
	d *= o["wardMul"]
	o["rowOut"] = row_out(src, is_phys)
	o["rowIn"] = row_in(tgt, is_phys)
	d *= o["rowOut"] * o["rowIn"]
	o["preFloor"] = d
	o["damage"] = max(1, floori(d))
	return o

static func heal_for(src: Dictionary, tgt: Dictionary, act: Dictionary, _b: Dictionary, pv: float) -> Dictionary:
	var v: float = pv * (stat_by_key(src, act["scaleStat"]) if act.get("scaleStat") else eff_mag(src)) * aff_boost(src["affinity"]["spirit"], tgt["affinity"]["spirit"])
	var amt: int = max(1, floori(v))
	var before: float = tgt["hp"]
	tgt["hp"] = min(tgt["maxHp"], tgt["hp"] + amt)
	return {"heal": true, "targetName": tgt["name"], "amount": tgt["hp"] - before}

## ===== the battle loop (mirrors farroad-core.js:768-842) =====
static func pick_next(b: Dictionary) -> Variant:
	var best = null
	for u in b["units"]:
		if u["hp"] <= 0:
			continue
		if best == null:
			best = u; continue
		if u["nextActAt"] < best["nextActAt"]:
			best = u; continue
		if u["nextActAt"] > best["nextActAt"]:
			continue
		if u["isParty"] != best["isParty"]:
			if u["isParty"]: best = u
			continue
		if u["base"]["spd"] != best["base"]["spd"]:
			if u["base"]["spd"] > best["base"]["spd"]: best = u
			continue
		if u["slotIndex"] < best["slotIndex"]:
			best = u
	return best

static func check_end(b: Dictionary) -> void:
	var pa := false
	var fa := false
	for u in b["units"]:
		if u["hp"] > 0:
			if u["isParty"]: pa = true
			else: fa = true
	if not fa: b["over"] = "party"
	elif not pa: b["over"] = "enemy"

static func step(b: Dictionary) -> Variant:
	if b["over"] != null:
		return null
	var u = pick_next(b)
	if u == null:
		b["over"] = "draw"
		return null
	b["t"] = u["nextActAt"]
	b["beat"] += 1
	var ms: int = beat_ms(b["beat"])
	b["elapsedMs"] += ms
	# NOTE: every field ever read off e must be pre-populated here, even if a
	# later branch overwrites it -- unlike JS (a missing property just reads
	# `undefined`), GDScript's Dictionary throws on `dict[missing_key]`. The
	# "burned out" early-return below deliberately mirrors the JS original by
	# NOT setting targetName/isCharge/tickCost/enrageStacks itself; the
	# defaults here are what make that safe to read afterward.
	var e := {"beat": b["beat"], "t": b["t"], "ms": ms, "actorId": u["id"], "actorName": u["name"],
		"isParty": u["isParty"], "chargeBefore": u["charge"], "hits": [], "heals": [],
		"totalDamage": 0, "notes": [], "dot": 0, "regen": 0, "thorns": 0,
		"actionId": null, "actionName": null, "via": null, "isCharge": false,
		"rank": 1, "tickCost": 0, "targetName": null, "chargeAfter": u["charge"],
		"enrageStacks": null}
	if has(u, "burning"):
		var dot: int = max(1, ceili(mag_of(u, "burning") * u["maxHp"]))
		u["hp"] = max(0, u["hp"] - dot)
		e["dot"] = dot
	if has(u, "regen") and u["hp"] > 0:
		var rg: int = max(1, ceili(mag_of(u, "regen") * u["maxHp"]))
		var bf = u["hp"]
		u["hp"] = min(u["maxHp"], u["hp"] + rg)
		e["regen"] = u["hp"] - bf
	for sid in ST:
		if u["st"][sid] > 0:
			u["st"][sid] -= 1
	if u["hp"] <= 0:
		e["actionId"] = "none"; e["actionName"] = "(burned out)"; e["via"] = "-"
		e["rank"] = 1; e["chargeAfter"] = u["charge"]
		b["log"].append(e)
		check_end(b)
		return e
	# Post-Milestone-3 APK feedback (Group A2), broadened per later
	# feedback, redesigned again after further feedback ("I want actions to
	# be locked in as soon as they appear on the turn order... charge
	# actions should only enter the turn order once they're full, not
	# appearing beforehand. The same should be true for gambit conditions
	# being met"): the ORIGINAL fix only froze a unit's `slots` (its
	# loadout structure) -- but choose_from() still re-evaluates charge
	# readiness and gambit-condition truth against WHATEVER live state
	# exists at the moment it's actually called, so even a unit with
	# frozen slots could still resolve a DIFFERENT action at real
	# execution time than the one shown when it first appeared, if its
	# charge/HP/conditions drifted in the meantime (from another unit's
	# actions, not just a player edit). The fix now locks the fully
	# RESOLVED action id itself (BattlePresenter._lock_upcoming_actors
	# computes it via choose_from() against the unit's CURRENT real state
	# the FIRST moment it appears in the rail, matching preview()'s own
	# no-longer-projected-forward resolution exactly -- see preview()'s
	# own comment) -- honor that locked id directly instead of calling
	# choose()/choose_from() at all, then consume (clear) this one unit's
	# own lock entry. `target` stays null exactly like the real engine's
	# own "alternate" (no-condition) path already does, so resolve_target
	# below still picks a fresh, definitely-still-valid target for this
	# specific action at the ACTUAL moment it fires -- never a stale
	# reference to a unit that may have died in the meantime. Godot-only
	# WRITE site (only a live-watched fight ever sets it), but this READ/
	# consume is engine-layer so headless callers (expedition/dungeon/
	# offline catch-up) that never set it are unaffected -- `locked`
	# stays empty and this is a pure no-op there.
	var locked: Dictionary = b.get("lockedActors", {})
	var ch: Dictionary
	if locked.has(u["id"]):
		var locked_action_id: String = locked[u["id"]]
		ch = {"actionId": locked_action_id, "target": null, "via": "locked -> %s" % locked_action_id}
		locked.erase(u["id"])
	else:
		ch = choose(u, b)
	var act: Dictionary = ACTIONS.get(ch["actionId"], ACTIONS.get("strike"))
	e["actionId"] = act["id"]; e["actionName"] = act["name"]; e["via"] = ch["via"]
	e["isCharge"] = bool(act.get("isCharge", false)); e["rank"] = act["rank"]
	e["tickCost"] = tc_of(u, act["rank"])
	var primary = resolve_target(act, ch["target"], u, b)
	e["targetName"] = primary["name"] if primary != null else null
	if primary == null and act.get("tk") != "self":
		e["notes"].append("no legal target")
	else:
		var pv: float = eval_power_fn(act, u, primary) if act.get("powerFnId") else act["power"]
		var targets: Array = []
		if act.get("tk") == "allFoes": targets = foes(b, u)
		elif act.get("tk") == "allAllies": targets = allies(b, u)
		elif act.get("tk") == "self": targets = [u]
		else: targets = [primary]
		# Ian: "if an attack is evaded, status effects don't occur" -- tracked
		# per-target here (id -> did at least one hit land / was any hit even
		# attempted against them), only ever populated by the pv>0 hit loop
		# below, so the "applies" block further down can skip a target that
		# dodged every hit from a combined damage+status action, while a
		# pure status/buff/heal action (no hits resolved here at all) stays
		# completely unaffected -- evasion is never rolled for those.
		var hit_landed: Dictionary = {}
		var hit_attempted: Dictionary = {}
		if act.get("revive"):
			if primary != null and primary["hp"] <= 0:
				primary["hp"] = max(1, floori(primary["maxHp"] * act["revive"]))
				primary["st"] = new_st(); primary["stMag"] = {}
				e["notes"].append("revived " + primary["name"])
		elif act.get("heal"):
			for t in targets:
				e["heals"].append(heal_for(u, t, act, b, pv))
			if act.get("cleanse"):
				for t in targets:
					for d in DEBUFFS:
						if has(t, d):
							t["st"][d] = 0
							e["notes"].append("cleansed " + d)
							break
		elif pv > 0:
			for h in range(int(act.get("hits", 1))):
				var tl: Array = [def_foe(b, u)] if act.get("randomPerHit") else targets
				for tg in tl:
					if tg == null or tg["hp"] <= 0:
						continue
					var r := resolve_hit(u, tg, act, b, pv)
					e["hits"].append(r)
					e["totalDamage"] += r["damage"]
					tg["hp"] = max(0, tg["hp"] - r["damage"])
					hit_attempted[tg["id"]] = true
					if not r["evaded"]:
						hit_landed[tg["id"]] = true
					if act.get("lifesteal") and r["damage"] > 0:
						var hb = u["hp"]
						u["hp"] = min(u["maxHp"], u["hp"] + floori(r["damage"] * act["lifesteal"] * aff_boost(u["affinity"]["spirit"], u["affinity"]["spirit"])))
						if u["hp"] > hb:
							e["heals"].append({"heal": true, "targetName": u["name"], "amount": u["hp"] - hb})
			if act.get("tk") == "allFoes":
				var refl: float = 0.0
				for t in targets:
					if t.get("thorns"):
						refl += max(1, roundi(t["thorns"] * t["maxHp"]))
				if refl > 0:
					u["hp"] = max(0, u["hp"] - refl)
					e["thorns"] = refl
					e["notes"].append("thorns -%d" % refl)
		if act.get("applies"):
			for t in targets:
				if t["hp"] > 0:
					if hit_attempted.has(t["id"]) and not hit_landed.has(t["id"]):
						continue
					var already := has(t, act["applies"])
					apply_status(t, act["applies"], act["turns"], u["affinity"]["spirit"])
					e["notes"].append(("refreshed " if already else "applied ") + act["applies"] + " on " + t["name"])
		if act.get("selfTaunt"):
			apply_status(u, "taunted", act["selfTaunt"], u["affinity"]["spirit"])
			e["notes"].append("taunting")
	if act.get("isCharge"):
		u["charge"] -= cost_of_charge(act)
	else:
		u["charge"] += act["charge"] * eff_charge_rate(u)
	e["chargeAfter"] = u["charge"]
	u["turnsTaken"] += 1
	u["nextActAt"] = b["t"] + tc_of(u, act["rank"])
	if b["enrage"] and b["beat"] > ENRAGE_AFTER:
		b["enrageN"] = b.get("enrageN", 0) + 1
	if b["enrage"] and not u["isParty"] and u["hp"] > 0:
		var pending: int = int(b.get("enrageN", 0)) - int(u.get("enrageApplied", 0))
		if pending > 0:
			# Ian: "enraged damage scaling seems to be compounding, not
			# increasing at a linear rate" -- switched from
			# pow(1+ENRAGE_PCT, N) to a flat 1+ENRAGE_PCT*N. u["base"]["atk"]/
			# ["mag"] are mutated PERMANENTLY in place (no separate
			# "original, pre-enrage" value kept elsewhere), and a slow enemy
			# can have several turns' worth of stacks pending at once -- so
			# catching up from `applied_n` to `target_n` in one lump multiply
			# needs the RATIO between the two linear targets (both measured
			# against the true original), not the raw target multiplier
			# itself: base_atk currently already carries (1+PCT*applied_n)
			# baked in, so multiplying by (1+PCT*target_n)/(1+PCT*applied_n)
			# lands it exactly on (original * (1+PCT*target_n)).
			var applied_n: int = int(u.get("enrageApplied", 0))
			var target_n: int = int(b.get("enrageN", 0))
			var mul: float = (1.0 + ENRAGE_PCT * target_n) / (1.0 + ENRAGE_PCT * applied_n)
			u["base"]["atk"] *= mul
			u["base"]["mag"] *= mul
			u["enrageApplied"] = target_n
			e["enrageStacks"] = target_n
			e["notes"].append("enraged ×%d (+%d%% damage)" % [e["enrageStacks"], round(ENRAGE_PCT * target_n * 100)])
	b["log"].append(e)
	check_end(b)
	return e

## ===== turn-order preview (mirrors preview(), farroad-core.js:843-859) =====
## A non-mutating simulation of the next `count` turns' ORDER (who acts
## when -- driven by real nextActAt/spd/slotIndex, cloned into `sim` and
## advanced via tc_of only). Ian: "charge actions should only enter the
## turn order once they're full, not appearing beforehand. The same
## should be true for gambit conditions being met" -- ACTION CHOICE,
## unlike order, is no longer projected forward at all: every slot,
## including a fast unit's own further-out appearances within this same
## window, resolves choose_from() against that unit's REAL, CURRENT
## charge/HP/conditions (never a simulated future value) -- so a slot can
## only ever show a charge action if it's genuinely full RIGHT NOW, and a
## condition-gated action only if that condition is genuinely true RIGHT
## NOW. This is also what makes the result safe to lock in verbatim the
## instant it first appears (BattlePresenter._lock_upcoming_actors/
## FarroadCore.step()'s own lockedActors consumption) -- "what's shown"
## and "what would happen if resolved this instant" are the same
## question by construction, never a speculative forecast. choose_from()
## itself never mutates a unit (only the throwaway `state` dict passed
## in), so this stays safe to call every beat purely for display.
static func preview(b: Dictionary, count: int = 6) -> Array:
	var sim := []
	for u in b["units"]:
		if u["hp"] <= 0:
			continue
		sim.append({"u": u, "at": u["nextActAt"]})
	# Ian: "when a charge action is entered in the queue, consider it
	# expended and only list it once." A fast unit can occupy multiple of
	# the upcoming slots within one preview() call -- without this, every
	# one of those slots re-reads the SAME still-full u["charge"] (real
	# charge only ever decrements in step(), once the action truly
	# executes), so the same full charge action would get listed again
	# and again for that unit. Tracked per-unit, this preview() call only.
	var charge_shown: Dictionary = {}
	var out := []
	for n in range(count):
		if sim.is_empty():
			break
		var best_idx := 0
		for j in range(1, sim.size()):
			var s = sim[j]
			var best = sim[best_idx]
			if s["at"] < best["at"]:
				best_idx = j; continue
			if s["at"] > best["at"]:
				continue
			if s["u"]["isParty"] != best["u"]["isParty"]:
				if s["u"]["isParty"]: best_idx = j
				continue
			if s["u"]["base"]["spd"] != best["u"]["base"]["spd"]:
				if s["u"]["base"]["spd"] > best["u"]["base"]["spd"]: best_idx = j
				continue
			if s["u"]["slotIndex"] < best["u"]["slotIndex"]:
				best_idx = j
		var best = sim[best_idx]
		var uid: String = best["u"]["id"]
		var charge_val: float = 0.0 if charge_shown.has(uid) else best["u"]["charge"]
		var st := {"charge": charge_val, "alternateFlag": best["u"]["alternateFlag"]}
		var ch := choose_from(best["u"], b, st)
		var act = ACTIONS.get(ch["actionId"], ACTIONS.get("strike"))
		if act.get("isCharge", false):
			charge_shown[uid] = true
		out.append({"unitName": best["u"]["name"], "unitId": uid, "isParty": best["u"]["isParty"], "at": best["at"],
			"actionName": act["name"], "actionId": act["id"], "rank": act["rank"],
			"isCharge": bool(act.get("isCharge", false)), "cost": tc_of(best["u"], act["rank"])})
		best["at"] += tc_of(best["u"], act["rank"])
	return out

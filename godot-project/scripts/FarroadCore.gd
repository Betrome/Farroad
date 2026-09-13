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

## ===== affinity system (mirrors farroad-core.js:88-139) =====
static func affinity_mul(raw: float) -> float:
	var s: float = -1.0 if raw < 0 else 1.0
	var a: float = min(abs(raw), AFFINITY_CAP)
	return s * 0.80 * log(1 + a) / log(1 + AFFINITY_CAP)

static func aff_term(atk_raw: float, def_raw: float) -> float:
	return (1 + affinity_mul(atk_raw)) * (1 - affinity_mul(def_raw))

static func aff_boost(a: float, b: float) -> float:
	return min(AFFINITY_BOOST_CAP, (1 + affinity_mul(a)) * (1 + affinity_mul(b)))

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
	var mul: float = aff_boost(0.0 if caster_spirit == null else caster_spirit, u["affinity"]["spirit"])
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
		"turnsTaken": 0, "enrageN": 0, "row": cfg.get("row"), "arch": cfg.get("arch"),
		"thorns": cfg.get("thorns", 0.0), "isBoss": bool(cfg.get("isBoss", false))}

static func make_battle(units: Array, opts: Dictionary = {}) -> Dictionary:
	var b := {"units": units, "t": 0, "beat": 0, "elapsedMs": 0, "log": [], "over": null,
		"rng": opts.get("rng") if opts.get("rng") != null else make_rng(1),
		"det": bool(opts.get("deterministic", false)), "gambitMode": "topdown",
		"smartHeal": true, "enrage": bool(opts.get("enrage", false))}
	for u in units:
		u["st"] = new_st(); u["stMag"] = {}
		u["nextActAt"] = tc_of(u, 1.00); u["turnsTaken"] = 0; u["enrageN"] = 0; u["alternateFlag"] = 0
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
	# Non-'none' conditions: Step 1c. Falls through to Strike for now.
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
	var cb: float = act.get("critBonus", 0.0)
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
	var e := {"beat": b["beat"], "t": b["t"], "ms": ms, "actorId": u["id"], "actorName": u["name"],
		"isParty": u["isParty"], "chargeBefore": u["charge"], "hits": [], "heals": [],
		"totalDamage": 0, "notes": [], "dot": 0, "regen": 0, "thorns": 0}
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
	var ch := choose(u, b)
	var act: Dictionary = ACTIONS.get(ch["actionId"], ACTIONS.get("strike"))
	e["actionId"] = act["id"]; e["actionName"] = act["name"]; e["via"] = ch["via"]
	e["isCharge"] = bool(act.get("isCharge", false)); e["rank"] = act["rank"]
	e["tickCost"] = tc_of(u, act["rank"])
	var primary = resolve_target(act, ch["target"], u, b)
	e["targetName"] = primary["name"] if primary != null else null
	if primary == null and act.get("tk") != "self":
		e["notes"].append("no legal target")
	else:
		var pv: float = act["power"]
		var targets: Array = []
		if act.get("tk") == "allFoes": targets = foes(b, u)
		elif act.get("tk") == "allAllies": targets = allies(b, u)
		elif act.get("tk") == "self": targets = [u]
		else: targets = [primary]
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
	if b["enrage"] and not u["isParty"] and u["hp"] > 0 and b["beat"] > ENRAGE_AFTER:
		u["enrageN"] = u.get("enrageN", 0) + 1
		u["base"]["atk"] *= (1 + ENRAGE_PCT)
		u["base"]["mag"] *= (1 + ENRAGE_PCT)
		e["enrageStacks"] = u["enrageN"]
		e["notes"].append("enraged x%d (+%d%% damage)" % [e["enrageStacks"], round(ENRAGE_PCT * 100)])
	b["log"].append(e)
	check_end(b)
	return e

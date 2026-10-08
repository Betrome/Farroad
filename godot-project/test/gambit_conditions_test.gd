extends SceneTree
## Every gambit condition, checked against an independent reading of its
## Run: godot --headless --path godot-project --script test/gambit_conditions_test.gd
## description over thousands of random battle states.
const BUFFS := ["hasted", "warded", "bracing", "blurred", "regen", "surging"]
const DEBUFFS := ["enfeebled", "dulled", "sundered", "frail", "slowed", "burning", "poisoned", "exposed", "blinded", "confused"]
const ELEMS := ["fire", "water", "earth", "air", "light", "dark"]
var rng := RandomNumberGenerator.new()
var fails := {}
var checked := {}
var true_count := {}

func _unit(id: String, party: bool) -> Dictionary:
	var u := FarroadCore.make_unit({"id": id, "name": id, "isParty": party,
		"stats": {"hp": 100, "atk": rng.randi_range(5, 60), "mag": rng.randi_range(5, 60), "def": rng.randi_range(2, 40),
			"res": rng.randi_range(2, 40), "spd": rng.randi_range(5, 40)},
		"chargeAction": ["heavystrike", "wildfire", "reckoning"][rng.randi_range(0, 2)] if rng.randf() < 0.6 else null,
		"slots": [{"cond": "none", "action": ("mend" if rng.randf() < 0.2 else "strike")}]})
	u["hp"] = float(rng.randi_range(0, 100)) if rng.randf() < 0.15 else float(rng.randi_range(1, 100))
	for e in ELEMS:
		u["affinity"][e] = rng.randi_range(-5, 5) if rng.randf() < 0.3 else 0
	return u

## After make_battle (which resets timing and statuses).
func _scramble(u: Dictionary) -> void:
	u["charge"] = float(rng.randi_range(0, 120))
	u["nextActAt"] = rng.randi_range(0, 1000)
	u["turnsTaken"] = rng.randi_range(0, 2)
	for s in BUFFS + DEBUFFS:
		if rng.randf() < 0.15:
			FarroadCore.apply_status(u, s, 3, 0.0)

func _debuffed(x) -> bool:
	for s in DEBUFFS:
		if FarroadCore.has(x, s):
			return true
	return false

## Expected [ok, valid targets (Array) or null = any/none needed]
func _oracle(cid: String, u: Dictionary, b: Dictionary, act) -> Array:
	var foes: Array = b["units"].filter(func(x): return x["isParty"] != u["isParty"] and x["hp"] > 0)
	var allies: Array = b["units"].filter(func(x): return x["isParty"] == u["isParty"] and x["hp"] > 0)
	var dead: Array = b["units"].filter(func(x): return x["isParty"] == u["isParty"] and x["hp"] <= 0)
	var pct := func(x): return float(x["hp"]) / float(x["maxHp"])
	var m := RegEx.create_from_string("^(foe|ally|self)_hp_(gte|lte)_(\\d+)$").search(cid)
	if m:
		var who := m.get_string(1)
		var th := float(m.get_string(3)) / 100.0
		var test := func(x): return pct.call(x) >= th if m.get_string(2) == "gte" else pct.call(x) <= th
		var pool: Array = foes if who == "foe" else (allies if who == "ally" else [u])
		var v := pool.filter(test)
		return [not v.is_empty(), v]
	var cm := RegEx.create_from_string("^foe_charge_gte_(\\d+)$").search(cid)
	if cm:
		var need := float(cm.get_string(1)) / 100.0
		var cv := foes.filter(func(x): return x.get("chargeAction") and x["charge"] >= need * FarroadCore.cost_of_charge(FarroadCore.ACTIONS.get(x["chargeAction"])))
		return [not cv.is_empty(), cv]
	match cid:
		"none": return [true, null]
		"foe_any": return [not foes.is_empty(), foes]
		"foe_lowest_hp":
			var mn: float = 2.0
			for x in foes: mn = minf(mn, pct.call(x))
			return [not foes.is_empty(), foes.filter(func(x): return is_equal_approx(pct.call(x), mn))]
		"foe_highest_hp":
			var mx: float = -1.0
			for x in foes: mx = maxf(mx, pct.call(x))
			return [not foes.is_empty(), foes.filter(func(x): return is_equal_approx(pct.call(x), mx))]
		"foe_armoured":
			var v := foes.filter(func(x): return FarroadCore.eff_def(x) > FarroadCore.eff_res(x)); return [not v.is_empty(), v]
		"foe_warded":
			var v := foes.filter(func(x): return FarroadCore.eff_res(x) > FarroadCore.eff_def(x)); return [not v.is_empty(), v]
		"foe_fast":
			var v := foes.filter(func(x): return x["base"]["spd"] > u["base"]["spd"]); return [not v.is_empty(), v]
		"foe_2plus": return [foes.size() >= 2, foes]
		"foe_3plus": return [foes.size() >= 3, foes]
		"foe_isolated": return [foes.size() == 1, foes]
		"foe_charging":
			var v := foes.filter(func(x): return x.get("chargeAction") and x["charge"] >= 0.7 * FarroadCore.cost_of_charge(FarroadCore.ACTIONS.get(x["chargeAction"])))
			return [not v.is_empty(), v]
		"foe_softest_def", "foe_softest_res":
			var key := "def" if cid == "foe_softest_def" else "res"
			var f := func(x): return FarroadCore.eff_def(x) if key == "def" else FarroadCore.eff_res(x)
			var mn: float = 1e9
			for x in foes: mn = minf(mn, f.call(x))
			return [not foes.is_empty(), foes.filter(func(x): return is_equal_approx(f.call(x), mn))]
		"foe_most_dangerous":
			var mx: float = -1.0
			for x in foes: mx = maxf(mx, maxf(FarroadCore.eff_atk(x), FarroadCore.eff_mag(x)))
			return [not foes.is_empty(), foes.filter(func(x): return is_equal_approx(maxf(FarroadCore.eff_atk(x), FarroadCore.eff_mag(x)), mx))]
		"foe_acts_next":
			var mn: float = 1e12
			for x in foes: mn = minf(mn, x["nextActAt"])
			return [not foes.is_empty(), foes.filter(func(x): return x["nextActAt"] == mn)]
		"foe_healer_present":
			var v := foes.filter(func(x): return x["slots"].any(func(s): return FarroadCore.ACTIONS.get(s["action"], {}).get("heal", false)))
			return [not v.is_empty(), v]
		"foe_pack_hurt":
			var ok := not foes.is_empty() and foes.all(func(x): return pct.call(x) < 0.5)
			return [ok, foes]
		"foe_pack_healthy":
			var ok := not foes.is_empty() and foes.all(func(x): return pct.call(x) >= 0.7)
			return [ok, foes]
		"foe_mostly_weakened":
			var n := foes.filter(func(x): return _debuffed(x)).size()
			var v := foes.filter(func(x): return not _debuffed(x))
			return [n * 2 > foes.size(), v if not v.is_empty() else foes]
		"foe_lacks_debuff":
			var v := foes.filter(func(x): return not FarroadCore.has(x, act["applies"])); return [not v.is_empty(), v]
		"foe_not_weakened":
			var v := foes.filter(func(x): return not _debuffed(x)); return [not v.is_empty(), v]
		"ally_lowest_hp":
			var mn: float = 2.0
			for x in allies: mn = minf(mn, pct.call(x))
			return [not allies.is_empty(), allies.filter(func(x): return is_equal_approx(pct.call(x), mn))]
		"ally_is_dead": return [not dead.is_empty(), dead]
		"ally_lacks_buff":
			var v := allies.filter(func(x): return not FarroadCore.has(x, act["applies"])); return [not v.is_empty(), v]
		"self_first_turn": return [u["turnsTaken"] == 0, null]
	if cid.begins_with("foe_weak_"):
		var el := cid.trim_prefix("foe_weak_")
		var v := foes.filter(func(x): return x["affinity"][el] < 0); return [not v.is_empty(), v]
	return [null, null]

func _initialize() -> void:
	FarroadCore.load_real_content()
	FarroadCore.apply_bonuses({"wildfire": {"potent": 3}, "reckoning": {"thrifty": 2}})   # charge costs 136 and 70
	rng.seed = 12345
	var debuff_act: Dictionary = FarroadCore.ACTIONS["hex"]     # applies frail
	var buff_act: Dictionary = FarroadCore.ACTIONS["quicken"]   # applies hasted
	for trial in 3000:
		var units: Array = []
		var np := rng.randi_range(1, 5)
		var nf := rng.randi_range(1, 6)
		for i in np: units.append(_unit("p%d" % i, true))
		for i in nf: units.append(_unit("f%d" % i, false))
		var me: Dictionary = units[0]
		me["hp"] = maxf(1.0, me["hp"])
		var b := FarroadCore.make_battle(units, {"deterministic": true})
		for x in units:
			_scramble(x)
		for cid in FarroadCore.ALL_CONDITION_IDS:
			var act: Dictionary = buff_act if cid == "ally_lacks_buff" else (debuff_act if cid == "foe_lacks_debuff" else FarroadCore.ACTIONS["strike"])
			var exp := _oracle(cid, me, b, act)
			if exp[0] == null:
				fails[cid] = "no oracle"
				continue
			var got := FarroadCore.resolve_condition(cid, me, b, act)
			checked[cid] = checked.get(cid, 0) + 1
			if got["ok"]:
				true_count[cid] = true_count.get(cid, 0) + 1
			var bad := ""
			if bool(got["ok"]) != bool(exp[0]):
				bad = "said %s, expected %s" % [got["ok"], exp[0]]
			elif got["ok"] and exp[1] != null and got["target"] != null and not (exp[1] as Array).has(got["target"]):
				bad = "picked %s (hp %.0f%%) -- not a valid target" % [got["target"]["id"], 100.0 * got["target"]["hp"] / got["target"]["maxHp"]]
			if bad != "" and not fails.has(cid):
				fails[cid] = bad
	var never := FarroadCore.ALL_CONDITION_IDS.filter(func(c): return true_count.get(c, 0) == 0)
	print("checked %d conditions x 3000 battles" % checked.size())
	print("never true in any battle: ", never)
	for cid in fails:
		print("MISMATCH %-22s %s" % [cid, fails[cid]])
	quit()

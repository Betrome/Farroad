extends SceneTree
## Headless parity-test runner. Invoked as:
##   godot --headless --path godot-project --script res://test/parity_test.gd -- rng
## Prints JSON to stdout; parity-reference.js (repo root) produces the
## same shape from the real farroad-core.js so the two can be diffed.

func _initialize():
	var args := OS.get_cmdline_user_args()
	var mode := (args[0] if args.size() > 0 else "rng")
	if mode == "rng":
		_run_rng()
	elif mode == "battle":
		_run_battle_suite()
	elif mode == "bonuses":
		_run_bonuses_suite()
	quit()

## Step 1b: hand-authored test content -- kept identical, by hand, to
## TEST_ACTIONS in parity-reference.js (repo root).
func _register_test_actions() -> void:
	FarroadCore.register_actions({
		"strike": {"id": "strike", "name": "Strike", "camp": "atk", "tk": "foe", "power": 1.00, "rank": 1.00, "charge": 20},
		"mend": {"id": "mend", "name": "Mend", "camp": "mag", "tk": "ally", "power": 1.00, "rank": 1.20, "charge": 15, "heal": true},
		"ember": {"id": "ember", "name": "Ember", "camp": "mag", "tk": "foe", "power": 1.05, "rank": 1.05, "charge": 21, "applies": "burning", "turns": 3}
	})

func _run_battle(seed: int, units: Array, enrage: bool = false) -> Dictionary:
	var b := FarroadCore.make_battle(units, {"rng": FarroadCore.make_rng(seed), "enrage": enrage})
	var log := []
	var guard := 0
	while b["over"] == null and guard < 500:
		guard += 1
		var e = FarroadCore.step(b)
		if e == null:
			break
		var hits := []
		for h in e["hits"]:
			hits.append({"evaded": h["evaded"], "crit": h["crit"], "damage": h["damage"]})
		var heals := []
		for h in e["heals"]:
			heals.append({"targetName": h["targetName"], "amount": h["amount"]})
		var hp_after := []
		for u in b["units"]:
			hp_after.append(u["hp"])
		log.append({"beat": e["beat"], "actorId": e["actorId"], "actionId": e["actionId"],
			"targetName": e["targetName"], "totalDamage": e["totalDamage"], "dot": e["dot"],
			"regen": e["regen"], "hits": hits, "heals": heals, "notes": e["notes"], "hpAfter": hp_after})
	return {"over": b["over"], "beats": b["beat"], "log": log}

func _run_battle_suite() -> void:
	_register_test_actions()
	var out := {}

	FarroadCore.set_wave(1)
	out["A"] = _run_battle(7, [
		FarroadCore.make_unit({"id": "p1", "name": "Hero", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 200, "atk": 20, "mag": 5, "def": 10, "res": 10, "spd": 100},
			"slots": [{"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e1", "name": "Wolf", "isParty": false, "level": 1, "slotIndex": 10, "arch": "wolf",
			"stats": {"hp": 150, "atk": 15, "mag": 5, "def": 8, "res": 8, "spd": 90}, "row": "front",
			"slots": [{"cond": "none", "action": "strike"}]})
	])

	out["B"] = _run_battle(2024, [
		FarroadCore.make_unit({"id": "p1", "name": "Vanguard", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 220, "atk": 18, "mag": 5, "def": 12, "res": 10, "spd": 105},
			"slots": [{"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "p2", "name": "Cleric", "isParty": true, "level": 1, "slotIndex": 1,
			"stats": {"hp": 180, "atk": 8, "mag": 16, "def": 8, "res": 12, "spd": 95},
			"slots": [{"cond": "none", "action": "strike"}, {"cond": "none", "action": "mend"}]}),
		FarroadCore.make_unit({"id": "e1", "name": "Wolf", "isParty": false, "level": 1, "slotIndex": 10, "arch": "wolf", "row": "front",
			"stats": {"hp": 160, "atk": 14, "mag": 4, "def": 9, "res": 9, "spd": 92},
			"slots": [{"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e2", "name": "Hound", "isParty": false, "level": 1, "slotIndex": 11, "arch": "hound", "row": "back",
			"stats": {"hp": 130, "atk": 12, "mag": 4, "def": 7, "res": 7, "spd": 110},
			"slots": [{"cond": "none", "action": "strike"}]})
	])

	out["C"] = _run_battle(99, [
		FarroadCore.make_unit({"id": "p1", "name": "Ember Mage", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 190, "atk": 8, "mag": 22, "def": 8, "res": 10, "spd": 98},
			"slots": [{"cond": "none", "action": "ember"}]}),
		FarroadCore.make_unit({"id": "e1", "name": "Ox", "isParty": false, "level": 1, "slotIndex": 10, "arch": "ox", "row": "front",
			"stats": {"hp": 260, "atk": 16, "mag": 4, "def": 12, "res": 9, "spd": 80},
			"slots": [{"cond": "none", "action": "strike"}]})
	], true)

	out["D"] = _run_battle(555, [
		FarroadCore.make_unit({"id": "p1", "name": "Paladin", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 240, "atk": 16, "mag": 14, "def": 11, "res": 11, "spd": 100},
			"slots": [{"cond": "self_hp_lte_50", "action": "mend"}, {"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e1", "name": "Ox", "isParty": false, "level": 1, "slotIndex": 10, "arch": "ox", "row": "front",
			"stats": {"hp": 220, "atk": 17, "mag": 4, "def": 10, "res": 9, "spd": 88},
			"slots": [{"cond": "none", "action": "strike"}]})
	])

	out["E"] = _run_battle(777, [
		FarroadCore.make_unit({"id": "p1", "name": "Sniper", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 200, "atk": 19, "mag": 5, "def": 9, "res": 9, "spd": 102},
			"slots": [{"cond": "foe_lowest_hp", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "p2", "name": "Breaker", "isParty": true, "level": 1, "slotIndex": 1,
			"stats": {"hp": 210, "atk": 15, "mag": 5, "def": 10, "res": 10, "spd": 97},
			"slots": [{"cond": "foe_softest_def", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e1", "name": "Wolf", "isParty": false, "level": 1, "slotIndex": 10, "arch": "wolf", "row": "front",
			"stats": {"hp": 120, "atk": 13, "mag": 4, "def": 11, "res": 8, "spd": 91}, "slots": [{"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e2", "name": "Hound", "isParty": false, "level": 1, "slotIndex": 11, "arch": "hound", "row": "back",
			"stats": {"hp": 130, "atk": 12, "mag": 4, "def": 6, "res": 7, "spd": 108}, "slots": [{"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e3", "name": "Knight", "isParty": false, "level": 1, "slotIndex": 12, "arch": "knight", "row": "front",
			"stats": {"hp": 150, "atk": 11, "mag": 4, "def": 9, "res": 10, "spd": 85}, "slots": [{"cond": "none", "action": "strike"}]})
	])

	out["F"] = _run_battle(333, [
		FarroadCore.make_unit({"id": "p1", "name": "Pyromancer", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 210, "atk": 8, "mag": 20, "def": 9, "res": 11, "spd": 96},
			"slots": [{"cond": "foe_lacks_debuff", "action": "ember"}]}),
		FarroadCore.make_unit({"id": "p2", "name": "Watcher", "isParty": true, "level": 1, "slotIndex": 1,
			"stats": {"hp": 190, "atk": 14, "mag": 6, "def": 9, "res": 9, "spd": 101},
			"slots": [{"cond": "foe_healer_present", "action": "strike"}, {"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e1", "name": "Wolf", "isParty": false, "level": 1, "slotIndex": 10, "arch": "wolf", "row": "front",
			"stats": {"hp": 140, "atk": 12, "mag": 4, "def": 8, "res": 8, "spd": 90}, "slots": [{"cond": "none", "action": "strike"}]}),
		FarroadCore.make_unit({"id": "e2", "name": "Priest", "isParty": false, "level": 1, "slotIndex": 11, "arch": "priest", "row": "back",
			"stats": {"hp": 130, "atk": 8, "mag": 12, "def": 7, "res": 10, "spd": 88}, "slots": [{"cond": "none", "action": "mend"}]})
	])

	print(JSON.stringify(out))

func _run_rng() -> void:
	var seeds: Array[int] = [1, 12345, 987654321, 42]
	var out := {}
	for seed in seeds:
		var rng := FarroadCore.make_rng(seed)
		var nexts: Array[float] = []
		for i in range(200):
			nexts.append(rng.next())
		var rng2 := FarroadCore.make_rng(seed)
		var next_ints: Array[int] = []
		for i in range(100):
			next_ints.append(rng2.next_int(37))
		out[str(seed)] = {"next": nexts, "nextInt": next_ints}
	print(JSON.stringify(out))

## Step 1d: mirrors the 'bonuses' mode in parity-reference.js exactly.
func _run_bonuses_suite() -> void:
	_register_test_actions()
	FarroadCore.ACTIONS["heavystrike"] = FarroadCore.a_defaults({"id": "heavystrike", "name": "Heavy Strike",
		"camp": "atk", "tk": "foe", "power": 3.0, "rank": 1.4, "isCharge": true})
	FarroadCore.register_bonus_eligible(["strike", "mend", "ember", "heavystrike"])
	var out := {}

	out["bonusPrice"] = []
	for rarity in ["common", "rare", "legendary"]:
		for total in range(4):
			out["bonusPrice"].append({"rarity": rarity, "bid": "swift", "total": total,
				"price": FarroadCore.bonus_price({"rarity": rarity}, "swift", total)})
		out["bonusPrice"].append({"rarity": rarity, "bid": "broad",
			"price": FarroadCore.bonus_price({"rarity": rarity}, "broad", 0)})

	var shapes := {
		"atkDamage": {"power": 1.0, "camp": "atk", "tk": "foe"},
		"heal": {"power": 1.0, "heal": true, "tk": "ally"},
		"charge": {"power": 2.0, "isCharge": true, "tk": "foe"},
		"appliesDebuff": {"power": 1.0, "applies": "burning", "tk": "foe"},
		"appliesBuff": {"power": 0, "applies": "hasted", "tk": "self"}
	}
	var bonus_ids := ["swift", "potent", "lasting", "deepening", "surge", "piercing", "broad", "cleansing", "thrifty"]
	out["bonusApplies"] = {}
	for shape in shapes.keys():
		out["bonusApplies"][shape] = {}
		for bid in bonus_ids:
			out["bonusApplies"][shape][bid] = FarroadCore.bonus_applies(shapes[shape], bid)

	out["actionBonusTotal"] = [
		FarroadCore.action_bonus_total({"swift": 2, "piercing": 1}),
		FarroadCore.action_bonus_total({"broad": 1}),
		FarroadCore.action_bonus_total({"swift": 3, "broad": 1, "potent": 2}),
		FarroadCore.action_bonus_total({})
	]

	out["bonusSpend"] = [
		FarroadCore.bonus_spend({"strike": {"swift": 2, "piercing": 1}}),
		FarroadCore.bonus_spend({"strike": {"swift": 2, "piercing": 1}, "mend": {"potent": 1, "broad": 1}}),
		FarroadCore.bonus_spend({})
	]

	FarroadCore.apply_bonuses({
		"strike": {"swift": 2, "piercing": 3},
		"mend": {"potent": 1, "cleansing": 2},
		"heavystrike": {"surge": 1, "thrifty": 1}
	})
	out["afterApply"] = {
		"strikeRank": FarroadCore.ACTIONS["strike"]["rank"], "strikeDefPierce": FarroadCore.ACTIONS["strike"]["defPierce"],
		"mendPower": FarroadCore.ACTIONS["mend"]["power"], "mendCleanse": FarroadCore.ACTIONS["mend"]["cleanse"],
		"heavystrikeChargeCost": FarroadCore.ACTIONS["heavystrike"]["chargeCost"]
	}
	FarroadCore.apply_bonuses({})
	out["afterReset"] = {
		"strikeRank": FarroadCore.ACTIONS["strike"]["rank"], "strikeDefPierce": FarroadCore.ACTIONS["strike"]["defPierce"],
		"mendPower": FarroadCore.ACTIONS["mend"]["power"], "mendCleanse": FarroadCore.ACTIONS["mend"]["cleanse"],
		"heavystrikeChargeCost": FarroadCore.ACTIONS["heavystrike"]["chargeCost"]
	}
	FarroadCore.apply_bonuses({"strike": {"swift": 5}})
	out["afterReapply"] = {"strikeRank": FarroadCore.ACTIONS["strike"]["rank"], "strikeDefPierce": FarroadCore.ACTIONS["strike"]["defPierce"]}
	FarroadCore.apply_bonuses({})

	out["piercingProof"] = {"unpierced": _dmg_against_high_res(false), "pierced": _dmg_against_high_res(true)}

	print(JSON.stringify(out))

func _dmg_against_high_res(pierced: bool):
	FarroadCore.apply_bonuses({"ember": {"piercing": 2}} if pierced else {})
	var src := FarroadCore.make_unit({"id": "s", "name": "Src", "isParty": true, "level": 1, "slotIndex": 0,
		"stats": {"atk": 15, "mag": 40, "def": 15, "res": 15, "spd": 100}, "slots": [{"cond": "none", "action": "ember"}]})
	var tgt := FarroadCore.make_unit({"id": "t", "name": "Tgt", "isParty": false, "level": 1, "slotIndex": 10,
		"stats": {"atk": 10, "mag": 10, "def": 10, "res": 80, "spd": 90}, "maxHp": 100000, "hp": 100000,
		"slots": [{"cond": "none", "action": "strike"}]})
	var b := FarroadCore.make_battle([src, tgt], {"rng": FarroadCore.make_rng(1), "deterministic": true})
	var e = null
	var guard := 0
	while e == null and guard < 10:
		guard += 1
		var ev = FarroadCore.step(b)
		if ev != null and ev["actorId"] == "s" and not ev["hits"].is_empty():
			e = ev
	FarroadCore.apply_bonuses({})
	return e["hits"][0]["damage"] if e != null else null

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

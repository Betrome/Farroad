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
	elif mode == "content":
		_run_content_suite()
	elif mode == "progression":
		_run_progression_suite()
	elif mode == "save":
		_run_save_suite()
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

## Step 1e: mirrors the 'content' mode in parity-reference.js exactly.
## No _register_test_actions() here -- load_real_content() populates the
## genuine CSV-compiled ACTIONS/ARCH/ROSTER/EQUIPMENT tables directly.
func _run_content_suite() -> void:
	if not FarroadCore.load_real_content():
		print(JSON.stringify({"error": "failed to load content.json"}))
		return
	var out := {}
	out["counts"] = {
		"actions": FarroadCore.ACTIONS.size(),
		"arch": FarroadCore.ARCH.size(),
		"roster": FarroadCore.ROSTER.size(),
		"equipment": FarroadCore.EQUIPMENT.size()
	}
	out["spotCheck"] = {
		"strikePower": FarroadCore.ACTIONS["strike"]["power"],
		"keshHp": FarroadCore.roster_by_id("kesh")["hp"],
		"wolfAtk": FarroadCore.ARCH["wolf"]["atk"]
	}

	FarroadCore.set_wave(1)
	out["executeProof"] = _run_battle(2222, [
		FarroadCore.make_unit({"id": "kesh", "name": "Kesh", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 430, "atk": 26, "mag": 18, "def": 20, "res": 16, "spd": 100, "atkCrit": 0.05, "magCrit": 0.05},
			"affinity": {"body": 3}, "slots": [{"cond": "none", "action": "execute"}]}),
		FarroadCore.make_unit({"id": "wolf", "name": "Roadwolf", "isParty": false, "level": 1, "slotIndex": 10, "arch": "wolf", "row": "front",
			"stats": {"hp": 200, "atk": 21, "mag": 8, "def": 12, "res": 8, "spd": 92, "atkCrit": 0.04, "magCrit": 0.04, "evade": 0.05},
			"slots": [{"cond": "none", "action": "strike"}]})
	])

	out["vengeanceProof"] = _run_battle(4444, [
		FarroadCore.make_unit({"id": "kesh", "name": "Kesh", "isParty": true, "level": 1, "slotIndex": 0,
			"stats": {"hp": 150, "atk": 26, "mag": 18, "def": 12, "res": 16, "spd": 100, "atkCrit": 0.05, "magCrit": 0.05},
			"affinity": {"body": 3}, "slots": [{"cond": "none", "action": "vengeance"}]}),
		FarroadCore.make_unit({"id": "wolf", "name": "Roadwolf", "isParty": false, "level": 1, "slotIndex": 10, "arch": "wolf", "row": "front",
			"stats": {"hp": 260, "atk": 14, "mag": 8, "def": 12, "res": 8, "spd": 88, "atkCrit": 0.04, "magCrit": 0.04, "evade": 0.05},
			"slots": [{"cond": "none", "action": "strike"}]})
	])

	print(JSON.stringify(out))

## Step 3a: FarroadProgression.gd -- mirrors parity-reference.js's
## 'progression' mode exactly, same math spot-checks plus a full simulated
## playthrough (buildParty/buildEnemies/grantDrops/afterWaveCleared/onWipe)
## with the same seed and win/lose loop, for a bit-exact diff.
func _run_progression_suite() -> void:
	if not FarroadCore.load_real_content():
		print(JSON.stringify({"error": "failed to load content.json"}))
		return
	var out := {}

	var waves := [1, 5, 20, 21, 40, 41, 100, 101, 227, 500, 800, 1000, 3000]
	var math_out := []
	for w in waves:
		math_out.append({
			"w": w, "isBoss": FarroadProgression.is_boss_wave(w), "nextBoss": FarroadProgression.next_boss_wave(w),
			"hardMul": FarroadProgression.hard_mul(w), "bossSpdMul": FarroadProgression.boss_spd_mul(w),
			"killReward": FarroadProgression.kill_reward(w, 3), "bossAether": FarroadProgression.boss_aether(w),
			"dupUnitAether": FarroadProgression.dup_unit_aether(w), "idlePerSec": FarroadProgression.idle_per_sec(w),
			"enemyCount": FarroadProgression.enemy_count(w)})
	out["math"] = math_out

	var checkpoints := []
	for n in [0, 1, 2, 3, 5]:
		checkpoints.append(FarroadProgression.checkpoint(n))
	out["checkpoints"] = checkpoints

	var slots := []
	for l in [1, 9, 10, 99, 100, 499, 500, 999, 1000, 1500]:
		slots.append({"l": l, "slots": FarroadProgression.slots_at(l), "next": FarroadProgression.next_slot_at(l)})
	out["slots"] = slots

	var leveling := []
	for pair in [[1, 1], [10, 1], [10, 50], [100, 100], [1000, 1000]]:
		leveling.append({"l": pair[0], "r": pair[1], "cost": FarroadProgression.cost_to_next(pair[0], pair[1])})
	out["leveling"] = leveling

	var g := FarroadProgression.new_game(7, null)
	FarroadProgression.start_wave(g, 1)
	var trace := []
	for i in range(60):
		var guard := 0
		while g["battle"]["over"] == null and guard < 1000:
			guard += 1
			var e = FarroadCore.step(g["battle"])
			if e == null:
				break
		var w: int = g["wave"]
		var entry := {"wave": w, "outcome": g["battle"]["over"]}
		if g["battle"]["over"] == "party":
			entry["events"] = FarroadProgression.after_wave_cleared(g)
			entry["aether"] = g["aether"]; entry["marks"] = g["marks"]; entry["lore"] = g["lore"]
			entry["party"] = g["party"].duplicate(); entry["actions"] = g["actions"].duplicate()
			entry["conditions"] = g["conditions"].duplicate()
			trace.append(entry)
			FarroadProgression.start_wave(g, w + 1)
		else:
			entry["events"] = FarroadProgression.on_wipe(g)
			entry["aether"] = g["aether"]; entry["marks"] = g["marks"]; entry["lore"] = g["lore"]
			trace.append(entry)
	out["trace"] = trace

	# Step 3c: GAMBITS -- loadout sync + party bench/field, mirrors
	# parity-reference.js's own 'gambits' section exactly (same scenario).
	var g2 := FarroadProgression.new_game(7, null)
	FarroadProgression.start_wave(g2, 1)
	FarroadProgression.join_companion(g2, "ansa")
	g2["actions"].append("sear")
	g2["loadout"]["kesh"] = [{"cond": "none", "action": "sear"}, {"cond": "none", "action": "strike"}]
	FarroadProgression.sync_loadout(g2, "kesh")
	var gambits := {
		"keshLiveSlot0": g2["units"][0]["slots"][0],
		"holderExcludeNone": FarroadProgression.action_holder_in_party(g2, "sear", ""),
		"holderExcludeAnsa": FarroadProgression.action_holder_in_party(g2, "sear", "ansa"),
		"holderExcludeKesh": FarroadProgression.action_holder_in_party(g2, "sear", "kesh"),
		"holderStarter": FarroadProgression.action_holder_in_party(g2, "strike", ""),
		"availableFielded": FarroadProgression.available_for_party(g2)}
	gambits["benchAnsa"] = FarroadProgression.bench_unit(g2, "ansa")
	gambits["partyAfterBench"] = g2["party"].duplicate()
	gambits["availableBenched"] = FarroadProgression.available_for_party(g2)
	gambits["benchKeshRefused"] = FarroadProgression.bench_unit(g2, "kesh")
	gambits["partyAfterRefusedBench"] = g2["party"].duplicate()
	gambits["fieldAnsa"] = FarroadProgression.field_unit(g2, "ansa")
	gambits["partyAfterField"] = g2["party"].duplicate()
	gambits["fieldUnowned"] = FarroadProgression.field_unit(g2, "vey")
	out["gambits"] = gambits

	# Step 3d: AETHER -- leveling + Recovery + Evade/Crit + Affinity
	# purchases, mirrors parity-reference.js's own 'aether' section exactly.
	var g3 := FarroadProgression.new_game(7, null)
	FarroadProgression.start_wave(g3, 1)
	g3["aether"] = 100000
	var aether := {"costNextL1": FarroadProgression.cost_next(g3, "kesh")}
	aether["feed250"] = FarroadProgression.spend_feed(g3, "kesh", 250)
	aether["levelAfterFeed"] = FarroadProgression.level_of(g3, "kesh")
	aether["aetherAfterFeed"] = g3["aether"]
	aether["recoveryBefore"] = FarroadProgression.recovery_of(g3, "kesh")
	FarroadProgression.spend_recovery(g3, "kesh")
	aether["recoveryAfter"] = FarroadProgression.recovery_of(g3, "kesh")
	aether["fireBefore"] = FarroadProgression.affinity_raw(g3, "kesh", "fire")
	FarroadProgression.spend_affinity(g3, "kesh", "fire")
	aether["fireAfter"] = FarroadProgression.affinity_raw(g3, "kesh", "fire")
	aether["evadeBefore"] = FarroadProgression.pct_stat_value(g3, "kesh", "evade")
	FarroadProgression.spend_pct_stat(g3, "kesh", "evade")
	aether["evadeAfter"] = FarroadProgression.pct_stat_value(g3, "kesh", "evade")
	g3["aether"] = 0
	var aether_before_refuse = g3["aether"]
	aether["refusedFeed"] = FarroadProgression.spend_feed(g3, "kesh", 50)
	aether["aetherUnchanged"] = (g3["aether"] == aether_before_refuse)
	out["aether"] = aether

	print(JSON.stringify(out))

## Step 3a: FarroadSave.gd -- mirrors parity-reference.js's 'save' mode
## exactly: the same hand-built G, the same 17 RNG draws before serializing,
## the same post-restore RNG-position proof, and the same sparse/migration
## snapshot.
func _run_save_suite() -> void:
	if not FarroadCore.load_real_content():
		print(JSON.stringify({"error": "failed to load content.json"}))
		return
	var g := {
		"seed": 999, "rng": FarroadCore.make_rng(999), "wave": 5, "farthest": 5, "bossesCleared": 0,
		"aether": 42.5, "lore": 3, "marks": 7.25, "wipes": 1,
		"party": ["kesh", "ansa"], "actions": ["strike", "ember", "sear"], "conditions": ["none", "foe_lowest_hp"],
		"actionCounts": {"sear": 1}, "condCounts": {"foe_lowest_hp": 1}, "bonuses": {"strike": {"potent": 2}},
		"recovery": {"kesh": 3}, "loadout": {"kesh": [{"cond": "none", "action": "strike"}]},
		"hpCarry": {"kesh": 0.8}, "touched": {"kesh": true}, "clearedWaves": {1: 1, 2: 1, 3: 1, 4: 1},
		"dropsGranted": {1: 1, 2: 1, 3: 1, 4: 1, 5: 1},
		"lvl": {"kesh": 3, "ansa": 1}, "bank": {"kesh": 12, "ansa": 0}, "maxLevelEver": 3, "owned": {"kesh": 1, "ansa": 1},
		"enrage": true, "idleAcc": 1.5, "dropQueue": [{"name": "Sear"}], "dropHistory": [{"name": "Sear"}],
		"pullsSinceUnit": 4, "dropGains": {"lore": 2, "aether": 10},
		"mc": null, "expeditions": [], "dungeons": [], "quests": {"kesh": {"stage": 0, "frozen": []}},
		"directions": {"west": {"maxDepth": 3, "dungeonsUnlocked": 1}},
		"affinities": {"kesh": {"fire": 2}, "ansa": {}}, "statInvest": {"kesh": {"evade": 1}, "ansa": {}},
		"equipInv": {"emberwardencrown": 1}, "equipped": {"kesh": {"head": "emberwardencrown"}, "ansa": {}},
		"superBossQuests": [], "superBossesUnlocked": 0, "superBossesCleared": {}}
	for i in range(17):
		g["rng"].next()

	var out := {}
	var snap := FarroadSave.serialize(g, 1234567890)
	out["snapRngCalls"] = snap["rngCalls"]
	var restored := FarroadSave.deserialize(snap)
	out["restoredWave"] = restored["wave"]
	out["restoredParty"] = restored["party"]
	out["restoredAffinities"] = restored["affinities"]
	out["restoredEquipped"] = restored["equipped"]
	var orig_next := []
	var restored_next := []
	for j in range(10):
		orig_next.append(g["rng"].next())
	for j in range(10):
		restored_next.append(restored["rng"].next())
	out["rngMatch"] = (orig_next == restored_next)
	out["origNext"] = orig_next
	out["restoredNext"] = restored_next

	var sparse := {"v": 1, "savedAt": 1, "seed": 5, "rngCalls": 0, "wave": 3, "farthest": 3, "party": ["kesh"],
		"clearedWaves": {1: 1, 2: 1}}
	var migrated := FarroadSave.deserialize(sparse)
	out["migrated"] = {
		"dropsGranted": migrated["dropsGranted"], "owned": migrated["owned"], "lvl": migrated["lvl"],
		"bank": migrated["bank"], "affinities": migrated["affinities"], "statInvest": migrated["statInvest"],
		"equipped": migrated["equipped"], "directions": migrated["directions"], "quests": migrated["quests"],
		"expeditions": migrated["expeditions"], "enrage": migrated["enrage"], "actions": migrated["actions"],
		"conditions": migrated["conditions"]}

	print(JSON.stringify(out))

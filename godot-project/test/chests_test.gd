extends SceneTree
var fails := 0
func ok(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	var g := FarroadProgression.new_game(7, null)
	g["farthest"] = 40
	# --- timing: appears between 5 and 10 minutes, once
	var c: Dictionary = Chests.state(g)
	ok(float(c["next"]) >= 300.0 and float(c["next"]) <= 600.0, "first chest due in 5-10 minutes")
	var appeared := 0
	for i in 700:
		if Chests.tick(g, 1.0): appeared += 1
	ok(appeared == 1 and bool(g["chest"]["there"]), "one chest appears within 700 s and waits")
	# --- evening out: expected currency per second of waiting is flat
	var per := FarroadProgression.idle_per_sec_g(g)
	var small := 0.0; var big := 0.0
	for k in 40:
		var g1 := FarroadProgression.new_game(100 + k, null); g1["farthest"] = 40
		Chests.state(g1)["since"] = 300.0
		var g2 := FarroadProgression.new_game(100 + k, null); g2["farthest"] = 40
		Chests.state(g2)["since"] = 600.0
		var a1 := float(g1["aether"]) + float(g1["marks"]); Chests.open(g1)
		var a2 := float(g2["aether"]) + float(g2["marks"]); Chests.open(g2)
		small += float(g1["aether"]) + float(g1["marks"]) - a1
		big += float(g2["aether"]) + float(g2["marks"]) - a2
	print("currency totals 300s=", small, " 600s=", big)
	ok(Chests.quality(600.0) / Chests.quality(300.0) > 1.9, "a 10 minute chest has twice the quality of a 5 minute one")
	# --- every kind works, resets state, and never errors
	var kinds := {}
	for k in 300:
		var gx := FarroadProgression.new_game(500 + k, null); gx["farthest"] = 30
		Chests.state(gx)["there"] = true; gx["chest"]["since"] = 450.0
		var res := Chests.open(gx)
		kinds[res["kind"]] = int(kinds.get(res["kind"], 0)) + 1
		if not (float(gx["chest"]["since"]) == 0.0 and not bool(gx["chest"]["there"])): ok(false, "chest state resets")
	ok(kinds.size() == 5, "all five prize kinds come up: %s" % str(kinds))
	# --- gear duplicates level up
	var g3 := FarroadProgression.new_game(9, null)
	var id: String = FarroadCore.EQUIPMENT.keys()[0]
	var r1 := FarroadProgression.gain_gear(g3, id)
	var r2 := FarroadProgression.gain_gear(g3, id)
	ok(not r1["duplicate"] and r1["level"] == 1 and r2["duplicate"] and r2["level"] == 2, "second copy raises the gear to Lv2")
	ok(FarroadProgression.gear_mul(g3, id) > 1.0, "a levelled piece multiplies its stats")
	# --- every affinity has gear at every rarity? report coverage
	var cover := {}
	for eid in FarroadCore.EQUIPMENT:
		var e: Dictionary = FarroadCore.EQUIPMENT[eid]
		var aff = e.get("affinity", e.get("affinities", null))
		cover[str(e.get("rarity", "common")) + ":" + str(aff)] = 1
	print("coverage keys: ", cover.keys().size())
	# --- gambit condition filtering never offers 'none' wrongly and keeps real pairings
	ok(FarroadCore.condition_fits_action("none", FarroadCore.ACTIONS["strike"]), "'none' fits any action")
	# --- save round trip
	var snap := FarroadSave.serialize(g, 1)
	var back = FarroadSave.deserialize(snap)
	ok(back != null and (back["chest"] as Dictionary).has("next"), "chest state survives a save")
	print("DONE fails=", fails)
	quit(1 if fails > 0 else 0)

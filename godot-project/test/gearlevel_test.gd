extends SceneTree
var fails := 0
func ok(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	# --- save versioning and migration
	ok(FarroadSave.VERSION == 3, "save VERSION is 3")
	var g := FarroadProgression.new_game(7, null)
	var wid := ""
	for id in FarroadCore.EQUIPMENT:
		if FarroadCore.EQUIPMENT[id]["slot"] != null and wid == "":
			wid = id
	g["equipInv"][wid] = 3
	var snap := FarroadSave.serialize(g, 1)
	snap["v"] = 2
	var back = FarroadSave.deserialize(snap)
	ok(int(back["equipInv"][wid]) == 1 and int(back["gearLevel"][wid]) == 3, "a v2 save with 3 copies loads as Lv3, one piece")
	var newer := FarroadSave.serialize(g, 1); newer["v"] = 4
	ok(FarroadSave.is_from_newer_build(newer), "a v4 save is refused by this build")
	# --- two wearers: one loses the piece, with a note
	var g2 := FarroadProgression.new_game(8, null)
	g2["equipInv"][wid] = 1
	var slot: String = str(FarroadCore.EQUIPMENT[wid]["slot"])
	g2["equipped"]["kesh"] = {slot: wid}
	g2["equipped"]["wren"] = {slot: wid}
	FarroadProgression.migrate_gear(g2)
	var holders := 0
	for u in g2["equipped"]: if (g2["equipped"][u] as Dictionary).values().has(wid): holders += 1
	ok(holders == 1 and (g2.get("_gearNotes", []) as Array).size() == 1, "second wearer stripped, one note: %s" % str(g2.get("_gearNotes")))
	print(g2.get("_gearNotes"))
	# --- Arena: gear level in the team changes Power and the fight inputs, and is bounded
	var g3 := FarroadProgression.new_game(9, null)
	g3["farthest"] = 40
	g3["party"] = ["wren"]; g3["owned"]["wren"] = 1; g3["lvl"]["wren"] = 30
	var best := -1.0
	for id in FarroadCore.EQUIPMENT:
		var e: Dictionary = FarroadCore.EQUIPMENT[id]
		var tot := 0.0
		for k in ["atk", "mag", "def", "res", "spd", "hp"]: tot += float(e.get(k, 0.0))
		if tot > best and e.get("slot") != null:
			best = tot; wid = id
	for sn in FarroadCore.EQUIPMENT_SLOTS:
		if FarroadProgression.equip_kind_for_slot(str(sn)) == FarroadCore.EQUIPMENT[wid]["slot"]:
			slot = str(sn)
			break
	g3["equipInv"][wid] = 1; g3["gearLevel"][wid] = 1
	g3["equipped"]["wren"] = {slot: wid}
	var t1 := Ranked.team_from_game(g3)
	g3["gearLevel"][wid] = 25
	var t11 := Ranked.team_from_game(g3)
	ok(not (t1["units"][0]["gearLevel"] as Dictionary).has(wid) and int(t11["units"][0]["gearLevel"][wid]) == 25, "team carries gearLevel only when above 1")
	ok(Ranked.power_of(t11) > Ranked.power_of(t1), "levelled gear raises Arena Power (%d -> %d)" % [Ranked.power_of(t1), Ranked.power_of(t11)])
	var u1: Dictionary = Ranked.build_units(t1)[0]
	var u11: Dictionary = Ranked.build_units(t11)[0]
	var bad: Dictionary = t11.duplicate(true)
	bad["units"][0]["gearLevel"][wid] = 999
	ok(Ranked.validate(bad) == "bad_gear", "gear level 999 is refused")
	var bad2: Dictionary = t11.duplicate(true)
	bad2["units"][0]["gearLevel"]["not_worn"] = 3
	ok(Ranked.validate(bad2) == "bad_gear", "a level for an unworn piece is refused")
	ok(Ranked.validate(t11) == "", "a legitimate levelled team validates (%s)" % Ranked.validate(t11))
	# normal Power and Arena Power agree
	print("DONE fails=", fails)
	quit(1 if fails > 0 else 0)

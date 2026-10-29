extends SceneTree
var fails := 0
func ok(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	var ids := FarroadProgression.affinity_action_ids()
	ok(ids.size() == 16, "16 affinity buff/debuff actions (got %d)" % ids.size())
	var g := FarroadProgression.new_game(11, null)
	g["wave"] = 40; g["farthest"] = 40; g["marks"] = 1.0e9
	var hits := 0; var max_gap := 0; var gap := 0; var units := 0
	var n := 3000
	for i in n:
		var r := FarroadProgression.do_pull(g, "aff")
		if r["kind"] == "unit" or r["kind"] == "unit_dup": units += 1
		gap += 1
		if r["kind"] == "action" and ids.has(r["id"]):
			hits += 1
			max_gap = maxi(max_gap, gap); gap = 0
	var rate := float(hits) / n
	print("banner rate ", rate, " longest drought ", max_gap)
	ok(rate > 0.09 and rate < 0.16, "banner hit rate about 10%%+")
	ok(max_gap <= FarroadProgression.AFF_PITY_AT, "never more than 30 pulls without one")
	ok(units == 0, "no companions from the banner")
	ok(int(g["pullsSinceUnit"]) == 0, "banner pulls leave the unit pity alone")
	# pity alone
	var g2 := FarroadProgression.new_game(12, null)
	g2["wave"] = 40; g2["farthest"] = 40; g2["marks"] = 1.0e9; g2["pullsSinceAff"] = 29
	var r2 := FarroadProgression.do_pull(g2, "aff")
	ok(ids.has(r2["id"]) and r2["pity"] and g2["pullsSinceAff"] == 0, "30th pull is a guaranteed pity hit and resets")
	# standard banner unchanged
	var g3 := FarroadProgression.new_game(13, null)
	g3["wave"] = 40; g3["farthest"] = 40; g3["marks"] = 1.0e9
	FarroadProgression.do_pull(g3)
	ok(int(g3["pullsSinceUnit"]) == 1 and int(g3["pullsSinceAff"]) == 0, "standard pull counts only the unit pity")
	print("DONE fails=", fails)
	quit(1 if fails > 0 else 0)

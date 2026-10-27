extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	if c: print("PASS ", m)
	else:
		print("FAIL ", m); fails += 1
func _initialize():
	await process_frame
	FarroadCore.load_real_content()
	var now := 1800000000
	var g := FarroadProgression.new_game(7, null)
	var r := Paths.new_run(g, now)
	# gambits you set stay set when drops arrive
	r["actions"].append("pierce"); r["actions"].append("cleave")
	Paths.set_slot(g, r, "kesh", 1, "none", "pierce")
	var before: Array = (r["loadout"]["kesh"] as Array).duplicate(true)
	var meta := {"kind": "path", "row": 0, "col": 0, "diff": 1, "boss": false, "level": 1, "name": "x", "enemies": 2}
	for i in 6:
		Paths.finish_fight(g, meta, "party", [{"id": "kesh", "hp": 100.0, "maxHp": 100.0}], 2, now)
		meta["row"] = i + 1
	ok(JSON.stringify(r["loadout"]["kesh"]) == JSON.stringify(before), "an edited loadout survives fights and their drops")
	# the run only ends when the MC is down
	var g2 := FarroadProgression.new_game(7, null)
	var r2 := Paths.new_run(g2, now)
	var ev := Paths.finish_fight(g2, meta, "enemy", [{"id": "kesh", "hp": 50.0, "maxHp": 100.0}], 2, now)
	ok(not ev["ended"] and Paths.active(g2), "MC alive at the end: the run goes on even if the fight wasn't won")
	var ev2 := Paths.finish_fight(g2, meta, "enemy", [{"id": "kesh", "hp": 0.0, "maxHp": 100.0}], 2, now)
	ok(ev2["ended"] and not Paths.active(g2), "MC down: the run ends")
	# enemy counts follow difficulty
	var g3 := FarroadProgression.new_game(7, null)
	var r3 := Paths.new_run(g3, now)
	var counts := {0: [], 1: [], 2: []}
	for lv in [1, 3]:
		r3["level"] = lv
		for row in [2, 5, 8]:
			for d in 3:
				r3["map"][row][0] = {"t": "fight", "d": d, "next": [0]}
				var tot := 0.0
				var n := 0
				for rep in 6:
					g3["n"] = rep
					r3["n"] = rep * 7 + row
					var f := Paths.build_fight(g3, r3, row, 0)
					var ens: Array = f["battle"]["units"].filter(func(u): return not u["isParty"])
					n += ens.size()
				(counts[d] as Array).append(float(n) / 6.0)
	var avg := func(a: Array): 
		var t := 0.0
		for x in a: t += float(x)
		return t / float(a.size())
	print("NOTE average enemy count easy/medium/hard: ", snappedf(avg.call(counts[0]), 0.01), " / ", snappedf(avg.call(counts[1]), 0.01), " / ", snappedf(avg.call(counts[2]), 0.01))
	ok(avg.call(counts[0]) < avg.call(counts[1]) and avg.call(counts[1]) < avg.call(counts[2]), "harder fights have more enemies")
	print("DONE fails=", fails)
	quit()

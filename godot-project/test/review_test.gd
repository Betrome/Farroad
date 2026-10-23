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
	# ---- Paths: save, reload, continue the same run (open event; fight in flight)
	var g := FarroadProgression.new_game(7, null)
	var r := Paths.new_run(g, now)
	var opt: Array = Paths.options(r)[0]
	r["fight"] = [int(opt[0]), int(opt[1])]
	var g2 := FarroadSave.deserialize(FarroadSave.serialize(g, now))
	var f2 = Paths.run(g2).get("fight")
	ok(f2 is Array and int(f2[0]) == int(opt[0]) and int(f2[1]) == int(opt[1]), "a fight in flight survives save and load")
	ok(JSON.stringify(JSON.parse_string(JSON.stringify(Paths.run(g2)["map"]))) == JSON.stringify(JSON.parse_string(JSON.stringify(r["map"]))), "the map and trail are the same after a reload")
	for i in 3:
		var o: Array = Paths.options(r)
		var n := Paths.node_at(r, int(o[0][0]), int(o[0][1]))
		if String(n["t"]) == "event":
			Paths.open_event(r, int(o[0][0]), int(o[0][1]))
			break
		r["trail"].append([int(o[0][0]), int(o[0][1])]); r["row"] = int(o[0][0])
	if r.get("event") != null:
		var g3 := FarroadSave.deserialize(FarroadSave.serialize(g, now))
		ok(String(Paths.run(g3)["event"]) == String(r["event"]), "an open event is still open after a reload")
	else:
		print("NOTE no event in the first rows of this map")
	# finish_fight clears the in-flight marker
	var meta := {"kind": "path", "row": 0, "col": 0, "diff": 0, "boss": false, "level": 1, "name": "x", "enemies": 1}
	Paths.finish_fight(g, meta, "party", [{"id": "kesh", "hp": 10.0, "maxHp": 20.0}], 1, now)
	ok(not Paths.run(g).has("fight"), "finish_fight clears the marker")
	# ---- Lore isolation
	var gb := FarroadProgression.new_game(7, null)
	gb["bonuses"] = {"strike": {"potent": 5}}
	FarroadCore.apply_bonuses(gb["bonuses"])
	var base_pow := float(FarroadCore.ACTIONS["strike"]["power"])
	Paths.new_run(gb, now)
	var ob: Array = Paths.options(Paths.run(gb))[0]
	Paths.build_fight(gb, Paths.run(gb), int(ob[0]), int(ob[1]))
	ok(float(FarroadCore.ACTIONS["strike"]["power"]) < base_pow, "a path fight runs without your Lore (strike %.2f -> %.2f)" % [base_pow, float(FarroadCore.ACTIONS["strike"]["power"])])
	FarroadCore.apply_bonuses(gb["bonuses"])
	ok(is_equal_approx(float(FarroadCore.ACTIONS["strike"]["power"]), base_pow), "and your Lore is put back")
	FarroadCore.apply_bonuses({})
	# ---- pct_base
	var boss := {"maxHp": 5000000.0, "dotBase": 100000.0}
	var plain := {"maxHp": 1000.0}
	ok(FarroadCore.pct_base(boss) == 100000.0 and FarroadCore.pct_base(plain) == 1000.0, "pct_base: dotBase for a raid boss, max HP otherwise")
	# ---- Goals paused during the offline replay
	var gg := FarroadProgression.new_game(7, null)
	Goals.paused = true
	Goals.record(gg, "enemies_defeated", 50.0)
	Goals.paused = false
	var before := JSON.stringify(gg["goals"])
	Goals.record(gg, "enemies_defeated", 5.0)
	ok(JSON.stringify(gg["goals"]) != before, "goals record again once the replay is over")
	# ---- SaveCheck allowances
	var s1 := {"farthest": 300, "lvl": {"kesh": 90}, "aether": 1000, "marks": 2000, "crystal": 10}
	var s2: Dictionary = s1.duplicate(true)
	s2["crystal"] = 10 + 35
	s2["marks"] = 2000 + 1800
	ok(SaveCheck.check(s1, s2, 180.0, SaveCheck.new_credit(now)) == "", "Champion + raid Platinum in one upload passes with the starting credit")
	s2["crystal"] = 10 + 5000
	ok(SaveCheck.check(s1, s2, 180.0) == "too_much_crystal", "a made-up Crystal haul is still caught")
	# ---- SaveCheck ledger (how the server draws down credit)
	var T0 := 1800000000
	var cred := SaveCheck.new_credit(T0)
	var cur: Dictionary = {"farthest": 300, "lvl": {"kesh": 90}, "aether": 1000, "marks": 2000, "crystal": 10}
	var tt := T0
	var accepted := 0
	for i in 40:
		tt += 180
		SaveCheck.accrue(cred, tt)
		var nxt: Dictionary = cur.duplicate(true)
		nxt["crystal"] = int(cur["crystal"]) + 35
		var why := SaveCheck.check(cur, nxt, 180.0, cred)
		if why != "":
			break
		SaveCheck.spend_credit(cred, cur, nxt, 180.0)
		cur = nxt
		accepted += 1
	ok(accepted < 40, "+35 Crystal every 3 minutes is cut off once the credit is gone (%d of 40 accepted; the flat headroom per upload still lets small gains through)" % accepted)
	# one upload after 8 quiet weeks claiming 8 weeks of raid rewards passes
	var c2 := SaveCheck.new_credit(T0)
	var t8 := T0 + int(8.0 * SaveCheck.WEEK_SEC)
	SaveCheck.accrue(c2, t8)
	var p2: Dictionary = {"farthest": 300, "lvl": {"kesh": 90}, "aether": 1000, "marks": 2000, "crystal": 10}
	var n2: Dictionary = p2.duplicate(true)
	n2["crystal"] = 10 + 8 * 10
	n2["marks"] = 2000 + 8 * 800
	ok(SaveCheck.check(p2, n2, 8.0 * SaveCheck.WEEK_SEC, c2) == "", "one upload claiming 8 weeks of raid rewards passes")
	# a season claim credits exactly what it paid, once
	var c3 := SaveCheck.new_credit(T0)
	c3["crystal"] = 0.0
	SaveCheck.add_claim(c3, 25.0, 1000.0, 5.0)
	var n3: Dictionary = p2.duplicate(true)
	n3["crystal"] = 10 + 25
	ok(SaveCheck.check(p2, n3, 180.0, c3) == "", "a claimed Champion reward passes the next upload")
	# ---- AutoInvest: time it on the real save, and check the game isn't touched
	var path: String = OS.get_environment("APPDATA") + "/Godot/app_userdata/Farroad/save.json"
	if FileAccess.file_exists(path):
		var d = JSON.parse_string(FileAccess.get_file_as_string(path))
		var gr := FarroadSave.deserialize(d if d is Dictionary else {})
		var uid := String(gr["party"][0])
		var h_before := JSON.stringify([gr["lvl"], gr["bank"], gr["recovery"], gr["statInvest"], gr["affinities"], gr.get("maxLevelEver")]).sha256_text()
		var t := Time.get_ticks_msec()
		var plan := AutoInvest.plan(gr, uid, float(gr["aether"]))
		var ms := Time.get_ticks_msec() - t
		print("NOTE AutoInvest.plan on the real save (wave ", gr.get("wave"), ", party ", gr["party"].size(), "): ", ms, " ms, ", plan["steps"].size(), " steps")
		var h_after := JSON.stringify([gr["lvl"], gr["bank"], gr["recovery"], gr["statInvest"], gr["affinities"], gr.get("maxLevelEver")]).sha256_text()
		ok(h_before == h_after, "AutoInvest.plan leaves the real game untouched")
		ok(ms < 1500, "one unit's plan takes under 1.5 s (%d ms)" % ms)
	print("DONE fails=", fails)
	quit()

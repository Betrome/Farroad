extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c: fails += 1

func _level_all(g: Dictionary, r: Dictionary) -> void:
	var guard := 0
	while guard < 500:
		guard += 1
		var best := ""
		var best_lv := 1 << 30
		for uid in r["party"]:
			var lv := int(r["lvl"][uid])
			if lv < best_lv and Paths.level_cost(g, r, uid) <= float(r["aether"]):
				best_lv = lv
				best = uid
		if best == "" or not Paths.level_up(g, r, best):
			break

func _play(g: Dictionary, seed: int, now: int) -> Dictionary:
	var r := Paths.new_run(g, now + seed)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var steps := 0
	var lost := 0
	var events := 0
	var recruits := 0
	while bool(r["active"]) and steps < 200:
		steps += 1
		_level_all(g, r)
		var opts := Paths.options(r)
		var pick: Array = opts[rng.randi_range(0, opts.size() - 1)]
		var node := Paths.node_at(r, pick[0], pick[1])
		if String(node["t"]) == "event":
			events += 1
			var e := Paths.open_event(r, pick[0], pick[1])
			Paths.resolve_event(g, r, rng.randi_range(0, (e["opts"] as Array).size() - 1))
			if (r["party"] as Array).is_empty() or not (r["party"] as Array).has("kesh"):
				Paths.end_if_wiped(g, now)
			continue
		var fight := Paths.build_fight(g, r, pick[0], pick[1])
		var b: Dictionary = fight["battle"]
		var guard := 0
		while b["over"] == null and guard < 400:
			guard += 1
			if FarroadCore.step(b) == null: break
		var res := "party" if b["over"] == "party" else "enemy"
		var snap := Paths.snapshot_battle(b)
		var ev := Paths.finish_fight(g, fight["meta"], res, snap, int(fight["meta"]["enemies"]), now)
		lost += (ev["lost"] as Array).size()
	return {"cleared": int(r["cleared"]), "rows": int(r["rowsDone"]), "steps": steps, "lost": (r["lost"] as Array).size(), "party": (r["party"] as Array).size(), "victory": bool(r.get("result", {}).get("victory", false)), "actions": (r["actions"] as Array).size(), "events": events, "level_kesh": int(r["lvl"].get("kesh", 1))}

func _initialize():
	FarroadCore.load_real_content()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("mul="): Paths.AETHER_MUL = float(a.substr(4))
	print("PATHS Aether multiplier ", Paths.AETHER_MUL)
	# ---- map invariants
	var all_ok := true
	for seed in range(1, 60):
		for lvl in range(1, 6):
			var m := Paths.gen_map(seed, lvl)
			if m.size() != 10 or (m[9] as Array).size() != 1 or m[9][0]["t"] != "boss": all_ok = false
			# every node of row r+1 reachable from row r; every node leads on
			for r in range(9):
				for c in (m[r] as Array).size():
					if (m[r][c]["next"] as Array).is_empty(): all_ok = false
				for j in (m[r + 1] as Array).size():
					var reached := false
					for c in (m[r] as Array).size():
						if (m[r][c]["next"] as Array).has(j): reached = true
					if not reached: all_ok = false
				for row_c in (m[r] as Array):
					if (row_c["next"] as Array).size() > 2: all_ok = false
	ok(all_ok, "all maps: 10 rows, a single boss at the end, every node leads on and is reachable, at most 2 exits")
	# branching and converging exist
	var branches := 0
	var merges := 0
	for seed in range(1, 40):
		var m := Paths.gen_map(seed, 1)
		for r in range(9):
			for c in (m[r] as Array).size():
				if (m[r][c]["next"] as Array).size() == 2: branches += 1
			for j in (m[r + 1] as Array).size():
				var incoming := 0
				for c in (m[r] as Array).size():
					if (m[r][c]["next"] as Array).has(j): incoming += 1
				if incoming >= 2: merges += 1
	ok(branches > 40 and merges > 40, "paths branch and converge (%d forks, %d merges over 39 maps)" % [branches, merges])
	ok(Paths.node_wave(1, 9) == 20 and Paths.node_wave(5, 9) == 100 and FarroadProgression.is_boss_wave(Paths.node_wave(3, 9)), "a level's boss sits on a boss wave (20, 40 ... 100)")
	# ---- a new run
	var g := FarroadProgression.new_game(7, null)
	g["aether"] = 12345.0
	g["lvl"]["kesh"] = 80
	var r := Paths.new_run(g, 1800000000)
	ok(int(r["lvl"]["kesh"]) == 1 and float(r["aether"]) == 0.0 and (r["party"] as Array) == ["kesh"], "a run starts with the main character at level 1 and nothing from the main game")
	ok((r["actions"] as Array).size() == 2 and (r["conditions"] as Array) == ["none"], "two starter actions and no gambits")
	ok(float(g["aether"]) == 12345.0 and int(g["lvl"]["kesh"]) == 80, "the main game is untouched by a run")
	# save round trip
	var snap := FarroadSave.serialize(g, 1800000000)
	var g2 := FarroadSave.deserialize(snap)
	ok(g2["path"]["run"]["level"] == 1 and g2["path"]["run"]["map"].size() == 10, "a run survives save and load")
	# crystals: once per level per day
	var g3 := FarroadProgression.new_game(7, null)
	var t0 := 1800000000
	ok(Paths.pay_depth(g3, 2, t0) == 2 and int(g3["crystal"]) == 2, "2 levels cleared = 2 Crystal")
	ok(Paths.pay_depth(g3, 2, t0 + 3600) == 0, "the same levels again the same day pay nothing")
	ok(Paths.pay_depth(g3, 3, t0 + 7200) == 1, "a deeper run pays only the new level")
	ok(Paths.pay_depth(g3, 2, t0 + 86400 * 2) == 2, "the next day pays again")
	# ---- bot runs
	var results := []
	var now := 1800000000
	for seed in range(1, 41):
		var gg := FarroadProgression.new_game(7, null)
		results.append(_play(gg, seed, now))
	var depth := {}
	var victories := 0
	var total_lost := 0
	var total_recruits := 0
	for res in results:
		depth[res["cleared"]] = int(depth.get(res["cleared"], 0)) + 1
		if res["victory"]: victories += 1
		total_lost += int(res["lost"])
	print("PATHS bot runs (random routes, auto-level): levels cleared -> runs ", depth, "; victories ", victories, "; units lost in total ", total_lost)
	for res in results.slice(0, 5):
		print("PATHS   ", res)
	ok(results.size() == 40 and int(results[0]["steps"]) > 0, "bot runs finish")
	print("DONE fails=", fails)
	quit()

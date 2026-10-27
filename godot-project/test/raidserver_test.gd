extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	if c: print("PASS ", m)
	else:
		print("FAIL ", m); fails += 1
func _initialize():
	await process_frame
	FarroadCore.load_real_content()
	var srv = load("res://scripts/ArenaServer.gd").new()
	var store := ArenaStore.new()
	store.data_dir = "user://raid_test_" + str(Time.get_ticks_msec())
	root.add_child(store)
	await process_frame
	srv.store = store
	await store.open()
	var key := "k".repeat(40)
	# the server's clock: Thursday noon UTC of this week, so "yesterday" is still this week
	var wk0 := Seasons.season_of(Time.get_unix_time_from_system())
	var monday := Seasons.season_end(wk0) - 7 * 86400
	srv.time_offset = monday + 3 * 86400 + 12 * 3600 - int(Time.get_unix_time_from_system())
	var body := {"id": "AAAAAAAAA", "key": key, "week": 0, "pct": 0.05}
	# off by default
	var r = await srv._raid_state({"id": "AAAAAAAAA", "key": key})
	ok(r[1].get("error") == "raids_off", "off: /raid/state answers raids_off")
	srv.raids_enabled = true
	var rec = await srv._auth({"id": "AAAAAAAAA", "key": key}, true)
	var rec2 = await srv._auth({"id": "BBBBBBBBB", "key": key}, true)
	var week := Seasons.season_of(srv._now())
	r = await srv._raid_state({"id": "AAAAAAAAA", "key": key})
	ok(r[0] == 200 and int(r[1]["week"]) == week and float(r[1]["target"]) == Raids.COMMUNITY_MIN_TARGET and float(r[1]["shares"]) == 0.0, "state: this week, the minimum target, no damage yet")
	body["week"] = week
	r = await srv._raid_report(body)
	ok(is_equal_approx(float(r[1]["shares"]), 0.05) and is_equal_approx(float(r[1]["mine"]), 0.05), "a report adds its share")
	body["pct"] = 5.0
	r = await srv._raid_report(body)
	ok(is_equal_approx(float(r[1]["shares"]), Raids.PLAYER_WEEK_CAP) and is_equal_approx(float(r[1]["mine"]), Raids.PLAYER_WEEK_CAP), "a player adds at most one whole boss (%.1f)" % Raids.PLAYER_WEEK_CAP)
	var before := float(r[1]["shares"])
	r = await srv._raid_report(body)
	ok(is_equal_approx(float(r[1]["shares"]), before), "nothing more from them that week")
	var other := {"id": "BBBBBBBBB", "key": key, "week": week, "pct": 0.02}
	r = await srv._raid_report(other)
	ok(is_equal_approx(float(r[1]["shares"]), before + 0.02) and int(r[1]["contributors"]) == 2, "another player adds to the same bar")
	var wrong := {"id": "AAAAAAAAA", "key": key, "week": week - 1, "pct": 0.05}
	r = await srv._raid_report(wrong)
	ok(r[1].get("error") == "wrong_week", "a report for another week is refused")
	# attempts made offline on earlier days are told later and counted on their own day
	var today := int(floor(float(srv._now()) / 86400.0))
	var c := {"id": "CCCCCCCCC", "key": key, "week": week, "pct": 0.01}
	await srv._auth({"id": "CCCCCCCCC", "key": key}, true)
	var accepted := 0
	for i in 4:
		c["day"] = today - 1
		r = await srv._raid_report(c)
		if not r[1].has("error"): accepted += 1
	ok(accepted == 3 and r[1].get("error") == "day_full", "yesterday's 4th attempt is refused (day_full), the first 3 counted")
	accepted = 0
	for i in 3:
		c["day"] = today
		r = await srv._raid_report(c)
		if not r[1].has("error"): accepted += 1
	ok(accepted == 3, "today's 3 attempts still count after yesterday's")
	var crec = await store.get_player("CCCCCCCCC")
	ok((crec.get("flags", []) as Array).is_empty(), "no cheat flag for honest offline play")
	c["day"] = today + 1
	r = await srv._raid_report(c)
	var crec2 = await store.get_player("CCCCCCCCC")
	ok(r[1].get("error") == "bad_day" and (crec2.get("flags", []) as Array).size() == 1, "a day in the future is refused and flagged")
	c["day"] = today - 5
	r = await srv._raid_report(c)
	var crec3 = await store.get_player("CCCCCCCCC")
	ok(r[1].get("error") == "bad_day" and (crec3.get("flags", []) as Array).size() == 1, "a day in an earlier week is refused without a flag")
	# milestones and the boss going down
	var doc: Dictionary = await srv._raid_doc(week, false)
	doc["shares"] = 0.5 * float(doc["target"])
	await store.put_meta_doc("raid-%d" % week, doc)
	r = await srv._raid_state({"id": "AAAAAAAAA", "key": key})
	ok(int(r[1]["reached"]) == 2, "half way = 2 milestones")
	doc["shares"] = float(doc["target"]) - 0.01
	doc["att"] = {}
	doc["players"] = {}
	await store.put_meta_doc("raid-%d" % week, doc)
	r = await srv._raid_report({"id": "AAAAAAAAA", "key": key, "week": week, "pct": 0.1})
	ok(int(r[1]["reached"]) == 4 and float(r[1]["shares"]) >= float(r[1]["target"]), "the last bit brings the boss down: all 4 milestones")
	var done_shares := float(r[1]["shares"])
	r = await srv._raid_report({"id": "BBBBBBBBB", "key": key, "week": week, "pct": 0.1})
	ok(is_equal_approx(float(r[1]["shares"]), done_shares), "nothing more is added once it is down")
	# the target counts only players seen in the last 4 weeks
	var srv2 = load("res://scripts/ArenaServer.gd").new()
	var store2 := ArenaStore.new()
	store2.data_dir = "user://raid_test2_" + str(Time.get_ticks_msec())
	root.add_child(store2)
	await process_frame
	srv2.store = store2
	await store2.open()
	srv2.raids_enabled = true
	srv2.time_offset = srv.time_offset
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for i in 60:
		var pid := "P" + chars[i % 32] + chars[(i / 32) % 32] + "XXXXXX"
		var fresh: bool = i < 40
		await store2.put_player({"id": pid, "keyHash": "x", "name": "p", "rating": 1000, "saveAt": (srv2._now() - 86400) if fresh else (srv2._now() - 9 * 7 * 86400), "history": [], "flags": []})
	var d2: Dictionary = await srv2._raid_doc(week, true)
	ok(is_equal_approx(float(d2["target"]), 10.0), "target counts the 40 recently active players of 60 (%s)" % d2["target"])
	# the target grows with the player count
	ok(Raids.community_target(100) == 25.0 and Raids.community_target(3) == Raids.COMMUNITY_MIN_TARGET, "target = max(5, 0.25 x players)")
	# client side
	var g := FarroadProgression.new_game(7, null)
	var now := float(srv._now())
	Raids.apply_community(g, now, {"week": week, "shares": 4.0, "target": 5.0, "mine": 0.1, "reached": 3, "contributors": 9})
	ok(not Raids.community_down(g, now), "client: 4 of 5 shares is not down")
	Raids.apply_community(g, now, {"week": week, "shares": 5.0, "target": 5.0, "mine": 0.1, "reached": 4, "contributors": 9})
	ok(Raids.community_down(g, now) and Raids.start_attempt(g, now).is_empty(), "client: down = no attempt starts")
	# week close pays the milestones
	var st := Raids.refresh(g, now)
	st["damage"] = 0.0
	var gp := FarroadProgression.new_game(7, null)
	var fz := Raids.frozen_boss(gp, now)
	var stp := Raids.refresh(gp, now)
	stp["damage"] = 0.5 * float(fz["pool"])   # silver tier
	stp["commReached"] = 3
	var next_week_now := now + 7.0 * 86400.0
	Raids.refresh(gp, next_week_now)
	var pend: Array = Raids.refresh(gp, next_week_now)["pending"]
	ok(pend.size() == 1 and int(pend[0]["milestones"]) == 3, "a finished week remembers the community milestones")
	var paid := Raids.claim_pending(gp, next_week_now)
	ok(int(paid["crystal"]) == int(Raids.tier_by_id("silver")["crystal"]) + int(Raids.MILESTONE_CRYSTAL[2]) and int(paid["distilled"]) == int(Raids.MILESTONE_DISTILLED[2]), "the claim pays the tier plus 3 milestones (%d Crystal, %d Distilled)" % [paid["crystal"], paid["distilled"]])
	print("DONE fails=", fails)
	quit()

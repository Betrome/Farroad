extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	# --- clock
	var mon := int(Time.get_unix_time_from_datetime_string("2026-10-26T00:00:00"))   # a Monday
	ok(Seasons.season_of(mon) == Seasons.season_of(mon + 6 * 86400 + 86399), "a season is Monday 00:00 UTC to Sunday 23:59:59 UTC")
	ok(Seasons.season_of(mon) == Seasons.season_of(mon - 1) + 1, "Monday 00:00 UTC starts a new season")
	ok(Seasons.season_end(Seasons.season_of(mon)) == mon + 7 * 86400, "a season ends on the next Monday 00:00 UTC")
	# --- tiers
	ok(Seasons.tier_for(1010, 9)["id"] == "bronze", "rating 1010 = Bronze")
	ok(Seasons.tier_for(1060, 9)["id"] == "silver" and Seasons.tier_for(1120, 9)["id"] == "gold" and Seasons.tier_for(1250, 9)["id"] == "platinum", "silver / gold / platinum by rating")
	ok(Seasons.tier_for(1260, 2)["id"] == "champion", "top 3 with a good rating = Champion")
	ok(Seasons.tier_for(1020, 1)["id"] == "bronze", "rank 1 with a low rating is not Champion")
	ok(Seasons.carried_rating(1200, 1000) == 1100 and Seasons.carried_rating(900, 1000) == 950, "ratings are pulled halfway back to 1000")
	# --- payout
	var g := FarroadProgression.new_game(7, null)
	g["wave"] = 100
	var paid := Seasons.pay(g, "gold")
	ok(int(g["crystal"]) == 7 and int(g["distilled"]) == 2 and float(g["marks"]) == 3.0 * FarroadProgression.pull_cost(100), "Gold pays 7 Crystal, 2 Distilled Aether and 3 pulls of Marks")
	# --- distilled aether
	var g2 := FarroadProgression.new_game(7, null)
	g2["lvl"]["kesh"] = 10
	g2["distilled"] = 2
	g2["aether"] = 0.0
	ok(FarroadProgression.can_use_distilled(g2, "kesh"), "Distilled Aether is usable with no Aether")
	ok(FarroadProgression.use_distilled(g2, "kesh") and FarroadProgression.level_of(g2, "kesh") == 11 and int(g2["distilled"]) == 1, "one Distilled Aether = one level")
	g2["aether"] = 1e9
	ok(not FarroadProgression.can_use_distilled(g2, "kesh"), "not usable when you can afford the level")
	# --- server
	var srv = load("res://scripts/ArenaServer.gd").new()
	var store := ArenaStore.new()
	store.data_dir = "user://season_test_" + str(Time.get_ticks_msec())
	root.add_child(store)
	await process_frame
	srv.store = store   # (the server node itself stays out of the tree: its _ready would start listening)
	await store.open()
	srv.seasons_enabled = true
	srv.time_offset = mon + 3 * 86400 + 12 * 3600 - int(Time.get_unix_time_from_system())   # Thursday noon UTC
	await srv._season_tick()
	var s0: int = srv._season_current
	ok(s0 == Seasons.season_of(mon), "the server starts in the current season")
	var ids := ["AAAAAAAAA", "BBBBBBBBB", "CCCCCCCCC", "DDDDDDDDD", "EEEEEEEEE"]
	var ratings := [1270, 1260, 1120, 1020, 1300]
	var fights := [10, 6, 5, 4, 12]   # D has too few fights; E is best
	for i in ids.size():
		var rec: Dictionary = {"id": ids[i], "keyHash": "x", "name": "P" + str(i), "rating": ratings[i], "wins": 0, "losses": 0, "defWins": 0, "defLosses": 0,
			"team": {"game": "x", "units": []}, "power": 1, "history": [], "flags": [], "seasonId": s0, "seasonFights": fights[i]}
		await store.put_player(rec)
	await store.put_player({"id": "rival_x", "keyHash": "", "rival": true, "name": "R", "rating": 1365, "team": {"game": "x", "units": []}, "seasonId": s0, "seasonFights": 99})
	# jump to next week
	srv.time_offset += 5 * 86400
	await srv._season_tick()
	ok(srv._season_current == s0 + 1, "a week later the server is in the next season")
	var e: Dictionary = await store.get_player("EEEEEEEEE")
	var a: Dictionary = await store.get_player("AAAAAAAAA")
	var b: Dictionary = await store.get_player("BBBBBBBBB")
	var c: Dictionary = await store.get_player("CCCCCCCCC")
	var d: Dictionary = await store.get_player("DDDDDDDDD")
	var r: Dictionary = await store.get_player("rival_x")
	ok((e["seasonPending"] as Array).size() == 1 and e["seasonPending"][0]["tier"] == "champion" and e["seasonPending"][0]["rank"] == 1, "rank 1 (rating 1300) = Champion")
	ok(a["seasonPending"][0]["tier"] == "champion" and a["seasonPending"][0]["rank"] == 2, "rank 2 (1270) = Champion")
	ok(b["seasonPending"][0]["tier"] == "champion" and b["seasonPending"][0]["rank"] == 3, "rank 3 (1260) = Champion")
	ok(c["seasonPending"][0]["tier"] == "gold" and c["seasonPending"][0]["rank"] == 4, "rank 4 (1120) = Gold")
	ok(not d.has("seasonPending") or (d["seasonPending"] as Array).is_empty(), "4 fights is below the minimum: no reward")
	ok(int(e["rating"]) == 1150 and int(a["rating"]) == 1135 and int(d["rating"]) == 1010, "ratings are carried halfway back (1300 to 1150, 1270 to 1135, 1020 to 1010)")
	ok(int(r["rating"]) == 1365 and not r.has("seasonPending"), "rival teams are left alone")
	ok(int(e["seasonFights"]) == 0, "fight counters start again")
	# hello shows the season, claim pays once
	var hello: Array = await srv._hello({"id": "EEEEEEEEE", "key": "k".repeat(40)})
	ok(hello[0] == 403, "(auth needs the real key, so hello is refused for the fake record)")
	var info: Dictionary = srv._season_info(e)
	ok(int(info["id"]) == s0 + 1 and int(info["endsAt"]) == Seasons.season_end(s0 + 1) and (info["pending"] as Array).size() == 1, "season info: id, end time and the pending reward")
	e["keyHash"] = ("k".repeat(40)).sha256_text()
	await store.put_player(e)
	var claim: Array = await srv._season_claim({"id": "EEEEEEEEE", "key": "k".repeat(40), "season": s0})
	ok(claim[0] == 200 and claim[1]["claimed"]["tier"] == "champion", "claiming returns the tier")
	var claim2: Array = await srv._season_claim({"id": "EEEEEEEEE", "key": "k".repeat(40), "season": s0})
	ok(claim2[0] == 404, "a reward can only be claimed once")
	# a server with seasons off adds nothing
	var srv2 = load("res://scripts/ArenaServer.gd").new()
	srv2.store = store
	var rec2: Dictionary = await store.get_player("CCCCCCCCC")
	ok(srv2.seasons_enabled == false, "seasons are off unless switched on")
	print("DONE fails=", fails)
	quit()

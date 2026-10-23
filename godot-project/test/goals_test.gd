extends SceneTree
var fails := 0
func ok(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	Goals.tz_bias_override = -6.0 * 3600.0     # Mountain-ish: local = UTC - 6h
	# 2026-10-21 (Wed) 23:30 local = 2026-10-22 05:30 UTC
	var wed_2330_local := int(Time.get_unix_time_from_datetime_string("2026-10-22T05:30:00"))
	var g := FarroadProgression.new_game(7, null)
	Goals.record(g, "expedition_sent", 1.0, wed_2330_local)
	Goals.record(g, "aether_spent", 6000.0, wed_2330_local)
	var d: Dictionary = Goals.DAILY[0]
	var dw: Dictionary = Goals.WEEKLY[0]
	var st: Dictionary = g["goals"]
	ok(float(st["daily"]["d_expedition"]["n"]) == 1.0 and float(st["weekly"]["w_expedition"]["n"]) == 1.0, "one expedition counts for the daily AND the weekly goal")
	ok(float(st["daily"]["d_aether"]["n"]) == 6000.0, "6000 Aether spent counts toward the daily goal")
	# 30 minutes later = Thu 00:00 local: new day, same week
	var thu_0001_local := wed_2330_local + 31 * 60
	Goals.record(g, "pull", 1.0, thu_0001_local)
	st = g["goals"]
	ok(not st["daily"].has("d_expedition") and float(st["daily"]["d_pull"]["n"]) == 1.0, "daily goals reset at local midnight (Thu 00:01 local)")
	ok(float(st["weekly"]["w_expedition"]["n"]) == 1.0, "weekly goals survive the daily reset")
	# the UTC midnight for that moment is at 18:00 local: a goal recorded at 17:59 and 18:01 local stays in the same day
	var wed_1759_local := wed_2330_local - (5 * 3600 + 31 * 60)
	var g2 := FarroadProgression.new_game(7, null)
	Goals.record(g2, "pull", 1.0, wed_1759_local)
	Goals.record(g2, "pull", 1.0, wed_1759_local + 120)
	ok(float(g2["goals"]["daily"]["d_pull"]["n"]) == 2.0, "UTC midnight (18:00 local) does NOT reset the goals")
	# weekly resets Monday 00:00 local. Sunday 23:59 -> Monday 00:01
	var sun_2359_local := int(Time.get_unix_time_from_datetime_string("2026-10-26T05:59:00"))   # Sun 23:59 local (10-25)
	var g3 := FarroadProgression.new_game(7, null)
	Goals.record(g3, "pull", 1.0, sun_2359_local)
	Goals.record(g3, "pull", 1.0, sun_2359_local + 120)
	ok(float(g3["goals"]["weekly"]["w_pull"]["n"]) == 1.0 and float(g3["goals"]["daily"]["d_pull"]["n"]) == 1.0, "Monday 00:01 local starts a new week and a new day")
	# claim
	var g4 := FarroadProgression.new_game(7, null)
	Goals.record(g4, "arena_fight", 2.0, wed_2330_local)
	var darena := {"id": "d_arena"}
	# use live clock for claim tests
	var g5 := FarroadProgression.new_game(7, null)
	Goals.tz_bias_override = NAN
	Goals.record(g5, "arena_fight", 2.0)
	ok(not Goals.claim(g5, "daily", "d_arena"), "cannot claim a goal below its target (2 of 3)")
	Goals.record(g5, "arena_fight", 1.0)
	ok(Goals.claimable_count(g5) == 1, "one goal ready to claim")
	ok(Goals.claim(g5, "daily", "d_arena") and int(g5["crystal"]) == 1, "claim pays 1 Crystal")
	ok(not Goals.claim(g5, "daily", "d_arena") and int(g5["crystal"]) == 1, "a goal cannot be claimed twice")
	ok(Goals.claimable_count(g5) == 0, "nothing left to claim")
	# seconds to reset
	Goals.tz_bias_override = -6.0 * 3600.0
	ok(absf(Goals.seconds_to_reset("daily", wed_2330_local) - 1800.0) < 1.0, "daily reset is 30 minutes after Wed 23:30 local")
	ok(absf(Goals.seconds_to_reset("weekly", wed_2330_local) - (4 * 86400.0 + 1800.0)) < 1.0, "weekly reset is 4 days 30 minutes after Wed 23:30 local (Monday 00:00)")
	# hooks
	Goals.tz_bias_override = NAN
	var g6 := FarroadProgression.new_game(7, null)
	g6["aether"] = 100000.0
	g6["lvl"]["kesh"] = 1
	FarroadProgression.spend_feed(g6, "kesh", 500)
	ok(float(g6["goals"]["daily"]["d_aether"]["n"]) == 500.0, "spending Aether on a level counts")
	FarroadProgression.spend_recovery(g6, "kesh")
	FarroadProgression.spend_affinity(g6, "kesh", "fire")
	FarroadProgression.spend_pct_stat(g6, "kesh", "evade")
	ok(float(g6["goals"]["daily"]["d_aether"]["n"]) > 500.0, "Recovery / affinity / evade purchases count too")
	# save round trip
	var snap := FarroadSave.serialize(g6, 1800000000)
	var g7 := FarroadSave.deserialize(snap)
	ok(g7.has("goals") and float(g7["goals"]["daily"]["d_aether"]["n"]) == float(g6["goals"]["daily"]["d_aether"]["n"]), "goal progress survives save and load")
	var old := FarroadSave.serialize(FarroadProgression.new_game(7, null), 1800000000)
	old.erase("goals")
	ok(FarroadSave.deserialize(old).has("goals"), "an old save without goals loads with an empty list")
	# dungeon charges at local midnight
	Goals.tz_bias_override = -6.0 * 3600.0
	var dun := {"charges": 0, "chargeDay": FarroadProgression._utc_day(wed_2330_local)}
	ok(FarroadProgression.dungeon_charges(dun, wed_2330_local + 600) == 0, "no dungeon charge at 23:40 local")
	dun = {"charges": 0, "chargeDay": FarroadProgression._utc_day(wed_2330_local)}
	ok(FarroadProgression.dungeon_charges(dun, wed_2330_local + 31 * 60) == 1, "a dungeon charge arrives at local midnight")
	dun = {"charges": 0, "chargeDay": FarroadProgression._utc_day(wed_1759_local)}
	ok(FarroadProgression.dungeon_charges(dun, wed_1759_local + 120) == 0, "UTC midnight (18:00 local) gives no charge")
	print("DONE fails=", fails)
	quit()

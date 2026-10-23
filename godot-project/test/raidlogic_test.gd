extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	var mon := int(Time.get_unix_time_from_datetime_string("2026-10-26T00:00:00"))
	var g := FarroadProgression.new_game(7, null)
	g["farthest"] = 100
	var wk := Seasons.season_of(mon)
	ok(Raids.attempts_left(g, mon + 3600) == 3, "3 attempts at the start of a day")
	var st := Raids.refresh(g, mon + 3600)
	st["used"] = 3
	ok(Raids.attempts_left(g, mon + 7200) == 0, "no attempts left after 3 today")
	ok(Raids.attempts_left(g, mon + 86400 + 60) == 3, "attempts come back at 00:00 UTC")
	# damage and tiers
	var pool := Raids.pool(g, mon + 86400 + 60)
	Raids.finish(g, pool * 0.05, mon + 86400 + 60)
	ok(Raids.tier_for(Raids.pct_done(g, mon + 86400 + 60)).is_empty(), "5% is below the first tier")
	Raids.finish(g, pool * 0.30, mon + 86400 + 120)
	ok(Raids.tier_for(Raids.pct_done(g, mon + 86400 + 120))["id"] == "silver", "35% is Silver")
	Raids.finish(g, pool * 1.2, mon + 86400 + 180)
	ok(Raids.remaining_hp(g, mon + 86400 + 200) == 0.0 and Raids.start_attempt(g, mon + 2 * 86400).is_empty(), "a defeated boss can't be fought again")
	# the boss is frozen for the week even if you get stronger
	var w1: int = Raids.frozen_boss(g, mon + 86400)["wave"]
	g["farthest"] = 400
	ok(Raids.frozen_boss(g, mon + 3 * 86400)["wave"] == w1, "the boss is fixed for the week")
	# a new week closes the old one and leaves a reward
	var next_week := mon + 7 * 86400 + 600
	Raids.refresh(g, next_week)
	var pend: Array = g["raid"]["pending"]
	ok(pend.size() == 1 and pend[0]["tier"] == "platinum", "the finished week leaves a Platinum reward to claim")
	ok(float(g["raid"]["damage"]) == 0.0 and Raids.attempts_left(g, next_week) == 3, "the new week starts clean")
	g["wave"] = 100
	var before_c := int(g["crystal"])
	var paid := Raids.claim_pending(g, next_week)
	ok(paid["crystal"] == 10 and paid["marks"] == 800 and paid["distilled"] == 2 and int(g["crystal"]) == before_c + 10, "Platinum pays 10 Crystal, 800 Marks (8 pulls), 2 Distilled Aether")
	ok(Raids.claim_pending(g, next_week)["weeks"] == 0, "a reward is paid once")
	# a week with no damage leaves no reward
	var g2 := FarroadProgression.new_game(7, null)
	g2["farthest"] = 60
	Raids.refresh(g2, mon)
	Raids.refresh(g2, mon + 8 * 86400)
	ok((g2["raid"]["pending"] as Array).is_empty(), "no damage, no reward")
	# save round trip
	var snap := FarroadSave.serialize(g, 1800000000)
	var g3 := FarroadSave.deserialize(snap)
	ok(g3.has("raid") and g3["raid"].has("week"), "raid state survives save and load")
	var old := FarroadSave.serialize(FarroadProgression.new_game(7, null), 1800000000)
	old.erase("raid")
	ok(FarroadSave.deserialize(old).has("raid"), "an old save loads with an empty raid")
	# the boss's own stats follow the week
	var sp := Raids.spec(wk)
	var gg := FarroadProgression.new_game(7, null)
	gg["farthest"] = 100
	var fz := Raids.frozen_boss(gg, mon + 3600)
	var aff: Dictionary = fz["snap"]["affinity"]
	ok(float(aff[sp["strong"][0]]) >= 20.0 and float(aff[sp["weak"][0]]) <= -20.0, "the boss resists its strong elements and is weak to its weak ones")
	print("DONE fails=", fails)
	quit()

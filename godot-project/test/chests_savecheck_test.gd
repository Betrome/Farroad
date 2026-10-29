extends SceneTree
var fails := 0
func ok(cond: bool, msg: String) -> void:
	print(("PASS " if cond else "FAIL ") + msg)
	if not cond: fails += 1
func _initialize():
	FarroadCore.load_real_content()
	var T0 := 1800000000
	for far in [100, 300, 1000]:
		var g := FarroadProgression.new_game(77, null)
		g["farthest"] = far
		var per := FarroadProgression.idle_per_sec(far)
		var cred := SaveCheck.new_credit(T0)
		var cur: Dictionary = {"farthest": far, "lvl": {"kesh": 90}, "aether": 1.0e12, "marks": 1.0e9, "crystal": 10}
		var rejected := {}
		var sent := 0; var chests := 0
		var worst_ratio := 0.0
		var t := 0
		var chest_a := 0.0; var chest_m := 0.0
		var next_chest := Chests.roll_gap(g["rng"])
		for sec in range(0, 7200, 1):
			Chests.tick(g, 1.0)
			if bool(g["chest"]["there"]):
				var a0 := float(g["aether"]); var m0 := float(g["marks"])
				Chests.open(g); chests += 1
				chest_a += float(g["aether"]) - a0; chest_m += float(g["marks"]) - m0
			if (sec + 1) % 180 == 0:
				t += 180
				SaveCheck.accrue(cred, T0 + t)
				var nxt: Dictionary = cur.duplicate(true)
				# the chests' haul since the last upload + the idle income of those 180 s (the least a player earns)
				nxt["aether"] = float(cur["aether"]) + chest_a + per["aether"] * 180.0
				nxt["marks"] = float(cur["marks"]) + chest_m + per["marks"] * 180.0
				var ceil_a := SaveCheck.aether_ceiling(far, 180.0)
				var ceil_m := SaveCheck.marks_ceiling(far, 180.0)
				worst_ratio = maxf(worst_ratio, maxf((chest_a + per["aether"] * 180.0) / ceil_a, (chest_m + per["marks"] * 180.0) / ceil_m))
				var why := SaveCheck.check(cur, nxt, 180.0, cred)
				sent += 1
				if why != "": rejected[why] = int(rejected.get(why, 0)) + 1
				else: SaveCheck.spend_credit(cred, cur, nxt, 180.0); cur = nxt
				chest_a = 0.0; chest_m = 0.0
		ok(rejected.is_empty(), "far %d: no chest-plus-idle upload is rejected (%d chests, worst share of ceiling %.3f)" % [far, chests, worst_ratio])
		print("SC far ", far, " chests ", chests, " uploads ", sent, " rejected ", rejected, " worst share of ceiling ", snappedf(worst_ratio, 0.001))
	for far in [100, 300, 1000]:
		print("RATIO far ", far, " chest allowance / normal aether ceiling at 180 s: ", snappedf(SaveCheck.chest_allowance(far, 180.0, "aether") / SaveCheck.aether_ceiling(far, 180.0), 0.01))
	print("DONE fails=", fails)
	quit(1 if fails > 0 else 0)

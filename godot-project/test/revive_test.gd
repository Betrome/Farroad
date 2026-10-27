extends SceneTree
func _initialize():
	await process_frame
	FarroadCore.load_real_content()
	var rev := ""
	for id in FarroadCore.ACTIONS:
		if FarroadCore.ACTIONS[id].get("revive") and not FarroadCore.ACTIONS[id].get("isCharge"):
			rev = String(id); break
	print("REV action ", rev)
	var g := FarroadProgression.new_game(7, null)
	g["owned"]["ansa"] = 1
	var a: Dictionary = FarroadProgression.build_party_unit(g, "kesh", 0)
	var b2: Dictionary = FarroadProgression.build_party_unit(g, "ansa", 1)
	b2["hp"] = 0.0
	a["slots"] = [{"cond": "none", "action": rev}, {"cond": "none", "action": rev}]
	var bat := FarroadCore.make_battle([a, b2] + FarroadProgression.build_enemies(g, 3, true), {"rng": g["rng"], "enrage": false})
	var maxn := 0.0
	var e = FarroadCore.step(bat)
	for u in bat["units"]:
		if u["hp"] > 0 and u != b2: maxn = maxf(maxn, float(u["nextActAt"]))
	print("REV notes ", e.get("notes"), " ansa hp ", b2["hp"], " ansa next ", b2["nextActAt"], " latest other ", maxn)
	print("REV ", "PASS" if b2["hp"] > 0 and float(b2["nextActAt"]) > maxn else "FAIL", " revived unit acts last")
	quit()

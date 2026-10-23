extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	if c: print("PASS ", m)
	else:
		print("FAIL ", m); fails += 1
func _initialize():
	await process_frame
	FarroadCore.load_real_content()
	var buffs := []
	var debuffs := []
	for id in FarroadCore.ACTIONS:
		var a = FarroadCore.ACTIONS[id]
		if FarroadCore.is_pure_status(a) and not a.get("isCharge"):
			(buffs if FarroadCore.is_buff_status(str(a["applies"])) else debuffs).append(id)
	print("NOTE pure buffs ", buffs.slice(0, 4), " debuffs ", debuffs.slice(0, 4))
	ok(not buffs.is_empty() and not debuffs.is_empty(), "there are pure buff and debuff actions")
	var bid: String = buffs[0]
	var did: String = debuffs[0]
	# a unit whose slots are [buff, buff2-or-same, strike] with no trigger: never two statuses in a row
	var g := FarroadProgression.new_game(7, null)
	var party := [FarroadProgression.build_party_unit(g, "kesh", 0)]
	var enemies: Array = FarroadProgression.build_enemies(g, 3, true)
	var u: Dictionary = party[0]
	u["slots"] = [{"cond": "none", "action": bid}, {"cond": "none", "action": did}, {"cond": "none", "action": "strike"}]
	u["chargeAction"] = null
	var b := FarroadCore.make_battle(party + enemies, {"rng": g["rng"], "enrage": false})
	var seq := []
	for i in 400:
		var e = FarroadCore.step(b)
		if e == null or b["over"] != null: break
		if e.get("actorName", "") == u["name"] or e.get("actor") == u["name"]:
			seq.append(e.get("actionId", e.get("action", "")))
	print("NOTE kesh's actions: ", seq.slice(0, 12))
	var bad := false
	for i in range(1, seq.size()):
		var a1 = FarroadCore.ACTIONS.get(str(seq[i - 1])); var a2 = FarroadCore.ACTIONS.get(str(seq[i]))
		if FarroadCore.is_pure_status(a1) and FarroadCore.is_pure_status(a2): bad = true
	ok(seq.size() >= 3 and not bad, "no buff or debuff straight after another (%d actions)" % seq.size())
	# with a 'lacks' trigger it may repeat
	var g2 := FarroadProgression.new_game(7, null)
	var u2: Dictionary = FarroadProgression.build_party_unit(g2, "kesh", 0)
	u2["slots"] = [{"cond": "foe_lacks_debuff", "action": did}, {"cond": "none", "action": "strike"}]
	u2["chargeAction"] = null
	u2["lastWasStatus"] = true
	var b2 := FarroadCore.make_battle([u2] + FarroadProgression.build_enemies(g2, 3, true), {"rng": g2["rng"], "enrage": false})
	u2["lastWasStatus"] = true
	var pick := FarroadCore.choose(u2, b2)
	ok(str(pick["actionId"]) == did, "a debuff with 'foe lacks this debuff' can follow another status (%s)" % str(pick["actionId"]))
	var u3: Dictionary = FarroadProgression.build_party_unit(g2, "kesh", 0)
	u3["slots"] = [{"cond": "none", "action": did}, {"cond": "none", "action": "strike"}]
	u3["chargeAction"] = null
	var b3 := FarroadCore.make_battle([u3] + FarroadProgression.build_enemies(g2, 3, true), {"rng": g2["rng"], "enrage": false})
	u3["lastWasStatus"] = true
	ok(str(FarroadCore.choose(u3, b3)["actionId"]) == "strike", "an unconditional debuff is skipped right after a status")
	# the status is already on every foe: the 'lacks' trigger is false on the second turn in a row
	var g4 := FarroadProgression.new_game(7, null)
	var u4: Dictionary = FarroadProgression.build_party_unit(g4, "kesh", 0)
	u4["slots"] = [{"cond": "foe_lacks_debuff", "action": did}, {"cond": "none", "action": "strike"}]
	u4["chargeAction"] = null
	var foes4: Array = FarroadProgression.build_enemies(g4, 3, true)
	var b4 := FarroadCore.make_battle([u4] + foes4, {"rng": g4["rng"], "enrage": false})
	var applies: String = str(FarroadCore.ACTIONS[did]["applies"])
	var first := FarroadCore.choose(u4, b4)
	ok(str(first["actionId"]) == did, "first turn: debuff used while foes lack it")
	for f in foes4:
		f["st"][applies] = 3
	u4["lastWasStatus"] = true
	print("NOTE foe status after forcing: ", FarroadCore.has(foes4[0], applies))
	var second := FarroadCore.choose(u4, b4)
	ok(str(second["actionId"]) == "strike" and FarroadCore.has(foes4[0], applies), "second turn in a row: the trigger is rechecked (%s)" % str(second["actionId"]))
	# ---- Power
	var gp := FarroadProgression.new_game(7, null)
	var p0 := FarroadProgression.power_level(gp)
	gp["affinities"]["kesh"] = {"fire": 10}
	var p1 := FarroadProgression.power_level(gp)
	gp["statInvest"]["kesh"] = {"evade": 6}
	var p2 := FarroadProgression.power_level(gp)
	ok(p1 > p0 and p2 > p1, "affinity points and Evade steps raise Power (%d -> %d -> %d)" % [p0, p1, p2])
	var eq := ""
	for id in FarroadCore.EQUIPMENT:
		var it: Dictionary = FarroadCore.EQUIPMENT[id]
		if float(it.get("stats", {}).get("atk", 0.0)) > 0.0 or float(it.get("atk", 0.0)) > 0.0:
			eq = String(id); break
	print("NOTE gear item ", eq, " ", FarroadCore.EQUIPMENT[eq])
	gp["equipInv"][eq] = 1
	gp["equipped"]["kesh"] = {String(FarroadCore.EQUIPMENT[eq]["slot"]) if String(FarroadCore.EQUIPMENT[eq]["slot"]) != "hand" else "hand1": eq}
	var p3 := FarroadProgression.power_level(gp)
	ok(p3 > p2, "gear raises Power (%d -> %d)" % [p2, p3])
	gp["loreByAction"]["strike"] = 50.0
	var p4 := FarroadProgression.power_level(gp)
	ok(p4 == p3, "unspent Lore does not raise Power")
	gp["bonuses"]["strike"] = {"potent": 3}
	ok(FarroadProgression.power_level(gp) > p3, "applied Lore does")
	# ---- lighting numbers
	for h in [0.0, 12.5, 22.0]:
		var look := Lighting.look_for("forest", h)
		Lighting.params = look
		var tt: Color = Lighting.unit_tint()
		print("NOTE forest hour ", h, " tint ", snappedf(tt.r, 0.01), " ", snappedf(tt.g, 0.01), " ", snappedf(tt.b, 0.01))
	Lighting.params = Lighting.look_for("cave", 12.0)
	var ct: Color = Lighting.unit_tint()
	print("NOTE cave tint ", snappedf(ct.r, 0.01), " ", snappedf(ct.g, 0.01), " ", snappedf(ct.b, 0.01))
	print("DONE fails=", fails)
	quit()

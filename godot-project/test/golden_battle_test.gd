extends SceneTree
## A fixed-seed fight, hashed. If this fails, the fight rules (or the content) changed: the Arena replays fights
## from a seed on both the game and the server, so Ranked.PROTOCOL must be bumped (see the note at the top of
## FarroadCore.gd) and EXPECTED updated in the same commit. Run: godot --headless --script test/golden_battle_test.gd
const EXPECTED := "5bd372096ad0af72d225f9184a8ca2a784d0a8f642ef283d0d162033498661d6"

func _initialize():
	await process_frame
	FarroadCore.load_real_content()
	var g := FarroadProgression.new_game(7, null)
	g["owned"]["ansa"] = 1
	g["lvl"]["kesh"] = 20
	g["lvl"]["ansa"] = 18
	var party := [FarroadProgression.build_party_unit(g, "kesh", 0), FarroadProgression.build_party_unit(g, "ansa", 1)]
	FarroadCore.set_wave(60)
	g["wave"] = 60
	var enemies: Array = FarroadProgression.build_enemies(g, 60, true)
	var b := FarroadCore.make_battle(party + enemies, {"rng": FarroadCore.make_rng(12345), "enrage": true})
	var trace := []
	var beats := 0
	while b["over"] == null and beats < 400:
		beats += 1
		var e = FarroadCore.step(b)
		if e == null:
			break
		trace.append([e["beat"], e["actorId"], e["actionId"], e["targetName"], e["totalDamage"], e["dot"]])
	trace.append([b["over"], beats])
	var h := JSON.stringify(trace).sha256_text()
	print("GOLDEN beats ", beats, " over ", b["over"], " hash ", h)
	if EXPECTED == "PLACEHOLDER":
		print("GOLDEN set EXPECTED to the hash above")
		quit()
		return
	if h == EXPECTED:
		print("PASS golden battle unchanged")
		print("DONE fails=0")
	else:
		print("FAIL the fight rules (or content.json) changed: update EXPECTED to ", h, ". If step() or what it calls changed, also bump Ranked.PROTOCOL; a content.json-only change already changes game_version, so the bump is then redundant but harmless.")
		print("DONE fails=1")
	quit()

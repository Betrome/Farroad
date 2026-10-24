extends SceneTree
var fails := 0
func ok(c: bool, m: String) -> void:
	if c: print("PASS ", m)
	else:
		print("FAIL ", m); fails += 1
func _initialize():
	await process_frame
	FarroadCore.load_real_content()
	var g := FarroadProgression.new_game(7, null)
	var u: Dictionary = FarroadProgression.build_party_unit(g, "kesh", 0)
	var view := UnitView.new()
	view.setup(u, 60.0)
	root.add_child(view)
	await process_frame
	var sf: SpriteFrames = (view.shape as AnimatedSprite2D).sprite_frames
	ok(is_equal_approx(sf.get_frame_duration("attack", 0), 1.4), "attack frame 0: 100 ms at 14 fps = 1.4 (%s)" % sf.get_frame_duration("attack", 0))
	ok(is_equal_approx(sf.get_frame_duration("attack", 12), 2.8), "attack frame 12: 200 ms = 2.8")
	ok(is_equal_approx(sf.get_frame_duration("idle", 0), 1.0), "an animation without meta keeps 1.0")
	ok(is_equal_approx(view.time_to_impact("attack"), 1.4), "time to the named impact frame (12) = 1.4 s (%s)" % view.time_to_impact("attack"))
	ok(is_equal_approx(view.time_to_mark("cast", "release"), 0.48), "release frame 6 at 80 ms = 0.48 s (%s)" % view.time_to_mark("cast", "release"))
	ok(is_equal_approx(view.time_to_mark("cast", "flash"), 0.24), "any named event works (flash at 3 = 0.24 s)")
	ok(view.time_to_mark("cast", "nothing") == 0.0, "an unknown event gives 0")
	print("DONE fails=", fails)
	quit()

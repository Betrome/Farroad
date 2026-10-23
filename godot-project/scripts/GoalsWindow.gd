class_name GoalsWindow
extends RefCounted
## The Goals window: a Daily tab and a Weekly tab, each a short list of goals with a progress bar
## and a Claim button (1 Crystal each). Opened from the small Goals button above the Log button
## in the battle view. See Goals.gd for the goals themselves and when they reset.

static func open(gc: GameController) -> void:
	var o := gc.build_overlay_window()
	var vbox: VBoxContainer = o["vbox"]
	var state := {"tab": "daily"}

	var title := Label.new()
	title.text = "GOALS"
	title.add_theme_font_size_override("font_size", int(gc.vp.y * 0.03))
	vbox.add_child(title)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	vbox.add_child(tabs)
	var tab_buttons := {}
	for entry in [["daily", "Daily"], ["weekly", "Weekly"]]:
		var b := Button.new()
		b.text = entry[1]
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, maxf(40.0, gc.vp.y * 0.05))
		tabs.add_child(b)
		tab_buttons[entry[0]] = b

	var reset_lbl := Label.new()
	reset_lbl.modulate = Palette.TEXT_DIM
	reset_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reset_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_lbl.add_theme_font_size_override("font_size", int(gc.vp.y * 0.02))
	vbox.add_child(reset_lbl)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(list)

	# (a lambda captures variables by value, so the callable lives in a Dictionary it can look itself up in)
	var ctx := {}
	ctx["render"] = func():
		var kind: String = state["tab"]
		for k in tab_buttons.keys():
			(tab_buttons[k] as Button).set_pressed_no_signal(k == kind)
		reset_lbl.text = "Each goal pays %d Crystal when claimed. Resets in %s." % [Goals.REWARD_CRYSTAL, eta_text(Goals.seconds_to_reset(kind))]
		for c in list.get_children():
			c.queue_free()
		for def in Goals.lists(kind):
			list.add_child(_goal_row(gc, kind, def, ctx["render"]))
		gc.refresh_goals_badges()
	for k in tab_buttons.keys():
		(tab_buttons[k] as Button).pressed.connect(func():
			state["tab"] = k
			ctx["render"].call())
	ctx["render"].call()
	# the render lambda captures ctx: break that cycle when the window goes
	o["backdrop"].tree_exited.connect(func(): ctx.clear())
	await gc.finish_overlay_window(o)

static func _goal_row(gc: GameController, kind: String, def: Dictionary, render: Callable) -> Control:
	var n: float = Goals.progress(gc.g, kind, def)
	var target: float = float(def["target"])
	var done: bool = n >= target
	var claimed: bool = Goals.is_claimed(gc.g, kind, def)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	box.add_child(top)
	var name_lbl := Label.new()
	name_lbl.text = String(def["text"])
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_lbl)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(maxf(96.0, gc.vp.x * 0.24), maxf(36.0, gc.vp.y * 0.045))
	if claimed:
		btn.text = "Claimed"
		btn.disabled = true
	elif done:
		btn.text = "Claim"
		btn.pressed.connect(func():
			if Goals.claim(gc.g, kind, String(def["id"])):
				gc.goal_claimed()
			render.call())
	else:
		btn.text = "%d Crystal" % Goals.REWARD_CRYSTAL
		btn.disabled = true
	top.add_child(btn)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = target
	bar.value = minf(n, target)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, maxf(10.0, gc.vp.y * 0.014))
	box.add_child(bar)
	var prog := Label.new()
	prog.text = "%s / %s" % [_num(minf(n, target)), _num(target)]
	prog.modulate = Palette.TEXT_DIM
	prog.add_theme_font_size_override("font_size", int(gc.vp.y * 0.018))
	box.add_child(prog)
	return box

static func _num(v: float) -> String:
	var s := str(int(floor(v)))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return out

static func eta_text(sec: float) -> String:
	var s := int(maxf(0.0, sec))
	var d := s / 86400
	var h := (s % 86400) / 3600
	var m := (s % 3600) / 60
	if d > 0:
		return "%dd %dh" % [d, h]
	if h > 0:
		return "%dh %dm" % [h, m]
	return "%dm" % maxi(1, m)

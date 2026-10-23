class_name PathsWindow
extends RefCounted
## The Paths window (Quests > Trials): your run's party and Aether, the map of the current level, an event's
## choices, and the loadout editor. Everything is rebuilt after each action. See Paths.gd for the rules.

const COL_NAMES := ["A", "B", "C"]

static func open(gc: GameController) -> void:
	var o := gc.build_overlay_window(true, true)
	var ctx := {"lines": []}
	ctx["render"] = func(): _render(gc, o, ctx)
	ctx["render"].call()
	# the render lambda captures ctx: break that cycle when the window goes
	o["backdrop"].tree_exited.connect(func(): ctx.clear())
	await gc.finish_overlay_window(o)

static func _clear(n: Node) -> void:
	for c in n.get_children():
		c.queue_free()

static func _label(text: String, dim: bool = false, size: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if dim:
		l.modulate = Palette.TEXT_DIM
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	return l

static func _render(gc: GameController, o: Dictionary, ctx: Dictionary) -> void:
	if not is_instance_valid(o["backdrop"]):
		return
	var header: VBoxContainer = o["header"]
	var vbox: VBoxContainer = o["vbox"]
	_clear(header)
	_clear(vbox)
	var g: Dictionary = gc.g
	var render: Callable = ctx["render"]
	header.add_child(_label("PATHS", false, int(gc.vp.y * 0.03)))
	if not Paths.active(g):
		_intro(gc, o, vbox, render)
		return
	var r := Paths.run(g)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var where := _label("Level %d of %d, row %d of %d   Aether %d" % [int(r["level"]), Paths.LEVELS, int(r["row"]) + 2, Paths.ROWS, roundi(float(r["aether"]))])
	top.add_child(where)
	var retreat := Button.new()
	retreat.text = "Retreat"
	var armed := [false]
	retreat.pressed.connect(func():
		if not armed[0]:
			armed[0] = true
			retreat.text = "Tap again to end the run"
			return
		o["backdrop"].queue_free()
		gc.path_retreat())
	top.add_child(retreat)
	header.add_child(top)
	for l in ctx["lines"]:
		vbox.add_child(_label(String(l)))
	ctx["lines"] = []

	_party(gc, o, vbox, r, render)
	if r.get("event") != null:
		_event(gc, vbox, r, render, ctx)
		return
	vbox.add_child(_label("MAP", false, 16))
	_map(gc, o, vbox, r, render, ctx)

static func _intro(gc: GameController, o: Dictionary, vbox: VBoxContainer, render: Callable) -> void:
	var g: Dictionary = gc.g
	vbox.add_child(_label("A short run with only what you find on the way. You start with your main character at level 1 and nothing from your main game."))
	vbox.add_child(_label("5 levels of 10 rows, ending in a boss. Routes branch and rejoin. Fights come in Easy, Medium and Hard; harder ones are likelier to drop a rare action. Events can help or hurt. Every fight drops an action, a gambit and Aether. Bosses add a unit and a legendary action.", true))
	vbox.add_child(_label("Units that fall are lost for the run. If your main character falls, or your whole party does, the run ends. You are paid 1 Crystal per level cleared (each level once a day).", true))
	var meta: Dictionary = Paths.root(g)["meta"]
	vbox.add_child(_label("Runs: %d.  Best: %d of %d levels cleared." % [int(meta["runs"]), int(meta["bestLevel"]), Paths.LEVELS], true))
	var last: Dictionary = Paths.run(g).get("result", {})
	if not last.is_empty():
		vbox.add_child(_label("Last run: %d levels cleared, %d rows%s. Reward: %d Crystal." % [int(last["cleared"]), int(last["rows"]), " (victory!)" if last["victory"] else "", int(last["crystal"])]))
	var go := Button.new()
	go.text = "Start a new run"
	UiKit.primary(go)
	go.disabled = g.get("sideBattle") != null
	go.pressed.connect(func():
		Paths.new_run(g, Time.get_unix_time_from_system())
		gc.save_game()
		render.call())
	vbox.add_child(go)

static func _party(gc: GameController, o: Dictionary, vbox: VBoxContainer, r: Dictionary, render: Callable) -> void:
	vbox.add_child(_label("PARTY", false, 16))
	for uid in r["party"]:
		var def = FarroadCore.roster_by_id(String(uid))
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 4)
		var top_row := HBoxContainer.new()
		top_row.add_theme_constant_override("separation", 8)
		var name_lbl := _label("%s  Lv %d" % [def["name"] if def else uid, int(r["lvl"].get(uid, 1))])
		top_row.add_child(name_lbl)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value = clampf(float(r["hp"].get(uid, 1.0)), 0.0, 1.0)
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(gc.vp.x * 0.25, maxf(10.0, gc.vp.y * 0.014))
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top_row.add_child(bar)
		card.add_child(top_row)
		var btn_row := HBoxContainer.new()
		btn_row.add_theme_constant_override("separation", 8)
		var cost := Paths.level_cost(gc.g, r, String(uid))
		var up := Button.new()
		up.text = "Lv up (%d)" % cost
		up.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		up.clip_text = true
		up.disabled = float(r["aether"]) < float(cost)
		up.pressed.connect(func():
			Paths.level_up(gc.g, r, String(uid))
			gc.save_game()
			render.call())
		btn_row.add_child(up)
		var lo := Button.new()
		lo.text = "Gambits"
		lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lo.clip_text = true
		lo.pressed.connect(func(): _loadout(gc, r, String(uid), render))
		btn_row.add_child(lo)
		card.add_child(btn_row)
		vbox.add_child(card)
	if not (r["lost"] as Array).is_empty():
		var names: Array = []
		for uid in r["lost"]:
			names.append(Paths._name_of(String(uid)))
		vbox.add_child(_label("Lost: " + ", ".join(names), true))

static func _node_label(n: Dictionary) -> String:
	match String(n["t"]):
		"event": return "Event"
		"boss": return "BOSS"
		_: return ["Easy", "Medium", "Hard"][int(n["d"])]

const COL_EASY := Color(0.35, 0.65, 0.38)
const COL_MEDIUM := Color(0.85, 0.65, 0.25)
const COL_HARD := Color(0.80, 0.30, 0.28)
const COL_EVENT := Color(0.45, 0.50, 0.85)
const COL_BOSS := Color(0.55, 0.20, 0.60)

static func _node_color(n: Dictionary) -> Color:
	match String(n["t"]):
		"event": return COL_EVENT
		"boss": return COL_BOSS
		_: return [COL_EASY, COL_MEDIUM, COL_HARD][int(n["d"])]

## The map: nodes laid out in rows (the boss on top, the start at the bottom), coloured by kind and
## difficulty, with a line from each node to the nodes it leads to. Lines on the route you have walked are
## gold, lines out of where you stand are bright, the rest are dim.
class MapView extends Control:
	var run: Dictionary
	var opts: Array
	var busy := false
	var on_pick: Callable
	var node_w := 62.0
	var node_h := 40.0
	var row_h := 64.0
	var pos := {}   # "row,col" -> centre

	func _key(r: int, c: int) -> String:
		return "%d,%d" % [r, c]

	func _centre(r: int, c: int, cols: int) -> Vector2:
		var y := (Paths.ROWS - 1 - r) * row_h + row_h * 0.5
		return Vector2(size.x * (c + 1) / float(cols + 1), y)

	func build() -> void:
		custom_minimum_size = Vector2(0, Paths.ROWS * row_h)
		var map: Array = run["map"]
		var trail: Array = run["trail"]
		for rr in Paths.ROWS:
			var cols: int = (map[rr] as Array).size()
			for c in cols:
				var n: Dictionary = map[rr][c]
				var visited := false
				for t in trail:
					if int(t[0]) == rr and int(t[1]) == c:
						visited = true
				var available := false
				for opt in opts:
					if int(opt[0]) == rr and int(opt[1]) == c:
						available = true
				var b := Button.new()
				b.clip_text = true
				b.custom_minimum_size = Vector2.ZERO
				var kind := String(n["t"])
				b.text = ("✓ " if visited else "") + ("Event" if kind == "event" else ("BOSS" if kind == "boss" else ["Easy", "Medium", "Hard"][int(n["d"])]))
				b.add_theme_font_size_override("font_size", 13)
				var col := PathsWindow._node_color(n)
				var w := node_w * (1.25 if kind == "boss" else 1.0)
				b.set_meta("rc", Vector2i(rr, c))
				b.set_meta("w", w)
				b.set_meta("cols", cols)
				var dim := 1.0 if (available or visited) else 0.45
				for st in ["normal", "hover", "pressed", "disabled", "focus"]:
					var sb := StyleBoxFlat.new()
					sb.bg_color = Color(col.r * dim, col.g * dim, col.b * dim, 1.0 if (available or visited) else 0.85)
					sb.set_corner_radius_all(14)
					sb.set_border_width_all(3 if (available or visited) else 1)
					sb.border_color = Color(1, 1, 1) if available else (Color(0.95, 0.8, 0.3) if visited else Color(0, 0, 0, 0.5))
					b.add_theme_stylebox_override(st, sb)
				b.add_theme_color_override("font_color", Color(1, 1, 1))
				b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.85 if visited else 0.6))
				b.disabled = not available or busy
				b.size = Vector2(w, node_h)
				var rc := Vector2i(rr, c)
				b.pressed.connect(func(): on_pick.call(rc.x, rc.y))
				add_child(b)
		resized.connect(_layout)
		_layout()

	func _layout() -> void:
		var map: Array = run["map"]
		for ch in get_children():
			if not (ch is Button):
				continue
			var rc: Vector2i = ch.get_meta("rc")
			var w: float = ch.get_meta("w")
			var cen := _centre(rc.x, rc.y, int(ch.get_meta("cols")))
			ch.size = Vector2(w, node_h)
			ch.position = cen - ch.size * 0.5
		queue_redraw()

	func _draw() -> void:
		var map: Array = run["map"]
		var trail: Array = run["trail"]
		var on_trail := {}
		for t in trail:
			on_trail[_key(int(t[0]), int(t[1]))] = true
		var avail := {}
		for opt in opts:
			avail[_key(int(opt[0]), int(opt[1]))] = true
		var last_row := -1
		var last_col := -1
		if not trail.is_empty():
			last_row = int(trail[trail.size() - 1][0])
			last_col = int(trail[trail.size() - 1][1])
		for rr in Paths.ROWS - 1:
			var cols: int = (map[rr] as Array).size()
			var ncols: int = (map[rr + 1] as Array).size()
			for c in cols:
				var a := _centre(rr, c, cols)
				for e in map[rr][c]["next"]:
					var bpt := _centre(rr + 1, int(e), ncols)
					var walked: bool = on_trail.has(_key(rr, c)) and on_trail.has(_key(rr + 1, int(e)))
					var live: bool = rr == last_row and c == last_col and avail.has(_key(rr + 1, int(e)))
					var col := Color(1, 1, 1, 0.18)
					var width := 2.0
					if walked:
						col = Color(0.95, 0.8, 0.3)
						width = 4.0
					elif live:
						col = Color(1, 1, 1, 0.9)
						width = 3.0
					draw_line(a, bpt, col, width, true)
		# the start: the first row's nodes hang off a base line
		if trail.is_empty():
			var cols0: int = (map[0] as Array).size()
			for c in cols0:
				var p := _centre(0, c, cols0)
				draw_line(p + Vector2(0, node_h * 0.5), Vector2(size.x * 0.5, size.y), Color(1, 1, 1, 0.9), 3.0, true)

static func _map(gc: GameController, o: Dictionary, vbox: VBoxContainer, r: Dictionary, render: Callable, ctx: Dictionary) -> void:
	var legend := HFlowContainer.new()
	legend.add_theme_constant_override("h_separation", 12)
	for item in [["Easy", COL_EASY], ["Medium", COL_MEDIUM], ["Hard", COL_HARD], ["Event", COL_EVENT], ["Boss", COL_BOSS]]:
		var l := Label.new()
		l.text = "● " + String(item[0])
		l.add_theme_color_override("font_color", item[1])
		l.add_theme_font_size_override("font_size", 14)
		legend.add_child(l)
	vbox.add_child(legend)
	var mv := MapView.new()
	mv.run = r
	mv.opts = Paths.options(r)
	mv.busy = gc.g.get("sideBattle") != null
	mv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mv.on_pick = func(row: int, col: int): _go(gc, o, r, row, col, render)
	vbox.add_child(mv)
	mv.build()

static func _go(gc: GameController, o: Dictionary, r: Dictionary, row: int, col: int, render: Callable) -> void:
	var node := Paths.node_at(r, row, col)
	if String(node["t"]) == "event":
		Paths.open_event(r, row, col)
		gc.save_game()
		render.call()
		return
	o["backdrop"].queue_free()
	gc.path_fight(row, col)

static func _event(gc: GameController, vbox: VBoxContainer, r: Dictionary, render: Callable, ctx: Dictionary) -> void:
	var e := Paths.event_by_id(String(r["event"]))
	vbox.add_child(_label(String(e["title"]), false, int(gc.vp.y * 0.026)))
	vbox.add_child(_label(String(e["text"])))
	for i in (e["opts"] as Array).size():
		var b := Button.new()
		b.text = String(e["opts"][i]["label"])
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size = Vector2(0, maxf(44.0, gc.vp.y * 0.055))
		b.pressed.connect(func():
			var lines := Paths.resolve_event(gc.g, r, i)
			ctx["lines"] = lines
			if Paths.end_if_wiped(gc.g, Time.get_unix_time_from_system()):
				lines.append("The run is over.")
				gc.refresh_hud()
			gc.save_game()
			render.call())
		vbox.add_child(b)

## One unit's gambit slots: a condition and an action each, from what the run has found.
static func _loadout(gc: GameController, r: Dictionary, uid: String, render: Callable) -> void:
	var o := gc.build_overlay_window(false)
	var vbox: VBoxContainer = o["vbox"]
	var def = FarroadCore.roster_by_id(uid)
	vbox.add_child(_label("%s's gambits" % (def["name"] if def else uid), false, 16))
	var auto := Button.new()
	auto.text = "Auto-set"
	vbox.add_child(auto)
	var slots_box := VBoxContainer.new()
	slots_box.add_theme_constant_override("separation", 6)
	vbox.add_child(slots_box)
	var ctx := {}
	ctx["fill"] = func():
		_clear(slots_box)
		var slots := Paths.loadout_of(gc.g, r, uid)
		for i in slots.size():
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			row.add_child(_label("%d" % (i + 1)))
			var cond := OptionButton.new()
			cond.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var conds: Array = r["conditions"]
			for k in conds.size():
				cond.add_item(FarroadCore.cond_label(String(conds[k])), k)
				if String(conds[k]) == String(slots[i]["cond"]):
					cond.select(k)
			var act := OptionButton.new()
			act.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var acts: Array = r["actions"]
			for k in acts.size():
				var a: Dictionary = FarroadCore.ACTIONS.get(String(acts[k]), {})
				act.add_item(String(a.get("name", acts[k])), k)
				if String(acts[k]) == String(slots[i]["action"]):
					act.select(k)
			var changed := func(_idx: int):
				Paths.set_slot(gc.g, r, uid, i, String(conds[cond.selected]), String(acts[act.selected]))
				gc.save_game()
			cond.item_selected.connect(changed)
			act.item_selected.connect(changed)
			row.add_child(cond)
			row.add_child(act)
			slots_box.add_child(row)
	auto.pressed.connect(func():
		Paths.auto_equip(gc.g, r, uid)
		gc.save_game()
		ctx["fill"].call())
	ctx["fill"].call()
	var close := Button.new()
	close.text = "Done"
	close.pressed.connect(func():
		o["backdrop"].queue_free()
		render.call())
	vbox.add_child(close)
	# the render lambda captures ctx: break that cycle when the window goes
	o["backdrop"].tree_exited.connect(func(): ctx.clear())
	await gc.finish_overlay_window(o)

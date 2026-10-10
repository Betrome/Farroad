class_name TrainingSetup
extends RefCounted
## The Training screen (Ian): a bar to place 1-10 dummies, and for each one,
## buttons to change its level, stats, affinities, statuses and what it is
## (the plain dummy, or any enemy met so far). It builds into a vbox it is
## given; GameController starts the fight when "Start training" is pressed.
## The same screen opens from the Gambits editor and from the Quests tab.

var g: Dictionary
var setup: Dictionary
var _on_start: Callable
var _slider: HSlider
var _count_label: Label
var _tiles: HFlowContainer
var _editor: VBoxContainer

const STAT_LABELS := {"hp": "HP", "atk": "ATK", "mag": "MAG", "def": "DEF", "res": "RES", "spd": "SPD"}
const AXES: Array[String] = ["fire", "water", "earth", "air", "light", "dark", "body", "spirit"]
const HP_PRESETS: Array[int] = [100, 70, 50, 30, 10]

func build(vbox: VBoxContainer, game: Dictionary, on_start: Callable) -> void:
	g = game
	setup = FarroadProgression.training_setup(g)
	_on_start = on_start

	var title := Label.new()
	title.text = "Training"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Palette.TEXT_INK)
	vbox.add_child(title)
	vbox.add_child(_note("Test your gambits on dummies. Nothing here gives rewards or changes your save. "
		+ "You can edit gambits from Units while it runs."))

	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", Palette.TEXT_INK)
	vbox.add_child(_count_label)
	_slider = HSlider.new()
	_slider.min_value = 1
	_slider.max_value = FarroadProgression.TRAINING_MAX
	_slider.step = 1
	_slider.value = int(setup["count"])
	_slider.custom_minimum_size = Vector2(0, 36)
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.value_changed.connect(_on_count_changed)
	vbox.add_child(_slider)

	_tiles = HFlowContainer.new()
	_tiles.add_theme_constant_override("h_separation", 6)
	_tiles.add_theme_constant_override("v_separation", 6)
	vbox.add_child(_tiles)

	vbox.add_child(HSeparator.new())
	_editor = VBoxContainer.new()
	_editor.add_theme_constant_override("separation", 8)
	vbox.add_child(_editor)

	vbox.add_child(HSeparator.new())
	var start := Button.new()
	start.text = "Start training"
	start.custom_minimum_size = Vector2(0, 44)
	start.pressed.connect(func(): _on_start.call())
	vbox.add_child(start)

	_refresh()

func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_color_override("font_color", Palette.TEXT_INK)
	l.modulate = Color(1, 1, 1, 0.75)
	return l

func _spec() -> Dictionary:
	return setup["dummies"][int(setup["selected"])]

func _on_count_changed(v: float) -> void:
	setup["count"] = int(v)
	setup["selected"] = mini(int(setup["selected"]), int(v) - 1)
	_refresh()

func _refresh() -> void:
	_count_label.text = "Dummies: %d" % int(setup["count"])
	_refresh_tiles()
	_refresh_editor()

func _spec_name(spec: Dictionary) -> String:
	var key := str(spec.get("arch", ""))
	return "Dummy" if key == "" or not FarroadCore.ARCH.has(key) else str(FarroadCore.ARCH[key]["name"])

## Empties a container safely even when called from one of its own buttons'
## tap handlers (a node can't be freed while it is emitting its signal).
func _clear(container: Container) -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()

func _refresh_tiles() -> void:
	_clear(_tiles)
	for i in int(setup["count"]):
		var spec: Dictionary = setup["dummies"][i]
		var b := Button.new()
		b.text = ("%s%d: %s L%d" % ["▶ " if i == int(setup["selected"]) else "", i + 1, _spec_name(spec), int(spec["level"])])
		b.pressed.connect(func():
			setup["selected"] = i
			_refresh_tiles()
			_refresh_editor())
		_tiles.add_child(b)

func _row(label_text: String) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 4)
	var l := Label.new()
	l.text = label_text
	l.add_theme_color_override("font_color", Palette.TEXT_INK)
	l.custom_minimum_size = Vector2(70, 0)
	row.add_child(l)
	_editor.add_child(row)
	return row

func _small_button(text: String, on_press: Callable, min_w: float = 40.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 34)
	b.pressed.connect(on_press)
	return b

func _refresh_editor() -> void:
	_clear(_editor)
	var spec := _spec()
	var heading := Label.new()
	heading.text = "Dummy %d" % (int(setup["selected"]) + 1)
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Palette.TEXT_INK)
	_editor.add_child(heading)

	# what it is: the plain dummy, or an enemy met so far
	var is_row := _row("Is")
	var opt := OptionButton.new()
	opt.add_item("Training dummy", 0)
	var met := FarroadProgression.training_met_enemies(g)
	var selected := 0
	for i in met.size():
		opt.add_item(str(met[i][1]), i + 1)
		if met[i][0] == str(spec.get("arch", "")):
			selected = i + 1
	opt.select(selected)
	opt.item_selected.connect(func(idx: int):
		spec["arch"] = "" if idx == 0 else str(met[idx - 1][0])
		spec["passive"] = (idx == 0)   # a real enemy fights back, the plain dummy doesn't
		_refresh_tiles()
		_refresh_editor())
	is_row.add_child(opt)
	if met.is_empty():
		_editor.add_child(_note("Enemies you meet on the Road appear in this list."))

	# level
	var lv := _row("Level")
	for d in [-100, -10, -1]:
		lv.add_child(_small_button(str(d), func(): _change_level(d)))
	var lvl := Label.new()
	lvl.text = " %d " % int(spec["level"])
	lvl.add_theme_color_override("font_color", Palette.TEXT_INK)
	lv.add_child(lvl)
	for d in [1, 10, 100]:
		lv.add_child(_small_button("+%d" % d, func(): _change_level(d)))
	_editor.add_child(_note("Its stats are scaled like an enemy at that wave."))

	# stat multipliers
	var mods: Dictionary = spec["mods"]
	for k in FarroadProgression.TRAINING_STATS:
		var r := _row(STAT_LABELS[k])
		var key: String = k
		r.add_child(_small_button("−", func(): _change_mod(key, -0.1)))
		var val := Label.new()
		val.text = " %d%% " % roundi(float(mods[k]) * 100.0)
		val.add_theme_color_override("font_color", Palette.TEXT_INK)
		val.custom_minimum_size = Vector2(54, 0)
		r.add_child(val)
		r.add_child(_small_button("+", func(): _change_mod(key, 0.1)))

	# behaviour
	var imm := CheckButton.new()
	imm.text = "Can't be defeated"
	imm.button_pressed = bool(spec.get("immortal", true))
	imm.toggled.connect(func(on: bool): spec["immortal"] = on)
	_editor.add_child(imm)
	var act := CheckButton.new()
	act.text = "Fights back"
	act.button_pressed = not bool(spec.get("passive", true))
	act.toggled.connect(func(on: bool): spec["passive"] = not on)
	_editor.add_child(act)

	var hp_row := _row("Starts at")
	for p in HP_PRESETS:
		var set_hp := func():
			spec["hpPct"] = p
			_refresh_editor()
		var pb := _small_button("%d%%" % p, set_hp, 46)
		pb.disabled = int(spec.get("hpPct", 100)) == p
		hp_row.add_child(pb)

	# affinities: none / weak / strong
	_editor.add_child(_note("Affinities (tap to cycle none, weak, strong):"))
	var aff_row := HFlowContainer.new()
	aff_row.add_theme_constant_override("h_separation", 6)
	aff_row.add_theme_constant_override("v_separation", 6)
	_editor.add_child(aff_row)
	var aff: Dictionary = spec["affinity"]
	for ax in AXES:
		var axis: String = ax
		var cur: float = float(aff.get(ax, 0.0))
		var state := "" if cur == 0.0 else (": weak" if cur < 0.0 else ": strong")
		var ab := Button.new()
		ab.text = axis.capitalize() + state
		ab.custom_minimum_size = Vector2(0, 34)
		ab.pressed.connect(func():
			var c: float = float(aff.get(axis, 0.0))
			if c == 0.0:
				aff[axis] = -FarroadProgression.TRAINING_AFFINITY_STEP
			elif c < 0.0:
				aff[axis] = FarroadProgression.TRAINING_AFFINITY_STEP
			else:
				aff.erase(axis)
			_refresh_editor())
		aff_row.add_child(ab)

	# statuses held for the whole fight
	_editor.add_child(_note("Statuses it holds for the whole fight:"))
	var st_row := HFlowContainer.new()
	st_row.add_theme_constant_override("h_separation", 6)
	st_row.add_theme_constant_override("v_separation", 6)
	_editor.add_child(st_row)
	var held: Array = spec["statuses"]
	for st in FarroadProgression.TRAINING_STATUSES:
		var sid: String = st
		var sb := Button.new()
		sb.text = ("✔ " if held.has(sid) else "") + sid.capitalize()
		sb.custom_minimum_size = Vector2(0, 34)
		sb.pressed.connect(func():
			if held.has(sid):
				held.erase(sid)
			else:
				held.append(sid)
			_refresh_editor())
		st_row.add_child(sb)

	var copy := Button.new()
	copy.text = "Copy this dummy to all dummies"
	copy.pressed.connect(func():
		for i in FarroadProgression.TRAINING_MAX:
			if i != int(setup["selected"]):
				setup["dummies"][i] = spec.duplicate(true)
		_refresh_tiles())
	_editor.add_child(copy)

func _change_level(d: int) -> void:
	var spec := _spec()
	spec["level"] = clampi(int(spec["level"]) + d, 1, 5000)
	_refresh_tiles()
	_refresh_editor()

func _change_mod(k: String, d: float) -> void:
	var mods: Dictionary = _spec()["mods"]
	mods[k] = snappedf(clampf(float(mods[k]) + d, 0.1, 10.0), 0.1)
	_refresh_editor()

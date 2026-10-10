extends Control
## One-page mockup of the proposed UI kit (UiKit.gd): a panel and the three
## text tiers, buttons in all five states (primary and secondary), a list with
## a light-band selection, the three bars (tap Hit to see the recent-damage
## segment), the status colour logic, and the bottom bar. Nothing in the game
## uses the kit yet. Open it with the game's --ui-preview option, or open
## res://scenes/UiKitMockup.tscn in the Godot editor and press F6.
##
## The bottom bar's icons are placeholders (letters): the painted round-1 icons
## from the Sprite Work session aren't in this project yet.

const SECTION_GAP := 16
var _bg: ColorRect
var _selected_row := 1
var _rows: Array = []
var _hp_bar: UiBar
var _active_tab := 3
var _tab_plates: Array = []
var _bright := false
var _font: Font = ThemeDB.fallback_font
var _font_label: Label
var _font_picker: OptionButton
## Fonts already installed on this PC, to compare. (The game would bundle one it
## ships; a system font only exists on the computer that has it.)
## Free fonts bundled with the project (godot-project/fonts/alegreya, SIL Open
## Font Licence). "label" is the font for the small-caps tier; "caps" says it
## has real small caps.
const FA := "res://fonts/alegreya/"
const FS := "res://fonts/selawik/"
const BUNDLED := {
	"Selawik (free Segoe UI lookalike)": {"body": FS + "Selawik-Regular.ttf", "label": FS + "Selawik-Semibold.ttf", "caps": false},
	"Alegreya + Alegreya Sans SC labels": {"body": FA + "Alegreya.ttf", "label": FA + "AlegreyaSansSC-Medium.ttf", "caps": true},
	"Alegreya + Alegreya SC labels": {"body": FA + "Alegreya.ttf", "label": FA + "AlegreyaSC-Regular.ttf", "caps": true},
	"Alegreya (all text)": {"body": FA + "Alegreya.ttf", "label": "", "caps": false},
	"Alegreya SC (all text)": {"body": FA + "AlegreyaSC-Regular.ttf", "label": FA + "AlegreyaSC-Regular.ttf", "caps": true},
}
const FONT_CHOICES: Array[String] = ["Selawik (free Segoe UI lookalike)", "Segoe UI", "Alegreya + Alegreya Sans SC labels", "Alegreya + Alegreya SC labels",
	"Alegreya (all text)", "Alegreya SC (all text)", "(game default)", "FS Benjamin", "Georgia", "Palatino Linotype", "Constantia",
	"Cambria", "Candara", "Corbel", "Trebuchet MS", "Bahnschrift", "Sitka Text", "Gabriola", "Century",
	"Baskerville Old Face", "Goudy Old Style", "Rockwell", "Verdana"]

func _ready() -> void:
	var vp := get_viewport_rect().size
	_bg = ColorRect.new()
	_bg.color = Color("171510")
	_bg.size = vp
	add_child(_bg)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2.ZERO
	scroll.size = Vector2(vp.x, vp.y - 100)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var page := VBoxContainer.new()
	page.custom_minimum_size = Vector2(vp.x - 24, 0)
	page.add_theme_constant_override("separation", SECTION_GAP)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_child(page)
	scroll.add_child(margin)

	_build_header(page)
	_build_font_picker(page)
	_build_panel_section(page)
	_build_buttons_section(page)
	_build_list_section(page)
	_build_bars_section(page)
	_build_colour_section(page)
	_build_bottom_bar(vp)
	_set_font(FONT_CHOICES[0])

func _build_font_picker(page: VBoxContainer) -> void:
	var box := _section(page, "Font")
	var opt := OptionButton.new()
	for f in FONT_CHOICES:
		opt.add_item(f)
	UiKit.style_button(opt, "secondary")
	opt.item_selected.connect(func(i: int): _set_font(FONT_CHOICES[i]))
	box.add_child(opt)
	_font_picker = opt
	_font_label = UiKit.make_label("The quick brown fox jumps over the lazy dog. 0123456789 — Gambit: Foe weak to Fire", "body")
	_font_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_font_label)

## A bundled font falls back to the engine's default for the few characters it
## lacks (Selawik has no true minus or the >= and <= signs, for example).
func _with_fallback(f: Font) -> Font:
	if f != null and not f.fallbacks.has(ThemeDB.fallback_font):
		f.fallbacks.append(ThemeDB.fallback_font)
	return f

func _label_font() -> Font:
	return UiKit.label_font if UiKit.label_font != null else _font

func _set_font(font_name: String) -> void:
	var t := Theme.new()
	UiKit.label_font = null
	UiKit.label_small_caps = false
	if BUNDLED.has(font_name):
		var spec: Dictionary = BUNDLED[font_name]
		_font = _with_fallback(load(spec["body"]))
		t.default_font = _font
		if str(spec["label"]) != "":
			UiKit.label_font = _with_fallback(load(spec["label"]))
		UiKit.label_small_caps = bool(spec["caps"])
	elif font_name == "(game default)":
		_font = ThemeDB.fallback_font
	else:
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray([font_name])
		sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		_font = sf
		t.default_font = sf
	theme = t
	# the small-caps labels already on screen follow the new label font
	for l in _all_labels(self):
		if l.has_meta("ui_tier"):
			l.text = UiKit.label_text(str(l.get_meta("ui_raw")))
			if UiKit.label_font != null:
				l.add_theme_font_override("font", UiKit.label_font)
			else:
				l.remove_theme_font_override("font")
			l.add_theme_font_size_override("font_size", 12 if UiKit.label_small_caps else 11)
	for p in _tab_plates:
		p.queue_redraw()
	for r in _rows:
		r.queue_redraw()

func _all_labels(n: Node) -> Array:
	var out: Array = []
	if n is Label:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_labels(c))
	return out

func _section(parent: Control, title: String) -> VBoxContainer:
	var panel := UiPanel.new()
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(UiKit.make_label(title, "label"))
	return box

func _build_header(page: VBoxContainer) -> void:
	var box := _section(page, "Mockup")
	box.add_child(UiKit.make_label("Farroad UI kit", "number"))
	var intro := UiKit.make_label("Brown plates, a silver rim lit from the upper left, capsule buttons, selection by light, recessed bars. Nothing in the game uses it yet.", "body")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(intro)
	var toggle := Button.new()
	toggle.text = "Test on a bright background"
	UiKit.style_button(toggle, "secondary")
	toggle.pressed.connect(func():
		_bright = not _bright
		_bg.color = Color("ada58c") if _bright else Color("171510")
		toggle.text = "Test on a dark background" if _bright else "Test on a bright background")
	box.add_child(toggle)

func _build_panel_section(page: VBoxContainer) -> void:
	var box := _section(page, "Panel and type")
	box.add_child(UiKit.make_label("Section label", "label"))
	box.add_child(UiKit.make_label("Body text is warm white at 90%, 14 px — readable on the plate.", "body"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	for pair in [["Power", "12,480"], ["Wave", "142"], ["Rating", "1,236"]]:
		var col := VBoxContainer.new()
		col.add_child(UiKit.make_label(pair[0], "label"))
		col.add_child(UiKit.make_label(pair[1], "number"))
		row.add_child(col)
	box.add_child(row)
	var modal := UiPanel.new(true)
	modal.add_child(UiKit.make_label("A modal gets the heavier 2 px rim.", "body"))
	box.add_child(modal)

func _build_buttons_section(page: VBoxContainer) -> void:
	var box := _section(page, "Buttons")
	for kind in ["primary", "secondary"]:
		box.add_child(UiKit.make_label(kind, "label"))
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		box.add_child(flow)
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			var b := Button.new()
			b.text = st.capitalize()
			b.custom_minimum_size = Vector2(0, 44)
			b.disabled = (st == "disabled")
			UiKit.style_button(b, kind, st)
			flow.add_child(b)
	box.add_child(UiKit.make_label("Live (these react to touch)", "label"))
	var live := HFlowContainer.new()
	live.add_theme_constant_override("h_separation", 8)
	box.add_child(live)
	for kind in ["primary", "secondary"]:
		var b := Button.new()
		b.text = "Tap me (%s)" % kind
		b.custom_minimum_size = Vector2(0, 44)
		UiKit.style_button(b, kind)
		live.add_child(b)

func _build_list_section(page: VBoxContainer) -> void:
	var box := _section(page, "List with a selected row")
	for i in 5:
		var row := _make_row(["Kesh", "Ansa", "Dorrek", "Mirel", "Lyrael"][i], ["Warden", "Spirit Mage", "Earth Fighter", "Fire Mage", "Spirit Mage"][i])
		box.add_child(row)
		_rows.append(row)
		var idx := i
		row.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed:
				_selected_row = idx
				for r in _rows:
					r.queue_redraw())
	box.add_child(UiKit.make_label("The selected row is a gold light band that fades to the right, with a chevron — no border.", "body"))

func _make_row(unit_name: String, title: String) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, 44)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.draw.connect(func():
		var idx := _rows.find(row)
		var selected: bool = idx == _selected_row
		var r := Rect2(Vector2.ZERO, row.size)
		if selected:
			var band := PackedVector2Array([r.position, Vector2(r.size.x * 0.7, 0), Vector2(r.size.x * 0.7, r.size.y), Vector2(0, r.size.y)])
			var strong := Color(UiKit.BAND, UiKit.BAND_ALPHA)
			var clear := Color(UiKit.BAND, 0.0)
			row.draw_polygon(band, PackedColorArray([strong, clear, clear, strong]))
			row.draw_string(_font, Vector2(8, r.size.y / 2.0 + 6), "›", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, UiKit.BAND.lightened(0.2))
		row.draw_string(_font, Vector2(28, r.size.y / 2.0 - 2), unit_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UiKit.TEXT)
		row.draw_string(_label_font(), Vector2(28, r.size.y / 2.0 + 14), UiKit.label_text(title), HORIZONTAL_ALIGNMENT_LEFT, -1, 12 if UiKit.label_small_caps else 10, UiKit.TEXT if selected else UiKit.TEXT_DIM)
		row.draw_line(Vector2(0, r.size.y - 0.5), Vector2(r.size.x, r.size.y - 0.5), Color(UiKit.SILVER_DIM, 0.25), 1.0))
	return row

func _build_bars_section(page: VBoxContainer) -> void:
	var box := _section(page, "Bars")
	box.add_child(UiKit.make_label("HP (green, then yellow at 50%, red at 25%) with the recent-damage segment", "label"))
	_hp_bar = UiBar.new(UiKit.HP_GOOD, true)
	box.add_child(_hp_bar)
	var hit := Button.new()
	hit.text = "Hit −25%   (then refill)"
	UiKit.style_button(hit, "secondary")
	var hp := [1.0]
	hit.pressed.connect(func():
		hp[0] = 1.0 if hp[0] <= 0.3 else hp[0] - 0.25
		_hp_bar.set_frac(hp[0]))
	box.add_child(hit)
	box.add_child(UiKit.make_label("Charge (stepped gauge)", "label"))
	var ch := UiBar.new(UiKit.CHARGE, false, 4)
	ch.set_frac(0.55, false)
	box.add_child(ch)

func _build_colour_section(page: VBoxContainer) -> void:
	var box := _section(page, "Colour logic")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 12)
	box.add_child(flow)
	for pair in [["Buff", UiKit.BUFF_TEXT], ["Debuff", UiKit.DEBUFF_TEXT], ["Damage over time", UiKit.DOT_TEXT]]:
		var chip := Label.new()
		chip.text = "• " + pair[0]
		chip.add_theme_color_override("font_color", pair[1])
		flow.add_child(chip)
	var stat := HBoxContainer.new()
	stat.add_theme_constant_override("separation", 14)
	box.add_child(stat)
	var up := Label.new()
	up.text = "ATK +12  better"
	up.add_theme_color_override("font_color", UiKit.BETTER_TEXT)
	stat.add_child(up)
	var down := Label.new()
	down.text = "DEF −8  worse"
	down.add_theme_color_override("font_color", UiKit.WORSE_TEXT)
	stat.add_child(down)
	box.add_child(UiKit.make_label("The exact colours, as chips", "label"))
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 10)
	box.add_child(chips)
	for pair in [["ATK +12", UiKit.BETTER, Color.WHITE], ["DEF −8", UiKit.WORSE, Color.BLACK]]:
		var chip := PanelContainer.new()
		var cs := StyleBoxFlat.new()
		cs.bg_color = pair[1]
		cs.set_corner_radius_all(10)
		cs.content_margin_left = 10
		cs.content_margin_right = 10
		cs.content_margin_top = 3
		cs.content_margin_bottom = 3
		chip.add_theme_stylebox_override("panel", cs)
		var cl := Label.new()
		cl.text = pair[0]
		cl.add_theme_color_override("font_color", pair[2])
		chip.add_child(cl)
		chips.add_child(chip)

func _build_bottom_bar(vp: Vector2) -> void:
	var strip := Control.new()
	strip.position = Vector2(0, vp.y - 100)
	strip.size = Vector2(vp.x, 100)
	strip.draw.connect(func():
		strip.draw_rect(Rect2(Vector2.ZERO, strip.size), Color(UiKit.PLATE_DARK, 0.96))
		strip.draw_line(Vector2.ZERO, Vector2(strip.size.x, 0), Color(UiKit.SILVER, 0.55), 1.0))
	add_child(strip)
	var names := ["Units", "Party", "Shop", "Road", "Trips", "Quests", "Menu"]
	var glyphs := ["U", "P", "$", "R", "E", "Q", "M"]
	var d := 46.0
	var gap := (vp.x - d * names.size()) / float(names.size() + 1)
	for i in names.size():
		var plate := Control.new()
		plate.position = Vector2(gap + i * (d + gap), 14)
		plate.size = Vector2(d, d + 22)
		plate.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := i
		plate.draw.connect(func():
			var active: bool = idx == _active_tab
			var c := Vector2(d / 2.0, d / 2.0)
			if active:
				plate.draw_circle(c, d / 2.0 + 7, Color(UiKit.BAND, 0.28))
			plate.draw_circle(c, d / 2.0, UiKit.PLATE_LIGHT if active else UiKit.PLATE)
			plate.draw_arc(c, d / 2.0 - 1, 0, TAU, 40, UiKit.SILVER_DIM, 1.5, true)
			plate.draw_arc(c, d / 2.0 - 1, PI * 0.75, PI * 1.75, 24, UiKit.SILVER, 2.0, true)   # lit upper-left arc
			plate.draw_string(_font, Vector2(c.x - 8, c.y + 8), glyphs[idx], HORIZONTAL_ALIGNMENT_CENTER, 16, 20, UiKit.TEXT)
			plate.draw_string(_label_font(), Vector2(0, d + 16), UiKit.label_text(names[idx]), HORIZONTAL_ALIGNMENT_CENTER, d, 12 if UiKit.label_small_caps else 10, UiKit.BAND.lightened(0.15) if active else UiKit.TEXT_DIM)
			if active:   # the notch under the active tab
				var tri := PackedVector2Array([Vector2(c.x - 5, d + 22), Vector2(c.x + 5, d + 22), Vector2(c.x, d + 17)])
				plate.draw_colored_polygon(tri, UiKit.SILVER))
		plate.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed:
				_active_tab = idx
				for p in _tab_plates:
					p.queue_redraw())
		strip.add_child(plate)
		_tab_plates.append(plate)

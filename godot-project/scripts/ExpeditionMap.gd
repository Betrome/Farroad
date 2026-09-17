class_name ExpeditionMap
extends Control
## 20-item batch, Group K: a compass-style home-base map replacing the flat
## 8-direction-button row in ExpeditionPanel's send picker. Ian confirmed
## this is presentation-only ("meander = visual only, no new mechanics")
## and needs NO new persisted data: `direction`/`ew` (depth along a
## direction's line, already tracked), `g["directions"][dir]["maxDepth"]`
## (fog-of-war), and each expedition's own `id` (a stable meander-offset
## seed) are all real, already-persisted fields. The first custom
## `_draw()`-based widget in this project -- every other visual surface so
## far has been built entirely from Control/Node2D primitives
## (StyleBoxFlat buttons, Polygon2D shapes), never raw canvas drawing.
##
## Direction icons and expedition dots are BOTH real Buttons (not raw
## `_gui_input` hit-testing against `_draw()` geometry) -- more reliable on
## touch, the same reasoning this project already applied to every other
## tappable surface. `_draw()` only ever renders the non-interactive parts
## (the home-base icon and the 8 radiating lines, including their fog-of-
## war fade) plus a small visual dot UNDER each expedition's own (mostly
## transparent) tap-target Button.

## Real compass angles (math convention: 0=East, 90=South (Godot's 2D Y
## axis points down), 180=West, 270=North) -- these 8 direction ids are
## themselves real compass-direction names (confirmed via content.json's
## DIRECTION_CONFIG), so the angle assignment matches them directly
## rather than being arbitrary.
const DIRECTION_ANGLES_DEG := {
	"east": 0.0, "southeast": 45.0, "south": 90.0, "southwest": 135.0,
	"west": 180.0, "northwest": 225.0, "north": 270.0, "northeast": 315.0,
}

## Ian: real compass abbreviations for the direction-icon buttons -- the
## old `.left(3)` truncation of the full label ("Nor", "Nort", "Sout")
## read as cut-off text, not a real abbreviation.
const DIRECTION_ABBREV := {
	"west": "W", "northwest": "NW", "southwest": "SW", "north": "N",
	"south": "S", "northeast": "NE", "southeast": "SE", "east": "E",
}

## First-pass, adjustable: how much `ew` (an expedition's own depth along
## its direction) reads as "the full length of the line" -- deliberately
## NOT tied to g["directions"][dir]["maxDepth"] (which an expedition can
## itself be actively extending in real time, which would make the dot's
## own position a moving target relative to its own progress). A little
## past one dungeon-unlock threshold (DIRECTION_CONFIG.unlockEvery=100)
## so early progress doesn't read as "already at the edge".
const EW_VISUAL_REF := 150.0
const MEANDER_AMPLITUDE_FRAC := 0.09   # fraction of the map's own radius

const LINE_COLOR := Color(0.42, 0.28, 0.17, 0.9)
const LINE_COLOR_FOGGED := Color(0.42, 0.28, 0.17, 0.18)
const HOME_COLOR := Color(0.66, 0.48, 0.10)
const DOT_COLOR := Color(0.18, 0.34, 0.56)
const DOT_ARRIVED_COLOR := Color(0.20, 0.46, 0.24)

var g: Dictionary
var selected_direction: String = ""
var _on_direction_selected: Callable
var _on_dot_pressed: Callable

var _center: Vector2
var _radius: float
var _direction_buttons: Dictionary = {}   # dir -> Button, persists across refreshes
var _dot_buttons: Array = []              # Buttons, freed/rebuilt each refresh (expeditions come and go)

## ExpeditionPanel rebuilds this widget fresh every _refresh_send_picker()
## call -- same "just rebuild everything, no partial diffing" convention
## every other panel in this project already uses for its own per-refresh
## content -- so setup() alone (no separate refresh()) does the full job:
## direction buttons, expedition dots, and the initial _draw().
func setup(new_g: Dictionary, map_size: Vector2, current_selected_direction: String, direction_cb: Callable, dot_cb: Callable) -> void:
	g = new_g
	selected_direction = current_selected_direction
	_on_direction_selected = direction_cb
	_on_dot_pressed = dot_cb
	custom_minimum_size = map_size
	_center = map_size / 2.0
	_radius = minf(map_size.x, map_size.y) / 2.0 * 0.82
	_build_direction_buttons()
	for exp in g["expeditions"]:
		_dot_buttons.append(_build_dot_button(exp))

func _dir_vec(dir: String) -> Vector2:
	return Vector2.RIGHT.rotated(deg_to_rad(DIRECTION_ANGLES_DEG.get(dir, 0.0)))

func _build_direction_buttons() -> void:
	var btn_size: float = _radius * 0.34
	for dir in FarroadProgression.direction_ids():
		var pos: Vector2 = _center + _dir_vec(dir) * _radius
		var btn := Button.new()
		btn.text = DIRECTION_ABBREV.get(dir, FarroadProgression.direction_label(dir).left(3))
		btn.custom_minimum_size = Vector2(btn_size, btn_size)
		btn.position = pos - Vector2(btn_size, btn_size) / 2.0
		btn.clip_text = true
		btn.toggle_mode = true
		btn.add_theme_font_size_override("font_size", maxi(8, int(btn_size * 0.32)))
		btn.pressed.connect(_on_direction_selected.bind(dir))
		add_child(btn)
		_direction_buttons[dir] = btn
		_style_direction_button(btn, dir)

func _style_direction_button(btn: Button, dir: String) -> void:
	var occupied: bool = false
	for exp in g["expeditions"]:
		if exp["direction"] == dir:
			occupied = true
	var is_selected: bool = (selected_direction == dir)
	btn.button_pressed = is_selected
	btn.disabled = occupied and not is_selected
	var radius_px: int = int(btn.custom_minimum_size.x / 2.0)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Palette.GOLD_PRESSED if is_selected else Palette.BTN_NORMAL
	normal.set_corner_radius_all(radius_px)
	var disabled_style := StyleBoxFlat.new()
	disabled_style.bg_color = Palette.BTN_DISABLED
	disabled_style.set_corner_radius_all(radius_px)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", normal)
	btn.add_theme_stylebox_override("pressed", normal)
	btn.add_theme_stylebox_override("disabled", disabled_style)

## Deterministic (hashed off the expedition's own id, never re-randomized
## on a later refresh) so a redraw never makes an expedition's dot jump
## sideways -- shrinks toward zero near the home base (scaled by
## travel_frac) per Ian's own confirmed "visual only" meander.
func _meander_offset(exp: Dictionary, travel_frac: float) -> float:
	var h: int = String(exp["id"]).hash()
	var unit_mag: float = float(h % 1000) / 999.0   # [0, 1]
	var sign_val: float = 1.0 if (h % 2 == 0) else -1.0
	return sign_val * unit_mag * _radius * MEANDER_AMPLITUDE_FRAC * travel_frac

func _dot_position(exp: Dictionary) -> Vector2:
	var dir_vec: Vector2 = _dir_vec(exp["direction"])
	var travel_frac: float = clampf(float(exp["ew"]) / EW_VISUAL_REF, 0.0, 1.0)
	var perp: Vector2 = dir_vec.rotated(PI / 2.0)
	return _center + dir_vec * _radius * travel_frac + perp * _meander_offset(exp, travel_frac)

func _build_dot_button(exp: Dictionary) -> Button:
	var dot_size: float = _radius * 0.16
	var pos: Vector2 = _dot_position(exp)
	var btn := Button.new()
	btn.flat = true
	btn.custom_minimum_size = Vector2(dot_size, dot_size)
	btn.position = pos - Vector2(dot_size, dot_size) / 2.0
	btn.tooltip_text = "Log"
	btn.pressed.connect(_on_dot_pressed.bind(exp))
	add_child(btn)
	return btn

func _draw() -> void:
	for dir in FarroadProgression.direction_ids():
		var dir_vec: Vector2 = _dir_vec(dir)
		var max_depth: float = float(g["directions"].get(dir, {}).get("maxDepth", 0))
		var revealed_frac: float = clampf(max_depth / EW_VISUAL_REF, 0.0, 1.0)
		var revealed_end: Vector2 = _center + dir_vec * _radius * revealed_frac
		var full_end: Vector2 = _center + dir_vec * _radius
		if revealed_frac > 0.0:
			draw_line(_center, revealed_end, LINE_COLOR, 2.0)
		if revealed_frac < 1.0:
			draw_line(revealed_end, full_end, LINE_COLOR_FOGGED, 2.0)

	for exp in g["expeditions"]:
		var dot_color: Color = DOT_ARRIVED_COLOR if exp.get("arrivedAt") != null else DOT_COLOR
		draw_circle(_dot_position(exp), _radius * 0.05, dot_color)

	draw_circle(_center, _radius * 0.11, HOME_COLOR)

class_name AscensionGate
extends Node2D
## The glowing gate that appears after the wave 100, 200, ... boss: it fades in, its doors slide open onto
## light, and a staircase descends from it down to the ground. Art in res://sprites/gate/ (placement and
## draw order from gate_meta.json, kept in art_src/environments/gate). The gate faces the lower left, so
## its pieces are sheared and the door slide is baked into a 12-frame strip.
## `door` is the doorway's base-left corner in global pixels; `u` is the art-pixel scale (battle height / 544).

const DIR := "res://sprites/gate/"
const STEPS := 9
const FRAMES := 12
const FRAME_W := 120
const FRAME_H := 250
const DOORWAY_BASE_LEFT := Vector2(40.0, 176.0)
const DOORWAY_CENTRE := Vector2(63.0, 134.0)
const GLOW_CENTRE := Vector2(80.0, 112.0)
const TOP_STEP := Vector2(42.0, 175.0)
const STEP_DX := -11.0          # steeper than the first pass (-18)
const STEP_DY_MIN := 11.5
const STEP_DY_MAX := 22.0
const STEP_H := 28.0
const ARC_FPS := 12.0
const GLOW_MUL := 0.70   # Ian: glow at 70% of the original

var u := 1.0
var appear := 0.0            # 0..1: the gate wakes (fades in, runes light)
var open := 0.0              # 0..1: the doors slide apart
var stairs := 0.0            # 0..1: the steps appear from the gate downward
var _step := Vector2(STEP_DX, STEP_DY_MIN)   # offset from one step to the next, in art pixels
var _origin := Vector2.ZERO  # global position of the frame canvas's top-left
var _t := 0.0

var _glow: Sprite2D
var _doors: Sprite2D
var _frame: Sprite2D
var _frame_runes: Sprite2D
var _doors_runes: Sprite2D
var _arcs: Sprite2D
var _arcs_add: Sprite2D
var _steps: Array = []        # [Sprite2D, runes Sprite2D]
var _light: PointLight2D
var _core: PointLight2D

## `lowest_unit_top` (global y, or -1): the stairs are made just steep enough that the last step ends
## just short of the lowest unit standing below.
func setup(doorway_base_left: Vector2, art_scale: float, lowest_unit_top: float = -1.0) -> void:
	u = art_scale
	_origin = doorway_base_left - DOORWAY_BASE_LEFT * u
	if lowest_unit_top > 0.0:
		var last_top_art: float = (lowest_unit_top - _origin.y) / u - STEP_H
		_step.y = clampf((last_top_art - TOP_STEP.y) / float(STEPS - 1), STEP_DY_MIN, STEP_DY_MAX)
	global_position = Vector2.ZERO
	_build()
	_apply()

func _tex(name: String) -> Texture2D:
	return load(DIR + name) as Texture2D

func _sprite(name: String, pos_in_frame: Vector2, additive: bool = false, centre_on: Vector2 = Vector2.ZERO) -> Sprite2D:
	var sp := Sprite2D.new()
	sp.texture = _tex(name)
	sp.centered = false
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sp.scale = Vector2(u, u)
	sp.position = _origin + (pos_in_frame - centre_on) * u
	if additive:
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		sp.material = m
	add_child(sp)
	return sp

func _strip(name: String, additive: bool = false) -> Sprite2D:
	var sp := _sprite(name, Vector2.ZERO, additive)
	sp.region_enabled = true
	sp.region_rect = Rect2(0, 0, FRAME_W, FRAME_H)
	return sp

func _build() -> void:
	_glow = _sprite("gate_glow.png", DOORWAY_CENTRE, true, GLOW_CENTRE)
	_doors = _strip("gate_doors.png")
	_frame = _sprite("gate_frame.png", Vector2.ZERO)
	_frame_runes = _sprite("gate_frame_runes.png", Vector2.ZERO)
	_doors_runes = _strip("gate_doors_runes.png")
	_arcs = _strip("gate_arcs.png")
	_arcs_add = _strip("gate_arcs.png", true)
	# stairs sit in front of the gate, top step first so each nearer step overlaps the one above
	for i in STEPS:
		var p: Vector2 = TOP_STEP + _step * float(i)
		_steps.append([_sprite("stair_step.png", p), _sprite("stair_step_runes.png", p)])
	_light = _point_light(Color("ffd98a"), 1.5)
	_core = _point_light(Color("fff4c4"), 0.6)

func _point_light(col: Color, tex_scale: float) -> PointLight2D:
	var l := PointLight2D.new()
	var gt := GradientTexture2D.new()
	var grad := Gradient.new()
	grad.set_color(0, Color.WHITE)
	grad.set_color(1, Color(1, 1, 1, 0))
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 512
	gt.height = 512
	l.texture = gt
	l.texture_scale = tex_scale * u / 1.68   # about 1.5 at the portrait scale
	l.color = col
	l.blend_mode = Light2D.BLEND_MODE_ADD
	l.energy = 0.0
	l.position = _origin + DOORWAY_CENTRE * u
	add_child(l)
	return l

func set_appear(v: float) -> void:
	appear = v
	_apply()

func set_open(v: float) -> void:
	open = v
	_apply()

func set_stairs(v: float) -> void:
	stairs = v
	_apply()

func _process(delta: float) -> void:
	_t += delta
	if appear > 0.0:
		_apply()

func _region(sp: Sprite2D, frame: int) -> void:
	sp.region_rect = Rect2(float(frame) * FRAME_W, 0, FRAME_W, FRAME_H)

func _apply() -> void:
	if _glow == null:
		return
	var a: float = clampf(appear, 0.0, 1.0)
	var door_frame: int = clampi(int(floor(open * float(FRAMES - 1) + 0.5)), 0, FRAMES - 1)
	var arcs_on: bool = open >= 0.5
	_glow.modulate.a = a * (0.35 + 0.65 * open) * GLOW_MUL
	for sp in [_doors, _frame]:
		sp.modulate.a = a
	_region(_doors, door_frame)
	for sp in [_frame_runes, _doors_runes]:
		sp.modulate.a = a   # the runes fade in as the gate wakes
	_region(_doors_runes, door_frame)
	var arc_frame: int = int(_t * ARC_FPS) % FRAMES
	for sp in [_arcs, _arcs_add]:
		sp.visible = arcs_on
		_region(sp, arc_frame)
	_arcs_add.modulate.a = 0.6 * GLOW_MUL
	var shown: int = int(ceil(stairs * float(STEPS)))
	for i in STEPS:
		var on: bool = i < shown
		for sp in _steps[i]:
			sp.visible = on
			sp.modulate.a = a
	# the light rises with the doors, flickering, with a spike when an arc frame starts
	var flick: float = 0.08 * sin(_t * 17.0) + 0.04 * sin(_t * 41.0)
	var spike: float = 0.15 if (arcs_on and arc_frame % 4 == 0) else 0.0
	_light.energy = (a * 1.1 * open + (flick + spike) * open) * GLOW_MUL
	_core.energy = a * 0.6 * open * GLOW_MUL
	_light.energy = maxf(0.0, _light.energy)

## Where the party steps onto the stairs, and where it enters the doorway.
func stair_foot() -> Vector2:
	var p: Vector2 = TOP_STEP + _step * float(STEPS - 1) + Vector2(0.0, 10.0)
	return _origin + p * u

func door_point() -> Vector2:
	return _origin + (DOORWAY_CENTRE + Vector2(0.0, 36.0)) * u

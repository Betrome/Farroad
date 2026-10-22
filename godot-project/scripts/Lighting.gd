class_name Lighting
extends Node
## Dynamic lighting for the battle view (Ian): a sun (or moon) that tints the art and
## shades the unit sprites through their normal maps, blob shadows that lean away from
## it, and, in the cave, small blue lights on the crystals.
##
## How it stays out of the HUD: no CanvasModulate (that would tint every Control too).
## Instead the art that should be lit -- the background and front-tree sprites, and the
## unit sprites -- carries the SUN_LAYER light-mask bit and a self_modulate holding the
## ambient colour; the lights only reach items with that bit.
##
## The look follows the environment and the player's local time of day (dawn, noon,
## dusk, night blend into each other). Turned off from Settings > Dynamic lighting:
## then nothing is tinted, no lights exist, sprites use their plain frames, and the blob
## shadows stay but sit straight under the unit.

const SUN_LAYER := 4   # light-mask bit (1 = default, 2 = AttackFX's UNIT_LIGHT_LAYER)
const REFRESH_SEC := 60.0
## How much of the sun a flat, un-normal-mapped surface picks up (the sun's height is low).
const FLAT_LIGHT := 0.35

## A look: ambient colour, sun colour/energy/direction (radians; 0 = from straight above,
## PI/4 = from the top-right), sun height (0..1, how far above the ground), the blob shadow's
## lean (a fraction of its width), length (blob width relative to the unit) and opacity.
const NOON := {"ambient": Color(0.80, 0.82, 0.92), "sun": Color(1.0, 0.95, 0.82), "energy": 0.6, "rot": PI / 4.0, "height": 0.35, "lean": -0.14, "len": 1.9, "alpha": 0.55}
const DAWN := {"ambient": Color(0.74, 0.72, 0.86), "sun": Color(1.0, 0.74, 0.50), "energy": 0.8, "rot": -1.25, "height": 0.15, "lean": 0.18, "len": 2.6, "alpha": 0.45}
const DUSK := {"ambient": Color(0.66, 0.58, 0.78), "sun": Color(1.0, 0.52, 0.28), "energy": 0.9, "rot": 1.25, "height": 0.15, "lean": -0.17, "len": 2.8, "alpha": 0.50}
const NIGHT := {"ambient": Color(0.30, 0.34, 0.58), "sun": Color(0.55, 0.66, 1.0), "energy": 0.45, "rot": PI / 5.0, "height": 0.30, "lean": -0.13, "len": 1.7, "alpha": 0.30}
## Local hour -> look. Between two keys every value is blended.
const DAY_KEYS := [[0.0, NIGHT], [5.0, NIGHT], [7.0, DAWN], [10.0, NOON], [15.0, NOON], [18.0, DUSK], [20.0, NIGHT], [24.0, NIGHT]]
## Sets with a fixed look, whatever the hour: the cave (blue ambient, crystal lights) -- sunless.
const CAVE := {"ambient": Color(0.30, 0.38, 0.62), "sun": Color(0.45, 0.65, 1.0), "energy": 0.45, "rot": PI / 4.0, "height": 0.30, "lean": -0.13, "len": 1.4, "alpha": 0.45}
## The forest canopy dims and greens whatever the hour is doing.
const FOREST_TINT := Color(0.78, 0.90, 0.72)
const FOREST_SUN_MUL := 0.75

## Crystal positions in cave_near.png (art pixels): x, y, size. Each gets a small blue light.
const CAVE_CRYSTALS := [Vector3(109, 197, 40), Vector3(224, 282, 71), Vector3(188, 351, 56), Vector3(251, 350, 51),
	Vector3(434, 383, 61), Vector3(26, 388, 56), Vector3(91, 389, 49), Vector3(257, 391, 62), Vector3(138, 433, 54),
	Vector3(99, 440, 58), Vector3(310, 442, 61), Vector3(469, 483, 63), Vector3(272, 490, 60)]
const CRYSTAL_COLOR := Color(0.40, 0.78, 1.0)

## The look in force right now (read by UnitView for its tint and blob). Empty while off.
static var params: Dictionary = {}
static var _blob_tex: Texture2D
static var _lit_cache: Dictionary = {}   # SpriteFrames instance id -> lit copy

var _gc: Node = null
var _sun: DirectionalLight2D = null
var _glow_tex: Texture2D

static func enabled() -> bool:
	return bool(Analytics.state.get("lighting", true)) if not Analytics.state.is_empty() else true

static func set_enabled(on: bool) -> void:
	Analytics.enabled()   # loads the device settings file
	Analytics.state["lighting"] = on
	Analytics._dirty = true
	Analytics.save()

## `gc` is the GameController: it owns background_layer, foreground_layer and bg_set.
func setup(gc: Node) -> void:
	_gc = gc
	var t := Timer.new()
	t.wait_time = REFRESH_SEC
	t.autostart = true
	t.ignore_time_scale = true
	t.timeout.connect(refresh)
	add_child(t)
	refresh()

## ===== the look =====

## Tests only: pin the hour (negative = use the real clock).
static var hour_override := -1.0

static func _local_hour() -> float:
	if hour_override >= 0.0:
		return hour_override
	var d := Time.get_datetime_dict_from_system()   # the player's own clock
	return float(d["hour"]) + float(d["minute"]) / 60.0

static func _mix(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for k in a.keys():
		var x = a[k]
		var y = b[k]
		out[k] = (x as Color).lerp(y, t) if x is Color else lerpf(float(x), float(y), t)
	return out

static func look_for(env: String, hour: float) -> Dictionary:
	if env == "cave":
		return CAVE.duplicate()
	var look: Dictionary = NOON.duplicate()
	for i in range(DAY_KEYS.size() - 1):
		var k0: Array = DAY_KEYS[i]
		var k1: Array = DAY_KEYS[i + 1]
		if hour >= float(k0[0]) and hour <= float(k1[0]):
			var span: float = maxf(0.001, float(k1[0]) - float(k0[0]))
			look = _mix(k0[1], k1[1], (hour - float(k0[0])) / span)
			break
	if env == "forest":
		look["ambient"] = (look["ambient"] as Color) * FOREST_TINT
		look["energy"] = float(look["energy"]) * FOREST_SUN_MUL
	return look

## What an art item's self_modulate should be so that (it x the sun's flat light) lands on
## the intended ambient: without a CanvasModulate the light is added on top of the item's colour.
func _art_tint() -> Color:
	return unit_tint()

## Re-reads the time, environment and setting, and applies the result everywhere.
func refresh() -> void:
	if _gc == null or not is_instance_valid(_gc):
		return
	if not enabled():
		params = {}
		_free_sun()
		_apply_to_art(false)
		get_tree().call_group("lit_units", "refresh_lighting")
		return
	params = look_for(str(_gc.get("bg_set")), _local_hour())
	if _sun == null:
		_sun = DirectionalLight2D.new()
		_sun.range_item_cull_mask = SUN_LAYER
		_gc.add_child(_sun)
	_sun.color = params["sun"]
	_sun.energy = params["energy"]
	_sun.rotation = params["rot"]
	_sun.height = params["height"]
	_apply_to_art(true)
	get_tree().call_group("lit_units", "refresh_lighting")

func _free_sun() -> void:
	if _sun != null and is_instance_valid(_sun):
		_sun.queue_free()
	_sun = null

func _apply_to_art(on: bool) -> void:
	var tint := _art_tint() if on else Color.WHITE
	for root in [_gc.get("background_layer"), _gc.get("foreground_layer")]:
		if root != null and is_instance_valid(root):
			_tint_tree(root, tint, on, 0)

func _tint_tree(n: Node, tint: Color, on: bool, depth: int) -> void:
	for c in n.get_children():
		if c is Sprite2D:
			(c as Sprite2D).self_modulate = tint
			(c as Sprite2D).light_mask = (1 | SUN_LAYER) if on else 1
		if depth < 2 and not (c is Light2D):
			_tint_tree(c, tint, on, depth + 1)

## Called by GameController after it rebuilds the background layers: tints the new
## sprites and, in the cave, puts a small light on each crystal of the near layer
## (a child of the scrolling layer, so the lights travel with their crystals).
func on_background_rebuilt() -> void:
	if _gc == null or not is_instance_valid(_gc):
		return
	refresh()
	if not enabled() or str(_gc.get("bg_set")) != "cave":
		return
	var bl: Node = _gc.get("background_layer")
	if bl == null or bl.get_child_count() < 3:
		return
	var near: Node = bl.get_child(2)
	var vis_w: float = float((_gc.get("bvp") as Vector2).x)
	if _glow_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color.WHITE)
		g.set_color(1, Color(1, 1, 1, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 128
		t.height = 128
		_glow_tex = t
	for tile in near.get_children():
		if not (tile is Sprite2D) or (tile as Sprite2D).texture == null:
			continue
		var sp: Sprite2D = tile
		# only the tiles that can come on screen carry lights (the rest are off to the sides)
		if sp.position.x > vis_w + sp.texture.get_width() * sp.scale.x or sp.position.x < -3.0 * sp.texture.get_width() * sp.scale.x:
			continue
		var holder := Node2D.new()
		holder.position = sp.position
		near.add_child(holder)
		for c in CAVE_CRYSTALS:
			var l := PointLight2D.new()
			l.texture = _glow_tex
			l.texture_scale = (0.55 + c.z / 300.0) * sp.scale.y
			l.color = CRYSTAL_COLOR
			l.energy = 0.9
			l.height = 30.0
			l.range_item_cull_mask = SUN_LAYER
			l.position = Vector2(c.x * sp.scale.x, c.y * sp.scale.y)
			holder.add_child(l)

## ===== units =====

## A copy of `frames` with each frame wrapped in a CanvasTexture carrying its baked
## normal map (<frame>_n.png). Frames without one stay as they are.
static func lit_frames(frames: SpriteFrames) -> SpriteFrames:
	if frames == null:
		return null
	var key := frames.get_instance_id()
	if _lit_cache.has(key):
		return _lit_cache[key]
	var out := SpriteFrames.new()
	for a in out.get_animation_names():
		out.remove_animation(a)
	for a in frames.get_animation_names():
		out.add_animation(a)
		out.set_animation_loop(a, frames.get_animation_loop(a))
		out.set_animation_speed(a, frames.get_animation_speed(a))
		for i in frames.get_frame_count(a):
			var tex: Texture2D = frames.get_frame_texture(a, i)
			var path := tex.resource_path if tex != null else ""
			var npath := path.replace(".png", "_n.png")
			if path.ends_with(".png") and ResourceLoader.exists(npath):
				var ct := CanvasTexture.new()
				ct.diffuse_texture = tex
				ct.normal_texture = load(npath)
				tex = ct
			out.add_frame(a, tex, frames.get_frame_duration(a, i))
	for m in frames.get_meta_list():
		out.set_meta(m, frames.get_meta(m))
	_lit_cache[key] = out
	return out

static func blob_texture() -> Texture2D:
	if _blob_tex == null:
		var g := Gradient.new()
		# solid through the middle, fading only toward the edge (a hard-edged shadow)
		g.offsets = PackedFloat32Array([0.0, 0.56, 1.0])
		g.colors = PackedColorArray([Color(0, 0, 0, 1), Color(0, 0, 0, 0.9), Color(0, 0, 0, 0)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		_blob_tex = t
	return _blob_tex

## The unit-sprite tint that matches the art's (see _art_tint).
static func unit_tint() -> Color:
	if params.is_empty():
		return Color.WHITE
	var sun: Color = params["sun"]
	var e: float = float(params["energy"]) * FLAT_LIGHT
	var amb: Color = params["ambient"]
	return Color((amb.r + sun.r * e) / (1.0 + sun.r * e), (amb.g + sun.g * e) / (1.0 + sun.g * e), (amb.b + sun.b * e) / (1.0 + sun.b * e))

class_name LayeredCharacter
extends Node2D

## A paper-doll battle sprite: one animated body layer plus head layers
## (face, eyes, hair) that are drawn once and placed on every frame using
## the per-frame head offsets from tools/sprite_layers.py's manifest.json.
##
## Folder layout (what sprite_layers.py writes):
##   body_<n>.png, face.png, eyes.png, hair.png, manifest.json
## Any head layer can be swapped at runtime with set_layer_texture(), and
## recoloured with set_layer_colors() (tint_ramp.gdshader).

const HEAD_LAYERS := ["face", "eyes", "hair"]
## Per-layer saturation floor for recolouring (see tint_ramp.gdshader):
## eyes only recolour the iris, not the whites/lashes/pupil.
const LAYER_SAT_MIN := {"face": 0.0, "eyes": 0.15, "hair": 0.0}
const TINT_SHADER := preload("res://shaders/tint_ramp.gdshader")

var manifest: Dictionary = {}
var body_frames: Array[Texture2D] = []
var frame_order: Array[int] = []   # e.g. ping-pong 0,1,2,1
var frame_index := 0
var fps := 6.0
var _time := 0.0

var body: Sprite2D
var head_root: Node2D
var head_sprites := {}   # layer name -> Sprite2D

func load_from(dir: String, ping_pong := true) -> void:
	var f := FileAccess.open(dir.path_join("manifest.json"), FileAccess.READ)
	manifest = JSON.parse_string(f.get_as_text())
	var n: int = int(manifest["frames"])
	body_frames.clear()
	for i in range(n):
		body_frames.append(load(dir.path_join("body_%d.png" % i)))
	frame_order.clear()
	for i in range(n):
		frame_order.append(i)
	if ping_pong and n > 2:
		for i in range(n - 2, 0, -1):
			frame_order.append(i)
	fps = float(manifest.get("fps", 6))

	body = Sprite2D.new()
	body.centered = false
	body.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(body)
	head_root = Node2D.new()
	add_child(head_root)
	var origin: Array = manifest["head_origin"]
	for layer in HEAD_LAYERS:
		var s := Sprite2D.new()
		s.centered = false
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		s.position = Vector2(origin[0], origin[1])
		s.texture = load(dir.path_join(layer + ".png"))
		var mat := ShaderMaterial.new()
		mat.shader = TINT_SHADER
		s.material = mat
		head_root.add_child(s)
		head_sprites[layer] = s
	_show_frame()

func _process(delta: float) -> void:
	if body_frames.is_empty():
		return
	_time += delta
	if _time >= 1.0 / fps:
		_time -= 1.0 / fps
		frame_index = (frame_index + 1) % frame_order.size()
		_show_frame()

func _show_frame() -> void:
	var fi: int = frame_order[frame_index]
	body.texture = body_frames[fi]
	var off: Array = manifest["offsets"][fi]
	head_root.position = Vector2(off[0], off[1])

func set_layer_visible(layer: String, on: bool) -> void:
	head_sprites[layer].visible = on

func set_layer_texture(layer: String, tex: Texture2D) -> void:
	head_sprites[layer].texture = tex

## Recolour a layer onto a shadow->light ramp. Pass strength 0 to restore
## the drawn colours.
func set_layer_colors(layer: String, shadow: Color, light: Color, strength := 1.0) -> void:
	var mat: ShaderMaterial = head_sprites[layer].material
	mat.set_shader_parameter("shadow", shadow)
	mat.set_shader_parameter("light", light)
	mat.set_shader_parameter("strength", strength)
	var sat_min: float = LAYER_SAT_MIN.get(layer, 0.0)
	mat.set_shader_parameter("sat_min", sat_min)
	var r := _lum_range(head_sprites[layer].texture, sat_min)
	mat.set_shader_parameter("lum_min", r.x)
	mat.set_shader_parameter("lum_max", r.y)

## Brightness range of the pixels that will actually be recoloured.
func _lum_range(tex: Texture2D, sat_min := 0.0) -> Vector2:
	var img := tex.get_image()
	var lo := 1.0
	var hi := 0.0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			var sat := maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
			if c.a > 0.0 and sat >= sat_min:
				var l := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
				lo = minf(lo, l)
				hi = maxf(hi, l)
	return Vector2(lo, hi) if hi > lo else Vector2(0, 1)

extends Control

## Test scene for the paper-doll main character (not part of the game).
## Left: the original PixelLab frames. Right: the same animation rebuilt
## from body frames + tracked face/eyes/hair layers, with recolour swatches.
## Run with `-- --shot=<dir>` to save a few screenshots and quit.

const DIR := "res://art/mc_test"
const SCALE := 3.0

const HAIR := {
	"Original": null,
	"Black": [Color(0.04, 0.04, 0.06), Color(0.30, 0.30, 0.38)],
	"Blonde": [Color(0.45, 0.30, 0.10), Color(1.00, 0.92, 0.55)],
	"Red": [Color(0.30, 0.05, 0.03), Color(0.95, 0.40, 0.20)],
	"Silver": [Color(0.30, 0.32, 0.40), Color(0.95, 0.96, 1.00)],
	"Blue": [Color(0.05, 0.10, 0.30), Color(0.40, 0.65, 1.00)],
}
const EYES := {
	"Original": null,
	"Brown": [Color(0.05, 0.03, 0.02), Color(0.75, 0.50, 0.25)],
	"Green": [Color(0.02, 0.08, 0.04), Color(0.45, 0.90, 0.45)],
	"Red": [Color(0.10, 0.02, 0.02), Color(0.95, 0.30, 0.25)],
	"Violet": [Color(0.06, 0.02, 0.10), Color(0.75, 0.50, 1.00)],
}

var character: LayeredCharacter
var original: Sprite2D
var orig_frames: Array[Texture2D] = []

func _ready() -> void:
	var vp := get_viewport_rect().size
	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.16, 0.19)
	bg.size = vp
	add_child(bg)

	var title := Label.new()
	title.text = "Original                 Layered"
	title.position = Vector2(vp.x * 0.12, 12)
	add_child(title)

	# Content sits around x=105 of the 204px canvas; centre each copy in its half.
	original = Sprite2D.new()
	original.centered = false
	original.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	original.scale = Vector2(SCALE, SCALE)
	original.position = Vector2(vp.x * 0.25 - 105 * SCALE, 40 - 30 * SCALE)
	add_child(original)
	for i in range(3):
		orig_frames.append(load(DIR + "/orig_%d.png" % i))

	character = LayeredCharacter.new()
	character.scale = Vector2(SCALE, SCALE)
	character.position = Vector2(vp.x * 0.75 - 105 * SCALE, 40 - 30 * SCALE)
	add_child(character)
	character.load_from(DIR)

	var panel := VBoxContainer.new()
	panel.position = Vector2(12, 40 + 150 * SCALE)
	panel.size = Vector2(vp.x - 24, 0)
	add_child(panel)
	panel.add_child(_row("Hair", HAIR, "hair"))
	panel.add_child(_row("Eyes", EYES, "eyes"))
	var toggles := HFlowContainer.new()
	for layer in ["hair", "eyes"]:
		var cb := CheckBox.new()
		cb.text = "Show " + layer
		cb.button_pressed = true
		cb.toggled.connect(func(on): character.set_layer_visible(layer, on))
		toggles.add_child(cb)
	panel.add_child(toggles)

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_screenshots(a.trim_prefix("--shot="))

func _row(label: String, options: Dictionary, layer: String) -> Control:
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = label
	box.add_child(l)
	var flow := HFlowContainer.new()
	for name in options.keys():
		var b := Button.new()
		b.text = name
		b.pressed.connect(_apply.bind(layer, options[name]))
		flow.add_child(b)
	box.add_child(flow)
	return box

func _apply(layer: String, ramp) -> void:
	if ramp == null:
		character.set_layer_colors(layer, Color.BLACK, Color.WHITE, 0.0)
	else:
		character.set_layer_colors(layer, ramp[0], ramp[1], 1.0)

func _process(_delta: float) -> void:
	if character and not orig_frames.is_empty():
		original.texture = orig_frames[character.frame_order[character.frame_index]]

func _screenshots(out_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var states := [
		["original", null, null, true],
		["blonde_green", HAIR["Blonde"], EYES["Green"], true],
		["silver_red", HAIR["Silver"], EYES["Red"], true],
		["no_hair", null, null, false],
	]
	for st in states:
		_apply("hair", st[1])
		_apply("eyes", st[2])
		character.set_layer_visible("hair", st[3])
		for i in range(6):
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(out_dir.path_join(st[0] + ".png"))
	get_tree().quit()

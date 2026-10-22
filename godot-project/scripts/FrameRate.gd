class_name FrameRate
extends Node
## Frame-rate option (Settings > Frame rate) and, in debug builds, an fps readout.
## Only the drawing rate changes: combat, timers and offline progress run on time,
## not on frames (see Lighting/UnitView: everything animated uses seconds or delta).
## 0 = the device's own refresh rate, capped at DEFAULT_CAP (today's behaviour).

const OPTIONS := [0, 30, 60, 90, 120]
const DEFAULT_CAP := 60

var _label: Label
var _acc := 0.0

static func chosen() -> int:
	return int(Analytics.state.get("fps", 0)) if not Analytics.state.is_empty() else 0

static func set_chosen(v: int) -> void:
	Analytics.enabled()   # loads the device settings file
	Analytics.state["fps"] = v
	Analytics._dirty = true
	Analytics.save()
	apply()

## The screen's refresh rate, or 0 if the platform doesn't say.
static func screen_hz() -> int:
	var r := DisplayServer.screen_get_refresh_rate()
	return roundi(r) if r > 0.0 else 0

static func apply() -> void:
	var v := chosen()
	Engine.max_fps = DEFAULT_CAP if v == 0 else v

## Choices that make sense on this screen (a 60 Hz screen can't show 90).
static func available() -> Array:
	var hz := screen_hz()
	var out: Array = []
	for o in OPTIONS:
		if o == 0 or hz == 0 or o <= hz + 2:
			out.append(o)
	return out

static func label_for(v: int) -> String:
	return "Default (%d)" % DEFAULT_CAP if v == 0 else "%d fps" % v

func _ready() -> void:
	apply()
	if OS.is_debug_build():
		var layer := CanvasLayer.new()
		layer.layer = 100
		add_child(layer)
		_label = Label.new()
		_label.position = Vector2(6, 4)
		_label.add_theme_font_size_override("font_size", 14)
		_label.add_theme_color_override("font_color", Color(1, 1, 0.4))
		_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_label.add_theme_constant_override("outline_size", 4)
		layer.add_child(_label)

func _process(delta: float) -> void:
	if _label == null:
		return
	_acc += delta
	if _acc >= 0.5:
		_acc = 0.0
		_label.text = "%d fps (cap %s, screen %s Hz)" % [Engine.get_frames_per_second(), str(Engine.max_fps), str(screen_hz())]

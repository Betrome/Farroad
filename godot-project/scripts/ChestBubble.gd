class_name ChestBubble
extends Control
## A treasure chest floating in a magical bubble over the party (see Chests.gd). It drifts after the
## units, bobs, and glitters; tapping it emits `tapped`. Drawn in code, no art needed.

signal tapped

const SIZE := 72.0
var _t := 0.0
var _phase := 0.0
## Where the bubble wants to be (the game moves it after the party); it eases there.
var target := Vector2.ZERO
var _popping := false

func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	pivot_offset = Vector2(SIZE, SIZE) / 2.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_phase = randf() * TAU

func _process(delta: float) -> void:
	_t += delta
	var bob := sin(_t * 2.0 + _phase) * 5.0
	var want := target + Vector2(sin(_t * 0.9 + _phase) * 6.0, bob) - Vector2(SIZE, SIZE) / 2.0
	position = position.lerp(want, clampf(delta * 3.0, 0.0, 1.0))
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if _popping:
		return
	var press: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
		or (event is InputEventScreenTouch and event.pressed)
	if press:
		accept_event()
		tapped.emit()

## The bubble bursts and the node goes away.
func pop() -> void:
	_popping = true
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "scale", Vector2(1.6, 1.6), 0.25)
	tw.tween_property(self, "modulate:a", 0.0, 0.25)
	tw.chain().tween_callback(queue_free)

func _draw() -> void:
	var c := Vector2(SIZE, SIZE) / 2.0
	var r := SIZE / 2.0 - 2.0
	var shimmer := 0.5 + 0.5 * sin(_t * 3.0)
	# the bubble
	draw_circle(c, r, Color(0.62, 0.86, 1.0, 0.22))
	draw_arc(c, r, 0.0, TAU, 40, Color(0.8, 0.95, 1.0, 0.55 + 0.25 * shimmer), 2.0, true)
	draw_arc(c, r - 5.0, PI * 1.15, PI * 1.55, 12, Color(1, 1, 1, 0.7), 2.5, true)
	# the chest
	var w := 34.0
	var body := Rect2(c.x - w / 2.0, c.y - 2.0, w, 18.0)
	var lid := Rect2(c.x - w / 2.0, c.y - 12.0, w, 11.0)
	draw_rect(body, Color(0.50, 0.30, 0.14))
	draw_rect(lid, Color(0.60, 0.37, 0.17))
	draw_rect(Rect2(body.position.x, body.position.y, w, 3.0), Color(0.86, 0.68, 0.22))
	draw_rect(Rect2(c.x - 2.0, c.y - 12.0, 4.0, 28.0), Color(0.86, 0.68, 0.22))
	draw_rect(Rect2(c.x - 4.0, c.y - 1.0, 8.0, 7.0), Color(0.95, 0.80, 0.30))
	draw_rect(body, Color(0.25, 0.14, 0.06), false, 1.5)
	draw_rect(lid, Color(0.25, 0.14, 0.06), false, 1.5)
	# sparkles
	for i in 3:
		var a: float = _t * 1.3 + float(i) * TAU / 3.0 + _phase
		var p := c + Vector2(cos(a), sin(a)) * (r - 3.0)
		var s: float = 1.5 + 1.5 * (0.5 + 0.5 * sin(_t * 4.0 + float(i) * 2.0))
		draw_circle(p, s, Color(1.0, 0.95, 0.7, 0.9))

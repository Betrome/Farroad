class_name WaveRipple
extends Control
## The yellow ripple that goes out from a wave's dot when the wave is cleared:
## a thin ring (drawn, so it stays thin however large it grows) that eases out
## and fades.

var progress := 0.0              # 0..1
var max_radius := 40.0
var base_radius := 4.0
var color := Color(1.0, 0.86, 0.3)
var thickness := 1.5

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	if progress <= 0.0 or progress >= 1.0:
		return
	var a: float = pow(1.0 - progress, 0.9)
	draw_arc(Vector2.ZERO, base_radius + (max_radius - base_radius) * progress, 0.0, TAU, 72, Color(color, a), thickness, true)

## Eases out (fast, then slowing): 90% of the way a little before the end.
static func ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - clampf(t, 0.0, 1.0), 1.66)

## Plays one ring from `centre` (in `parent`'s local space) after `delay`.
static func play(parent: Node, centre: Vector2, base_r: float, max_r: float, delay: float, duration: float, width: float) -> void:
	var rp := WaveRipple.new()
	rp.base_radius = base_r
	rp.max_radius = max_r
	rp.thickness = width
	rp.position = centre
	rp.z_index = 30
	parent.add_child(rp)
	var tw := rp.create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.tween_method(func(t: float):
		rp.progress = ease_out(t)
		rp.queue_redraw(), 0.0, 1.0, duration)
	tw.tween_callback(rp.queue_free)

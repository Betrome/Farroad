class_name BlobShadow
extends Node2D
## A unit's ground shadow: a round end at the feet (squashed a little for the camera's
## angle) with a tail stretching away from the sun, drawn as one soft-edged shape.
## A larger, fainter copy underneath gives the edge its softness.

var radius := 10.0       # the round end at the feet
var tail := Vector2.ZERO # where the far end sits, relative to the feet (zero = just a circle)
var opacity := 0.5
const SQUASH := 0.75     # vertical squash of the whole shape
const TAIL_END_FRAC := 0.65   # the far end's radius relative to the feet end's
const FEATHER := 1.28    # the faint outer layer is this much bigger
const SEGMENTS := 20

func set_shape(r: float, t: Vector2, a: float) -> void:
	radius = r
	tail = t
	opacity = a
	queue_redraw()

func _hull(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in SEGMENTS:
		var ang := TAU * float(i) / float(SEGMENTS)
		pts.append(Vector2(cos(ang), sin(ang)) * r)
		if tail != Vector2.ZERO:
			pts.append(tail + Vector2(cos(ang), sin(ang)) * r * TAIL_END_FRAC)
	var hull := Geometry2D.convex_hull(pts)
	for i in hull.size():
		hull[i] = Vector2(hull[i].x, hull[i].y * SQUASH)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)   # convex_hull closes the loop; a polygon doesn't want the repeat
	return hull

func _draw() -> void:
	var outer := _hull(radius * FEATHER)
	if outer.size() >= 3:
		draw_colored_polygon(outer, Color(0, 0, 0, opacity * 0.35))
	var core := _hull(radius)
	if core.size() >= 3:
		draw_colored_polygon(core, Color(0, 0, 0, opacity * 0.75))

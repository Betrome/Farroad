class_name BlobShadow
extends Node2D
## A unit's ground shadow: a round end at the feet and a tail stretching away from the
## sun that narrows to a pointed, elliptical far end. The edge is hardest at the feet and
## softens with distance: several stacked layers of the same outline, each a little wider
## than the last, and the gap between them grows along the tail.

var radius := 10.0        # the round end at the feet
var tail := Vector2.ZERO  # where the far end sits, relative to the feet (zero = just a circle)
var opacity := 0.5
const X_STRETCH := 1.2   # the feet end is a little wider than it is tall: an ellipse at noon
const SQUASH := 0.75      # vertical squash of the whole shape
const TIP_FRAC := 0.22    # half-width at the far end, relative to the feet end's radius
const CAP_FRAC := 1.8     # the far end's cap is this many half-widths long (pointy, not round)
const LAYERS := 4
const SOFT_NEAR := 0.04   # how far each layer grows outward at the feet (as a share of the radius) ...
const SOFT_FAR := 0.16    # ... and at the far end
const FADE := 0.45        # how much fainter the far end is than the feet
const STEPS := 14
const ARC := 10

func set_shape(r: float, t: Vector2, a: float) -> void:
	radius = r
	tail = t
	opacity = a
	queue_redraw()

## The outline: the convex hull of the ellipse under the unit and a small, pointy ellipse at
## the far end. With no tail that is just the ellipse (noon); as the tail grows the sides
## taper straight out to the tip, so the shape stays convex all the way.
func _outline(layer: int, sgn: float, length: float) -> PackedVector2Array:
	var grow_near := float(layer) * SOFT_NEAR * radius
	var grow_far := float(layer) * SOFT_FAR * radius
	var rx := radius * X_STRETCH + grow_near
	var ry := radius + grow_near
	var tip_w := radius * TIP_FRAC + grow_far
	var pts := PackedVector2Array()
	for k in range(ARC * 2 + 4):
		var ang := TAU * float(k) / float(ARC * 2 + 4)
		pts.append(Vector2(cos(ang) * rx, sin(ang) * ry * SQUASH))
		if length >= 2.0:
			pts.append(Vector2(sgn * (length + cos(ang) * tip_w * CAP_FRAC), sin(ang) * tip_w * SQUASH))
	var hull := Geometry2D.convex_hull(pts)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)   # convex_hull closes the loop; a polygon doesn't want the repeat
	return hull

func _draw() -> void:
	var sgn: float = -1.0 if tail.x < 0.0 else 1.0
	var length: float = absf(tail.x)
	var a: float = opacity * 0.32
	for layer in range(LAYERS - 1, -1, -1):
		var pts := _outline(layer, sgn, length)
		if pts.size() < 3:
			continue
		var cols := PackedColorArray()
		for p in pts:
			var u: float = clampf(p.x * sgn / maxf(length, 1.0), 0.0, 1.0) if length >= 2.0 else 0.0
			cols.append(Color(0, 0, 0, a * (1.0 - FADE * u)))
		draw_polygon(pts, cols)

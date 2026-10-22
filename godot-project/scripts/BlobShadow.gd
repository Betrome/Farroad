class_name BlobShadow
extends Node2D
## A unit's ground shadow: a round end at the feet and a tail stretching away from the
## sun that narrows to a pointed, elliptical far end. The edge is hardest at the feet and
## softens with distance: several stacked layers of the same outline, each a little wider
## than the last, and the gap between them grows along the tail.

var radius := 10.0        # the round end at the feet
var tail := Vector2.ZERO  # where the far end sits, relative to the feet (zero = just a circle)
var opacity := 0.5
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

func _half_width(u: float) -> float:
	# teardrop: the width falls steadily from the feet to the tip and the sides bulge
	# outward (convex), not inward (a power below 1 on the remaining length does that)
	return radius * lerpf(TIP_FRAC, 1.0, pow(maxf(0.0, 1.0 - u), 0.75))

func _outline(layer: int, sgn: float, length: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	# top edge, feet -> far end
	for k in range(STEPS + 1):
		var u := float(k) / float(STEPS)
		var w := _half_width(u) + float(layer) * lerpf(SOFT_NEAR, SOFT_FAR, u) * radius
		pts.append(Vector2(sgn * length * u, -w * SQUASH))
	# the pointy cap, top to bottom
	var w_end := _half_width(1.0) + float(layer) * SOFT_FAR * radius
	for k in range(1, ARC):
		var ang := -PI / 2.0 + PI * float(k) / float(ARC)
		pts.append(Vector2(sgn * (length + cos(ang) * w_end * CAP_FRAC), sin(ang) * w_end * SQUASH))
	# bottom edge, far end -> feet
	for k in range(STEPS, -1, -1):
		var u := float(k) / float(STEPS)
		var w := _half_width(u) + float(layer) * lerpf(SOFT_NEAR, SOFT_FAR, u) * radius
		pts.append(Vector2(sgn * length * u, w * SQUASH))
	# the round end behind the feet
	var w0 := radius * (1.0 + float(layer) * SOFT_NEAR)
	for k in range(1, ARC):
		var ang := PI / 2.0 + PI * float(k) / float(ARC)
		pts.append(Vector2(sgn * cos(ang) * w0, sin(ang) * w0 * SQUASH))
	return pts

## No tail (lighting off): just the round shadow.
func _circle(layer: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var w := radius * (1.0 + float(layer) * SOFT_NEAR)
	for k in range(ARC * 2 + 4):
		var ang := TAU * float(k) / float(ARC * 2 + 4)
		pts.append(Vector2(cos(ang) * w, sin(ang) * w * SQUASH))
	return pts

func _draw() -> void:
	var sgn: float = -1.0 if tail.x < 0.0 else 1.0
	var length: float = absf(tail.x)
	var a: float = opacity * 0.32
	for layer in range(LAYERS - 1, -1, -1):
		var pts := _outline(layer, sgn, length) if length >= 2.0 else _circle(layer)
		if pts.size() < 3:
			continue
		var cols := PackedColorArray()
		for p in pts:
			var u: float = clampf(absf(p.x) / maxf(length, 1.0), 0.0, 1.0) if p.x * sgn > 0.0 else 0.0
			cols.append(Color(0, 0, 0, a * (1.0 - FADE * u)))
		draw_polygon(pts, cols)

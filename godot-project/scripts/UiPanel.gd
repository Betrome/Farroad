class_name UiPanel
extends PanelContainer
## A kit panel: olive-brown plate, 1 px inner top highlight, and a silver rim
## that is brightest along the upper-left edges and darker on the lower right
## (the light comes from the upper left, like the icons).

var modal := false

func _init(is_modal: bool = false) -> void:
	modal = is_modal
	var s := UiKit.plate_style(modal)
	s.border_color = Color(0, 0, 0, 0)    # the rim is drawn below
	s.set_border_width_all(0)
	add_theme_stylebox_override("panel", s)
	resized.connect(queue_redraw)

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var rad: float = UiKit.RADIUS
	var w: float = 2.0 if modal else 1.5
	var h := r.size
	# the full rim, shaded
	var dim := StyleBoxFlat.new()
	dim.bg_color = Color(0, 0, 0, 0)
	dim.draw_center = false
	dim.set_corner_radius_all(int(rad))
	dim.set_border_width_all(int(ceil(w)))
	dim.border_color = UiKit.SILVER_DIM
	draw_style_box(dim, r)
	# the lit upper-left arc over it: up the left edge, round the corner, along the top
	var lit := PackedVector2Array()
	var half := w / 2.0
	lit.append(Vector2(half, h.y * 0.62))
	lit.append(Vector2(half, rad))
	for i in range(1, 9):
		var a: float = PI + (PI / 2.0) * float(i) / 8.0
		lit.append(Vector2(rad + cos(a) * (rad - half), rad + sin(a) * (rad - half)))
	lit.append(Vector2(h.x * 0.78, half))
	draw_polyline(lit, UiKit.SILVER, w, true)
	# inner top highlight
	draw_line(Vector2(rad, w + 1.0), Vector2(h.x - rad, w + 1.0), Color(1, 1, 1, 0.12), 1.0)

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
	UiKit.draw_rim(self, size, modal)

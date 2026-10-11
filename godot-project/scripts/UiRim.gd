class_name UiRim
extends Control
## The kit's silver rim (lit from the upper left) drawn over a window or box
## whose own background is a plain stylebox -- e.g. a PopupPanel. Ignores the
## mouse; follows the parent's size.

var modal := true

func _init(is_modal: bool = true) -> void:
	modal = is_modal
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true

func follow(win: Window) -> void:
	position = Vector2.ZERO
	size = Vector2(win.size)
	queue_redraw()

func _draw() -> void:
	UiKit.draw_rim(self, size, modal)

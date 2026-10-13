class_name ValueTick
extends RefCounted
## A number that has just gone up counts from its old value to the new one,
## flashes green, and a ▲ rises beside it. Shared by the Aether screen and the
## Units summary.

const GREEN := Color(0.55, 1.0, 0.7)

static func animate(node: Control, from_v: float, to_v: float, fmt: Callable, final_text: String) -> void:
	node.modulate = GREEN
	node.text = fmt.call(from_v)
	var as_int: bool = is_equal_approx(to_v, roundf(to_v)) and is_equal_approx(from_v, roundf(from_v))
	var tw := node.create_tween()
	tw.tween_method(func(v: float):
		if is_instance_valid(node):
			node.text = fmt.call(roundf(v) if as_int else v), from_v, to_v, 0.7).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func():
		if is_instance_valid(node):
			node.text = final_text)
	tw.tween_property(node, "modulate", Color.WHITE, 0.4)
	# the arrow: pops in beside the value, rises and fades
	var arrow := Label.new()
	arrow.text = "▲"
	arrow.add_theme_font_size_override("font_size", 13)
	arrow.add_theme_color_override("font_color", GREEN)
	arrow.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	arrow.add_theme_constant_override("outline_size", 3)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.modulate.a = 0.0
	node.add_child(arrow)
	var text_w: float = node.get_content_width() if node is RichTextLabel else node.get_minimum_size().x
	arrow.position = Vector2(minf(text_w, maxf(node.size.x - 14.0, 0.0)) + 4.0, 0.0)
	var at := arrow.create_tween()
	at.tween_property(arrow, "modulate:a", 1.0, 0.12)
	at.set_parallel(true)
	at.tween_property(arrow, "position:y", arrow.position.y - 12.0, 0.9).set_ease(Tween.EASE_OUT)
	at.tween_property(arrow, "modulate:a", 0.0, 0.5).set_delay(0.55)
	at.chain().tween_callback(arrow.queue_free)

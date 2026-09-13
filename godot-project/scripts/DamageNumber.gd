class_name DamageNumber
## Floating combat text -- a damage number, an "Evade", or a heal amount.
## Spawned on demand via spawn() rather than a hand-authored .tscn (it's a
## single Label with no fixed structure worth a sub-scene for).

static func spawn(parent: Node2D, pos: Vector2, text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 20)
	label.position = pos
	label.z_index = 10
	parent.add_child(label)

	var tw := parent.create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "position", pos + Vector2(0, -44), 0.8)
	tw.tween_property(label, "modulate:a", 0.0, 0.8)
	tw.chain().tween_callback(label.queue_free)

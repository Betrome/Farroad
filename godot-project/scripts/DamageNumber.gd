class_name DamageNumber
## Floating combat text -- a damage number, an "Evade", a heal amount, or a
## status name (e.g. "Bracing") when a unit applies/refreshes a stat-
## affecting status. Spawned on demand via spawn() rather than a
## hand-authored .tscn (it's a single Label with no fixed structure worth a
## sub-scene for).

## `stagger_index` offsets consecutive spawns AT THE SAME target upward by a
## fixed amount each, so e.g. a hit that both deals damage AND applies a
## status in the same beat (very common -- Ember hits for damage AND
## applies burning) reads as a small vertical stack instead of two labels
## landing exactly on top of each other for their entire flight (a one-time
## offset baked into the tween's START position, not just a brief visual
## nudge, since both labels otherwise tween the identical path in lockstep).
static func spawn(parent: Node2D, pos: Vector2, text: String, color: Color, stagger_index: int = 0) -> void:
	var start_pos: Vector2 = pos + Vector2(0, -22.0 * stagger_index)
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 20)
	# 24-item batch, Group D2: "add outline to combat text to enhance
	# readability" -- floating text crosses busy, moving sprites and the
	# light parchment field, so a dark outline keeps it legible on any
	# background.
	label.add_theme_color_override("font_outline_color", Color(0.08, 0.05, 0.03, 1.0))
	label.add_theme_constant_override("outline_size", 5)
	label.position = start_pos
	# No raised z_index: the label is added after the units, so it already
	# draws over them, and a raised z_index drew it over the pop-up windows too.
	parent.add_child(label)

	var tw := parent.create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "position", start_pos + Vector2(0, -44), 0.8)
	tw.tween_property(label, "modulate:a", 0.0, 0.8)
	tw.chain().tween_callback(label.queue_free)

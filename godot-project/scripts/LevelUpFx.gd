class_name LevelUpFx
extends RefCounted
## The level-up flourish: a burst of golden sparkles and a "LEVEL UP" banner
## with the unit's new level, drawn over everything (its own canvas layer) so
## it shows inside an open menu too.

static func play(host: Node, vp: Vector2, at: Vector2, unit_name: String, new_level: int) -> void:
	if host == null or not host.is_inside_tree():
		return
	var layer := CanvasLayer.new()
	layer.layer = 12
	host.add_child(layer)
	var tree := host.get_tree()

	# sparkles: four-point stars flung outward, spinning and fading
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in 22:
		var star := Polygon2D.new()
		var r: float = rng.randf_range(4.0, 9.0)
		star.polygon = PackedVector2Array([Vector2(0, -r), Vector2(r * 0.28, -r * 0.28), Vector2(r, 0), Vector2(r * 0.28, r * 0.28),
			Vector2(0, r), Vector2(-r * 0.28, r * 0.28), Vector2(-r, 0), Vector2(-r * 0.28, -r * 0.28)])
		star.color = Color("ffe9a0") if i % 3 != 0 else Color.WHITE
		star.position = at
		star.scale = Vector2(0.2, 0.2)
		layer.add_child(star)
		var ang: float = rng.randf() * TAU
		var dist: float = rng.randf_range(vp.x * 0.12, vp.x * 0.34)
		var life: float = rng.randf_range(0.7, 1.1)
		var tw := star.create_tween().set_parallel(true)
		tw.tween_property(star, "position", at + Vector2(cos(ang), sin(ang)) * dist - Vector2(0, vp.y * 0.03), life).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(star, "scale", Vector2(1.0, 1.0), life * 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(star, "rotation", rng.randf_range(-3.0, 3.0), life)
		tw.tween_property(star, "modulate:a", 0.0, life * 0.5).set_delay(life * 0.5)

	# banner
	var banner := VBoxContainer.new()
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.alignment = BoxContainer.ALIGNMENT_CENTER
	var title := Label.new()
	title.text = "LEVEL UP!"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.034))
	title.add_theme_color_override("font_color", Color("ffe28a"))
	title.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0, 0.95))
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(title)
	var sub := Label.new()
	sub.text = "%s  Lv %d" % [unit_name, new_level]
	sub.add_theme_font_size_override("font_size", int(vp.y * 0.024))
	sub.add_theme_color_override("font_color", Color.WHITE)
	sub.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0, 0.95))
	sub.add_theme_constant_override("outline_size", 5)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_child(sub)
	layer.add_child(banner)
	banner.size = Vector2(vp.x, vp.y * 0.1)
	banner.position = Vector2(0, at.y - vp.y * 0.07)
	banner.pivot_offset = Vector2(vp.x / 2.0, vp.y * 0.05)
	banner.modulate.a = 0.0
	banner.scale = Vector2(0.7, 0.7)
	var bt := banner.create_tween()
	bt.set_parallel(true)
	bt.tween_property(banner, "modulate:a", 1.0, 0.15)
	bt.tween_property(banner, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	bt.chain().tween_interval(0.7)
	bt.chain().set_parallel(true)
	bt.tween_property(banner, "modulate:a", 0.0, 0.4)
	bt.tween_property(banner, "position:y", banner.position.y - vp.y * 0.02, 0.4)
	tree.create_timer(1.8).timeout.connect(func():
		if is_instance_valid(layer):
			layer.queue_free())

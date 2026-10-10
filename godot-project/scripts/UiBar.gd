class_name UiBar
extends Control
## A kit bar: a thin gauge in a recessed trough with a lit fill, a 1 px
## highlight, optional segment ticks (stepped gauges like charge) and a
## "recent damage" segment that waits ~0.4 s and then shrinks away.

var frac := 1.0            # what the bar shows
var lag := 1.0             # the pale segment trailing behind after a drop
var color := UiKit.HP_GOOD
var hp_style := false      # colour follows the fill (green -> yellow -> red)
var segments := 0          # tick marks (0 = none)
var _tween: Tween

func _init(bar_color: Color = UiKit.HP_GOOD, is_hp: bool = false, seg: int = 0) -> void:
	color = bar_color
	hp_style = is_hp
	segments = seg
	custom_minimum_size = Vector2(0, 10)

func set_frac(f: float, animate: bool = true) -> void:
	f = clampf(f, 0.0, 1.0)
	if is_equal_approx(f, frac):
		return          # repeated refreshes with the same value must not cancel a running trail
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if f < frac and animate:
		lag = maxf(lag, frac)
		frac = f
		_tween = create_tween()
		_tween.tween_interval(0.55)
		_tween.tween_method(func(v: float): lag = v; queue_redraw(), lag, f, 0.45)
	else:
		frac = f
		lag = f
	queue_redraw()

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var thin: bool = r.size.y < 8.0      # on-field bars: no inner shadow / gloss
	var rad := minf(r.size.y / 2.0, 5.0)
	# trough
	var trough := StyleBoxFlat.new()
	trough.bg_color = UiKit.PLATE_DARK
	trough.set_corner_radius_all(int(rad))
	trough.set_border_width_all(1)
	trough.border_color = Color(UiKit.SILVER_DIM, 0.45)
	draw_style_box(trough, r)
	if not thin:
		draw_line(Vector2(rad, 1.5), Vector2(r.size.x - rad, 1.5), Color(0, 0, 0, 0.5), 1.0)   # inner shadow
	var inner := r.grow(-1.0 if thin else -2.0)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return
	# recent damage
	if lag > frac:
		var lw := inner.size.x * lag
		draw_rect(Rect2(inner.position, Vector2(lw, inner.size.y)), Color(1, 1, 1, 0.8))
	# fill
	var fill_color := UiKit.hp_color(frac) if hp_style else color
	var fw := inner.size.x * frac
	if fw > 0.0:
		var fr := Rect2(inner.position, Vector2(fw, inner.size.y))
		draw_rect(fr, fill_color)
		UiKit.top_light(self, Rect2(fr.position, Vector2(fr.size.x, fr.size.y * 0.6)), Color(1, 1, 1), 0.35)
		if not thin:
			draw_line(fr.position + Vector2(0, 0.5), Vector2(fr.end.x, fr.position.y + 0.5), Color(1, 1, 1, 0.55), 1.0)
	# stepped gauge ticks
	for i in range(1, segments):
		var x: float = inner.position.x + inner.size.x * float(i) / float(segments)
		draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), Color(0, 0, 0, 0.55), 1.0)

class_name ExpeditionScene
extends Control
## A live look at what an expedition party is doing right now (tap a party on the Expeditions tab):
## "battle" plays a real fight against that wave's enemies on repeat, "camping" shows the party round
## a campfire at night, "event" shows them at a roadside shrine. Everything is drawn in code for now
## (placeholder art). The scene never touches the saved game: the caller hands in builders.
##
## build_fight: Callable() -> {"battle": Dictionary, "units": Array}   (a fresh simulated fight)
## party_units: Array of unit Dictionaries (what UnitView draws) for the camp and event scenes.

signal closed

var mode := "battle"
var vp := Vector2(412, 915)
var build_fight: Callable
var party_units: Array = []
var title_text := ""
var _t := 0.0
var _presenter: BattlePresenter = null
var _views: Array = []
var _alive := true

func _ready() -> void:
	size = vp
	mouse_filter = Control.MOUSE_FILTER_STOP
	var title := Label.new()
	title.text = title_text
	title.position = Vector2(14, 12)
	title.size = Vector2(vp.x - 70, 40)
	title.add_theme_font_size_override("font_size", 16)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.z_index = 5
	add_child(title)
	match mode:
		"battle":
			_loop_fights()
		"camping":
			_place_units(true)
		_:
			_place_units(false)

func close() -> void:
	_alive = false
	closed.emit()
	queue_free()

func _process(delta: float) -> void:
	_t += delta
	if mode != "battle":
		queue_redraw()

# ---- camp and event: the party standing about the scene ----
func _ground_y() -> float:
	return vp.y * (0.16 if mode == "battle" else 0.62)

func _place_units(camp: bool) -> void:
	var n := party_units.size()
	var size_px: float = clampf(vp.x * 0.3, 96.0, 150.0)
	var cx := vp.x * 0.5
	for i in n:
		var v := UnitView.new()
		v.setup(party_units[i], size_px)
		add_child(v)
		v.hide_chrome()
		if camp:
			# round the fire: an arc, the back ones higher and smaller
			var a: float = PI * (0.12 + 0.76 * (float(i) / float(maxi(1, n - 1)))) if n > 1 else PI * 0.5
			v.position = Vector2(cx + cos(a) * vp.x * 0.36, _ground_y() + 34.0 + sin(a) * vp.y * 0.07)
			v.z_index = 1 + int(sin(a) * 10.0)
		else:
			# in a loose line on the left, looking at the shrine on the right
			var row := i % 2
			v.position = Vector2(vp.x * (0.16 + 0.11 * float(i / 2)) + float(row) * 18.0, _ground_y() + 26.0 + float(row) * 46.0)
			v.z_index = 1 + row
		_views.append(v)

# ---- battle: a fresh fight, again and again ----
func _loop_fights() -> void:
	while _alive and is_inside_tree():
		var f: Dictionary = build_fight.call()
		_presenter = BattlePresenter.new()
		_presenter.region_vp = vp
		_presenter.recovery_lookup = func(_uid): return 0.0
		_presenter.catchup_lookup = func(): return 1.0
		_presenter.title_lookup = func(_uid): return ""
		_presenter.goals_open = func(): pass
		_presenter.goals_count = func() -> int: return 0
		_presenter.wipes_lookup = func(): pass
		_presenter.action_info = func(_a, _h): pass
		add_child(_presenter)
		move_child(_presenter, 0)
		await get_tree().process_frame
		if not _alive:
			return
		_presenter.start_battle(f["battle"], f["units"], true, {}, false, false)
		_presenter.call("run_enemies_entering")
		await get_tree().create_timer(1.2).timeout
		if not _alive or not is_instance_valid(_presenter):
			return
		_presenter.begin_combat()
		await _presenter.battle_finished
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(_presenter):
			_presenter.queue_free()

# ---- placeholder art ----
func _draw() -> void:
	var gy := _ground_y()
	var night: bool = mode == "camping"
	var top := Color(0.04, 0.06, 0.14) if night else Color(0.45, 0.65, 0.85)
	var low := Color(0.12, 0.12, 0.24) if night else Color(0.85, 0.80, 0.62)
	var strips := 24
	for i in strips:
		var f := float(i) / float(strips)
		draw_rect(Rect2(0, gy * f, vp.x, gy / float(strips) + 1.0), top.lerp(low, f))
	if night:
		for i in 40:
			var sx: float = fposmod(float(i) * 97.3, vp.x)
			var sy: float = fposmod(float(i) * 53.7, gy * 0.8)
			var tw: float = 0.5 + 0.5 * sin(_t * 2.0 + float(i))
			draw_circle(Vector2(sx, sy), 1.0 + tw, Color(1, 1, 0.9, 0.4 + 0.5 * tw))
		draw_circle(Vector2(vp.x * 0.8, gy * 0.25), 22.0, Color(0.92, 0.93, 0.85))
		draw_circle(Vector2(vp.x * 0.8 + 8.0, gy * 0.25 - 4.0), 20.0, Color(0.06, 0.08, 0.16))
	# far hills and the ground
	var hills := PackedVector2Array([Vector2(0, gy)])
	for i in 13:
		hills.append(Vector2(vp.x * float(i) / 12.0, gy - 30.0 - 22.0 * sin(float(i) * 1.3 + 1.0)))
	hills.append(Vector2(vp.x, gy))
	draw_colored_polygon(hills, Color(0.10, 0.16, 0.14) if night else Color(0.42, 0.55, 0.35))
	draw_rect(Rect2(0, gy, vp.x, vp.y - gy), Color(0.14, 0.20, 0.14) if night else Color(0.50, 0.62, 0.34))
	if mode != "battle":
		draw_rect(Rect2(0, gy + 10.0, vp.x, 40.0), Color(0.22, 0.17, 0.12) if night else Color(0.66, 0.55, 0.38))   # the road
	if mode == "battle":
		return
	if night:
		_draw_fire(Vector2(vp.x * 0.5, gy + 44.0))
	else:
		_draw_shrine(Vector2(vp.x * 0.74, gy + 36.0))

func _draw_fire(p: Vector2) -> void:
	var flick: float = 0.85 + 0.15 * sin(_t * 9.0) + 0.08 * sin(_t * 23.0)
	for i in 6:
		var r: float = 190.0 - float(i) * 24.0
		draw_circle(p + Vector2(0, -14), r * flick, Color(1.0, 0.55, 0.15, 0.035))
	# logs
	draw_line(p + Vector2(-26, 4), p + Vector2(22, -4), Color(0.32, 0.20, 0.10), 8.0)
	draw_line(p + Vector2(-22, -4), p + Vector2(26, 4), Color(0.28, 0.17, 0.08), 8.0)
	# flames
	var tongues := [[0.0, 46.0, Color(0.95, 0.35, 0.08)], [-9.0, 34.0, Color(1.0, 0.55, 0.12)], [9.0, 30.0, Color(1.0, 0.6, 0.15)],
		[0.0, 26.0, Color(1.0, 0.85, 0.3)]]
	for k in tongues.size():
		var tg: Array = tongues[k]
		var h: float = float(tg[1]) * (0.85 + 0.25 * sin(_t * (7.0 + k * 2.3) + k))
		var w: float = 15.0 - float(k) * 2.0
		var sway: float = sin(_t * 5.0 + k) * 4.0
		var pts := PackedVector2Array([p + Vector2(float(tg[0]) - w, 0), p + Vector2(float(tg[0]) + sway, -h), p + Vector2(float(tg[0]) + w, 0)])
		draw_colored_polygon(pts, tg[2])
	for i in 5:   # sparks
		var life: float = fposmod(_t * 0.8 + float(i) * 0.37, 1.0)
		draw_circle(p + Vector2(sin(float(i) * 3.1 + _t) * 14.0, -20.0 - life * 90.0), 1.6 * (1.0 - life), Color(1.0, 0.8, 0.3, 1.0 - life))

func _draw_shrine(p: Vector2) -> void:
	# a stone plinth under a post and a hanging lantern, glowing softly
	draw_rect(Rect2(p.x - 36, p.y - 18, 72, 18), Color(0.45, 0.45, 0.48))
	draw_rect(Rect2(p.x - 26, p.y - 40, 52, 22), Color(0.55, 0.55, 0.58))
	draw_rect(Rect2(p.x - 5, p.y - 130, 10, 92), Color(0.40, 0.28, 0.16))
	draw_rect(Rect2(p.x - 30, p.y - 138, 60, 10), Color(0.34, 0.22, 0.12))
	var glow: float = 0.7 + 0.3 * sin(_t * 2.4)
	var lp := Vector2(p.x + 22, p.y - 104)
	draw_line(Vector2(lp.x, p.y - 128), lp, Color(0.2, 0.15, 0.1), 2.0)
	draw_circle(lp, 34.0, Color(1.0, 0.85, 0.4, 0.10 * glow))
	draw_circle(lp, 20.0, Color(1.0, 0.85, 0.4, 0.16 * glow))
	draw_rect(Rect2(lp.x - 7, lp.y - 8, 14, 18), Color(1.0, 0.85, 0.4, 0.9))
	draw_rect(Rect2(lp.x - 7, lp.y - 8, 14, 18), Color(0.25, 0.15, 0.08), false, 2.0)
	# a few motes drifting up from the plinth
	for i in 4:
		var life: float = fposmod(_t * 0.4 + float(i) * 0.27, 1.0)
		draw_circle(Vector2(p.x - 14.0 + float(i) * 9.0, p.y - 44.0 - life * 70.0), 2.0 * (1.0 - life), Color(0.8, 0.95, 1.0, 0.8 * (1.0 - life)))

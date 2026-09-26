class_name AttackFX
extends Node2D
## One unit's attack effects, driven frame by frame by UnitView from the
## sprite's weapon metadata (sword grip/tip per frame, the impact frame):
##
##   - TRAIL: a swept band from the blade's base to its tip, full blade
##     width where the sword is now and tapering toward the tip as it ages
##     (the classic sword smear), in the element's colour.
##   - LIGHT: a PointLight2D that only lights unit sprites (their own light
##     layer), with a per-element PATTERN over time -- fire flickers and
##     drifts up, water ripples, earth thuds twice low at the target's feet,
##     air strobes along the swing, light swells slowly, dark (subtractive)
##     spreads and lingers, plain attacks spark.
##   - PARTICLES: small pixel-sized CPUParticles2D bursts per element --
##     flames/embers, droplets, wind streaks, rock chunks and dust,
##     sparkles, wisps, sparks -- along the blade during the swing and at
##     the impact point.
## All nodes are top_level (world space), so effects stay where they
## happened while the attacker hops home.

const UNIT_LIGHT_LAYER := 2

const ELEMENTS := {
	"": {"color": Color(0.95, 0.97, 1.0), "charge": 0.0, "peak": 1.0, "radius": 0.9},
	"fire": {"color": Color(1.0, 0.45, 0.1), "charge": 0.9, "peak": 1.8, "radius": 1.9},
	"water": {"color": Color(0.25, 0.55, 1.0), "charge": 0.5, "peak": 1.4, "radius": 2.4},
	"earth": {"color": Color(0.8, 0.55, 0.2), "charge": 0.3, "peak": 2.0, "radius": 1.6},
	"air": {"color": Color(0.35, 0.85, 0.6), "charge": 0.5, "peak": 1.5, "radius": 1.2},
	"light": {"color": Color(1.0, 0.93, 0.7), "charge": 0.7, "peak": 1.4, "radius": 2.2},
	"dark": {"color": Color(0.6, 0.3, 0.9), "charge": 0.6, "peak": 1.5, "radius": 2.0,
		"subtract": Color(0.45, 0.6, 0.35)},
}
const TRAIL_LIFE := 0.38         # seconds the arc takes to retract and fade
const ARC_REACH := 1.6           # short swings: arc radius as a share of the blade's reach
const ARC_BAND := 0.7            # band width at the leading edge, as a share of the radius

var element := ""
var unit_size := 46.0
var _trail: Polygon2D
var _light: PointLight2D
var _light_t := -1.0              # seconds since impact (<0: not in the impact pattern)
var _light_origin := Vector2.ZERO
var _swing_dir := Vector2.RIGHT
var _prev = null                  # [grip, tip] of the latest blade seen
var _windup_blade = null          # [grip, tip] on the last wind-up frame
var _smear_blade = null           # [grip, tip] on the smear frame
# the arc: pivot, radius, start angle, signed sweep, how much of it shows,
# and its age (<0 = not showing)
var _arc := {"pivot": Vector2.ZERO, "r": 0.0, "a0": 0.0, "da": 0.0, "shown": 0.0, "age": -1.0}
var _blade_emitter: CPUParticles2D
static var _tex_cache: Dictionary = {}

func setup(size_px: float) -> void:
	unit_size = size_px
	top_level = true
	_trail = Polygon2D.new()
	add_child(_trail)
	_light = PointLight2D.new()
	_light.texture = _radial_texture()
	_light.range_item_cull_mask = UNIT_LIGHT_LAYER
	_light.enabled = false
	add_child(_light)

func profile() -> Dictionary:
	return ELEMENTS.get(element, ELEMENTS[""])

## Start of an attack: which element, and a clean slate.
func begin(el) -> void:
	element = str(el) if el != null else ""
	if not ELEMENTS.has(element):
		element = ""
	_prev = null
	_windup_blade = null
	_smear_blade = null
	_arc["age"] = -1.0
	_light_t = -1.0
	_light.enabled = false
	_stop_blade_emitter()

## Wind-up frames: a glow gathering on the blade (t 0..1).
func windup(grip: Vector2, tip: Vector2, t: float) -> void:
	_windup_blade = [grip, tip]
	_prev = [grip, tip]
	var p := profile()
	if float(p["charge"]) <= 0.0:
		return
	_place_light(tip, float(p["charge"]) * t, float(p["radius"]) * 0.4)

## Swing frames. The trail is ONE arc, worked out from where the blade was
## on the wind-up to where it is now, pivoting on the current grip -- a clean
## crescent instead of stitched per-frame samples (which wiggled as the grip
## moved). The sweep direction is the one that passes through the smear
## frame's blade, so it always follows the actual swing.
func swing(grip: Vector2, tip: Vector2, is_impact: bool) -> void:
	var p := profile()
	var start = _windup_blade if _windup_blade != null else (_prev if _prev != null else [grip, tip])
	if not is_impact:
		_smear_blade = [grip, tip]
	_set_arc(grip, start[1], tip, _smear_blade[1] if (_smear_blade != null and is_impact) else null,
		(tip - grip).length())
	_arc["shown"] = 1.0 if is_impact else 0.55
	_arc["age"] = 0.0 if is_impact else -2.0      # the smear frame holds; impact starts the fade
	_swing_dir = (tip - (_prev[1] if _prev != null else tip)).normalized() if _prev != null and (tip - _prev[1]).length() > 0.5 else _swing_dir
	_prev = [grip, tip]
	if not is_impact:
		_place_light(tip, maxf(float(p["charge"]), float(p["peak"]) * 0.45), float(p["radius"]) * 0.55)
		_start_blade_emitter(tip)
		return
	_stop_blade_emitter()
	_light_origin = tip
	_light_t = 0.0
	_impact_particles(tip)

const ARC_SPAN := 160.0          # degrees of circle the arc covers between the two blade tips

## The arc passes through the blade tip at the start of the swing and at
## its end, on a circle that bulges out in front of the character (the
## way a real swing arcs around the shoulder) -- big and even, however the
## hands moved. Very short swings fall back to pivoting on the grip.
func _set_arc(pivot: Vector2, from_tip: Vector2, to_tip: Vector2, via, reach: float) -> void:
	var chord: Vector2 = to_tip - from_tip
	var L: float = chord.length()
	if L < unit_size * 0.25:
		_set_arc_grip(pivot, from_tip, to_tip, via, reach)
		return
	var half := deg_to_rad(ARC_SPAN) / 2.0
	var R: float = L / (2.0 * sin(half))
	var mid: Vector2 = (from_tip + to_tip) / 2.0
	var facing: float = signf(to_tip.x - pivot.x) if absf(to_tip.x - pivot.x) > 1.0 else 1.0
	var n: Vector2 = chord.orthogonal().normalized()
	if absf(n.x) < 0.35:
		if n.y > 0.0:
			n = -n                               # a mostly back-to-front swing arcs over the head
	elif n.x * facing < 0.0:
		n = -n                                   # otherwise bulge toward where the character faces
	var centre: Vector2 = mid - n * R * cos(half)
	var a0: float = (from_tip - centre).angle()
	var a1: float = (to_tip - centre).angle()
	var cw: float = fposmod(a1 - a0, TAU)
	var bulge_a: float = fposmod((mid + n * R - centre).angle() - a0, TAU)
	_arc["pivot"] = centre
	_arc["r"] = R * 1.12                         # reach a little past the blade tips
	_arc["a0"] = a0
	_arc["da"] = cw if bulge_a < cw else cw - TAU

func _set_arc_grip(pivot: Vector2, from_tip: Vector2, to_tip: Vector2, via, reach: float) -> void:
	var a0: float = (from_tip - pivot).angle()
	var a1: float = (to_tip - pivot).angle()
	var cw: float = fposmod(a1 - a0, TAU)
	var da: float = cw
	if via != null:
		var av: float = fposmod((via - pivot).angle() - a0, TAU)
		if av > cw:
			da = cw - TAU
	elif cw > PI:
		da = cw - TAU
	_arc["pivot"] = pivot
	_arc["r"] = reach * ARC_REACH
	_arc["a0"] = a0
	_arc["da"] = da

func _process(delta: float) -> void:
	if float(_arc["age"]) >= 0.0:
		_arc["age"] = float(_arc["age"]) + delta
		if float(_arc["age"]) > TRAIL_LIFE:
			_arc["age"] = -1.0
	_rebuild_trail()
	if _blade_emitter != null and _prev != null:
		_blade_emitter.global_position = _prev[1]
	if _light_t >= 0.0:
		_light_t += delta
		_light_pattern(_light_t)

## A crescent: leading edge (the blade now) full width, tapering to a point
## at the tail; as it ages, the tail retracts toward the blade and it fades.
func _rebuild_trail() -> void:
	var age: float = float(_arc["age"])
	if age == -1.0 or float(_arc["r"]) <= 0.0:
		_trail.polygon = PackedVector2Array()
		return
	var life: float = 1.0 if age < 0.0 else 1.0 - age / TRAIL_LIFE      # smear frame: held
	var tail: float = (1.0 - float(_arc["shown"])) + (1.0 - life) * 0.85   # 0..1 along the sweep
	var pivot: Vector2 = _arc["pivot"]
	var r: float = _arc["r"]
	var a0: float = _arc["a0"]
	var da: float = _arc["da"]
	var c: Color = profile()["color"]
	var edge := c.lerp(Color.WHITE, 0.5)
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	var cols_o := PackedColorArray()
	var cols_i := PackedColorArray()
	var n := 28
	for i in range(n + 1):
		var t: float = lerpf(tail, 1.0, float(i) / n)          # tail -> leading edge
		var k: float = (t - tail) / maxf(0.001, 1.0 - tail)     # 0 at the tail, 1 at the blade
		var dir := Vector2.RIGHT.rotated(a0 + da * t)
		var band: float = ARC_BAND * pow(k, 0.8)
		outer.append(pivot + dir * r)
		inner.append(pivot + dir * r * (1.0 - band))
		var alpha: float = life * (0.25 + 0.75 * k)
		cols_o.append(Color(edge, 1.0 * alpha))
		cols_i.append(Color(c, 0.55 * alpha))   # a filled band, brightest on the outer edge
	inner.reverse()
	cols_i.reverse()
	_trail.polygon = outer + inner
	_trail.vertex_colors = cols_o + cols_i

# ---------------------------------------------------------------- light
func _place_light(pos: Vector2, energy: float, radius_mul: float) -> void:
	var p := profile()
	_light_t = -1.0
	_light.global_position = pos
	if p.has("subtract"):
		_light.blend_mode = Light2D.BLEND_MODE_SUB
		_light.color = p["subtract"]
	else:
		_light.blend_mode = Light2D.BLEND_MODE_ADD
		_light.color = p["color"]
	_light.texture_scale = maxf(0.2, unit_size / 64.0 * radius_mul)
	_light.energy = energy
	_light.enabled = energy > 0.0

## Each element's light over the seconds after impact.
func _light_pattern(t: float) -> void:
	var p := profile()
	var peak: float = float(p["peak"])
	var rad: float = unit_size / 64.0 * float(p["radius"])
	var e := 0.0
	var pos := _light_origin
	var scale := rad
	match element:
		"fire":   # flickers, lingers, drifts up like embers
			e = peak * exp(-t / 0.45) * randf_range(0.55, 1.15)
			pos = _light_origin + Vector2(0, -40.0 * t)
			scale = rad * (1.0 + 0.3 * t)
		"water":  # rippling pulse that spreads
			e = peak * exp(-t / 0.35) * (0.7 + 0.3 * cos(t * 22.0))
			scale = rad * (0.8 + 1.0 * t)
		"earth":  # two heavy thuds, low at the target's feet
			e = peak * (exp(-t / 0.06) + 0.55 * exp(-pow((t - 0.2) / 0.05, 2)))
			pos = _light_origin + Vector2(0, unit_size * 0.35)
			scale = rad * 1.2
		"air":    # three quick strobes travelling along the swing
			var k := int(t / 0.07)
			e = peak if k < 3 and fmod(t, 0.07) < 0.035 else 0.0
			pos = _light_origin + _swing_dir * (unit_size * 0.6 * t / 0.21)
			scale = rad * 0.8
		"light":  # a slow swell and a long soft fade
			e = peak * (1.0 - exp(-t / 0.05)) * exp(-t / 0.5)
			scale = rad * (0.9 + 0.4 * t)
		"dark":   # spreads and lingers (subtractive)
			e = peak * (1.0 - exp(-t / 0.08)) * exp(-t / 0.55)
			scale = rad * (0.7 + 1.2 * t)
		_:        # plain: a tiny white spark
			e = peak * exp(-t / 0.05)
			scale = rad * 0.8
	_light.global_position = pos
	_light.texture_scale = maxf(0.2, scale)
	_light.energy = e
	_light.enabled = true
	if t > 1.2:
		_light_t = -1.0
		_light.enabled = false

# ---------------------------------------------------------------- particles
func _start_blade_emitter(at: Vector2) -> void:
	if _blade_emitter != null:
		return
	var c := _emitter(at, false)
	match element:
		"fire":
			_fx_setup(c, 18, 0.35, Vector2.UP, 40.0, 10.0, 35.0, Vector2(0, -60), 1.5, 3.0, _ramp([Color(1, 0.9, 0.4), Color(1, 0.45, 0.1), Color(0.6, 0.1, 0.05, 0.0)]))
		"water":
			_fx_setup(c, 10, 0.4, Vector2.DOWN, 60.0, 10.0, 30.0, Vector2(0, 200), 1.0, 2.0, _ramp([Color(0.8, 0.95, 1), Color(0.3, 0.6, 1, 0.0)]))
		"air":
			_fx_setup(c, 14, 0.25, -_swing_dir, 20.0, 60.0, 120.0, Vector2.ZERO, 1.0, 1.0, _ramp([Color(0.25, 0.75, 0.55, 0.95), Color(0.2, 0.6, 0.45, 0.0)]))
			c.texture = _line_texture()
			c.particle_flag_align_y = true
		"light":
			_fx_setup(c, 10, 0.5, Vector2.UP, 180.0, 5.0, 20.0, Vector2.ZERO, 1.0, 2.0, _ramp([Color(1, 1, 1), Color(1, 0.9, 0.5, 0.0)]))
			c.texture = _star_texture()
		"dark":
			_fx_setup(c, 10, 0.5, Vector2.UP, 180.0, 5.0, 18.0, Vector2(0, -10), 1.5, 3.0, _ramp([Color(0.35, 0.15, 0.5, 0.9), Color(0.15, 0.05, 0.25, 0.0)]))
		_:
			c.queue_free()
			return
	c.emitting = true
	_blade_emitter = c

func _stop_blade_emitter() -> void:
	if _blade_emitter != null and is_instance_valid(_blade_emitter):
		var e := _blade_emitter
		e.emitting = false
		get_tree().create_timer(e.lifetime + 0.1).timeout.connect(e.queue_free)
	_blade_emitter = null

func _impact_particles(at: Vector2) -> void:
	match element:
		"fire":
			_burst(at, 26, 0.6, Vector2.UP, 70.0, 30.0, 80.0, Vector2(0, -70), 1.5, 3.5, _ramp([Color(1, 0.95, 0.5), Color(1, 0.5, 0.1), Color(0.5, 0.08, 0.05, 0.0)]))
		"water":
			_burst(at, 24, 0.6, Vector2.UP, 75.0, 60.0, 120.0, Vector2(0, 320), 1.0, 2.5, _ramp([Color(0.85, 0.97, 1), Color(0.3, 0.6, 1.0), Color(0.2, 0.4, 0.9, 0.0)]))
		"earth":
			_burst(at + Vector2(0, unit_size * 0.25), 14, 0.6, Vector2.UP, 55.0, 60.0, 110.0, Vector2(0, 420), 2.0, 4.0, _ramp([Color(0.55, 0.38, 0.2), Color(0.4, 0.27, 0.15, 0.0)]))
			_burst(at + Vector2(0, unit_size * 0.35), 12, 0.5, Vector2.UP, 90.0, 10.0, 25.0, Vector2(0, -10), 3.0, 6.0, _ramp([Color(0.8, 0.7, 0.5, 0.7), Color(0.8, 0.7, 0.5, 0.0)]))
		"air":
			var c := _burst(at, 24, 0.32, _swing_dir, 40.0, 140.0, 240.0, Vector2.ZERO, 1.0, 1.0, _ramp([Color(0.3, 0.8, 0.6), Color(0.2, 0.6, 0.45, 0.0)]))
			c.texture = _line_texture()
			c.particle_flag_align_y = true
		"light":
			var c := _burst(at, 20, 0.7, Vector2.UP, 180.0, 20.0, 60.0, Vector2.ZERO, 1.0, 2.0, _ramp([Color(1, 1, 1), Color(1, 0.92, 0.55), Color(1, 0.85, 0.4, 0.0)]))
			c.texture = _star_texture()
			c.damping_min = 40.0
			c.damping_max = 60.0
		"dark":
			_burst(at, 18, 0.8, Vector2.UP, 180.0, 15.0, 40.0, Vector2(0, -15), 2.0, 4.0, _ramp([Color(0.3, 0.1, 0.45, 0.9), Color(0.15, 0.05, 0.25, 0.0)]))
		_:
			_burst(at, 9, 0.22, -_swing_dir.orthogonal() if _swing_dir != Vector2.ZERO else Vector2.UP, 60.0, 80.0, 140.0, Vector2(0, 220), 1.0, 1.5, _ramp([Color(1, 1, 0.8), Color(1, 0.8, 0.4, 0.0)]))

func _burst(at: Vector2, amount: int, life: float, dir: Vector2, spread: float, vmin: float, vmax: float,
		gravity: Vector2, smin: float, smax: float, ramp: Gradient) -> CPUParticles2D:
	var c := _emitter(at, true)
	_fx_setup(c, amount, life, dir, spread, vmin, vmax, gravity, smin, smax, ramp)
	c.emitting = true
	get_tree().create_timer(life + 0.2).timeout.connect(c.queue_free)
	return c

func _emitter(at: Vector2, one_shot: bool) -> CPUParticles2D:
	var c := CPUParticles2D.new()
	c.top_level = true
	c.global_position = at
	c.one_shot = one_shot
	c.explosiveness = 0.9 if one_shot else 0.0
	c.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	c.local_coords = false
	add_child(c)
	return c

func _fx_setup(c: CPUParticles2D, amount: int, life: float, dir: Vector2, spread: float, vmin: float, vmax: float,
		gravity: Vector2, smin: float, smax: float, ramp: Gradient) -> void:
	# sizes/speeds are authored for a ~46 px unit; scale with the real one
	var k := unit_size / 46.0
	var ks := k * 1.4   # particles read better a little chunkier at battle scale
	c.amount = amount
	c.lifetime = life
	c.direction = dir if dir != Vector2.ZERO else Vector2.UP
	c.spread = spread
	c.initial_velocity_min = vmin * k
	c.initial_velocity_max = vmax * k
	c.gravity = gravity * k
	c.scale_amount_min = smin * ks
	c.scale_amount_max = smax * ks
	c.color_ramp = ramp

func _ramp(cols: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for i in cols.size():
		g.add_point(float(i) / float(maxi(1, cols.size() - 1)), cols[i])
	return g

# ---------------------------------------------------------------- tiny textures
func _radial_texture() -> Texture2D:
	if _tex_cache.has("radial"):
		return _tex_cache["radial"]
	var lt := GradientTexture2D.new()
	lt.fill = GradientTexture2D.FILL_RADIAL
	lt.fill_from = Vector2(0.5, 0.5)
	lt.fill_to = Vector2(1.0, 0.5)
	lt.width = 64
	lt.height = 64
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	lt.gradient = g
	_tex_cache["radial"] = lt
	return lt

func _line_texture() -> Texture2D:   # a 1x5 streak, aligned to the particle's velocity
	if _tex_cache.has("line"):
		return _tex_cache["line"]
	var img := Image.create(1, 5, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var t := ImageTexture.create_from_image(img)
	_tex_cache["line"] = t
	return t

func _star_texture() -> Texture2D:   # a 3x3 plus: a pixel sparkle
	if _tex_cache.has("star"):
		return _tex_cache["star"]
	var img := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for p in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]:
		img.set_pixelv(p, Color.WHITE)
	var t := ImageTexture.create_from_image(img)
	_tex_cache["star"] = t
	return t

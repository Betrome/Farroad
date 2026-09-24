class_name UnitView
extends Node2D
## One unit's on-field visual: a placeholder shape (no sprite art in the repo
## yet -- Ian's own call), a name label, an HP bar, and a thin charge bar
## just below it. Built entirely in code (setup()), not a hand-authored
## .tscn sub-scene -- the battle field's unit count varies per fight, so
## constructing views programmatically from FarroadCore's own unit dicts is
## the natural fit, not just easier to author reliably by hand.
##
## Sized from the caller's OWN viewport-relative size, not a fixed pixel
## constant -- meant to run on phones, where the visible viewport varies by
## device aspect ratio (see BattlePresenter's stretch/aspect="expand" note).
##
## Ian: "I want to eventually replace the blocks with sprite assets... what
## do we need to do now to prepare for that?" `shape` is a real Sprite2D
## rather than a vector shape, so a real sprite sheet drops straight into
## `shape.texture` later with no other code changes -- every hop/shake/run
## animation already tweens `shape.position`/`.scale`, which work
## identically on a Sprite2D.
##
## Ian: "do a procedural polish pass" (a stopgap ahead of real art) --
## `shape.texture` is now one of a small set of PROCEDURALLY-DRAWN shape
## textures (see _get_shape_texture), keyed by archetype/party-role, each
## baked with its own tint and a soft vertical shade for a sense of volume
## instead of one flat-colored square for every unit in the game. Still a
## placeholder (still just `shape.texture`, still swapped for real art with
## zero other code changes) -- just a more legible one.
##
## Ian: real animations, added "unit by unit" -- `shape` is now typed
## Node2D (the nearest common ancestor) rather than strictly Sprite2D,
## because it's built as ONE of two things depending on whether real art
## exists for this specific unit yet:
##   - a real AnimatedSprite2D, if a SpriteFrames resource exists at this
##     unit's own expected path (see _sprite_frames_path_for) -- self-serve
##     for Ian: drop a .tres at that exact path and it activates with no
##     code change, per-unit or per-archetype.
##   - otherwise the SAME procedural placeholder Sprite2D as before.
## Every existing hop/shake/run tween already only touches
## shape.position/.scale/.modulate, which both node types share as
## Node2D/CanvasItem, so none of that needed to change. The one thing that
## DOES differ is which named ANIMATION plays and when -- see play_state()
## and prefers_run_approach() below, which are the only two entry points
## BattlePresenter needs to know about; a fallback-shape unit's calls to
## either are safe, cheap no-ops.
## Named animations, when present: idle / hurt / dead / jump / run /
## attack / cast. "jump" (a sine-arc hop, the existing default) and "run"
## (a straight-line dash) are alternate styles for a physical action's
## approach+return -- a unit uses "run" only if its own SpriteFrames
## actually HAS a "run" animation (prefers_run_approach()), otherwise it
## always falls back to "jump", exactly like today.

## Ian: "tapping on a unit in the battle should show its stats page,
## live." Emitted on a real click/touch inside this unit's own bounding
## square -- BattlePresenter connects one listener per view (at the same
## two sites that already call setup()) and opens its Status popup
## filtered to just this unit.
signal tapped

var unit: Dictionary
var rest_position: Vector2
var size: float

var shape: Node2D   # public -- BattlePresenter animates ONLY this during a hop/shake/run, not the whole UnitView, so the name/HP/charge bars below (siblings, not children of shape) stay put at the unit's rest position. Either an AnimatedSprite2D (real art) or a Sprite2D (procedural fallback) -- see play_state()/prefers_run_approach() for the only two ways callers should ever care which.
var _boss_ring: Sprite2D   # only built for a boss STILL ON the procedural fallback shape -- a bigger, darker copy of the same shape, drawn BEHIND it. Not yet extended to real animated boss art (flagged, revisit once that exists).
var _played_dead_state: bool = false   # guards play_state("dead") to fire only once per death, not on every subsequent update_hp() refresh while already dead

## Procedural placeholder shapes, one per archetype (party units all share
## CIRCLE) -- baked at a fixed resolution regardless of final on-screen
## size (shape.scale stretches it, same as the old flat-color texture did)
## so edges stay smooth rather than blocky.
enum ShapeKind { CIRCLE, DIAMOND, HEX, SQUARE, TRIANGLE_UP, TRIANGLE_DOWN }
const _SHAPE_TEX_SIZE := 64

## How long an animated (real SpriteFrames) enemy's "dead" animation gets
## to actually play before the view disappears -- a first-pass guess,
## easy to retune once there's real death art to time it against.
const DEAD_HOLD_TIME := 0.6

## Enemy archetype -> {shape, tint}. All 6 real archetypes (confirmed via
## farroadenemies.csv's own `key` column -- "boss" is a modifier applied to
## a rotation archetype, not a 7th real one, so a boss unit's own `arch`
## still points at one of these 6 and picks up its shape/tint normally; the
## boss-only ring below is what marks it as a boss). Shapes chosen to read
## as loosely thematic (knight=armoured/blocky, ox=bulky, wolf/shrike=feral/
## swift, priest=mystical, hound=fast) without needing real art; tints stay
## in the same red family as ENEMY_RED/ENEMY_RED_BRIGHT so every enemy still
## reads as "enemy" at a glance, just individually distinguishable.
const _ENEMY_ARCH_STYLE := {
	"wolf": {"shape": ShapeKind.TRIANGLE_UP, "tint": Color(0.80, 0.35, 0.15)},
	"knight": {"shape": ShapeKind.SQUARE, "tint": Color(0.55, 0.12, 0.12)},
	"hound": {"shape": ShapeKind.CIRCLE, "tint": Color(0.60, 0.28, 0.15)},
	"ox": {"shape": ShapeKind.HEX, "tint": Color(0.45, 0.10, 0.10)},
	"priest": {"shape": ShapeKind.DIAMOND, "tint": Color(0.65, 0.15, 0.35)},
	"shrike": {"shape": ShapeKind.TRIANGLE_DOWN, "tint": Color(0.80, 0.20, 0.35)},
	# Elemental batch -- tinted by element so weaknesses read at a glance.
	"cinderimp": {"shape": ShapeKind.TRIANGLE_UP, "tint": Color(0.95, 0.40, 0.10)},
	"tidewraith": {"shape": ShapeKind.DIAMOND, "tint": Color(0.15, 0.45, 0.90)},
	"cragback": {"shape": ShapeKind.HEX, "tint": Color(0.55, 0.40, 0.20)},
	"galeharpy": {"shape": ShapeKind.TRIANGLE_DOWN, "tint": Color(0.45, 0.85, 0.70)},
	"dawnacolyte": {"shape": ShapeKind.DIAMOND, "tint": Color(0.95, 0.85, 0.35)},
	"umbralstalker": {"shape": ShapeKind.CIRCLE, "tint": Color(0.40, 0.18, 0.55)},
	"pyretyrant": {"shape": ShapeKind.HEX, "tint": Color(0.90, 0.30, 0.05)},
	"drownedmatriarch": {"shape": ShapeKind.HEX, "tint": Color(0.10, 0.35, 0.80)},
	"mountaincolossus": {"shape": ShapeKind.HEX, "tint": Color(0.50, 0.35, 0.18)},
	"stormroc": {"shape": ShapeKind.HEX, "tint": Color(0.35, 0.80, 0.65)},
	"dawnseraph": {"shape": ShapeKind.HEX, "tint": Color(0.95, 0.80, 0.30)},
	"hollowking": {"shape": ShapeKind.HEX, "tint": Color(0.35, 0.12, 0.50)},
}
const _ENEMY_DEFAULT_STYLE := {"shape": ShapeKind.SQUARE, "tint": Color(0.85, 0.30, 0.28)}   # unrecognized/absent arch -- the old flat enemy-red

## Party members all use CIRCLE ("friendly, rounded" vs. enemies' more
## angular assortment); the exact hue is picked per roster id (hashed, so
## it's automatic for any current or future roster entry -- no per-unit
## hardcoding to maintain) from a small family of cool, ally-coded hues.
const _PARTY_HUES := [
	Color(0.08, 0.38, 0.88),   # blue -- the original party color, stays first/most common
	Color(0.10, 0.50, 0.55),   # teal
	Color(0.32, 0.28, 0.78),   # indigo
	Color(0.12, 0.55, 0.40),   # green-teal
	Color(0.20, 0.45, 0.85),   # sky blue
]

static var _shape_texture_cache: Dictionary = {}   # "<ShapeKind>|<html color>" -> Texture2D

## Draws one shape into a _SHAPE_TEX_SIZE^2 RGBA image: an analytic
## inside/outside test per pixel (no polygon-fill API on Image itself),
## 1px of edge antialiasing, and a soft vertical shade (lighter near the
## top, darker near the bottom) for a sense of volume instead of one flat
## fill. Cached per (shape, tint) pair -- generated once, shared by every
## unit of that archetype/party-hue for the life of the process.
static func _get_shape_texture(kind: int, tint: Color) -> Texture2D:
	var key: String = "%d|%s" % [kind, tint.to_html(false)]
	if _shape_texture_cache.has(key):
		return _shape_texture_cache[key]
	var n := _SHAPE_TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var center := Vector2(n / 2.0, n / 2.0)
	var r := n / 2.0 - 1.0
	for y in range(n):
		for x in range(n):
			var p := Vector2(x + 0.5, y + 0.5)
			var d: Vector2 = p - center
			var edge_dist := -1.0   # >0 inside the shape, magnitude ~= distance from its edge
			match kind:
				ShapeKind.CIRCLE:
					edge_dist = r - d.length()
				ShapeKind.DIAMOND:
					edge_dist = r - (absf(d.x) + absf(d.y))
				ShapeKind.SQUARE:
					edge_dist = r - maxf(absf(d.x), absf(d.y))
				ShapeKind.HEX:
					# An octagon (square intersected with a wider diamond,
					# clipping just the corners) -- reads as "armored/bulky"
					# without needing a full hexagon distance formula.
					var square_d: float = r - maxf(absf(d.x), absf(d.y))
					var diamond_d: float = r * 1.3 - (absf(d.x) + absf(d.y))
					edge_dist = minf(square_d, diamond_d)
				ShapeKind.TRIANGLE_UP:
					var ny: float = (d.y + r) / (2.0 * r)   # 0 at top point, 1 at base
					edge_dist = minf(ny * r - absf(d.x), minf(d.y + r, r - d.y))
				ShapeKind.TRIANGLE_DOWN:
					var ny2: float = (r - d.y) / (2.0 * r)   # 0 at bottom point, 1 at base
					edge_dist = minf(ny2 * r - absf(d.x), minf(d.y + r, r - d.y))
			var alpha: float = clampf(edge_dist, 0.0, 1.0)
			var shade_t: float = clampf(p.y / float(n), 0.0, 1.0)
			var shaded: Color = tint.lerp(Color(1, 1, 1), 0.22 * (1.0 - shade_t)).lerp(Color(0, 0, 0), 0.20 * shade_t)
			img.set_pixel(x, y, Color(shaded.r, shaded.g, shaded.b, alpha))
	var tex := ImageTexture.create_from_image(img)
	_shape_texture_cache[key] = tex
	return tex

## Resolves which shape/tint a unit gets -- archetype for enemies (falling
## back to the old flat enemy-red square if `arch` is absent/unrecognized),
## a hashed hue for party members. Boss-ness is NOT part of this (bosses
## keep their rotation archetype's own shape/tint) -- see _boss_ring below
## for what actually marks a boss visually.
static func _style_for(u: Dictionary) -> Dictionary:
	if u["isParty"]:
		var hue: Color = _PARTY_HUES[hash(String(u["id"])) % _PARTY_HUES.size()]
		return {"shape": ShapeKind.CIRCLE, "tint": hue}
	var arch = u.get("arch")
	if arch != null and _ENEMY_ARCH_STYLE.has(arch):
		return _ENEMY_ARCH_STYLE[arch]
	return _ENEMY_DEFAULT_STYLE

## Fixed path convention so a new SpriteFrames resource activates with no
## code change: party units at "res://sprites/units/<uid>.tres", enemies
## at "res://sprites/units/arch_<archetype>.tres" (shared across every
## enemy of that archetype, same granularity the procedural shapes/tints
## already use). An enemy with no `arch` at all (shouldn't normally
## happen) has no path to check and always falls back.
static func _sprite_frames_path_for(u: Dictionary) -> String:
	if u["isParty"]:
		return "res://sprites/units/%s.tres" % u["id"]
	var arch = u.get("arch")
	if arch == null:
		return ""
	return "res://sprites/units/arch_%s.tres" % arch

## path -> SpriteFrames, or `false` for a path already confirmed to have
## nothing there -- checked once per unique path for the life of the
## process (ResourceLoader.exists() is cheap but not free, and this can be
## queried once per unit built).
static var _sprite_frames_cache: Dictionary = {}

static func _load_sprite_frames(path: String) -> SpriteFrames:
	if path == "":
		return null
	if _sprite_frames_cache.has(path):
		var cached = _sprite_frames_cache[path]
		return cached if cached is SpriteFrames else null
	if not ResourceLoader.exists(path):
		_sprite_frames_cache[path] = false
		return null
	var res := ResourceLoader.load(path)
	if res is SpriteFrames:
		_sprite_frames_cache[path] = res
		return res
	_sprite_frames_cache[path] = false
	return null

var _hp_bg: ColorRect
var _hp_fg: ColorRect
var _charge_bg: ColorRect
var _charge_fg: ColorRect
var _click_area: Area2D
var _name_label: Label

func setup(u: Dictionary, unit_size: float) -> void:
	unit = u
	_build(unit_size)

## Rebuilds this SAME UnitView at a new size, `unit` unchanged -- used by
## BattlePresenter._place_weighted's overflow shrink (Group I, 20-item
## batch: several large archetypes sharing one column can genuinely not
## fit at their own natural size; shrinking the actual rendered size,
## not just the reserved band, is what keeps the visual footprint honest).
## Safe to call before this UnitView has ever been rendered a frame (the
## normal case -- _layout_units/_place_weighted run synchronously before
## the scene tree's first draw), since the old children's queue_free()
## never gets a chance to show on screen either way.
func resize(unit_size: float) -> void:
	for c in get_children():
		c.queue_free()
	_build(unit_size)

func _build(unit_size: float) -> void:
	size = unit_size
	var half := size / 2.0
	var bar_h: float = max(4.0, size * 0.12)
	var charge_h: float = max(2.0, bar_h * 0.5)
	# Group I (20-item batch): tightened from the original bar_h-sized gaps
	# (the bar's own height doubling as the gap between it and the next
	# element) to a small, consistent gap -- shrinks each unit's total
	# vertical footprint so adjacent units don't overlap at max occupancy.
	var gap: float = max(1.0, size * 0.05)

	var style: Dictionary = _style_for(unit)
	var frames: SpriteFrames = _load_sprite_frames(_sprite_frames_path_for(unit))
	_boss_ring = null

	if frames != null:
		var anim := AnimatedSprite2D.new()
		anim.sprite_frames = frames
		var anim_names: PackedStringArray = frames.get_animation_names()
		var start_anim: String = "idle" if frames.has_animation("idle") else (anim_names[0] if anim_names.size() > 0 else "")
		if start_anim != "":
			anim.play(start_anim)
			var frame_tex: Texture2D = frames.get_frame_texture(start_anim, 0)
			var largest: float = maxf(frame_tex.get_size().x, frame_tex.get_size().y) if frame_tex != null else 0.0
			var s: float = size / largest if largest > 0.0 else 1.0
			anim.scale = Vector2(s, s)
		shape = anim
		add_child(shape)
	else:
		var sp := Sprite2D.new()
		sp.texture = _get_shape_texture(style["shape"], style["tint"])
		sp.scale = Vector2(size, size) / float(_SHAPE_TEX_SIZE)
		shape = sp
		add_child(shape)

		# A bigger, darker copy of the SAME shape drawn behind it -- the only
		# thing that visually marks a boss (its own rotation archetype's
		# shape/tint are otherwise unchanged), a cheap stand-in for a real
		# "this one's dangerous" silhouette treatment later -- procedural
		# fallback only for now (flagged: not yet extended to real animated
		# boss art). A CHILD of `shape` itself (not a sibling) specifically
		# so it inherits every hop/shake/run tween that already animates
		# shape.position/.scale for free -- z_index=-1 keeps it drawn behind
		# shape despite being its child.
		if unit.get("isBoss"):
			_boss_ring = Sprite2D.new()
			_boss_ring.texture = _get_shape_texture(style["shape"], (style["tint"] as Color).darkened(0.55))
			_boss_ring.scale = Vector2(1.22, 1.22)
			_boss_ring.z_index = -1
			shape.add_child(_boss_ring)

	_hp_bg = ColorRect.new()
	_hp_bg.size = Vector2(size, bar_h)
	_hp_bg.position = Vector2(-half, half + gap)
	_hp_bg.color = Color(0.15, 0.15, 0.15)
	add_child(_hp_bg)

	_hp_fg = ColorRect.new()
	_hp_fg.size = Vector2(size, bar_h)
	_hp_fg.position = _hp_bg.position
	_hp_fg.color = Color(0.25, 0.85, 0.30)
	add_child(_hp_fg)

	# Thin charge bar, directly below the HP bar -- fills toward whichever
	# charge action the unit itself has (costOfCharge), or the generic
	# CHARGE_FULL if it has none, so it never visually overflows past full.
	var charge_y: float = _hp_bg.position.y + bar_h + gap
	_charge_bg = ColorRect.new()
	_charge_bg.size = Vector2(size, charge_h)
	_charge_bg.position = Vector2(-half, charge_y)
	_charge_bg.color = Color(0.12, 0.12, 0.16)
	add_child(_charge_bg)

	_charge_fg = ColorRect.new()
	_charge_fg.size = Vector2(0, charge_h)
	_charge_fg.position = Vector2(-half, charge_y)
	_charge_fg.color = Color(0.85, 0.7, 0.15)
	add_child(_charge_fg)

	# Group I: "space out units vertically so names aren't overlapping. Put
	# names under the charge bar." -- moved from above the shape (its old
	# spot) to directly below the charge bar, now the bottom-most element.
	_name_label = Label.new()
	_name_label.text = unit["name"]
	_name_label.position = Vector2(-half, charge_y + charge_h + gap)
	_name_label.add_theme_font_size_override("font_size", int(size * 0.25))
	add_child(_name_label)

	# Tap/click target -- a plain rectangle covering the shape's own bounds
	# (not the whole footprint including bars/name, which would make
	# adjacent units' tap zones overlap at tight spacing). Area2D, not a
	# Control, since this whole view is a Node2D tree positioned by
	# BattlePresenter's own world-space layout math, not a Control layout.
	_click_area = Area2D.new()
	_click_area.input_pickable = true
	var collision := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(size, size)
	collision.shape = rect
	_click_area.add_child(collision)
	_click_area.input_event.connect(_on_click_area_input_event)
	add_child(_click_area)

	update_hp()
	update_charge()

func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit()
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit()

## The ONE entry point BattlePresenter needs for animation state -- named
## per the 7-animation set (idle/hurt/dead/jump/run/attack/cast). A true
## no-op for a unit still on the procedural fallback shape (no animations
## exist at all), and also a no-op if THIS unit's own SpriteFrames simply
## doesn't happen to define that particular name yet -- callers never need
## to check first, "unit by unit" rollout means any given unit may only
## have SOME of the 7 defined.
func play_state(anim_name: String) -> void:
	if shape is AnimatedSprite2D:
		var asp: AnimatedSprite2D = shape
		if asp.sprite_frames != null and asp.sprite_frames.has_animation(anim_name):
			asp.play(anim_name)

## Whether this unit's physical-attack approach/return should be a
## straight-line RUN instead of the default sine-arc JUMP -- a per-unit
## preference DERIVED from whether a real "run" animation exists, not a
## separate flag to maintain. The procedural fallback shape has no
## animations at all, so it always answers false (today's jump/hop,
## unchanged).
func prefers_run_approach() -> bool:
	if not (shape is AnimatedSprite2D):
		return false
	var asp: AnimatedSprite2D = shape
	return asp.sprite_frames != null and asp.sprite_frames.has_animation("run")

## Called by BattlePresenter.sync_mc_name right after a MC rename -- unlike
## hp/charge, the unit dict's own "name" field isn't re-read every frame,
## so the label needs an explicit push when it changes mid-fight.
func update_name(new_name: String) -> void:
	_name_label.text = new_name

## Re-reads unit["hp"]/["maxHp"] -- FarroadCore.step() mutates the unit dict
## in place, so this always reflects the live value, no separate sync needed.
func update_hp() -> void:
	var frac: float = clamp(float(unit["hp"]) / float(unit["maxHp"]), 0.0, 1.0)
	var bar_h: float = _hp_bg.size.y
	_hp_fg.size = Vector2(size * frac, bar_h)
	_hp_fg.color = Color(0.25, 0.85, 0.30) if frac > 0.3 else Color(0.90, 0.70, 0.15) if frac > 0.0 else Color(0.5, 0.1, 0.1)
	if frac <= 0.0:
		if not _played_dead_state:
			_played_dead_state = true
			play_state("dead")
		# A dead enemy disappears outright (there's no reviving one mid-fight,
		# so nothing is lost by removing it from view) -- an ANIMATED enemy
		# gets a short hold first so its death animation actually has time to
		# play; the procedural fallback (nothing to show) still disappears
		# instantly, unchanged. A dead PARTY member always stays visible, just
		# dimmed -- a fallen ally isn't gone the way a kill is, and a
		# vanishing party sprite would read as a bug, not a death.
		if not unit["isParty"]:
			if shape is AnimatedSprite2D:
				modulate.a = 1.0
				get_tree().create_timer(DEAD_HOLD_TIME).timeout.connect(func(): visible = false)
			else:
				visible = false
			return
		visible = true
		modulate.a = 0.35
		return
	_played_dead_state = false
	visible = true
	modulate.a = 1.0

## Re-reads unit["charge"] against its own chargeAction's costOfCharge --
## same "live dict, no separate sync" reasoning as update_hp(). A unit
## with no chargeAction at all (most non-boss enemies) has nothing to
## ever spend charge on, so the bar is hidden outright rather than shown
## clamped-at-some-fraction-of-a-generic-fallback, which used to read as
## "this enemy is charging something" when it never was.
func update_charge() -> void:
	if not unit.get("chargeAction"):
		_charge_bg.visible = false
		_charge_fg.visible = false
		return
	_charge_bg.visible = true
	_charge_fg.visible = true
	var act = FarroadCore.ACTIONS.get(unit["chargeAction"])
	var max_charge: float = FarroadCore.cost_of_charge(act)
	var frac: float = clamp(float(unit.get("charge", 0.0)) / max_charge, 0.0, 1.0)
	_charge_fg.size = Vector2(size * frac, _charge_bg.size.y)

## World-space point a floating damage number should spawn from.
func damage_spawn_position() -> Vector2:
	return global_position + Vector2(0, -size / 2.0 - size * 0.18)

## Piece G (wave-transition polish): "have the hp, charge bars, and names
## disappear before party members and unit move." Hides the three "info"
## elements instantly -- NOT `shape`, which stays visible and moving the
## whole time. Called right before a view starts a run/retreat/entrance
## tween.
func hide_chrome() -> void:
	_hp_bg.visible = false
	_hp_fg.visible = false
	_charge_bg.visible = false
	_charge_fg.visible = false
	_name_label.visible = false

## "...and fade in over .5 seconds when they stop moving." Called once a
## view's own movement tween has finished. Respects update_charge()'s own
## rule that a unit with no chargeAction never shows a charge bar at all --
## fading one in for such a unit would contradict its normal (non-transition)
## state.
func fade_in_chrome(duration: float = 0.5) -> void:
	_hp_bg.visible = true
	_hp_fg.visible = true
	_hp_bg.modulate.a = 0.0
	_hp_fg.modulate.a = 0.0
	_name_label.visible = true
	_name_label.modulate.a = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_hp_bg, "modulate:a", 1.0, duration)
	tw.tween_property(_hp_fg, "modulate:a", 1.0, duration)
	tw.tween_property(_name_label, "modulate:a", 1.0, duration)
	if unit.get("chargeAction"):
		_charge_bg.visible = true
		_charge_fg.visible = true
		_charge_bg.modulate.a = 0.0
		_charge_fg.modulate.a = 0.0
		tw.tween_property(_charge_bg, "modulate:a", 1.0, duration)
		tw.tween_property(_charge_fg, "modulate:a", 1.0, duration)

## A quick decaying left-right shake -- played when this unit takes a
## non-evaded hit. Shakes only `shape` (the colored square/sprite), not the
## whole UnitView, so the name/HP/charge bars stay put instead of shaking
## along with it. Safe to fire without awaiting: targets never move during
## the ATTACKER's own hop/projectile animation, so this never fights
## another tween over `shape.position`.
##
## Also plays/clears the "hurt" animation state, guarded against a killing
## blow: update_hp() (called just before this, same hits loop) already sets
## "dead" first when this hit was lethal, so a plain unconditional "hurt"
## here would immediately stomp it, then stomp it AGAIN back to "idle" once
## this tween finishes -- checked once, up front, against the unit's own
## live (already-updated) hp.
func shake() -> void:
	var is_dead: bool = float(unit["hp"]) <= 0.0
	if not is_dead:
		play_state("hurt")
	var base := shape.position
	var amt: float = size * 0.14
	var tw := create_tween()
	tw.tween_property(shape, "position", base + Vector2(amt, 0), 0.035)
	tw.tween_property(shape, "position", base + Vector2(-amt, 0), 0.06)
	tw.tween_property(shape, "position", base + Vector2(amt * 0.4, 0), 0.06)
	tw.tween_property(shape, "position", base, 0.05)
	if not is_dead:
		tw.finished.connect(func(): play_state("idle"))

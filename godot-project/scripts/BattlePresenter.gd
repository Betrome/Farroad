extends Node2D
## Milestone 2, Step 2a: the battle view. Drives FarroadCore.step() beat by
## beat and animates each event -- FarroadCore.gd itself is never modified,
## this is presentation only, consuming the exact same event shape
## parity_test.gd already dumps to JSON for the headless diff tests.
##
## Layout is computed from the viewport's OWN size at runtime, as fractions,
## not fixed pixel constants -- this is meant to run on phones, and Godot's
## stretch/aspect="expand" (project.godot) means the actual visible viewport
## size varies by device aspect ratio, not just the 1280x720 design size.
##
## Milestone 3, Step 3b: no longer self-contained -- GameController.gd owns
## the real game-state Dictionary and the real battle it's fighting.
## `_ready()` only builds the reusable UI chrome (log/status/enrage/turn
## order); `start_battle()` is the new entry point a caller uses to actually
## begin animating a real, externally-built battle. A fresh instance is
## created per wave (see GameController._begin_next_fight) rather than
## reused, so there's no reset-state path to get wrong between fights.

signal battle_finished(outcome)

const TURN_ORDER_COUNT := 5
# Status/Log now sit just to the right of the enrage gauge (x 0.016-0.316)
# as small square icon buttons -- placeholder squares (see _build_icon_tab)
# until real art replaces them, a caption below each rather than text
# inside. Sized as a fraction of vp.x (not vp.y) so the square stays a true
# square regardless of aspect ratio and so two of them plus the enrage bar
# reliably fit side by side even on a narrow portrait screen.
const STATUS_LOG_ICON_FRAC := 0.08    # of viewport width -- Status/Log icon size
# Turn-order frame's own top, as a shared constant -- both _build_turn_order_ui
# (which builds the frame itself) and the Status/Log icon row (which sits
# right above it, right-aligned) need the SAME number, so it's a named
# constant rather than a value hardcoded independently in two places.
const TURN_ORDER_FRAME_TOP_FRAC := 0.775   # of viewport height
const HOP_HEIGHT_FRAC := 0.099      # of viewport height (doubled from round 4's 0.0495)
# How far short of the target's rest position a physical attacker's hop
# stops -- 0.05 originally drew the two shapes nearly on top of each other
# at the peak of the hop; 50% farther back than that.
const HOP_STOP_SHORT := 0.075       # of viewport width
# 24-item batch (Group B3): "if actions are physical, have the next action
# take place while they are in the middle of moving back to their
# position, so after 0.75 seconds. Make magic actions take 0.75 seconds."
# HOP_TIME is now just the OUTBOUND leg's own duration -- the return leg
# is fire-and-forget (started, never awaited), so the two are no longer
# coupled into one blocking round trip. PHYS_BEAT_TOTAL is the actual
# gate before the next beat's step() fires: since HOP_TIME(0.475) is
# comfortably under PHYS_BEAT_TOTAL(0.75), and the RETURN leg takes its
# own HOP_TIME to finish, the return is still visibly mid-flight when the
# next action starts, exactly as asked. MAGIC_BEAT_TOTAL replaces the old
# PROJECTILE_TIME+BEAT_PAUSE pair -- the projectile's own flight duration
# IS the full magic beat now, nothing tacked on after.
const HOP_TIME := 0.475             # outbound leg only now (see above)
const ATTACK_START_IN_LEG := 0.75   # the attack's wind-up starts this far through the approach leg
const PHYS_BEAT_TOTAL := 0.75
const MAGIC_BEAT_TOTAL := 0.75
const IDLE_PAUSE := 0.45            # no-target/burned-out beats -- nothing to animate anyway

## camp/element glyphs -- mirrors ELEMENT_GLYPH/actionGlyphText exactly
## (farroad-ui.js:486-505), same unicode icons, no sprite assets needed.
const ELEMENT_GLYPH := {"fire": "🔥", "water": "💧", "earth": "🪨",
	"air": "💨", "light": "☀️", "dark": "🌑"}

var battle: Dictionary
var unit_views_by_id: Dictionary = {}
var _bar_layer: Node2D   # every unit's HP/charge bars and name, drawn under all unit sprites
var unit_views_by_name: Dictionary = {}
var active_unit_id: String = ""   # whichever unit's beat is currently animating -- drives the gold border in the Status popup too
var status_filter_uid: String = ""   # "" shows every unit's card; set (via a battlefield tap) shows just one
var log_lines: Array = []   # each entry: {head_bbcode, dmg_text, via_bbcode, note_bbcodes, calc, expanded}
var log_popup: PopupPanel
var log_container: VBoxContainer
var pause_log_btn: Button
## While true, new beats still accumulate into log_lines (nothing is lost),
## but the OPEN popup stops auto-rebuilding on every one -- lets a player
## actually read/scroll a fast-moving fight's log without new entries
## (inserted newest-first) jumping their place around underneath them.
## _on_log_pressed's own rebuild on open is unaffected either way -- opening
## the log always shows a fresh snapshot regardless of pause state; pausing
## only stops it from moving once it's already open.
var log_paused: bool = false
var turn_cards: Array = []
var status_icon_btn: Button
var log_icon_btn: Button
var turn_order_header: Label
var turn_order_frame: Panel
var _turn_card_w: float = 0.0   # inner width available to each turn-order card's labels

# Layout fractions of the viewport, resolved to pixels in _ready(). Front
# rows sit closer to center (a visibly smaller gap than the first pass) so
# hops/projectiles cover less empty ground and read faster/snappier.
var _vp: Vector2
var field_top: float
var field_bottom: float
var party_back_x: float
var party_front_x: float
var enemy_front_x: float
var enemy_back_x: float

func _recompute_field_fractions() -> void:
	field_top = _vp.y * 0.11
	field_bottom = _vp.y * 0.58
	# Back rows pulled in from the screen edges -- a back-row unit's own name
	# label extends further left of its position than the unit itself (see
	# UnitView.setup's -half-size*0.2 offset), so at the old 0.06/0.94 back-row
	# fractions the label's left/right edge could land off-screen entirely on
	# a narrow phone width (confirmed live). Front rows unchanged.
	party_back_x = _vp.x * 0.14
	party_front_x = _vp.x * 0.30
	enemy_front_x = _vp.x * 0.70
	enemy_back_x = _vp.x * 0.86

func _ready() -> void:
	_vp = get_viewport_rect().size
	_bar_layer = Node2D.new()
	add_child(_bar_layer)
	# Needed for UnitView's own Area2D.input_event (tap-a-unit-for-stats,
	# post-batch feedback) to ever fire -- off by default project-wide.
	get_viewport().physics_object_picking = true
	_recompute_field_fractions()
	_build_log_ui()
	_build_status_ui()
	_build_wave_progress_ui()
	_build_enrage_ui()
	_build_turn_order_ui()

## Entry point for a caller (GameController) that already built a real
## battle via FarroadProgression -- content is assumed already loaded and
## FarroadCore.set_wave() already called by build_enemies() itself, neither
## of which is this presenter's job anymore.
## Piece G (wave-transition polish): `hide_party_until_revealed`, when true,
## hides every party UnitView (chrome AND body) right after layout, revealed
## later by reveal_party(). `stage_enemies_offscreen`, when true, snaps every
## enemy view off-screen-right and hides its chrome (see _stage_enemies_
## offscreen) WITHOUT starting their run-in tween yet -- that's a separate
## call, run_enemies_entering(), so the caller controls exactly when they
## start appearing (see its own comment for why). `auto_start_loop=false`
## skips starting the battle loop here too -- the caller starts it later via
## begin_combat(), once everyone's actually assembled.
func start_battle(new_battle: Dictionary, units: Array, stage_enemies_offscreen: bool = false, cleared_waves: Dictionary = {}, hide_party_until_revealed: bool = false, auto_start_loop: bool = true) -> void:
	battle = new_battle
	_layout_units(units)
	if hide_party_until_revealed:
		for view in unit_views_by_id.values():
			if view.unit["isParty"]:
				view.hide_chrome()
				view.visible = false
	if stage_enemies_offscreen:
		_stage_enemies_offscreen()
	_refresh_wave_progress(cleared_waves)
	_refresh_turn_order()
	_refresh_enrage()
	if auto_start_loop:
		_run_battle_loop()

## Reveals a party hidden by start_battle's hide_party_until_revealed --
## called by GameController once the OLD presenter's own retreat tween
## finishes. This party was never actually moving (already laid out at
## rest), but from the player's perspective it's the same party that just
## retreated, so it gets the same "fade in over .5s once stopped moving"
## treatment as a view that genuinely just finished a tween.
func reveal_party(fade_duration: float = 0.5) -> void:
	for view in unit_views_by_id.values():
		if view.unit["isParty"]:
			view.visible = true
			view.fade_in_chrome(fade_duration)

## Ian: "slow down the enemy movement into their positions" -- was 1.0.
const ENEMY_RUN_IN_TIME := 1.6

## Ian, follow-up to the original "enemies run in" ask: "make it feel like
## the party stops because they see enemies coming, assuming battle
## stances, and THEN we see enemies coming in from off-screen. After
## everyone's assembled in their spot, then combat begins." That's a
## strictly SEQUENCED beat (party settles -> enemies arrive -> combat
## starts), not the earlier concurrent design -- split what used to be one
## function into three so GameController can hold each stage until the
## previous one has actually finished:
##   1. _stage_enemies_offscreen() (below) -- snaps every enemy view
##      off-screen-right and hides its chrome, called from start_battle
##      BEFORE this frame ever draws (same "invisible snap" idiom
##      _layout_units's own placement already relies on), so enemies exist
##      in the scene but are nowhere visible yet.
##   2. run_enemies_entering() -- actually starts each one's run-in tween.
##      Called only once GameController has confirmed the party has fully
##      stopped moving.
##   3. begin_combat() -- starts the actual battle loop. Called only once
##      GameController has waited out ENEMY_RUN_IN_TIME, so the first beat
##      never animates while an enemy is still mid-arrival.
func _stage_enemies_offscreen() -> void:
	for view in unit_views_by_id.values():
		if view.unit["isParty"]:
			continue
		view.position = Vector2(_vp.x + view.size * 2.0, view.rest_position.y)
		view.hide_chrome()

func run_enemies_entering() -> void:
	for view in unit_views_by_id.values():
		if view.unit["isParty"]:
			continue
		var tw := create_tween()
		tw.tween_property(view, "position", view.rest_position, ENEMY_RUN_IN_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.finished.connect(view.fade_in_chrome)

func begin_combat() -> void:
	_run_battle_loop()

## Called by GameController when the viewport's real size changes (window
## resize, or a device with a different aspect ratio than assumed at
## startup) -- rebuilds the STATIC chrome (enrage bar, Status/Log icons,
## turn-order cards) fresh against the new size, AND repositions the
## currently-live UnitViews (see _reposition_units) -- confirmed live that
## leaving them alone was a real bug, not just a cosmetic one-beat delay:
## dragging the window mid-fight could leave a unit rendered fully outside
## the new visible area until the next wave, not just slightly offset.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	_recompute_field_fractions()

	if enrage_bg: enrage_bg.queue_free()
	if enrage_fg: enrage_fg.queue_free()
	if enrage_label: enrage_label.queue_free()
	if status_icon_btn: status_icon_btn.queue_free()
	if log_icon_btn: log_icon_btn.queue_free()
	if turn_order_header: turn_order_header.queue_free()
	if turn_order_frame: turn_order_frame.queue_free()
	for card in turn_cards:
		if card["panel"]: card["panel"].queue_free()
	turn_cards.clear()
	if wave_progress_label: wave_progress_label.queue_free()
	for entry in wave_progress_circles:
		if entry["panel"]: entry["panel"].queue_free()
	wave_progress_circles.clear()

	# Icons only, NOT _build_status_ui()/_build_log_ui() -- those also build
	# status_popup/log_popup, which are built exactly once and must not be
	# duplicated/orphaned by a reflow.
	_build_wave_progress_ui()
	_refresh_wave_progress(_cleared_waves_cache)   # a resize carries no fresh save data -- reapply the cached state
	_build_enrage_ui()
	_build_status_icon()
	_build_log_icon()
	_build_turn_order_ui()
	_reposition_units()
	_refresh_turn_order()
	_refresh_enrage()
	_refresh_charge_bars()

## Re-runs _layout_units()'s own front/back grouping and _place_side()
## placement against the EXISTING UnitViews (not creating new ones) so a
## live fight's units snap to the new field bounds instead of staying at
## their old (now possibly offscreen) positions. This overwrites .position
## directly even if a Tween is mid-hop -- a resize is rare enough, and
## "unit stuck offscreen until next wave" bad enough, that a possible
## one-frame visual snap during the hop is the right tradeoff.
func _reposition_units() -> void:
	var party_front := []
	var party_back := []
	var enemy_front := []
	var enemy_back := []
	for view in unit_views_by_id.values():
		var u: Dictionary = view.unit
		if u["isParty"]:
			(party_front if u.get("row") == "front" else party_back).append(view)
		else:
			(enemy_front if u.get("row") == "front" else enemy_back).append(view)
	_place_side(party_front, party_back, party_front_x, party_back_x, false)
	_place_side(enemy_front, enemy_back, enemy_front_x, enemy_back_x, true)

## Group I (20-item batch): per-unit, not a single global constant -- a
## boss (u["isBoss"]) reads BOSS_SIZE_MUL bigger, and an archetype's own
## optional `size` CSV field (FarroadCore.ARCH[u["arch"]]["size"], default
## 1.0 -- content-pipeline.js's compileArch, omitted when the archetype is
## normal-sized) scales it further. A party member (no "arch") or an
## archetype with no size override both fall back to the plain base size,
## identical to every unit's size before this change.
const BOSS_SIZE_MUL := 1.5
func _unit_size(u: Dictionary) -> float:
	var base: float = _vp.y * 0.05
	var arch_mul: float = 1.0
	var arch_key = u.get("arch")
	if arch_key != null and FarroadCore.ARCH.has(arch_key):
		arch_mul = float(FarroadCore.ARCH[arch_key].get("size", 1.0))
	var boss_mul: float = BOSS_SIZE_MUL if u.get("isBoss", false) else 1.0
	return base * arch_mul * boss_mul

const JOIN_HOP_TIME := 0.5

## Called by GameController right after a PartyPanel bench/field edit --
## `added` (from FarroadProgression.refresh_live_party's own "added" key)
## is every unit JUST fielded into the live fight; `removed` (its own
## "removed" key) is every uid JUST benched (now actually gone from
## g["units"]/g["battle"]["units"], not just zeroed -- see that function's
## own comment for why). Builds a UnitView for each newly-fielded unit,
## re-runs _reposition_units() (which already re-places EVERY currently-
## tracked view, existing ones included, by row/side -- not
## _layout_units(), which would build a SECOND, orphaned view for units
## already on the field) to compute everyone's correct target position,
## then -- rather than leaving a new unit snapped straight to that
## position -- starts it off at the SAME Y but offscreen to the left and
## tweens it in; a removed unit's existing view gets the mirror treatment
## (tweened out to offscreen-left, THEN actually freed and untracked, not
## just left dimmed in place). Matches this project's own established
## hop/tween idiom (create_tween()/tween_property, same as the attack-hop
## animation) rather than inventing a new one.
func sync_live_party(added: Array, removed: Array = []) -> void:
	var new_views := []
	for u in added:
		var view := UnitView.new()
		view.setup(u, _unit_size(u))
		add_child(view)
		view.attach_chrome_to(_bar_layer)
		unit_views_by_id[u["id"]] = view
		unit_views_by_name[u["name"]] = view
		view.tapped.connect(_on_unit_tapped.bind(u["id"]))
		new_views.append(view)
	var leaving_views := []
	for uid in removed:
		var view: UnitView = unit_views_by_id.get(uid)
		if view != null:
			leaving_views.append(view)
			unit_views_by_id.erase(uid)
			unit_views_by_name.erase(view.unit["name"])
	_reposition_units()   # computes + sets the correct final position for every REMAINING tracked view
	for view in new_views:
		var target: Vector2 = view.position
		view.position = Vector2(-view.size, target.y)
		var tw := create_tween()
		tw.tween_property(view, "position", target, JOIN_HOP_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for view in leaving_views:
		var start_y: float = view.position.y
		var tw := create_tween()
		tw.tween_property(view, "position", Vector2(-view.size, start_y), JOIN_HOP_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.finished.connect(view.queue_free)
	for view in unit_views_by_id.values():
		view.update_hp()

## Called by GameController right after a PartyPanel front/back row toggle
## (post-Milestone-3 APK feedback, Group A1) -- replaces the earlier
## "self-corrects within one wave" tradeoff with a real live hop. The
## mover's own UnitView is still at its OLD slot when this runs; snapshot
## that, re-run _reposition_units() (which re-places EVERY tracked view,
## including the mover, by its now-updated `row` -- same shared recompute
## sync_live_party's own hop already uses), then tween just the mover from
## its old position to the freshly computed new one. Every OTHER view gets
## snapped instantly by _reposition_units() too, but harmlessly -- only the
## mover's own row changed, so only its own slot actually moved.
func hop_to_new_row(uid: String) -> void:
	var view: UnitView = unit_views_by_id.get(uid)
	if view == null:
		return
	var start: Vector2 = view.position
	_reposition_units()
	var target: Vector2 = view.position
	if start == target:
		return
	view.position = start
	var tw := create_tween()
	tw.tween_property(view, "position", target, JOIN_HOP_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

## Called by GameController right after a MC rename (post-batch feedback:
## "add a button to change our main character's name") -- the live unit
## dict's own "name" field is already updated by FarroadProgression.
## set_mc_name (same shared-reference reasoning sync_loadout/
## set_mc_charge_action rely on), but the on-field UnitView's own name
## label was only ever set once at build time, and unit_views_by_name's
## dict KEY would otherwise go stale -- a future event's target-name
## lookup (e.g. _apply_status_notes) reads the unit's already-renamed
## live name, which would miss the OLD key entirely.
func sync_mc_name(old_name: String, new_name: String) -> void:
	var view: UnitView = unit_views_by_id.get("kesh")
	if view == null:
		return
	view.update_name(new_name)
	if unit_views_by_name.get(old_name) == view:
		unit_views_by_name.erase(old_name)
	unit_views_by_name[new_name] = view

## The MC's body changed in the menu: rebuild just that unit's view with
## the other sprite set, in place (same size, same spot, live HP/charge).
func sync_mc_body() -> void:
	var view: UnitView = unit_views_by_id.get("kesh")
	if view == null:
		return
	view.resize(view.size)
	view.update_hp()
	view.update_charge()

func _layout_units(units: Array) -> void:
	var party_front := []
	var party_back := []
	var enemy_front := []
	var enemy_back := []
	for u in units:
		var view := UnitView.new()
		view.setup(u, _unit_size(u))
		add_child(view)
		view.attach_chrome_to(_bar_layer)
		unit_views_by_id[u["id"]] = view
		unit_views_by_name[u["name"]] = view
		view.tapped.connect(_on_unit_tapped.bind(u["id"]))
		if u["isParty"]:
			(party_front if u.get("row") == "front" else party_back).append(view)
		else:
			(enemy_front if u.get("row") == "front" else enemy_back).append(view)
	_place_side(party_front, party_back, party_front_x, party_back_x, false)
	_place_side(enemy_front, enemy_back, enemy_front_x, enemy_back_x, true)

## Assigns every unit on ONE side a Y position -- each reserving a vertical
## band proportional to its own field size (_unit_size), not an equal
## slice everyone shares regardless of how big they actually are (Group I,
## 20-item batch: "make bosses bigger" needs the boss to actually GET more
## room, not just draw a bigger shape squeezed into the same slot).
##
## allow_shared_rows=false (party) keeps the original no-two-units-ever-
## share-a-row guarantee: front and back interleaved into ONE combined list
## in the order they get slots, then laid out as one weighted column.
## allow_shared_rows=true (enemies) instead lays front and back out as TWO
## INDEPENDENT weighted columns, each spanning the full field height on its
## own -- restores the pre-interleaving behavior specifically for enemies,
## so e.g. a 1-front/1-back pair can land at the identical Y (directly
## behind each other), freeing vertical room for a bigger boss sprite, per
## Ian's own "saves space" reasoning.
func _place_side(front: Array, back: Array, front_x: float, back_x: float, allow_shared_rows: bool) -> void:
	if allow_shared_rows:
		_place_column(front, front_x)
		_place_column(back, back_x)
		return
	var views := []   # combined, in the Y order they'll be assigned
	var xs := []
	var fi := 0
	var bi := 0
	while fi < front.size() or bi < back.size():
		if fi < front.size():
			views.append(front[fi]); xs.append(front_x); fi += 1
		if bi < back.size():
			views.append(back[bi]); xs.append(back_x); bi += 1
	_place_weighted(views, xs)

## One row/back's own independent weighted column, all at the same X.
func _place_column(views: Array, x: float) -> void:
	var xs := []
	for i in range(views.size()):
		xs.append(x)
	_place_weighted(views, xs)

## Real vertical footprint a UnitView of this `size` actually occupies --
## shape + HP bar + charge bar + name label, using the exact same gap/
## bar_h/charge_h formula UnitView.setup() itself uses. A direct-
## measurement debug script caught that weighting _place_weighted purely
## by raw shape size (_unit_size()) badly underestimates a unit's true
## on-screen footprint -- the bars/label add real height that does NOT
## shrink proportionally with a smaller shape (a Label's own minimum line
## height in particular isn't linear in font size), so a boss-sized unit
## sharing a column with several normal ones measured as genuinely
## overlapping its neighbor. Probing a real Label's own get_minimum_size()
## (not added to the tree -- font metrics don't require that) rather than
## hand-deriving a multiplier is the same "measure, don't guess" discipline
## this project already applies everywhere else.
func _unit_footprint_height(size: float) -> float:
	var bar_h: float = max(4.0, size * 0.12)
	var charge_h: float = max(2.0, bar_h * 0.5)
	var gap: float = max(1.0, size * 0.05)
	var probe := Label.new()
	probe.add_theme_font_size_override("font_size", int(size * 0.25))
	probe.text = "Wg"
	var label_h: float = probe.get_minimum_size().y
	probe.free()
	return size + gap + bar_h + gap + charge_h + gap + label_h

## Lays `views` out top-to-bottom across (field_top, field_bottom), each
## reserving a vertical band proportional to its own real footprint
## (_unit_footprint_height) -- NOT raw shape size -- so a bigger unit's
## reserved band always covers its own actual on-screen extent, not just
## a size-proportional slice of it (see _unit_footprint_height's own
## comment for why raw size alone isn't safe here).
##
## If the column's total real footprint still exceeds the available field
## height even at natural size (a direct-measurement debug script found a
## real, reachable case: hard-mode's up-to-10-enemy rolls can put several
## of the biggest non-boss archetype, e.g. 5x "ox" at 1.25x, in one
## column) -- uniformly RESIZES every view in the column down by the
## overflow ratio first (UnitView.resize(), not just a smaller reserved
## band), then re-measures footprints at the new size before laying out,
## so the reserved bands stay honest about what's actually on screen
## rather than just packing oversized sprites into too-small slots.
## Footprint isn't perfectly linear in size (the bar-height/gap floors and
## a Label's own minimum-size metrics both flatten out at small sizes), so
## one shrink pass alone can slightly undershoot -- iterates (capped, same
## direct-measurement debug script confirmed 4 passes converges comfortably
## from the worst realistic case) rather than trusting a single estimate.
func _place_weighted(views: Array, xs: Array) -> void:
	if views.is_empty():
		return
	var avail: float = field_bottom - field_top
	var weights := _footprint_weights(views)
	var total: float = 0.0
	for w in weights:
		total += w
	var guard := 0
	while total > avail and guard < 6:
		guard += 1
		# A slight extra nudge (0.99) past the exact ratio biases each pass
		# toward converging from above rather than asymptotically
		# approaching zero margin from below.
		var shrink: float = (avail / total) * 0.99
		for view in views:
			view.resize(view.size * shrink)
		weights = _footprint_weights(views)
		total = 0.0
		for w in weights:
			total += w
	var y := field_top
	for i in range(views.size()):
		var band: float = avail * (weights[i] / total)
		var pos := Vector2(xs[i], y + band / 2.0)
		views[i].position = pos
		views[i].rest_position = pos
		y += band

func _footprint_weights(views: Array) -> Array:
	var weights := []
	for view in views:
		weights.append(_unit_footprint_height(view.size))
	return weights

const PARTY_COLOR := "2e578f"
const ENEMY_COLOR := "9e3329"
const BAD_COLOR := "9e3329"
const CRIT_COLOR := "bd6b14"
const DIM_COLOR := "786147"
const NOTE_COLOR := "75578f"

## Display names/glyphs for FarroadCore.ST's 14 status ids -- purely
## presentation, mirrors nothing in the engine (FarroadCore.gd has no
## display-name table for these, same reasoning as PREF_TEXT above).
const STATUS_NAMES := {
	"sundered": "Sundered", "frail": "Frail", "enfeebled": "Enfeebled",
	"dulled": "Dulled", "slowed": "Slowed", "blinded": "Blinded",
	"burning": "Burning", "hasted": "Hasted", "warded": "Warded",
	"taunted": "Taunted", "surging": "Surging", "bracing": "Bracing",
	"regen": "Regen", "blurred": "Blurred"}
const STATUS_GLYPH := {
	"sundered": "🛡", "frail": "🛡", "enfeebled": "💪", "dulled": "🔮",
	"slowed": "🐌", "blinded": "👁", "burning": "🔥", "hasted": "💨",
	"warded": "🛡", "taunted": "⚠", "surging": "⚡", "bracing": "🛡",
	"regen": "✚", "blurred": "💨"}

## Flavor text for a non-party unit's row tag -- mirrors PREF_TEXT
## (farroad-core.js:531-533), which this port only kept as numeric weights
## (pref_weight) since nothing needed the display strings until now.
const PREF_TEXT := {"wolf": "lunges at whoever is hurt", "knight": "engages the front line",
	"hound": "darts past the line at your back rank", "ox": "indiscriminate",
	"priest": "opportunist — prefers the wounded", "shrike": "indiscriminate"}

var status_popup: PopupPanel
var status_container: VBoxContainer

## "Unit status screens like the original implementation" -- mirrors
## renderUnits()'s per-unit card (farroad-ui.js:1683-1729) structurally:
## name+level+row tag, HP text+bar, charge action name+bar, one combined
## ATK/MAG/SPD/DEF/RES line (DEF/RES colored to flag the lower of the two,
## no separate hint sentence), a weakness line, and (party only)
## a RECOVERY line. Rebuilt fresh each time the popup opens, reading live
## unit data at that moment, rather than kept continuously in sync while
## hidden.
## The default theme's PopupPanel background wasn't fully opaque -- with the
## battle animating behind it, both popups were hard to read. Forces a solid,
## fully-opaque panel (alpha 1.0) on both, rather than relying on the theme
## default.
func _style_popup(popup: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	popup.add_theme_stylebox_override("panel", style)

## A tab square -- eventually a blank placeholder standing in for real art
## (same "placeholder shape until sprites exist" convention UnitView's own
## Polygon2D shapes already use), but FOR NOW showing its label directly ON
## the button (`btn.text`) rather than a separate caption Label below it --
## a caption positioned below a small, corner-anchored square is exactly
## the kind of element that can land partly or fully outside the visible
## window when the screen is resized smaller (confirmed live: "the text
## under the buttons will also fall off screen"), whereas text INSIDE the
## button's own already-correctly-bounded rect can't independently drift
## off it. `size` is in PIXELS (already resolved from a viewport fraction
## by the caller) and applied to both dimensions so it's always a true
## square regardless of the screen's aspect ratio.
## icon, when provided, shows a real icon texture instead of/alongside
## the placeholder text -- every EXISTING call site passes no icon
## (unchanged behavior) until real button art exists (Ian: "prepare for
## real button/icon assets").
func _build_icon_tab(pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	var btn := Button.new()
	btn.text = label_text
	if icon != null:
		btn.icon = icon
		btn.expand_icon = true
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Palette.BTN_NORMAL
	normal_style.set_corner_radius_all(int(size / 2.0))
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Palette.BTN_HOVER
	hover_style.set_corner_radius_all(int(size / 2.0))
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.pressed.connect(callback)
	add_child(btn)
	return btn

## Split from the popup itself (below) so reflow() can rebuild just the
## icon at a new size/position without also rebuilding (and thereby
## orphaning/duplicating) the popup, which is built exactly once.
## Shared row/position math for the Status/Log icons -- right-aligned,
## sitting just above the turn-order frame's own top edge
## (TURN_ORDER_FRAME_TOP_FRAC) rather than beside the enrage gauge, which
## used to cap how wide that gauge could be. slot 0 = Status (left of the
## pair), slot 1 = Log (right of the pair, flush with the right margin).
## Computed from the FRACTION, not the live turn_order_frame node, so build
## order between the icons and the frame itself doesn't matter.
func _status_log_row_pos(slot: int) -> Vector2:
	var icon_size: float = _vp.x * STATUS_LOG_ICON_FRAC
	var margin: float = _vp.x * 0.016
	var gap: float = _vp.x * 0.02
	var row_gap: float = _vp.y * 0.01
	var row_y: float = _vp.y * TURN_ORDER_FRAME_TOP_FRAC - icon_size - row_gap
	var log_x: float = _vp.x - margin - icon_size
	var status_x: float = log_x - gap - icon_size
	return Vector2(status_x if slot == 0 else log_x, row_y)

func _build_status_icon() -> void:
	var icon_size: float = _vp.x * STATUS_LOG_ICON_FRAC
	status_icon_btn = _build_icon_tab(_status_log_row_pos(0), icon_size, "Status", _on_status_pressed)

func _build_status_ui() -> void:
	_build_status_icon()

	status_popup = PopupPanel.new()
	_style_popup(status_popup)
	add_child(status_popup)

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	status_popup.add_child(scroll)

	status_container = VBoxContainer.new()
	status_container.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	status_container.add_theme_constant_override("separation", 14)
	scroll.add_child(status_container)

func _on_status_pressed() -> void:
	status_filter_uid = ""
	_refresh_status_popup()
	status_popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))

## Ian: "tapping on a unit in the battle should show its stats page,
## live." Opens the SAME Status popup, just filtered down to the one
## tapped unit -- reuses _refresh_status_popup's existing per-beat live
## refresh (_run_battle_loop's own `if status_popup.visible:` calls),
## so the single card keeps tracking the fight for as long as it's open,
## same as the full list already did.
func _on_unit_tapped(uid: String) -> void:
	status_filter_uid = uid
	_refresh_status_popup()
	status_popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))

## Rebuilds card(s) from LIVE battle data -- called on open, and then
## every beat for as long as it stays open (see _run_battle_loop), so HP/
## charge/the active-unit border actually track the fight instead of
## freezing at whatever the battle looked like the moment it was opened.
## status_filter_uid empty (the default, and what the Status button
## always resets it to) shows every unit; set, shows just that one.
func _refresh_status_popup() -> void:
	for c in status_container.get_children():
		c.queue_free()
	for u in battle["units"]:
		if status_filter_uid != "" and u["id"] != status_filter_uid:
			continue
		status_container.add_child(_build_status_card(u))

func _build_status_card(u: Dictionary) -> Control:
	var card := PanelContainer.new()
	if u["id"] == active_unit_id:
		var style := StyleBoxFlat.new()
		style.bg_color = Palette.BG_PARCHMENT_DEEP
		style.border_color = Palette.GOLD_LIGHT
		style.set_border_width_all(3)
		style.set_content_margin_all(10)
		card.add_theme_stylebox_override("panel", style)
	else:
		var style := StyleBoxFlat.new()
		style.bg_color = Palette.BG_PARCHMENT_DEEP
		style.set_content_margin_all(10)
		card.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	card.add_child(box)

	var header := HBoxContainer.new()
	var color: String = PARTY_COLOR if u["isParty"] else ENEMY_COLOR
	var level: int = u["level"] if u["isParty"] else roundi(FarroadCore.level_curve(FarroadCore.current_wave))
	# Ian: "reduce First boss level to 10." Display-only override, scoped
	# exactly like FIRST_BOSS_LEN/FIRST_BOSS_HARD_EXTRA/FIRST_BOSS_DMG_MUL
	# (the wave-20 boss's own dedicated softening constants) -- the
	# underlying level_curve/waveScale stat math is untouched, only the
	# number shown on this card for that one specific fight.
	if not u["isParty"] and u.get("isBoss") and FarroadCore.current_wave == FarroadProgression.BOSS_WAVES[0]:
		level = 10
	var row_tag: String = ""
	if u["isParty"]:
		row_tag = "FRONT" if u.get("row") == "front" else "BACK"
	else:
		row_tag = "boss" if u.get("isBoss") else PREF_TEXT.get(u.get("arch"), "")
	var left := _rich_line("[b][color=#%s][font_size=20]%s[/font_size][/color][/b]  Lv%d%s" % [
		color, u["name"], level, ("  [color=#382617]%s[/color]" % row_tag) if row_tag != "" else ""])
	header.add_child(left)
	var hp_lbl := Label.new()
	hp_lbl.text = "%d / %d" % [max(0, roundi(u["hp"])), u["maxHp"]]
	header.add_child(hp_lbl)
	box.add_child(header)

	var hp_bg := ColorRect.new()
	hp_bg.custom_minimum_size = Vector2(0, 10)
	hp_bg.color = Palette.BORDER_LEATHER
	box.add_child(hp_bg)
	var hp_fg := ColorRect.new()
	var hp_frac: float = clamp(float(u["hp"]) / float(u["maxHp"]), 0.0, 1.0)
	# Anchored to hp_bg's own actual size (not a size borrowed from a sibling
	# container) -- a fixed-pixel width computed from status_container's
	# minimum size ignored the card's own content margins and overflowed
	# past the bar at high fractions. Anchors always match the true rect.
	hp_fg.anchor_right = hp_frac
	hp_fg.anchor_bottom = 1.0
	hp_fg.color = Palette.GOOD_GREEN
	hp_bg.add_child(hp_fg)

	if u.get("chargeAction"):
		var act = FarroadCore.ACTIONS.get(u["chargeAction"])
		var charge_row := HBoxContainer.new()
		var incoming: String = " — INCOMING" if (not u["isParty"] and u["charge"] >= 70) else ""
		var charge_left := _rich_line("[color=#%s]⚡ %s%s[/color]" % [
			DIM_COLOR if u["isParty"] else BAD_COLOR, act["name"] if act != null else u["chargeAction"], incoming])
		charge_row.add_child(charge_left)
		var charge_num := Label.new()
		charge_num.text = "%d/100" % roundi(u["charge"])
		charge_row.add_child(charge_num)
		box.add_child(charge_row)

		var ch_bg := ColorRect.new()
		ch_bg.custom_minimum_size = Vector2(0, 6)
		ch_bg.color = Palette.BORDER_LEATHER
		box.add_child(ch_bg)
		var ch_fg := ColorRect.new()
		# Matches the ORIGINAL UI's own display convention exactly (farroad-ui.js:1711):
		# clamped against a flat 100, not this unit's own real costOfCharge --
		# the original shows e.g. "115/100" as a full bar plus an honest
		# over-100 number, it does not read against the actual adjusted cost.
		var ch_frac: float = clamp(float(u["charge"]) / 100.0, 0.0, 1.0)
		# Anchored to ch_bg's own actual size -- see hp_fg's comment above for
		# why a fixed-pixel width overflowed past the bar at high fractions.
		ch_fg.anchor_right = ch_frac
		ch_fg.anchor_bottom = 1.0
		ch_fg.color = Palette.GOLD if u["isParty"] else Palette.BAD_RED
		ch_bg.add_child(ch_fg)

	# ATK/MAG/SPD and DEF/RES on one combined line -- DEF/RES still color the
	# lower of the two via _def_res_hint (unchanged), just without the
	# trailing "X lands harder" sentence that used to follow it on its own
	# line.
	var dr := _def_res_hint(u)
	box.add_child(_rich_line(
		"[font_size=13]ATK %d MAG %d SPD %d [color=#%s]DEF %d[/color] [color=#%s]RES %d[/color][/font_size]" % [
			roundi(FarroadCore.eff_atk(u)), roundi(FarroadCore.eff_mag(u)), roundi(u["base"]["spd"]),
			(CRIT_COLOR if dr["flag_d"] else "382617"), roundi(dr["def"]),
			(CRIT_COLOR if dr["flag_r"] else "382617"), roundi(dr["res"])]))

	# Active status effects (burning, bracing, enfeebled, etc.) -- one line
	# per currently-active id (turns remaining > 0), reusing the same
	# buff/debuff color split _apply_status_notes' on-field popups already
	# use, so a unit's status page and its floating "Bracing"/"Frail" popups
	# read consistently.
	for id in FarroadCore.ST:
		if FarroadCore.has(u, id):
			var is_buff: bool = FarroadCore.is_buff_status(id)
			var status_color := "80d9ff" if is_buff else "d980ff"
			var turns: int = int(u["st"][id])
			box.add_child(_rich_line("[font_size=12][color=#%s]%s %s[/color] [color=#%s]— %s%s[/color][/font_size]" % [
				status_color, STATUS_GLYPH.get(id, "●"), STATUS_NAMES.get(id, id.capitalize()),
				DIM_COLOR, _status_effect_text(u, id), "" if turns <= 0 else " (%d turn%s)" % [turns, "" if turns == 1 else "s"]]))

	var weak := []
	for ax in ["fire", "water", "earth", "air", "light", "dark", "body", "spirit"]:
		if float(u.get("affinity", {}).get(ax, 0.0)) < 0:
			weak.append(ax.capitalize())
	if not weak.is_empty():
		box.add_child(_rich_line("[font_size=12][color=#%s]Weak to: %s[/color][/font_size]" % [BAD_COLOR, ", ".join(weak)]))

	if u["isParty"]:
		# No progression/Aether-investment layer ported yet (out of this
		# milestone's scope -- see the plan) -- shown honestly at its
		# unmodified baseline rather than a fabricated number.
		box.add_child(_rich_line("[font_size=12][color=#%s]RECOVERY 0%%[/color] [color=#%s]— HP regained between waves[/color][/font_size]" % ["336b28", DIM_COLOR]))
	elif battle.get("enrage"):
		# Stacks are battle-wide (battle["enrageN"], rising once per turn
		# regardless of who acts) -- every enemy shows the SAME stack count
		# once the gate is open; an enemy just hasn't caught its own stats up
		# to it yet if it hasn't acted since the count last rose.
		var stacks: int = int(battle.get("enrageN", 0))
		var beat: int = battle["beat"]
		var enrage_text: String
		if stacks > 0:
			enrage_text = "⏱ ENRAGED ×%d — +%d%% damage/speed, rising every turn" % [
				stacks, roundi(FarroadCore.ENRAGE_PCT * stacks * 100.0)]
		else:
			enrage_text = "⏱ calm — enrages at turn %d" % FarroadCore.ENRAGE_AFTER
		box.add_child(_rich_line("[font_size=12][color=#%s]%s[/color][/font_size]" % [BAD_COLOR if stacks > 0 else DIM_COLOR, enrage_text]))

	return card

## Mirrors defResPair (farroad-ui.js:1638-1651) -- EFFECTIVE DEF/RES, the
## lower one flagged only when the gap is >=15% (a smaller gap is noise).
func _def_res_hint(u: Dictionary) -> Dictionary:
	var d: float = FarroadCore.eff_def(u)
	var r: float = FarroadCore.eff_res(u)
	var lo: float = min(d, r)
	var hi: float = max(d, r)
	var gap: float = (hi - lo) / hi if hi > 0 else 0.0
	var flag_d: bool = gap >= 0.15 and d < r
	var flag_r: bool = gap >= 0.15 and r < d
	return {"def": d, "res": r, "flag_d": flag_d, "flag_r": flag_r}

## A short, real-mechanic-accurate effect summary for one of FarroadCore.ST's
## 14 statuses, read off the unit's OWN live magnitude (FarroadCore.mag_of --
## already correctly reflects any per-cast stMag override from the caster's
## Spirit affinity, not just the flat STATUS_BASE_MAG constant). Matches each
## status's REAL mechanic exactly as read from FarroadCore.gd (eff_atk/
## eff_mag/eff_def/eff_res/eff_evade/eff_charge_rate/tc_of/incoming_mul/
## threat_of/resolve_hit), not a guessed description:
## - burning/regen are stored as a POSITIVE magnitude representing the DOT/
##   HOT %-of-maxHp amount (see step()'s own e["dot"]/e["regen"] math) --
##   burning is flipped negative here since it's harmful, regen shown positive.
## - blinded's +30% enemy-evade-chance and taunted's threat multiplier are
##   flat literals in resolve_hit()/threat_of(), never stored in
##   STATUS_BASE_MAG, so they're not derived from mag_of() at all.
func _status_effect_text(u: Dictionary, id: String) -> String:
	var mag: float = FarroadCore.mag_of(u, id)
	var pct: float = mag * 100.0
	match id:
		"sundered", "bracing":
			return "DEF %+.0f%%" % pct
		"frail":
			return "RES %+.0f%%" % pct
		"enfeebled":
			return "ATK %+.0f%%" % pct
		"dulled":
			return "MAG %+.0f%%" % pct
		"slowed", "hasted":
			return "%+.0f%% turn cost" % pct
		"warded":
			return "%+.0f%% dmg taken" % pct
		"surging":
			return "%+.0f%% charge rate" % pct
		"blurred":
			return "%+.0f%% evade" % pct
		"burning":
			return "-%.0f%% max HP/turn" % pct
		"regen":
			return "+%.0f%% max HP/turn" % pct
		"blinded":
			return "attacks 30% more likely to miss"
		"taunted":
			return "draws enemy focus"
		_:
			return ""

## Split from the popup itself (below) for the same reason
## _build_status_icon() is split from _build_status_ui() -- see its comment.
func _build_log_icon() -> void:
	# Right of the Status icon, same row -- see _status_log_row_pos().
	var icon_size: float = _vp.x * STATUS_LOG_ICON_FRAC
	log_icon_btn = _build_icon_tab(_status_log_row_pos(1), icon_size, "Log", _on_log_pressed)

func _build_log_ui() -> void:
	_build_log_icon()

	log_popup = PopupPanel.new()
	_style_popup(log_popup)
	add_child(log_popup)

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.75)
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = popup_size - Vector2(20, 20)
	log_popup.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "BATTLE LOG"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	pause_log_btn = Button.new()
	pause_log_btn.text = "Pause"
	pause_log_btn.toggle_mode = true
	pause_log_btn.toggled.connect(_on_log_pause_toggled)
	header.add_child(pause_log_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	clear_btn.pressed.connect(_on_clear_pressed)
	header.add_child(clear_btn)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 60)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	log_container = VBoxContainer.new()
	log_container.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	log_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(log_container)

func _on_log_pressed() -> void:
	_rebuild_log_container()
	log_popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.75))

func _on_clear_pressed() -> void:
	log_lines.clear()
	_rebuild_log_container()

func _on_log_pause_toggled(paused: bool) -> void:
	log_paused = paused
	pause_log_btn.text = "Resume" if paused else "Pause"
	if not paused and log_popup != null and log_popup.visible:
		_rebuild_log_container()

## Rebuilds every entry's Control block from scratch, newest first (mirrors
## logEntry()'s insertBefore(d, L.firstChild)). A real HBoxContainer per
## header row -- not a BBCode [table] -- is what actually pins the damage
## figure to the panel's right edge: RichTextLabel tables size columns to
## their own content, they don't stretch a column out to the container's
## far edge, which is why the first pass's table-based attempt didn't
## visibly right-align. An HBoxContainer's first child expanding to fill
## does that reliably.
func _rebuild_log_container() -> void:
	for c in log_container.get_children():
		c.queue_free()
	for i in range(log_lines.size() - 1, -1, -1):
		log_container.add_child(_build_log_entry_node(log_lines[i]))
		log_container.add_child(HSeparator.new())

func _rich_line(bbcode: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.text = bbcode
	return r

func _build_log_entry_node(entry: Dictionary) -> Control:
	var box := VBoxContainer.new()

	var header := HBoxContainer.new()
	header.add_child(_rich_line(entry["head_bbcode"]))
	var dmg := Label.new()
	dmg.text = entry["dmg_text"]
	dmg.add_theme_font_size_override("font_size", 20)
	header.add_child(dmg)
	box.add_child(header)

	box.add_child(_rich_line(entry["via_bbcode"]))

	if entry["calc"] != "":
		var btn := Button.new()
		btn.flat = true
		btn.text = "tap for the damage breakdown"
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", Palette.TEXT_DIM)
		btn.add_theme_color_override("font_hover_color", Palette.TEXT_INK)
		box.add_child(btn)
		var calc_line := _rich_line("[font_size=12][color=#%s]%s[/color][/font_size]" % [DIM_COLOR, entry["calc"]])
		calc_line.visible = entry["expanded"]
		box.add_child(calc_line)
		# Captures `entry` (a Dictionary -- a reference type in GDScript) by
		# reference, so toggling it here correctly mutates the SAME dict
		# still held in log_lines -- mirrors logEntry()'s own d.onclick
		# toggling a class on that same log entry (farroad-ui.js:1804).
		# Flips only THIS entry's own expanded flag and its own calc line's
		# visibility -- deliberately NOT a full _rebuild_log_container() call
		# (the earlier version's approach), which re-pulls the CURRENT
		# log_lines wholesale and would silently undo a log pause: opening a
		# damage breakdown while paused shouldn't jump the whole list back
		# to whatever accumulated in the background since.
		btn.pressed.connect(func():
			entry["expanded"] = not entry["expanded"]
			calc_line.visible = entry["expanded"])

	for note_bbcode in entry["note_bbcodes"]:
		box.add_child(_rich_line(note_bbcode))

	return box

## Ian: "just above the Enrage bar, have 20 small circles, one for each
## wave and the boss at the end that is slightly bigger. Completing a
## wave 'lights up' its related circle as the party runs to the next
## encounter. Just above the line of circles have a small line of text
## that shows the current wave." WAVE_PROGRESS_COUNT matches
## FarroadProgression.BOSS_EVERY -- one circle per wave of the CURRENT
## boss-to-boss stretch, the last (bigger) one being its boss. See
## _refresh_wave_progress for how it tracks/resets (24-item batch, Group D4).
const WAVE_PROGRESS_COUNT := 20
var wave_progress_label: Label
var wave_progress_circles: Array = []   # [{"panel": Panel, "style": StyleBoxFlat, "wave": int}, ...]
var _cleared_waves_cache: Dictionary = {}

func _build_wave_progress_ui() -> void:
	var status_pos: Vector2 = _status_log_row_pos(0)
	var icon_size: float = _vp.x * STATUS_LOG_ICON_FRAC
	var margin: float = _vp.x * 0.016
	var end_gap: float = _vp.x * 0.03
	var bar_h: float = _vp.y * 0.012
	var enrage_y: float = status_pos.y + (icon_size - bar_h) / 2.0
	var enrage_top: float = enrage_y - _vp.y * 0.026
	var row_w: float = status_pos.x - end_gap - margin

	var circle_d: float = minf(_vp.y * 0.016, row_w / float(WAVE_PROGRESS_COUNT) * 0.72)
	var boss_d: float = circle_d * 1.35
	var circle_gap: float = _vp.y * 0.008
	var circle_row_y: float = enrage_top - circle_gap - boss_d

	wave_progress_label = Label.new()
	wave_progress_label.add_theme_font_size_override("font_size", int(_vp.y * 0.016))
	wave_progress_label.modulate = Color(0.65, 0.65, 0.65)
	wave_progress_label.position = Vector2(margin, circle_row_y - _vp.y * 0.005 - _vp.y * 0.02)
	add_child(wave_progress_label)

	wave_progress_circles.clear()
	var slot_w: float = row_w / float(WAVE_PROGRESS_COUNT)
	for i in range(WAVE_PROGRESS_COUNT):
		var w_num: int = i + 1
		var is_boss: bool = w_num == WAVE_PROGRESS_COUNT
		var d: float = boss_d if is_boss else circle_d
		var cx: float = margin + slot_w * i + (slot_w - d) / 2.0
		var cy: float = circle_row_y + (boss_d - d) / 2.0   # bottom-aligned against the taller boss slot
		var panel := Panel.new()
		panel.position = Vector2(cx, cy)
		panel.custom_minimum_size = Vector2(d, d)
		panel.size = Vector2(d, d)
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(int(d / 2.0))
		style.bg_color = _wave_circle_color(false)
		panel.add_theme_stylebox_override("panel", style)
		add_child(panel)
		wave_progress_circles.append({"panel": panel, "style": style, "wave": w_num})

func _wave_circle_color(lit: bool) -> Color:
	return Palette.GOLD_LIGHT if lit else Color(0.3, 0.3, 0.34, 0.9)

## Sets the "Wave N" text and every circle's lit/unlit state -- called
## once from start_battle (progress doesn't change mid-fight) and again by
## reflow().
##
## Ian (24-item batch, Group D4): "wave icons at the bottom should track
## live for the area you are in, resetting to your checkpoint after wipes
## and resetting after defeating a boss." The strip used to be a fixed,
## one-time waves-1-20 tracker lit from g["clearedWaves"] (permanent,
## never reset) -- useless past wave 20. It now always shows the CURRENT
## boss-to-boss stretch (BOSS_EVERY waves, the last one the boss), lit
## purely from how far into that stretch the live wave is. Derived fresh
## from the current wave rather than any new saved state, so it resets on
## its own: a wipe sends the wave back to the checkpoint (the stretch's
## own first wave -> nothing lit), and clearing a boss moves the wave into
## the next stretch (bounds recompute -> all unlit again). cleared_waves
## is still accepted/cached for call-site compatibility but no longer read.
func _refresh_wave_progress(cleared_waves: Dictionary) -> void:
	_cleared_waves_cache = cleared_waves
	var cur: int = int(FarroadCore.current_wave)
	var span: int = FarroadProgression.BOSS_EVERY
	var stretch_start: int = int(floor(float(maxi(cur, 1) - 1) / float(span))) * span + 1
	wave_progress_label.text = "Wave %d  ·  %d-%d" % [cur, stretch_start, stretch_start + span - 1]
	for i in range(wave_progress_circles.size()):
		var entry: Dictionary = wave_progress_circles[i]
		entry["wave"] = stretch_start + i
		(entry["panel"] as Panel).visible = true
		(entry["style"] as StyleBoxFlat).bg_color = _wave_circle_color(int(entry["wave"]) < cur)

## Called by GameController for a side battle (quest/dungeon) specifically
## -- overrides the "Wave N" text with the encounter's own name (e.g.
## "Quest: Roadwolf, stage 2"). A side battle's own presenter is always a
## fresh, short-lived instance (never reused across its own multi-wave
## dungeon crawl without rebuilding fully, and never reused for the Road
## afterward), so there's no separate "restore" path needed -- the Road's
## OWN presenter/label were never touched and are simply shown again once
## the side battle resolves.
func set_status_override(text: String) -> void:
	wave_progress_label.text = text
	# A quest/dungeon fight isn't part of the Road's boss-to-boss stretch --
	# hide the strip rather than show a stretch it doesn't belong to.
	for entry in wave_progress_circles:
		(entry["panel"] as Panel).visible = false

## Called by GameController right as the post-wave-clear "run" transition
## starts (on the OLD, about-to-be-freed presenter -- the NEW one for the
## next wave is built fresh afterward already showing this wave as lit,
## via _refresh_wave_progress's own cleared_waves argument). A short glow
## tween rather than an instant snap, so it reads as part of the same
## transition instead of a separate, disconnected event.
func light_up_wave(w: int) -> void:
	for entry in wave_progress_circles:
		if entry["wave"] == w:
			var style: StyleBoxFlat = entry["style"]
			var from_color: Color = style.bg_color
			var to_color: Color = _wave_circle_color(true)
			var tw := create_tween()
			tw.tween_method(func(c: Color): style.bg_color = c, from_color, to_color, 0.5)
			return

var enrage_bg: ColorRect
var enrage_fg: ColorRect
var enrage_label: Label

## Red bar tracking the battle-wide ENRAGE_AFTER gate (farroad-core.js's
## step(), ported as-is in FarroadCore.gd) -- fills as b.beat climbs toward
## ENRAGE_AFTER (20). A single label ABOVE the bar carries both states of
## the same story: "Enrage in N turns" while the gate is still closed, then
## (once it opens) the CURRENT worst-case damage-bonus text takes over that
## exact spot -- one line that changes meaning, not two separate texts.
func _build_enrage_ui() -> void:
	# Same row as the Status/Log icons, to their left -- vertically centered
	# against the icons' own height, and ending just short of Status rather
	# than running underneath/into the icons.
	var status_pos: Vector2 = _status_log_row_pos(0)
	var icon_size: float = _vp.x * STATUS_LOG_ICON_FRAC
	var margin: float = _vp.x * 0.016
	var end_gap: float = _vp.x * 0.03
	var bar_h: float = _vp.y * 0.012
	var y: float = status_pos.y + (icon_size - bar_h) / 2.0
	var w: float = status_pos.x - end_gap - margin
	enrage_label = Label.new()
	enrage_label.position = Vector2(margin, y - _vp.y * 0.026)
	enrage_label.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	enrage_label.modulate = Color(1.0, 0.45, 0.45)
	add_child(enrage_label)

	enrage_bg = ColorRect.new()
	enrage_bg.position = Vector2(margin, y)
	enrage_bg.size = Vector2(w, bar_h)
	enrage_bg.color = Color(0.16, 0.08, 0.08)
	add_child(enrage_bg)

	enrage_fg = ColorRect.new()
	enrage_fg.position = enrage_bg.position
	enrage_fg.size = Vector2(0, enrage_bg.size.y)
	enrage_fg.color = Color(0.85, 0.2, 0.2)
	add_child(enrage_fg)

func _refresh_enrage() -> void:
	# Ian: waves 1-20 wiping too often -- enrage is now off entirely for the
	# Road's own solo tutorial stretch (see FarroadProgression.start_wave).
	# Without this guard the bar/label would still count the beat clock up
	# toward ENRAGE_AFTER and eventually claim "ENRAGED" with no stacks --
	# genuinely misleading, since battle["enrageN"] stays 0 forever when
	# battle["enrage"] is false (step() gates its own increment on it too).
	if not battle.get("enrage", true):
		enrage_fg.size = Vector2(0, enrage_bg.size.y)
		enrage_label.text = ("No enrage until wave %d" % FarroadProgression.ENRAGE_FROM_WAVE) \
			if FarroadCore.current_wave < FarroadProgression.ENRAGE_FROM_WAVE else "Enrage off"
		return
	var beat: int = battle["beat"]
	var gate: int = FarroadCore.ENRAGE_AFTER
	var frac: float = clamp(float(beat) / float(gate), 0.0, 1.0)
	enrage_fg.size = Vector2(enrage_bg.size.x * frac, enrage_bg.size.y)
	# Ian: "enrage should start at 20 turns, not 21" -- gate is now
	# beat>=ENRAGE_AFTER (was beat>ENRAGE_AFTER), matching step()'s own
	# corrected gate check exactly.
	if beat >= gate:
		# Stacks are battle-wide now (battle["enrageN"], rising once per turn
		# regardless of who acts) -- no more per-unit max scan needed.
		var stacks: int = int(battle.get("enrageN", 0))
		# Ian: enrage now scales LINEARLY (1+ENRAGE_PCT*N), not compounding --
		# mirrors the JS display formula exactly (farroad-ui.js's own
		# enrageStacks-driven label).
		var pct := roundi(FarroadCore.ENRAGE_PCT * stacks * 100.0)
		enrage_label.text = ("ENRAGED +%d%% dmg/spd" % pct) if stacks > 0 else "ENRAGED"
	else:
		var turns_left: int = gate - beat
		enrage_label.text = "Enrage in %d turn%s" % [turns_left, "" if turns_left == 1 else "s"]

## Ian (24-item batch, Group B4): "after enrage hits 25%, increase game
## speed by 0.05 seconds every 25%." Enrage first crosses 25% at
## enrageN==10 (ENRAGE_PCT*10*100 == 25). Below that, no cut at all --
## matches the "after 25%" wording literally, not a gradual ramp from 0.
## MIN_BEAT_FLOOR keeps a long fight's pacing from ever collapsing to an
## unreadable blur.
const ENRAGE_SPEEDUP_STEP := 0.05
const MIN_BEAT_FLOOR := 0.2
func _enrage_speed_cut() -> float:
	if not battle.get("enrage", true):
		return 0.0
	var pct: float = FarroadCore.ENRAGE_PCT * float(battle.get("enrageN", 0)) * 100.0
	if pct < 25.0:
		return 0.0
	return floor(pct / 25.0) * ENRAGE_SPEEDUP_STEP

## "TURN ORDER ->" strip -- mirrors the JS version's preview()-powered strip
## (a fixed row of upcoming-turn cards, not the history log; that's the
## separate Log button/popup above). Always visible, fixed height, no
## scrolling needed since it only ever shows TURN_ORDER_COUNT cards.
func _build_turn_order_ui() -> void:
	# Spans the full screen width (minus small edge margins) -- card_w is
	# SOLVED FOR so TURN_ORDER_COUNT cards + the gaps between them exactly
	# fill margin..vp.x-margin, rather than a fixed fraction that only used
	# part of the width.
	var margin: float = _vp.x * 0.016
	var gap: float = _vp.x * 0.01
	var card_w: float = (_vp.x - margin * 2.0 - gap * (TURN_ORDER_COUNT - 1)) / float(TURN_ORDER_COUNT)
	# Shorter than before, per direct request (also frees a little more room
	# below for the bottom icon row).
	var card_h: float = _vp.y * 0.06
	var top: float = _vp.y * 0.82
	_turn_card_w = card_w

	# A background frame behind the header+cards, added FIRST so it draws
	# behind them (later-added siblings draw on top) -- gives the turn-order
	# strip a visible boundary of its own instead of sitting bare against the
	# battlefield/icon row it's sandwiched between.
	var frame_pad: float = _vp.x * 0.008
	var frame_top: float = _vp.y * TURN_ORDER_FRAME_TOP_FRAC
	var frame_bottom: float = top + card_h + _vp.y * 0.01
	turn_order_frame = Panel.new()
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Palette.BG_PARCHMENT_DEEP
	frame_style.border_color = Palette.BORDER_LEATHER
	frame_style.set_border_width_all(1)
	turn_order_frame.add_theme_stylebox_override("panel", frame_style)
	turn_order_frame.position = Vector2(margin - frame_pad, frame_top)
	turn_order_frame.custom_minimum_size = Vector2(
		_vp.x - (margin - frame_pad) * 2.0, frame_bottom - frame_top)
	add_child(turn_order_frame)

	turn_order_header = Label.new()
	turn_order_header.text = "TURN ORDER →"
	turn_order_header.position = Vector2(_vp.x * 0.016, _vp.y * (TURN_ORDER_FRAME_TOP_FRAC + 0.01))
	turn_order_header.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	turn_order_header.modulate = Palette.TEXT_DIM
	add_child(turn_order_header)

	for i in range(TURN_ORDER_COUNT):
		var panel := PanelContainer.new()
		panel.position = Vector2(margin + i * (card_w + gap), top)
		panel.custom_minimum_size = Vector2(card_w, card_h)
		# Every card gets the same light parchment background as the rest of
		# the UI (previously left unstyled, silently falling back to the
		# engine's own default dark PanelContainer look -- unreadable once
		# the project theme's Label font_color turned dark project-wide,
		# since that made these cards' own text dark-on-dark).
		var card_style := StyleBoxFlat.new()
		card_style.bg_color = Palette.BG_PARCHMENT_DEEP
		card_style.border_color = Palette.BORDER_LEATHER
		card_style.set_border_width_all(1)
		if i == 0:
			# Slot 0 always shows whoever's beat is currently resolving --
			# _refresh_turn_order() is called right after a beat finishes,
			# predicting the NEXT actor via the same pick_next()/chooseFrom
			# logic step() itself uses, so by construction slot 0 stays
			# accurate for the whole duration of that unit's animation. A
			# permanent gold border here, set once, needs no per-beat toggling.
			card_style.border_color = Palette.GOLD_LIGHT
			card_style.set_border_width_all(3)
		panel.add_theme_stylebox_override("panel", card_style)
		add_child(panel)

		var vbox := VBoxContainer.new()
		panel.add_child(vbox)

		var name_lbl := Label.new()
		name_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.016))
		vbox.add_child(name_lbl)

		var action_lbl := Label.new()
		action_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.014))
		vbox.add_child(action_lbl)

		turn_cards.append({"panel": panel, "name": name_lbl, "action": action_lbl})

## Ian: "I want actions to be locked in as soon as they appear on the
## turn order... charge actions should only enter the turn order once
## they're full, not appearing beforehand. The same should be true for
## gambit conditions being met." FarroadCore.preview() itself no longer
## projects charge/conditions forward at all (see its own comment) -- it
## always resolves every slot against each unit's REAL, CURRENT state,
## so "what's shown" already equals "what would happen if resolved this
## instant" by construction. The only remaining gap: once a unit's
## choice gets LOCKED (_lock_upcoming_actors, below) at the moment it
## first appears, a LATER refresh's freshly-computed preview() could
## still disagree with that frozen lock if real state has drifted since
## (another unit's action changing this one's HP-based condition, etc.).
## Overrides the display for any ALREADY-locked unit's card to show the
## locked action instead of preview()'s fresh (and possibly now
## different) recomputation, so the rail and the eventual execution can
## never disagree. Turn ORDER itself never depended on action choice in
## the first place (preview()'s own ordering compares nextActAt/isParty/
## spd/slotIndex only), so this only ever changes which ACTION text a
## card shows, never who's shown or in what order.
## lockedActors[uid] is a QUEUE (Array of {actionId, resultingAlternate}
## entries) -- see _lock_upcoming_actors' own comment for why a single
## value per uid was the actual bug behind "turn order still changes
## right as a unit enters the active box." Overlays each OCCURRENCE of a
## unit in `out` with the correspondingly-indexed queue entry (1st
## occurrence <-> queue[0], 2nd <-> queue[1], etc.), not just the first.
func _preview_respecting_locks() -> Array:
	var out: Array = FarroadCore.preview(battle, TURN_ORDER_COUNT)
	var locked: Dictionary = battle.get("lockedActors", {})
	if locked.is_empty():
		return out
	var occ_seen: Dictionary = {}
	for p in out:
		var uid: String = p["unitId"]
		var occ: int = occ_seen.get(uid, 0)
		occ_seen[uid] = occ + 1
		var queue: Array = locked.get(uid, [])
		if occ >= queue.size():
			continue
		var view: UnitView = unit_views_by_id.get(uid)
		if view == null:
			continue
		var act = FarroadCore.ACTIONS.get(queue[occ]["actionId"])
		if act == null:
			continue
		p["actionName"] = act["name"]
		p["actionId"] = act["id"]
		p["isCharge"] = bool(act.get("isCharge", false))
		p["cost"] = FarroadCore.tc_of(view.unit, act["rank"])
	return out

## Recomputes FarroadCore.preview() (a pure simulation, mutates nothing) and
## refreshes each card -- called once up front and again after every beat.
func _refresh_turn_order() -> void:
	var upcoming: Array = [] if battle["over"] != null else _preview_respecting_locks()
	_lock_upcoming_actors(upcoming)
	# A small inset off the card's own width -- the true content width after
	# the PanelContainer's own border/margins, not the full slot fraction.
	var max_w: float = _turn_card_w - _vp.x * 0.02
	for i in range(turn_cards.size()):
		var card = turn_cards[i]
		if i >= upcoming.size():
			card["panel"].visible = false
			continue
		card["panel"].visible = true
		var p = upcoming[i]
		_fit_label_text(card["name"], p["unitName"], int(_vp.y * 0.016), max_w)
		# Ian: "they aren't the colors I specified" -- `.modulate` MULTIPLIES
		# against the project theme's own Label font_color (a dark ink,
		# Color(0.22,0.15,0.09)), not replaces it, so #1462e0 modulated
		# through that ink rendered as a near-black smudge instead of the
		# actual vivid blue. A theme color override REPLACES the font color
		# outright, which is what was actually wanted here.
		card["name"].add_theme_color_override("font_color",
			Palette.PARTY_BLUE_BRIGHT if p["isParty"] else Palette.ENEMY_RED_BRIGHT)
		# No camp/element glyph prefix and no speed (×N) line -- just who's
		# acting and what the action is, per direct request. _action_glyph
		# is still used by the Log popup's own per-beat entries, unchanged.
		_fit_label_text(card["action"], p["actionName"], int(_vp.y * 0.014), max_w)

## Post-Milestone-3 APK feedback (Group A2), redesigned again after
## further feedback ("I want actions to be locked in as soon as they
## appear on the turn order... charge actions should only enter the
## turn order once they're full, not appearing beforehand. The same
## should be true for gambit conditions being met"). Locks the fully
## RESOLVED action id, not the unit's `slots` -- `upcoming` (from
## `_preview_respecting_locks`'s own fresh FarroadCore.preview() call)
## already resolved every NOT-yet-locked unit's action against its REAL,
## CURRENT charge/HP/conditions (preview() no longer projects any of
## that forward -- see its own comment), so `p["actionId"]` already IS
## exactly "what would happen if this unit's turn resolved right now" --
## simply recording it is both correct and needs no separate probe call.
## Confirmed via direct reads of FarroadCore.gd's choose_from/
## resolve_condition that action/target SELECTION is fully deterministic
## and RNG-free (only later damage/evade/crit resolution rolls), so
## freezing a unit's resolved choice this way is 100% safe w.r.t. RNG/
## parity -- no roll is skipped or added either way. Writes
## battle["lockedActors"] (a new transient, unsaved battle field -- uid
## -> action id -- consumed/cleared per-uid by FarroadCore.step()/
## farroad-core.js's own step()): every unit CURRENTLY visible anywhere
## in the turn-order preview gets locked the FIRST time it appears there
## (not re-locked on later refreshes, so a lock always reflects the
## moment a unit first became visible, not whatever real state has
## drifted to since).
##
## Post-batch feedback: "turn order is still changing actions when they
## enter the currently-activating box." Root cause -- a lock used to be
## dropped the instant its unit fell out of the small (TURN_ORDER_COUNT-
## wide) visible window, even for one beat. Since a fast unit can occupy
## several of the visible slots at once (see preview()'s own comment), a
## slower unit gets squeezed out of view easily -- and could reappear
## later, sometimes landing directly at slot 0, freshly re-locked
## against whatever real state had drifted to while it was invisible,
## visibly changing right as it became the active actor. Fixed: a lock
## now ONLY ever clears by actually being consumed in step(), or here if
## its unit has died (can never act again) -- never just for scrolling
## out of the visible rail.
##
## STILL still-changing bug, found on a fresh re-investigation: locked[uid]
## used to be a single action id, not one per UPCOMING TURN. A unit fast
## enough to occupy 2+ of the visible rail slots at once only ever got
## ONE lock value (taken from its nearest occurrence) -- _preview_
## respecting_locks then painted that SAME value onto every occurrence of
## it, so the far occurrence's card was never really locked to its own
## true future action, just borrowing the near one's. The instant the
## near turn actually fired, step() erased that single lock entirely --
## so on the very next refresh, the unit's now-nearest (formerly 2nd)
## occurrence looked "never locked" and got a FRESH, honestly-recomputed
## value, which could legitimately differ (other units' actions, HP
## changes, etc. had moved real state in the meantime) -- exactly
## "changes right before it fires." Fixed: locked[uid] is now a QUEUE,
## one entry per upcoming turn, indexed by OCCURRENCE order (1st
## occurrence of this unit anywhere in the rail locks queue[0], 2nd
## occurrence locks queue[1], etc.) -- each occurrence gets its own real,
## independently-frozen value the first moment IT specifically becomes
## visible, never borrowed from a sibling occurrence. Computed via a
## direct choose_from() call (not preview()'s own per-slot resolution,
## which deliberately does NOT project alternateFlag/charge forward
## across a unit's own occurrences -- see preview()'s comment) so a
## round-robin ("all_none") loadout's 2nd+ queued turn correctly shows
## (and later executes) the NEXT slot in rotation, not a repeat of the
## first, and so a charge action already queued once for this unit is
## correctly treated as spent for any later queued occurrence too,
## matching preview()'s own established "charge shown once" rule.
func _lock_upcoming_actors(upcoming: Array) -> void:
	if battle.get("lockedActors") == null:
		battle["lockedActors"] = {}
	var locked: Dictionary = battle["lockedActors"]
	var occ_seen: Dictionary = {}
	for p in upcoming:
		var uid: String = p["unitId"]
		var occ: int = occ_seen.get(uid, 0)
		occ_seen[uid] = occ + 1
		if not locked.has(uid):
			locked[uid] = []
		var queue: Array = locked[uid]
		if occ < queue.size():
			continue   # this occurrence is already locked
		var view: UnitView = unit_views_by_id.get(uid)
		if view == null:
			continue
		var u: Dictionary = view.unit
		var charge_spent := false
		var start_alt: int = int(u["alternateFlag"])
		for entry in queue:
			var prev_act = FarroadCore.ACTIONS.get(entry["actionId"])
			if prev_act != null and prev_act.get("isCharge", false):
				charge_spent = true
			start_alt = entry["resultingAlternate"]
		var state := {"charge": (0.0 if charge_spent else u["charge"]), "alternateFlag": start_alt}
		# Same det-flip preview() itself now uses -- this call also never
		# surfaces its resolved TARGET to anything, only the action id.
		var was_det: bool = battle["det"]
		battle["det"] = true
		var ch := FarroadCore.choose_from(u, battle, state)
		battle["det"] = was_det
		queue.append({"actionId": ch["actionId"], "resultingAlternate": int(state["alternateFlag"])})
	for uid in locked.keys().duplicate():
		var view: UnitView = unit_views_by_id.get(uid)
		if view == null or view.unit["hp"] <= 0:
			locked.erase(uid)

## A long action/unit name (e.g. "Wayfarer's Oath") could otherwise draw past
## a turn-order card's own edge into its neighbor -- there's no Godot Label
## feature that auto-shrinks font size to fit, so this measures the text's
## real natural width at the base size and scales the font down (never below
## min_font_size) until it fits max_width instead. clip_text stays on as a
## last-resort safety net for the rare case even the floor size overflows.
func _fit_label_text(lbl: Label, text: String, base_font_size: int, max_width: float, min_font_size: int = 8) -> void:
	# clip_text must be set AFTER measuring, not before -- a Label with
	# clip_text already true stops reporting its true unclipped text width
	# from get_minimum_size() (it reports a small "I don't need room, I'll
	# clip" size instead), which would silently defeat this exact check.
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", base_font_size)
	var natural_w: float = lbl.get_minimum_size().x
	if natural_w > max_width and natural_w > 0.0:
		var scaled: int = maxi(min_font_size, int(floor(base_font_size * (max_width / natural_w))))
		lbl.add_theme_font_size_override("font_size", scaled)
	lbl.clip_text = true
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

## Mirrors actionGlyphText (farroad-ui.js:501-505) -- camp icon + element icon.
func _action_glyph(act) -> String:
	if act == null:
		return ""
	var h: String = "⚔️" if act.get("camp") == "atk" else "🔮"
	var el = act.get("element")
	if el != null and ELEMENT_GLYPH.has(el):
		h += ELEMENT_GLYPH[el]
	return h + " "

## Builds one log entry from a step() event, closely mirroring logEntry()'s
## actual structure (farroad-ui.js:1781-1806), not just its rough content:
## "bN <b>Actor</b> → [icon] Action → Target [EVADED/CRIT]" with the damage
## figure pinned to the panel's right edge (an HBoxContainer in
## _build_log_entry_node, not a BBCode table -- see that function's comment
## for why), an italic "via · initiative ×NNN" line, note bullets, and a
## "tap for the damage breakdown" affordance expanding the same
## base/off/mitigation math resolveHit() itself already computed.
##
## The visual container is only rebuilt while the popup is actually
## VISIBLE (log_popup.visible) -- a real performance bug found and fixed
## here: this function (and _append_raw_log below) runs every single beat
## regardless of whether the log is open, and _rebuild_log_container() tears
## down and recreates a Control node per log_lines entry EVERY TIME it's
## called. Rebuilding unconditionally every beat meant a beat late in a long
## fight paid for rebuilding every earlier beat's entry too (O(beats) work
## per beat, O(beats^2) over a whole fight) even though nobody could see it
## -- exactly the kind of thing that reads as "gets choppier the longer a
## fight runs." log_lines itself still accumulates every beat regardless
## (cheap, just data); _on_log_pressed rebuilds once on open to catch up.
func _append_log(e: Dictionary) -> void:
	var color: String = PARTY_COLOR if e["isParty"] else ENEMY_COLOR
	var act = FarroadCore.ACTIONS.get(e["actionId"])
	var charge_prefix: String = "⚡ " if e.get("isCharge") else ""
	var icon: String = _action_glyph(act)
	var head := "[color=#%s][font_size=12]b%d[/font_size][/color] [b][color=#%s]%s[/color][/b] → %s%s[b]%s[/b]" % [
		DIM_COLOR, e["beat"], color, e["actorName"].split(" ")[0], charge_prefix, icon, e["actionName"]]
	if e["targetName"] != null:
		head += " → %s" % e["targetName"]
	var evaded: bool = not e["hits"].is_empty() and e["hits"][0]["evaded"]
	var crit: bool = not e["hits"].is_empty() and e["hits"][0].get("crit")
	if evaded:
		head += " [color=#%s]EVADED[/color]" % BAD_COLOR
	elif crit:
		head += " [color=#%s]CRIT[/color]" % CRIT_COLOR
	var dmg_text: String = str(e["totalDamage"]) if not e["hits"].is_empty() else "—"

	var via_bbcode := "[i][color=#%s]%s · initiative ×%d[/color][/i]" % [DIM_COLOR, e["via"], roundi(100.0 / e["rank"])]

	var note_bbcodes := []
	if e["dot"] > 0:
		note_bbcodes.append("[color=#%s]🔥 −%d[/color]" % [NOTE_COLOR, e["dot"]])
	for h in e["heals"]:
		note_bbcodes.append("[color=#%s]✚ %s +%d[/color]" % [NOTE_COLOR, h["targetName"], h["amount"]])
	for note in e["notes"]:
		note_bbcodes.append("[color=#%s]· %s[/color]" % [NOTE_COLOR, str(note)])

	log_lines.append({"head_bbcode": head, "dmg_text": dmg_text, "via_bbcode": via_bbcode,
		"note_bbcodes": note_bbcodes, "calc": _calc_text(e), "expanded": false})
	if log_popup != null and log_popup.visible and not log_paused:
		_rebuild_log_container()

## A plain, non-event log line (e.g. "Battle over") -- same storage shape,
## no calc breakdown to expand.
func _append_raw_log(bbcode: String) -> void:
	log_lines.append({"head_bbcode": bbcode, "dmg_text": "", "via_bbcode": "",
		"note_bbcodes": [], "calc": "", "expanded": false})
	if log_popup != null and log_popup.visible and not log_paused:
		_rebuild_log_container()

## Mirrors logEntry()'s `calc` string (farroad-ui.js:1783-1793) -- reuses
## resolveHit()'s OWN already-computed fields off the first real hit, no
## re-derivation. Evaded/no-hit actions have nothing to expand.
func _calc_text(e: Dictionary) -> String:
	if e["hits"].is_empty():
		return ""
	var h = e["hits"][0]
	if h["evaded"]:
		return "MISSED — evade %s%%" % [snapped(h["evadeChance"] * 100.0, 0.1)]
	var k = h["K"]
	var s := "base %s × %d × %s/(%s+%d) = %s" % [
		snapped(h["power"], 0.01), roundi(h["off"]), snapped(k, 0.1), snapped(k, 0.1), roundi(h["defEff"]), snapped(h["base"], 0.1)]
	s += "\nno variance roll — base damage is deterministic"
	if h["crit"]:
		s += "\ncrit ×1.75"
	s += "\n→ floor %d" % h["damage"]
	return s

## Set by GameController (via a dynamic has_method()+call(), same pattern
## AetherPanel/GambitsPanel already use to reach back into it) while the
## GAMBITS popup is open. Without this, the loop below keeps resolving beats
## in the background at its normal ~1s/beat cadence WHILE the player is
## navigating that popup -- a loadout edit's engine-level effect is already
## immediate (FarroadProgression.sync_loadout reaches the live unit right
## away), but by the time a real player finishes clicking through the menu
## the current wave has often already ended, making an already-immediate
## change LOOK like it only took effect next wave. Pausing between beats
## (not mid-animation -- see the wait's placement below) gives an edit a
## real chance to be observed within the CURRENT fight.
var loop_paused: bool = false
func set_loop_paused(p: bool) -> void:
	loop_paused = p

func _run_battle_loop() -> void:
	var guard := 0
	while battle["over"] == null and guard < 300:
		while loop_paused:
			await get_tree().create_timer(0.1).timeout
		guard += 1
		var e = FarroadCore.step(battle)
		if e == null:
			break
		_append_log(e)
		active_unit_id = e["actorId"]
		if status_popup.visible:
			_refresh_status_popup()
		await _animate_beat(e)
		active_unit_id = ""
		_refresh_turn_order()
		_refresh_charge_bars()
		_refresh_enrage()
		if status_popup.visible:
			_refresh_status_popup()
	# Defensive: if the loop exited via the guard cap (a genuine stalemate
	# running past 300 beats) or FarroadCore.step() returning null with
	# battle["over"] never actually set, battle["over"] would otherwise
	# still be null here -- emitting that into GameController's
	# non-nullable String outcome parameter raises a type error that
	# aborts the signal handler before any of its own cleanup runs,
	# freezing the game with exactly this log line as the last visible
	# sign of life. A real, if rare, stalemate is treated as a loss (the
	# same safe fallback every non-"party" outcome already gets).
	if battle["over"] == null:
		battle["over"] = "draw"
	_append_raw_log("[b]Battle over: %s[/b]" % str(battle["over"]))
	_refresh_turn_order()
	battle_finished.emit(battle["over"])

## Charge accumulates/spends for whichever unit just acted (and enrage can
## touch others) -- cheapest correct approach is refreshing everyone each
## beat rather than tracking exactly who changed, same choice
## _refresh_turn_order() already makes.
func _refresh_charge_bars() -> void:
	for view in unit_views_by_id.values():
		view.update_charge()

## Hit effects (damage numbers, HP bar updates) resolve at the moment of
## IMPACT -- after a physical unit's approach hop lands, or a projectile
## arrives -- not after the actor has already finished its whole animation
## and settled back home. The earlier version applied them only after a
## physical attack's full there-and-back round trip, which visually
## disconnected the hit from the moment the attacker was actually there.
## Group I (20-item batch): the field's own center point, in the same
## world-space coordinates as a UnitView's own position/rest_position --
## an AoE action's animation flies here instead of toward one arbitrary
## target, since it actually hits every foe/ally at once. Same point
## GameController._spawn_reward_drops already uses as its own flyer
## start position (Vector2(_vp.x/2.0, _vp.y*(0.11+0.58)/2.0)), just
## expressed via field_top/field_bottom directly rather than duplicating
## the raw 0.11/0.58 constants.
func _field_center() -> Vector2:
	return Vector2(_vp.x / 2.0, (field_top + field_bottom) / 2.0)

func _animate_beat(e: Dictionary) -> void:
	var actor_view: UnitView = unit_views_by_id.get(e["actorId"])
	if actor_view == null:
		await get_tree().create_timer(IDLE_PAUSE).timeout
		return
	var act = FarroadCore.ACTIONS.get(e["actionId"])
	var is_phys: bool = act != null and act.get("camp") == "atk" and not act.get("heal")
	var target_view: UnitView = unit_views_by_name.get(e["targetName"])

	if target_view == null:
		await get_tree().create_timer(IDLE_PAUSE).timeout
		return

	# An AoE action's e["targetName"] still names just ONE (arbitrary)
	# primary target -- every real target's own hit-effects (damage
	# numbers, HP bar updates) still apply individually and correctly
	# below regardless of where the visual itself flew, so redirecting
	# ONLY the animation's destination here is safe and sufficient.
	var is_aoe: bool = act != null and (act.get("tk") == "allFoes" or act.get("tk") == "allAllies")
	var dest_rest: Vector2 = _field_center() if is_aoe else target_view.rest_position
	var dest_world: Vector2 = _field_center() if is_aoe else target_view.position

	# 24-item batch (Group B4): reduces both the visual tween durations AND
	# the post-beat gate together, floored at MIN_BEAT_FLOOR so a long
	# fight's pacing can't collapse to an unreadable blur.
	var speed_cut: float = _enrage_speed_cut()

	if is_phys:
		# A LOCAL offset from the actor's own rest position (its shape
		# animates relative to itself -- see _hop's own comment), stopping
		# HOP_STOP_SHORT of the target's rest position rather than closing
		# the full gap.
		var full_delta: Vector2 = dest_rest - actor_view.rest_position
		var approach_offset: Vector2 = full_delta - full_delta.normalized() * (_vp.x * HOP_STOP_SHORT)
		# Ian: "jumping to attack can stay the default, but have the option
		# for units to use... running instead." Per-unit, derived from
		# whether THIS unit's own SpriteFrames actually has a "run"
		# animation -- a fallback-shape unit always answers false, so this
		# branch is a no-op change for every unit without real art yet.
		var use_run: bool = actor_view.prefers_run_approach()
		var leg_time: float = maxf(MIN_BEAT_FLOOR * 0.5, (RUN_TIME if use_run else HOP_TIME) - speed_cut)
		actor_view.play_state("run" if use_run else "jump")
		# Ian: start the attack's wind-up 3/4 of the way through the jump, so
		# the blow lands right after touching down. The leg runs on its own;
		# the attack animation takes over the sprite for the last quarter.
		var leg_done := [false]
		var leg := func():
			if use_run:
				await _run_to(actor_view, Vector2.ZERO, approach_offset, leg_time)
			else:
				await _hop(actor_view, Vector2.ZERO, approach_offset, leg_time)
			leg_done[0] = true
		leg.call()
		await get_tree().create_timer(leg_time * ATTACK_START_IN_LEG).timeout
		# Real attack art: the hit lands on the animation's impact frame,
		# with the weapon trail in the action's element colour (UnitView).
		actor_view.set_attack_element(act.get("element") if act != null else null)
		actor_view.play_state("attack")
		while not leg_done[0]:
			await get_tree().process_frame
		await actor_view.wait_for_impact()
		_apply_hit_effects(e)
		await actor_view.wait_for_animation(0.6)
		# Ian: "sear triggers after the afflicted unit acts" -- _apply_hit_
		# effects' own DOT handling can kill the ACTOR on their own turn.
		# update_hp() already set "dead" for that case; don't stomp it back
		# to jump/idle right after.
		var actor_still_alive: bool = float(actor_view.unit["hp"]) > 0.0
		if actor_still_alive:
			actor_view.play_state("run" if use_run else "jump")
		# Ian (Group B3): "have the next action take place while they are
		# in the middle of moving back to their position, so after 0.75
		# seconds." The return leg is now fire-and-forget (started, never
		# awaited) -- _return_and_settle keeps animating it home and sets
		# "idle" once it lands, entirely independent of this function's own
		# return. The gate below gives the WHOLE beat (outbound + this
		# wait) a fixed total budget; since the return leg's own duration
		# (leg_time) is longer than what's left of that budget once the
		# outbound leg is subtracted, the unit is still visibly mid-return
		# when the next beat's step() actually fires.
		_return_and_settle(actor_view, use_run, actor_still_alive, leg_time)
		var phys_total: float = maxf(MIN_BEAT_FLOOR, PHYS_BEAT_TOTAL - speed_cut)
		await get_tree().create_timer(maxf(0.05, phys_total - leg_time)).timeout
	else:
		actor_view.play_state("cast")
		var magic_total: float = maxf(MIN_BEAT_FLOOR, MAGIC_BEAT_TOTAL - speed_cut)
		await _animate_projectile(actor_view, dest_world, magic_total)
		_apply_hit_effects(e)
		if float(actor_view.unit["hp"]) > 0.0:
			actor_view.play_state("idle")

## `stagger` tracks how many floating texts have already spawned at each
## target THIS beat (across hits/heals/status notes together) -- see
## DamageNumber.spawn's own comment for why this matters: without it, a hit
## that both deals damage AND applies a status (or several hits landing on
## the same target in one beat) spawns multiple labels at the identical
## point, overlapping each other for their entire flight.
func _apply_hit_effects(e: Dictionary) -> void:
	# "Recalled units still appear dead despite acting" -- a revive action
	# (recall/lastlight) mutates its target's hp directly but is captured
	# ONLY as a text note (e["notes"]), never in e["hits"]/e["heals"] (see
	# FarroadCore.step()'s own revive branch) -- so neither loop below ever
	# reached the revived unit's view, leaving it dimmed/hidden despite
	# being alive and taking its own turns again. e["targetName"] already
	# correctly names the primary target for EVERY action (set unconditionally
	# before the revive/heal/hit branch), so unconditionally refreshing it
	# here is a cheap, always-correct general fix, not a revive-only special
	# case -- redundant (harmless) for actions whose hits/heals loops below
	# already cover the same target.
	var primary_view: UnitView = unit_views_by_name.get(e.get("targetName"))
	if primary_view != null:
		primary_view.update_hp()
	# Ian: "charge bar update on hit, not on return to starting position" --
	# was only ever refreshed by the post-beat _refresh_charge_bars() sweep,
	# AFTER a physical attacker's full there-and-back hop completed. This
	# unit's own charge already changed (spent or gained) by the time
	# step() returned this event, so update it right here, at the same
	# "impact" moment hits/heals already resolve at.
	var actor_view: UnitView = unit_views_by_id.get(e.get("actorId"))
	if actor_view != null:
		actor_view.update_charge()
	var stagger: Dictionary = {}
	for h in e["hits"]:
		var tv: UnitView = unit_views_by_name.get(h["targetName"])
		if tv == null:
			continue
		tv.update_hp()
		var n: int = stagger.get(h["targetName"], 0)
		stagger[h["targetName"]] = n + 1
		if h["evaded"]:
			DamageNumber.spawn(self, tv.damage_spawn_position(), "Evade", Color(0.75, 0.75, 0.75), n)
		else:
			var color := Color(1.0, 0.55, 0.2) if h.get("crit") else Color(1.0, 0.9, 0.3)
			DamageNumber.spawn(self, tv.damage_spawn_position(), str(h["damage"]), color, n)
			tv.shake()
	for h in e["heals"]:
		var tv: UnitView = unit_views_by_name.get(h["targetName"])
		if tv == null:
			continue
		tv.update_hp()
		var n: int = stagger.get(h["targetName"], 0)
		stagger[h["targetName"]] = n + 1
		DamageNumber.spawn(self, tv.damage_spawn_position(), "+%d" % h["amount"], Color(0.4, 0.95, 0.5), n)
	# Ian: "sear triggers after the afflicted unit acts and show the
	# amount" -- step() already moved burning's DOT tick to fire after this
	# unit's own action resolves (still this same beat/event); this is the
	# "show" half, giving it a floating number on the afflicted unit's own
	# field position, same as any other damage source. The log popup's own
	# "🔥 -N" note (BattlePresenter's log-building code) is unchanged.
	if actor_view != null and e.get("dot", 0) > 0:
		actor_view.update_hp()
		var an: int = stagger.get(e.get("actorName"), 0)
		stagger[e.get("actorName")] = an + 1
		DamageNumber.spawn(self, actor_view.damage_spawn_position(), str(e["dot"]), Color(1.0, 0.45, 0.15), an)
	_apply_status_notes(e, stagger)

## A unit applying/refreshing a stat-affecting status (bracing/enfeebled/
## dulled/frail/sundered/blurred/etc. -- anything with an "applies" field)
## only ever showed up as a text line in the Log popup, not on the field
## itself, unlike damage/heals which both get a floating number. Parses the
## exact note strings FarroadCore.gd already appends for this
## ("applied X on Y" / "refreshed X on Y", farroad-core.js's own status-apply
## branch) rather than duplicating that logic or touching the engine layer --
## presentation-only, same as everything else in this file. Excludes
## "enraged x%d" (its own dedicated enrage bar/label already covers that,
## every beat once enrage is open would be popup spam) and "taunting"/
## "thorns -%d" (self-effects with no stat change to call out this way).
func _apply_status_notes(e: Dictionary, stagger: Dictionary) -> void:
	for note in e["notes"]:
		var applied: bool = note.begins_with("applied ")
		var refreshed: bool = note.begins_with("refreshed ")
		if not applied and not refreshed:
			continue
		var rest: String = note.trim_prefix("applied " if applied else "refreshed ")
		var sep := rest.find(" on ")
		if sep == -1:
			continue
		var status_id: String = rest.substr(0, sep)
		var target_name: String = rest.substr(sep + 4)
		var tv: UnitView = unit_views_by_name.get(target_name)
		if tv == null:
			continue
		var color := Color(0.5, 0.85, 1.0) if FarroadCore.is_buff_status(status_id) else Color(0.85, 0.5, 1.0)
		var n: int = stagger.get(target_name, 0)
		stagger[target_name] = n + 1
		DamageNumber.spawn(self, tv.damage_spawn_position(), status_id.capitalize(), color, n)

## Animates ONLY the actor's shape -- `from`/`to` are LOCAL offsets from the
## unit's own rest position (Vector2.ZERO = at rest), not world-space points.
## The UnitView itself (and therefore its name/HP/charge bars, siblings of
## the shape, positioned relative to the UnitView's own origin) never moves,
## so they stay anchored at the unit's normal spot on the field throughout
## the hop instead of jumping toward the target along with the shape.
## `duration` defaults to HOP_TIME but is passed explicitly by
## _animate_beat once enrage pacing (Group B4) is in play, since the
## effective duration then varies beat-to-beat.
func _hop(actor: UnitView, from: Vector2, to: Vector2, duration: float = HOP_TIME) -> void:
	var height: float = _vp.y * HOP_HEIGHT_FRAC
	var tw := create_tween()
	tw.tween_method(func(t: float): actor.shape.position = from.lerp(to, t) + Vector2(0, -height * sin(t * PI)),
		0.0, 1.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

## Ian: "have the option for units to use a different animation such as
## running (which would mean having a straight line to their target
## instead of the current hop)." Same signature/local-offset convention as
## _hop() -- only used for a unit whose own SpriteFrames has a "run"
## animation (see prefers_run_approach()) -- no arc height, a direct line.
## RUN_TIME is a first-pass guess (no real run art to time it against
## yet), deliberately quicker than a HOP_TIME round trip since a run
## reads as brisker than an arcing jump.
const RUN_TIME := 0.35
func _run_to(actor: UnitView, from: Vector2, to: Vector2, duration: float = RUN_TIME) -> void:
	actor.shape.position = from
	var tw := create_tween()
	tw.tween_property(actor.shape, "position", to, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

## Fire-and-forget wrapper (Group B3) -- started without being awaited by
## _animate_beat, so the actor keeps visibly animating home in the
## background while combat has already moved on to the next actor's beat.
## was_alive is captured at call time (before this coroutine starts, which
## may itself run past the point some OTHER beat changes actor.unit["hp"])
## so a mid-flight death elsewhere can't retroactively flip whether this
## unit settles into "idle" once it lands.
func _return_and_settle(actor: UnitView, use_run: bool, was_alive: bool, duration: float) -> void:
	if use_run:
		await _run_to(actor, actor.shape.position, Vector2.ZERO, duration)
	else:
		await _hop(actor, actor.shape.position, Vector2.ZERO, duration)
	if was_alive:
		actor.play_state("land")
		await actor.wait_for_animation(0.3)
		if float(actor.unit["hp"]) > 0.0:
			actor.play_state("idle")

## Magic/ranged attack (and heals): a projectile travels actor -> a
## world-space destination (the real target's own position, or the
## field's center for an AoE action -- see _animate_beat's own dest_world).
## `duration` defaults to MAGIC_BEAT_TOTAL but is passed explicitly once
## enrage pacing (Group B4) is in play.
func _animate_projectile(actor: UnitView, dest: Vector2, duration: float = MAGIC_BEAT_TOTAL) -> void:
	var bolt := Polygon2D.new()
	var r: float = _vp.y * 0.008
	bolt.polygon = PackedVector2Array([Vector2(-r, -r), Vector2(r, -r), Vector2(r, r), Vector2(-r, r)])
	bolt.color = Color(0.6, 0.85, 1.0)
	bolt.position = actor.position
	add_child(bolt)
	var tw := create_tween()
	tw.tween_property(bolt, "position", dest, duration)
	await tw.finished
	bolt.queue_free()

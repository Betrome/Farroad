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
# The ~1s/beat pacing comes entirely from the motion itself, not a trailing
# static pause -- BEAT_PAUSE is just enough to let a spawned damage
# number/HP-bar update register on screen before the next beat starts.
const HOP_TIME := 0.475             # per leg (there, then back) -- ~1s round trip
const PROJECTILE_TIME := 0.95
const BEAT_PAUSE := 0.05
const IDLE_PAUSE := 0.45            # no-target/burned-out beats -- nothing to animate anyway

## camp/element glyphs -- mirrors ELEMENT_GLYPH/actionGlyphText exactly
## (farroad-ui.js:486-505), same unicode icons, no sprite assets needed.
const ELEMENT_GLYPH := {"fire": "🔥", "water": "💧", "earth": "🪨",
	"air": "💨", "light": "☀️", "dark": "🌑"}

var battle: Dictionary
var unit_views_by_id: Dictionary = {}
var unit_views_by_name: Dictionary = {}
var active_unit_id: String = ""   # whichever unit's beat is currently animating -- drives the gold border in the Status popup too
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
	_recompute_field_fractions()
	_build_log_ui()
	_build_status_ui()
	_build_enrage_ui()
	_build_turn_order_ui()

## Entry point for a caller (GameController) that already built a real
## battle via FarroadProgression -- content is assumed already loaded and
## FarroadCore.set_wave() already called by build_enemies() itself, neither
## of which is this presenter's job anymore.
func start_battle(new_battle: Dictionary, units: Array) -> void:
	battle = new_battle
	_layout_units(units)
	_refresh_turn_order()
	_refresh_enrage()
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

	# Icons only, NOT _build_status_ui()/_build_log_ui() -- those also build
	# status_popup/log_popup, which are built exactly once and must not be
	# duplicated/orphaned by a reflow.
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
		unit_views_by_id[u["id"]] = view
		unit_views_by_name[u["name"]] = view
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

func _layout_units(units: Array) -> void:
	var party_front := []
	var party_back := []
	var enemy_front := []
	var enemy_back := []
	for u in units:
		var view := UnitView.new()
		view.setup(u, _unit_size(u))
		add_child(view)
		unit_views_by_id[u["id"]] = view
		unit_views_by_name[u["name"]] = view
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

const PARTY_COLOR := "5b9bd5"
const ENEMY_COLOR := "e8825c"
const BAD_COLOR := "e05c5c"
const CRIT_COLOR := "ffb347"
const DIM_COLOR := "888888"
const NOTE_COLOR := "a8a0e0"

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
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
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
func _build_icon_tab(pos: Vector2, size: float, label_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.24, 0.24, 0.29)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(0.32, 0.32, 0.38)
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
	_refresh_status_popup()
	status_popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))

## Rebuilds every card from LIVE battle data -- called on open, and then
## every beat for as long as it stays open (see _run_battle_loop), so HP/
## charge/the active-unit border actually track the fight instead of
## freezing at whatever the battle looked like the moment it was opened.
func _refresh_status_popup() -> void:
	for c in status_container.get_children():
		c.queue_free()
	for u in battle["units"]:
		status_container.add_child(_build_status_card(u))

func _build_status_card(u: Dictionary) -> Control:
	var card := PanelContainer.new()
	if u["id"] == active_unit_id:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1, 0.1, 0.12)
		style.border_color = Color(1.0, 0.84, 0.0)
		style.set_border_width_all(3)
		style.set_content_margin_all(10)
		card.add_theme_stylebox_override("panel", style)
	else:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1, 0.1, 0.12)
		style.set_content_margin_all(10)
		card.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	card.add_child(box)

	var header := HBoxContainer.new()
	var color: String = PARTY_COLOR if u["isParty"] else ENEMY_COLOR
	var level: int = u["level"] if u["isParty"] else roundi(FarroadCore.level_curve(FarroadCore.current_wave))
	var row_tag: String = ""
	if u["isParty"]:
		row_tag = "FRONT" if u.get("row") == "front" else "BACK"
	else:
		row_tag = "boss" if u.get("isBoss") else PREF_TEXT.get(u.get("arch"), "")
	var left := _rich_line("[b][color=#%s][font_size=20]%s[/font_size][/color][/b]  Lv%d%s" % [
		color, u["name"], level, ("  [color=#ccc]%s[/color]" % row_tag) if row_tag != "" else ""])
	header.add_child(left)
	var hp_lbl := Label.new()
	hp_lbl.text = "%d / %d" % [max(0, roundi(u["hp"])), u["maxHp"]]
	header.add_child(hp_lbl)
	box.add_child(header)

	var hp_bg := ColorRect.new()
	hp_bg.custom_minimum_size = Vector2(0, 10)
	hp_bg.color = Color(0.15, 0.15, 0.15)
	box.add_child(hp_bg)
	var hp_fg := ColorRect.new()
	var hp_frac: float = clamp(float(u["hp"]) / float(u["maxHp"]), 0.0, 1.0)
	# Anchored to hp_bg's own actual size (not a size borrowed from a sibling
	# container) -- a fixed-pixel width computed from status_container's
	# minimum size ignored the card's own content margins and overflowed
	# past the bar at high fractions. Anchors always match the true rect.
	hp_fg.anchor_right = hp_frac
	hp_fg.anchor_bottom = 1.0
	hp_fg.color = Color(0.25, 0.85, 0.30)
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
		ch_bg.color = Color(0.15, 0.15, 0.15)
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
		ch_fg.color = Color(0.85, 0.7, 0.15) if u["isParty"] else Color(0.85, 0.25, 0.25)
		ch_bg.add_child(ch_fg)

	# ATK/MAG/SPD and DEF/RES on one combined line -- DEF/RES still color the
	# lower of the two via _def_res_hint (unchanged), just without the
	# trailing "X lands harder" sentence that used to follow it on its own
	# line.
	var dr := _def_res_hint(u)
	box.add_child(_rich_line(
		"[font_size=13]ATK %d MAG %d SPD %d [color=#%s]DEF %d[/color] [color=#%s]RES %d[/color][/font_size]" % [
			roundi(FarroadCore.eff_atk(u)), roundi(FarroadCore.eff_mag(u)), roundi(u["base"]["spd"]),
			(CRIT_COLOR if dr["flag_d"] else "cccccc"), roundi(dr["def"]),
			(CRIT_COLOR if dr["flag_r"] else "cccccc"), roundi(dr["res"])]))

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
		box.add_child(_rich_line("[font_size=12][color=#%s]RECOVERY 0%%[/color] [color=#%s]— HP regained between waves[/color][/font_size]" % ["8ec99a", DIM_COLOR]))
	elif battle.get("enrage"):
		# Stacks are battle-wide (battle["enrageN"], rising once per turn
		# regardless of who acts) -- every enemy shows the SAME stack count
		# once the gate is open; an enemy just hasn't caught its own stats up
		# to it yet if it hasn't acted since the count last rose.
		var stacks: int = int(battle.get("enrageN", 0))
		var beat: int = battle["beat"]
		var enrage_text: String
		if stacks > 0:
			enrage_text = "⏱ ENRAGED ×%d — +%d%% damage, rising every turn" % [
				stacks, roundi(FarroadCore.ENRAGE_PCT * stacks * 100.0)]
		else:
			enrage_text = "⏱ calm — enrages after turn %d" % FarroadCore.ENRAGE_AFTER
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
		btn.add_theme_color_override("font_color", Color(0.53, 0.53, 0.53))
		btn.add_theme_color_override("font_hover_color", Color(0.75, 0.75, 0.75))
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
	var beat: int = battle["beat"]
	var gate: int = FarroadCore.ENRAGE_AFTER
	var frac: float = clamp(float(beat) / float(gate), 0.0, 1.0)
	enrage_fg.size = Vector2(enrage_bg.size.x * frac, enrage_bg.size.y)
	if beat > gate:
		# Stacks are battle-wide now (battle["enrageN"], rising once per turn
		# regardless of who acts) -- no more per-unit max scan needed.
		var stacks: int = int(battle.get("enrageN", 0))
		# Ian: enrage now scales LINEARLY (1+ENRAGE_PCT*N), not compounding --
		# mirrors the JS display formula exactly (farroad-ui.js's own
		# enrageStacks-driven label).
		var pct := roundi(FarroadCore.ENRAGE_PCT * stacks * 100.0)
		enrage_label.text = ("ENRAGED +%d%% dmg" % pct) if stacks > 0 else "ENRAGED"
	else:
		var turns_left: int = gate - beat + 1
		enrage_label.text = "Enrage in %d turn%s" % [turns_left, "" if turns_left == 1 else "s"]

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
	frame_style.bg_color = Color(1.0, 1.0, 1.0, 0.03)
	frame_style.border_color = Color(0.4, 0.43, 0.5)
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
	turn_order_header.modulate = Color(0.6, 0.65, 0.75)
	add_child(turn_order_header)

	for i in range(TURN_ORDER_COUNT):
		var panel := PanelContainer.new()
		panel.position = Vector2(margin + i * (card_w + gap), top)
		panel.custom_minimum_size = Vector2(card_w, card_h)
		if i == 0:
			# Slot 0 always shows whoever's beat is currently resolving --
			# _refresh_turn_order() is called right after a beat finishes,
			# predicting the NEXT actor via the same pick_next()/chooseFrom
			# logic step() itself uses, so by construction slot 0 stays
			# accurate for the whole duration of that unit's animation. A
			# permanent gold border here, set once, needs no per-beat toggling.
			var active_style := StyleBoxFlat.new()
			active_style.bg_color = Color(0.13, 0.13, 0.15)
			active_style.border_color = Color(1.0, 0.84, 0.0)
			active_style.set_border_width_all(3)
			panel.add_theme_stylebox_override("panel", active_style)
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

## Ian: "the turn order no longer changes, but the actions tied to them
## will still change... I want actions to be locked in once they are on
## the turn order." Root cause: _lock_upcoming_actors (below) already
## protects what ACTUALLY fires in FarroadCore.step() once a unit's turn
## arrives, but FarroadCore.preview() (called every refresh purely to
## DRAW the rail) always reads each unit's CURRENT live `slots` -- so an
## already-locked unit's card could still visibly show a freshly-edited
## action for however long it stayed on the rail, even though step()
## itself was always going to honor the OLD, locked one. Temporarily
## swaps every currently-locked unit's `slots` for its locked snapshot
## before calling the real preview() (restored immediately after), so
## the DISPLAY and the eventual EXECUTION can never disagree. Turn ORDER
## itself never depended on `slots` in the first place (preview()'s own
## ordering compares nextActAt/isParty/spd/slotIndex only), so this only
## ever changes which ACTION text a card shows, never who's shown or in
## what order.
func _preview_respecting_locks() -> Array:
	var locked: Dictionary = battle.get("lockedActors", {})
	if locked.is_empty():
		return FarroadCore.preview(battle, TURN_ORDER_COUNT)
	var originals := {}
	for u in battle["units"]:
		if locked.has(u["id"]):
			originals[u["id"]] = u["slots"]
			u["slots"] = locked[u["id"]]
	var result: Array = FarroadCore.preview(battle, TURN_ORDER_COUNT)
	for u in battle["units"]:
		if originals.has(u["id"]):
			u["slots"] = originals[u["id"]]
	return result

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
		card["name"].modulate = Color(0.45, 0.7, 1.0) if p["isParty"] else Color(1.0, 0.55, 0.4)
		# No camp/element glyph prefix and no speed (×N) line -- just who's
		# acting and what the action is, per direct request. _action_glyph
		# is still used by the Log popup's own per-beat entries, unchanged.
		_fit_label_text(card["action"], p["actionName"], int(_vp.y * 0.014), max_w)

## Post-Milestone-3 APK feedback (Group A2), broadened after later
## feedback ("units still change actions even after they're listed on
## the turn order" -- the original version only locked upcoming[0], the
## very next actor; a unit shown further down the rail (slots 1+) stayed
## fully editable right up until it became slot 0, so an edit made while
## it was still, say, slot 2 silently changed what it did once its turn
## actually arrived). Confirmed via direct reads of FarroadCore.gd's
## choose_from/resolve_condition that action/target SELECTION is fully
## deterministic and RNG-free (only later damage/evade/crit resolution
## rolls) -- so freezing a unit's `slots` for its one upcoming decision is
## 100% safe w.r.t. RNG/parity, no roll is skipped or added either way.
## Writes battle["lockedActors"] (a new transient, unsaved battle field --
## uid -> slots snapshot -- consumed/cleared per-uid by FarroadCore.step()/
## farroad-core.js's own step()): every unit CURRENTLY visible anywhere in
## the turn-order preview gets locked the FIRST time it appears there (not
## re-snapshotted on later refreshes, so a lock always reflects the
## moment a unit first became visible, not whatever it was edited to
## since); a lock is dropped if its unit falls out of the visible window
## entirely without acting (e.g. died), so a later real reappearance gets
## a fresh snapshot rather than a stale leftover one.
func _lock_upcoming_actors(upcoming: Array) -> void:
	if battle.get("lockedActors") == null:
		battle["lockedActors"] = {}
	var locked: Dictionary = battle["lockedActors"]
	var visible_ids := {}
	for p in upcoming:
		var view: UnitView = unit_views_by_name.get(p["unitName"])
		if view == null:
			continue
		var u: Dictionary = view.unit
		visible_ids[u["id"]] = true
		if not locked.has(u["id"]):
			locked[u["id"]] = (u["slots"] as Array).duplicate(true)
	for uid in locked.keys().duplicate():
		if not visible_ids.has(uid):
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

	if is_phys:
		# A LOCAL offset from the actor's own rest position (its shape
		# animates relative to itself -- see _hop's own comment), stopping
		# HOP_STOP_SHORT of the target's rest position rather than closing
		# the full gap.
		var full_delta: Vector2 = dest_rest - actor_view.rest_position
		var approach_offset: Vector2 = full_delta - full_delta.normalized() * (_vp.x * HOP_STOP_SHORT)
		await _hop(actor_view, Vector2.ZERO, approach_offset)
		_apply_hit_effects(e)
		await _hop(actor_view, actor_view.shape.position, Vector2.ZERO)
	else:
		await _animate_projectile(actor_view, dest_world)
		_apply_hit_effects(e)

	await get_tree().create_timer(BEAT_PAUSE).timeout

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
func _hop(actor: UnitView, from: Vector2, to: Vector2) -> void:
	var height: float = _vp.y * HOP_HEIGHT_FRAC
	var tw := create_tween()
	tw.tween_method(func(t: float): actor.shape.position = from.lerp(to, t) + Vector2(0, -height * sin(t * PI)),
		0.0, 1.0, HOP_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

## Magic/ranged attack (and heals): a projectile travels actor -> a
## world-space destination (the real target's own position, or the
## field's center for an AoE action -- see _animate_beat's own dest_world).
func _animate_projectile(actor: UnitView, dest: Vector2) -> void:
	var bolt := Polygon2D.new()
	var r: float = _vp.y * 0.008
	bolt.polygon = PackedVector2Array([Vector2(-r, -r), Vector2(r, -r), Vector2(r, r), Vector2(-r, r)])
	bolt.color = Color(0.6, 0.85, 1.0)
	bolt.position = actor.position
	add_child(bolt)
	var tw := create_tween()
	tw.tween_property(bolt, "position", dest, PROJECTILE_TIME)
	await tw.finished
	bolt.queue_free()

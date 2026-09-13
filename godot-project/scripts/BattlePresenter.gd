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
	# Back rows pushed out toward the screen edges, front rows given a
	# bigger gap from their own back row than before -- both wider apart
	# overall than the original desktop-tuned spacing.
	party_back_x = _vp.x * 0.06
	party_front_x = _vp.x * 0.30
	enemy_front_x = _vp.x * 0.70
	enemy_back_x = _vp.x * 0.94

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
	_place_side(party_front, party_back, party_front_x, party_back_x)
	_place_side(enemy_front, enemy_back, enemy_front_x, enemy_back_x)

func _layout_units(units: Array) -> void:
	# Smaller than the original desktop-tuned size -- a full party/enemy
	# roster (up to 5 + 10) needs to fit comfortably, not just this demo's
	# 1v1/2v2.
	var unit_size: float = _vp.y * 0.05
	var party_front := []
	var party_back := []
	var enemy_front := []
	var enemy_back := []
	for u in units:
		var view := UnitView.new()
		view.setup(u, unit_size)
		add_child(view)
		unit_views_by_id[u["id"]] = view
		unit_views_by_name[u["name"]] = view
		if u["isParty"]:
			(party_front if u.get("row") == "front" else party_back).append(view)
		else:
			(enemy_front if u.get("row") == "front" else enemy_back).append(view)
	_place_side(party_front, party_back, party_front_x, party_back_x)
	_place_side(enemy_front, enemy_back, enemy_front_x, enemy_back_x)

## Assigns every unit on ONE side (front + back combined) a DISTINCT Y slot
## evenly spread across the field, interleaving front/back in the order they
## get slots -- guarantees no two units on the same side ever share a row,
## regardless of how the front/back split falls, scaling cleanly from 1 unit
## up to the engine's real caps (5 party, 10 enemy: 5 front + 5 back). The
## previous version gave front and back EACH their own independent column of
## slots, so e.g. 1 front + 1 back (this demo's exact scenario) landed at
## the identical Y -- directly in front of/behind each other.
func _place_side(front: Array, back: Array, front_x: float, back_x: float) -> void:
	var slots := []   # [{view, x}], in the Y order they'll be assigned
	var fi := 0
	var bi := 0
	while fi < front.size() or bi < back.size():
		if fi < front.size():
			slots.append({"view": front[fi], "x": front_x}); fi += 1
		if bi < back.size():
			slots.append({"view": back[bi], "x": back_x}); bi += 1
	if slots.is_empty():
		return
	var spacing: float = (field_bottom - field_top) / slots.size()
	for i in range(slots.size()):
		var pos := Vector2(slots[i]["x"], field_top + spacing * i + spacing / 2.0)
		slots[i]["view"].position = pos
		slots[i]["view"].rest_position = pos

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
		var stacks: int = int(u.get("enrageN", 0))
		var beat: int = battle["beat"]
		var enrage_text: String
		if stacks > 0:
			enrage_text = "⏱ ENRAGED ×%d — +%d%% damage, rising each of its turns" % [
				stacks, roundi((pow(1.0 + FarroadCore.ENRAGE_PCT, stacks) - 1.0) * 100.0)]
		elif beat > FarroadCore.ENRAGE_AFTER:
			enrage_text = "⏱ calm — enrages on its next turn"
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
	log_popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.75))

func _on_clear_pressed() -> void:
	log_lines.clear()
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
		# Captures `entry` (a Dictionary -- a reference type in GDScript) by
		# reference, so toggling it here correctly mutates the SAME dict
		# still held in log_lines -- mirrors logEntry()'s own
		# d.onclick toggling a class on that same log entry (farroad-ui.js:1804).
		btn.pressed.connect(func():
			entry["expanded"] = not entry["expanded"]
			_rebuild_log_container())
		box.add_child(btn)
		if entry["expanded"]:
			box.add_child(_rich_line("[font_size=12][color=#%s]%s[/color][/font_size]" % [DIM_COLOR, entry["calc"]]))

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
		var max_stacks := 0
		for u in battle["units"]:
			if not u["isParty"] and u["hp"] > 0:
				max_stacks = max(max_stacks, int(u.get("enrageN", 0)))
		# Mirrors the JS display formula exactly (farroad-ui.js:1727) -- each
		# stack multiplies the CURRENT (already-boosted) atk/mag, so N stacks
		# compound to (1+ENRAGE_PCT)^N, not a flat N*ENRAGE_PCT.
		var pct := roundi((pow(1.0 + FarroadCore.ENRAGE_PCT, max_stacks) - 1.0) * 100.0)
		enrage_label.text = ("ENRAGED +%d%% dmg" % pct) if max_stacks > 0 else "ENRAGED"
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

## Recomputes FarroadCore.preview() (a pure simulation, mutates nothing) and
## refreshes each card -- called once up front and again after every beat.
func _refresh_turn_order() -> void:
	var upcoming: Array = [] if battle["over"] != null else FarroadCore.preview(battle, TURN_ORDER_COUNT)
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
	if log_container != null:
		_rebuild_log_container()

## A plain, non-event log line (e.g. "Battle over") -- same storage shape,
## no calc breakdown to expand.
func _append_raw_log(bbcode: String) -> void:
	log_lines.append({"head_bbcode": bbcode, "dmg_text": "", "via_bbcode": "",
		"note_bbcodes": [], "calc": "", "expanded": false})
	if log_container != null:
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

func _run_battle_loop() -> void:
	var guard := 0
	while battle["over"] == null and guard < 300:
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

	if is_phys:
		# A LOCAL offset from the actor's own rest position (its shape
		# animates relative to itself -- see _hop's own comment), stopping
		# HOP_STOP_SHORT of the target's rest position rather than closing
		# the full gap.
		var full_delta: Vector2 = target_view.rest_position - actor_view.rest_position
		var approach_offset: Vector2 = full_delta - full_delta.normalized() * (_vp.x * HOP_STOP_SHORT)
		await _hop(actor_view, Vector2.ZERO, approach_offset)
		_apply_hit_effects(e)
		await _hop(actor_view, actor_view.shape.position, Vector2.ZERO)
	else:
		await _animate_projectile(actor_view, target_view)
		_apply_hit_effects(e)

	await get_tree().create_timer(BEAT_PAUSE).timeout

func _apply_hit_effects(e: Dictionary) -> void:
	for h in e["hits"]:
		var tv: UnitView = unit_views_by_name.get(h["targetName"])
		if tv == null:
			continue
		tv.update_hp()
		if h["evaded"]:
			DamageNumber.spawn(self, tv.damage_spawn_position(), "Evade", Color(0.75, 0.75, 0.75))
		else:
			var color := Color(1.0, 0.55, 0.2) if h.get("crit") else Color(1.0, 0.9, 0.3)
			DamageNumber.spawn(self, tv.damage_spawn_position(), str(h["damage"]), color)
			tv.shake()
	for h in e["heals"]:
		var tv: UnitView = unit_views_by_name.get(h["targetName"])
		if tv == null:
			continue
		tv.update_hp()
		DamageNumber.spawn(self, tv.damage_spawn_position(), "+%d" % h["amount"], Color(0.4, 0.95, 0.5))
	_apply_status_notes(e)

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
func _apply_status_notes(e: Dictionary) -> void:
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
		DamageNumber.spawn(self, tv.damage_spawn_position(), status_id.capitalize(), color)

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

## Magic/ranged attack (and heals): a projectile travels actor -> target.
func _animate_projectile(actor: UnitView, target: UnitView) -> void:
	var bolt := Polygon2D.new()
	var r: float = _vp.y * 0.008
	bolt.polygon = PackedVector2Array([Vector2(-r, -r), Vector2(r, -r), Vector2(r, r), Vector2(-r, r)])
	bolt.color = Color(0.6, 0.85, 1.0)
	bolt.position = actor.position
	add_child(bolt)
	var tw := create_tween()
	tw.tween_property(bolt, "position", target.position, PROJECTILE_TIME)
	await tw.finished
	bolt.queue_free()

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

const TURN_ORDER_COUNT := 5
const HOP_HEIGHT_FRAC := 0.099      # of viewport height (doubled from round 4's 0.0495)
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

func _ready() -> void:
	_vp = get_viewport_rect().size
	field_top = _vp.y * 0.11
	field_bottom = _vp.y * 0.58
	party_back_x = _vp.x * 0.14
	party_front_x = _vp.x * 0.33
	enemy_front_x = _vp.x * 0.62
	enemy_back_x = _vp.x * 0.81

	if not FarroadCore.load_real_content():
		push_error("BattlePresenter: failed to load res://data/content.json")
		return
	FarroadCore.set_wave(1)
	var units := _build_scenario()
	battle = FarroadCore.make_battle(units, {"rng": FarroadCore.make_rng(2222), "enrage": true})
	_layout_units(units)
	_build_log_ui()
	_build_status_ui()
	_build_enrage_ui()
	_build_turn_order_ui()
	_refresh_turn_order()
	_run_battle_loop()

## A real, hand-picked battle from the genuine exported content (Kesh +
## one more roster unit vs 2 real archetypes, split across both rows on
## both sides so the layout actually exercises front/back on each side).
func _build_scenario() -> Array:
	var kesh_def = FarroadCore.roster_by_id("kesh")
	var mirel_def = FarroadCore.roster_by_id("mirel")
	var party := [
		FarroadCore.make_unit({"id": "kesh", "name": "Kesh", "isParty": true, "level": 1, "slotIndex": 0,
			"row": "front", "arch": null,
			"stats": kesh_def["stats"].duplicate(), "maxHp": kesh_def["hp"], "hp": kesh_def["hp"],
			"affinity": kesh_def["affinity"], "chargeAction": kesh_def["chargeAction"],
			"slots": [{"cond": "none", "action": "strike"}, {"cond": "none", "action": "ember"}]}),
		FarroadCore.make_unit({"id": "mirel", "name": "Mirel", "isParty": true, "level": 1, "slotIndex": 1,
			"row": "back",
			"stats": mirel_def["stats"].duplicate(), "maxHp": mirel_def["hp"], "hp": mirel_def["hp"],
			"affinity": mirel_def["affinity"], "chargeAction": mirel_def["chargeAction"],
			"slots": [{"cond": "ally_hp_lte_80", "action": "mend"}, {"cond": "none", "action": "ember"}]})
	]
	var wolf = FarroadCore.ARCH["wolf"]
	var hound = FarroadCore.ARCH["hound"]
	var enemies := [
		FarroadCore.make_unit({"id": "e1", "name": "Roadwolf", "isParty": false, "level": 1, "slotIndex": 10,
			"arch": "wolf", "row": "front", "chargeAction": wolf.get("chargeAction"),
			"stats": {"hp": 180, "atk": wolf["atk"], "mag": wolf["mag"], "def": wolf["def"], "res": wolf["res"],
				"spd": wolf["spd"], "atkCrit": wolf["atkCrit"], "magCrit": wolf["magCrit"], "evade": wolf["evade"]},
			"maxHp": 180, "hp": 180, "slots": wolf["slots"]}),
		FarroadCore.make_unit({"id": "e2", "name": "Roadhound", "isParty": false, "level": 1, "slotIndex": 11,
			"arch": "hound", "row": "back", "chargeAction": hound.get("chargeAction"),
			"stats": {"hp": 140, "atk": hound["atk"], "mag": hound["mag"], "def": hound["def"], "res": hound["res"],
				"spd": hound["spd"], "atkCrit": hound["atkCrit"], "magCrit": hound["magCrit"], "evade": hound["evade"]},
			"maxHp": 140, "hp": 140, "slots": hound["slots"]})
	]
	return party + enemies

func _layout_units(units: Array) -> void:
	var unit_size: float = _vp.y * 0.075
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
## name+level+row tag, HP text+bar, charge action name+bar, ATK/MAG/SPD,
## DEF/RES with the "X lands harder" hint, a weakness line, and (party only)
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

func _build_status_ui() -> void:
	var btn := Button.new()
	btn.text = "Status"
	btn.position = Vector2(_vp.x * 0.74, _vp.y * 0.835)
	btn.custom_minimum_size = Vector2(_vp.x * 0.10, _vp.y * 0.07)
	btn.pressed.connect(_on_status_pressed)
	add_child(btn)

	status_popup = PopupPanel.new()
	_style_popup(status_popup)
	add_child(status_popup)

	var popup_size := Vector2(_vp.x * 0.6, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	status_popup.add_child(scroll)

	status_container = VBoxContainer.new()
	status_container.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	status_container.add_theme_constant_override("separation", 14)
	scroll.add_child(status_container)

func _on_status_pressed() -> void:
	_refresh_status_popup()
	status_popup.popup_centered(Vector2(_vp.x * 0.6, _vp.y * 0.85))

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

	box.add_child(_rich_line("[font_size=13]ATK %d MAG %d SPD %d[/font_size]" % [
		roundi(FarroadCore.eff_atk(u)), roundi(FarroadCore.eff_mag(u)), roundi(u["base"]["spd"])]))

	var dr := _def_res_hint(u)
	var dr_text := "[font_size=13][color=#%s]DEF %d[/color] / [color=#%s]RES %d[/color]" % [
		(CRIT_COLOR if dr["flag_d"] else "cccccc"), roundi(dr["def"]),
		(CRIT_COLOR if dr["flag_r"] else "cccccc"), roundi(dr["res"])]
	if dr["hint"] != "":
		dr_text += "  [i][color=#%s]%s[/color][/i]" % [DIM_COLOR, dr["hint"]]
	dr_text += "[/font_size]"
	box.add_child(_rich_line(dr_text))

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
	return {"def": d, "res": r, "flag_d": flag_d, "flag_r": flag_r,
		"hint": ("physical lands harder" if flag_d else ("magic lands harder" if flag_r else ""))}

func _build_log_ui() -> void:
	var btn := Button.new()
	btn.text = "Log"
	btn.position = Vector2(_vp.x * 0.86, _vp.y * 0.835)
	btn.custom_minimum_size = Vector2(_vp.x * 0.10, _vp.y * 0.07)
	btn.pressed.connect(_on_log_pressed)
	add_child(btn)

	log_popup = PopupPanel.new()
	_style_popup(log_popup)
	add_child(log_popup)

	var popup_size := Vector2(_vp.x * 0.75, _vp.y * 0.75)
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
	log_popup.popup_centered(Vector2(_vp.x * 0.75, _vp.y * 0.75))

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
## ENRAGE_AFTER (20). Past that point enrage is open-ended (each enemy stacks
## +5% ATK/MAG per turn it takes, unbounded, never "complete"), so once the
## gate opens the bar just shows full/red and a label takes over showing the
## CURRENT worst-case (highest-stacked living enemy's) damage increase.
func _build_enrage_ui() -> void:
	var y: float = _vp.y * 0.755
	var w: float = _vp.x * 0.30
	enrage_bg = ColorRect.new()
	enrage_bg.position = Vector2(_vp.x * 0.016, y)
	enrage_bg.size = Vector2(w, _vp.y * 0.012)
	enrage_bg.color = Color(0.16, 0.08, 0.08)
	add_child(enrage_bg)

	enrage_fg = ColorRect.new()
	enrage_fg.position = enrage_bg.position
	enrage_fg.size = Vector2(0, enrage_bg.size.y)
	enrage_fg.color = Color(0.85, 0.2, 0.2)
	add_child(enrage_fg)

	enrage_label = Label.new()
	enrage_label.position = enrage_bg.position + Vector2(w + _vp.x * 0.012, -_vp.y * 0.006)
	enrage_label.add_theme_font_size_override("font_size", int(_vp.y * 0.016))
	enrage_label.modulate = Color(1.0, 0.45, 0.45)
	add_child(enrage_label)
	_refresh_enrage()

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
		enrage_label.text = ""

## "TURN ORDER ->" strip -- mirrors the JS version's preview()-powered strip
## (a fixed row of upcoming-turn cards, not the history log; that's the
## separate Log button/popup above). Always visible, fixed height, no
## scrolling needed since it only ever shows TURN_ORDER_COUNT cards.
func _build_turn_order_ui() -> void:
	var header := Label.new()
	header.text = "TURN ORDER →"
	header.position = Vector2(_vp.x * 0.016, _vp.y * 0.785)
	header.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	header.modulate = Color(0.6, 0.65, 0.75)
	add_child(header)

	var card_w: float = _vp.x * 0.125
	var card_h: float = _vp.y * 0.10
	var gap: float = _vp.x * 0.01
	var top: float = _vp.y * 0.82
	for i in range(TURN_ORDER_COUNT):
		var panel := PanelContainer.new()
		panel.position = Vector2(_vp.x * 0.016 + i * (card_w + gap), top)
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
		name_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.02))
		vbox.add_child(name_lbl)

		var action_lbl := Label.new()
		action_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
		vbox.add_child(action_lbl)

		var speed_lbl := Label.new()
		speed_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.016))
		speed_lbl.modulate = Color(0.65, 0.7, 0.65)
		vbox.add_child(speed_lbl)

		turn_cards.append({"panel": panel, "name": name_lbl, "action": action_lbl, "speed": speed_lbl})

## Recomputes FarroadCore.preview() (a pure simulation, mutates nothing) and
## refreshes each card -- called once up front and again after every beat.
func _refresh_turn_order() -> void:
	var upcoming: Array = [] if battle["over"] != null else FarroadCore.preview(battle, TURN_ORDER_COUNT)
	for i in range(turn_cards.size()):
		var card = turn_cards[i]
		if i >= upcoming.size():
			card["panel"].visible = false
			continue
		card["panel"].visible = true
		var p = upcoming[i]
		card["name"].text = p["unitName"]
		card["name"].modulate = Color(0.45, 0.7, 1.0) if p["isParty"] else Color(1.0, 0.55, 0.4)
		var act = FarroadCore.ACTIONS.get(p["actionId"])
		card["action"].text = _action_glyph(act) + p["actionName"]
		card["speed"].text = "×%d" % roundi(100.0 / p["rank"])

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
		var approach: Vector2 = target_view.rest_position + (actor_view.rest_position - target_view.rest_position).normalized() * (_vp.x * 0.05)
		await _hop(actor_view, actor_view.position, approach)
		_apply_hit_effects(e)
		await _hop(actor_view, actor_view.position, actor_view.rest_position)
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

func _hop(actor: UnitView, from: Vector2, to: Vector2) -> void:
	var height: float = _vp.y * HOP_HEIGHT_FRAC
	var tw := create_tween()
	tw.tween_method(func(t: float): actor.position = from.lerp(to, t) + Vector2(0, -height * sin(t * PI)),
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

class_name PartyPanel
extends Node
## The PARTY tab -- bench/field management, split out of GambitsPanel (which
## originally covered both loadout editing AND roster management together).
## Structural sibling of GambitsPanel/AetherPanel/LorePanel (same "owns its
## own tab-row button + popup" shape), given the live game-state Dictionary
## `g` once at setup() and reading/writing it directly from then on.
##
## Unlike a GAMBITS slot edit (already live via sync_loadout) or an AETHER
## purchase (live via refresh_live_stats), a bench/field change here has no
## real-JS precedent for live-syncing a fight already in progress (confirmed
## by reading the real benchUnit/fieldUnit -- neither touches G.units
## either), so this is a Godot-only enhancement:
## FarroadProgression.refresh_live_party(g) is called after every bench/
## field edit, then BattlePresenter.sync_live_party() is notified (through
## GameController) so the change reaches the current fight immediately
## instead of only the next wave.

var g: Dictionary
var _vp: Vector2
var _parent: GameController

var toggle_button: Button
var popup: PopupPanel
var roster_container: VBoxContainer

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Called by GameController on a viewport resize -- rebuilds just the
## toggle icon at the new size/position, same limitation as the other
## sibling panels' own reflow() (see GambitsPanel.reflow's comment).
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if popup != null and _built_wide != _is_wide():
		_populate_popup()
		if popup.visible:
			_refresh_roster()
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.1675, _vp.y * 0.93), icon_size, "Party", open_menu)

func _build_ui(parent: Node) -> void:
	# 24-item batch's own Group C6 recomputed this to an 8-icon row (Shop
	# added): Units 0.0133, this one 0.1367, Marks 0.2600, Expedition
	# 0.3833, Road (GameController's own button, moved next to Expedition
	# to stay near true center) 0.5067, Quests 0.6300, Settings 0.7533,
	# Shop 0.8767 -- same 0.11*vp.x icon size/0.93*vp.y row as before, just
	# recomputed for 8 slots instead of 7 (duplicated per-file, no shared
	# base).
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.1675, _vp.y * 0.93), icon_size, "Party", open_menu)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	_populate_popup()

var _body: Control
var _built_wide := false

func _is_wide() -> bool:
	return _parent != null and _parent.wide

## Full-screen layout in a wide window, the portrait list otherwise; rebuilt in
## place (the popup itself stays, the controller has hooked into it).
func _populate_popup() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
	_built_wide = _is_wide()
	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.76)
	if _built_wide:
		var r: Rect2i = _parent.full_menu_rect()
		popup_size = Vector2(r.size.x, r.size.y)
	var scroll := ScrollContainer.new()
	_body = scroll
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if _built_wide else ScrollContainer.SCROLL_MODE_AUTO
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40 - (70 if _built_wide else 0), 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "PARTY"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	roster_container = VBoxContainer.new()
	roster_container.add_theme_constant_override("separation", 4)
	root_vbox.add_child(roster_container)

## Same opaque-panel convention every sibling panel already established --
## the default theme's PopupPanel background isn't fully opaque.
func _style_popup(p: PopupPanel) -> void:
	UiKit.style_popup(p)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
## icon, when provided, shows a real icon texture instead of/alongside
## the placeholder text -- every EXISTING call site passes no icon
## (unchanged behavior) until real button art exists (Ian: "prepare for
## real button/icon assets").
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	return UiKit.icon_tab(parent, pos, size, label_text, callback, icon)

func open_menu() -> void:
	_parent.panel_opening(self)
	_refresh_roster()
	popup.popup((_parent.full_menu_rect() if _is_wide() else _parent.menu_popup_rect()))

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as GambitsPanel/AetherPanel/LorePanel's own copy (see
## BattlePresenter.loop_paused's own comment for why this exists).
## Pushes a bench/field edit onto the CURRENT fight immediately -- see this
## file's own header comment for why this needs a dedicated Godot-only
## sync path (no real-JS precedent, unlike GAMBITS/AETHER's live-sync).
func _notify_party_changed() -> void:
	_parent.sync_party_change()

## Pushes a front/back row edit onto the CURRENT fight's on-field sprite
## immediately, animated -- see _on_row_toggle_pressed's own comment for
## why the "self-corrects within one wave" tradeoff was replaced with a
## real live hop (post-Milestone-3 APK feedback, Group A1).
func _notify_row_changed(uid: String) -> void:
	_parent.sync_row_change(uid)

## Mirrors partyRosterHTML/wirePartyRoster (farroad-ui.js:2722-2746) --
## fielded units with a Bench button (disabled at 1 remaining), owned-and-
## benched units with a Field button (disabled at PARTY_CAP). Moved here
## unchanged from GambitsPanel, which used to own this section too.
var _bench_page := 0
const BENCH_PER_PAGE := 12

func _refresh_roster() -> void:
	for c in roster_container.get_children():
		c.queue_free()
	if _built_wide:
		_refresh_roster_wide()
		return

	# Ian: what each row offers, at the top of the Party tab.
	for line in FarroadCore.row_summary():
		var row_lbl := Label.new()
		row_lbl.text = line
		row_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		roster_container.add_child(row_lbl)

	# Ian: filter and sort for units (physical / magic focus, rarity, level...)
	roster_container.add_child(UnitFilter.controls(_refresh_roster))

	_build_presets_section()

	var party_header := Label.new()
	party_header.text = "PARTY"
	party_header.modulate = Palette.PARTY_BLUE
	roster_container.add_child(party_header)
	for uid in UnitFilter.apply(g, FarroadProgression.mc_first(g["party"])):
		roster_container.add_child(_roster_row(uid, "Bench", g["party"].size() <= 1, _on_bench_pressed, true))

	var bench_header := Label.new()
	bench_header.text = "BENCHED"
	bench_header.modulate = Palette.PARTY_BLUE
	roster_container.add_child(bench_header)
	var avail: Array = UnitFilter.apply(g, FarroadProgression.available_for_party(g))
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(none)"
		none_lbl.modulate = Palette.TEXT_DIM
		roster_container.add_child(none_lbl)
	for uid in avail:
		roster_container.add_child(_roster_row(uid, "Field", g["party"].size() >= FarroadProgression.PARTY_CAP, _on_field_pressed))

## Wide windows: the party and the presets on the left, the bench as a paged
## grid on the right, so nothing scrolls.
func _refresh_roster_wide() -> void:
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 28)
	roster_container.add_child(cols)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	left.add_theme_constant_override("separation", 8)
	cols.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.25
	right.add_theme_constant_override("separation", 8)
	cols.add_child(right)
	for line in FarroadCore.row_summary():
		var row_lbl := Label.new()
		row_lbl.text = line
		row_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		left.add_child(row_lbl)
	var party_header := Label.new()
	party_header.text = "PARTY"
	party_header.modulate = Palette.PARTY_BLUE
	left.add_child(party_header)
	for uid in UnitFilter.apply(g, FarroadProgression.mc_first(g["party"])):
		left.add_child(_roster_row(uid, "Bench", g["party"].size() <= 1, _on_bench_pressed, true))
	_build_presets_section(left)

	right.add_child(UnitFilter.controls(_refresh_roster))
	var bench_header := Label.new()
	bench_header.text = "BENCHED"
	bench_header.modulate = Palette.PARTY_BLUE
	right.add_child(bench_header)
	var avail: Array = UnitFilter.apply(g, FarroadProgression.available_for_party(g))
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(none)"
		none_lbl.modulate = Palette.TEXT_DIM
		right.add_child(none_lbl)
		return
	var pages: int = maxi(1, ceili(avail.size() / float(BENCH_PER_PAGE)))
	_bench_page = clampi(_bench_page, 0, pages - 1)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	right.add_child(grid)
	for i in range(_bench_page * BENCH_PER_PAGE, mini(avail.size(), (_bench_page + 1) * BENCH_PER_PAGE)):
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", UiKit.card_style(6))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(_roster_row(avail[i], "Field", g["party"].size() >= FarroadProgression.PARTY_CAP, _on_field_pressed))
		grid.add_child(cell)
	if pages > 1:
		var pager := HBoxContainer.new()
		pager.alignment = BoxContainer.ALIGNMENT_CENTER
		pager.add_theme_constant_override("separation", 16)
		var prev := Button.new()
		prev.text = "‹ Prev"
		prev.disabled = _bench_page == 0
		prev.pressed.connect(func():
			_bench_page -= 1
			_refresh_roster())
		pager.add_child(prev)
		var lbl := Label.new()
		lbl.text = "Page %d of %d" % [_bench_page + 1, pages]
		pager.add_child(lbl)
		var nxt := Button.new()
		nxt.text = "Next ›"
		nxt.disabled = _bench_page >= pages - 1
		nxt.pressed.connect(func():
			_bench_page += 1
			_refresh_roster())
		pager.add_child(nxt)
		right.add_child(pager)

func _roster_row(uid: String, action_text: String, disabled: bool, callback: Callable, show_row_toggle: bool = false) -> Control:
	var row := HBoxContainer.new()
	var name_lbl := Label.new()
	var def = FarroadCore.roster_by_id(uid)
	name_lbl.text = ("%s  Lv %d" % [def["name"], int(g["lvl"].get(uid, 1))]) if def else uid
	name_lbl.custom_minimum_size = Vector2(150.0 if _built_wide else _vp.x * 0.18, 0)
	if _built_wide:
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	# Front/Back toggle -- fielded units only (bench row placement has no
	# effect until fielded anyway). `row` lives on the roster DEFINITION
	# itself (FarroadCore.roster_by_id(uid)["row"]), mutated in place, the
	# same technique apply_custom_mc already uses for kesh's own entry --
	# not a new per-party-instance field.
	if show_row_toggle and def != null:
		var row_btn := Button.new()
		var cur_row: String = def.get("row", "front")
		row_btn.text = "Front" if cur_row == "front" else "Back"
		row_btn.tooltip_text = "Tap to move to the %s row" % ("back" if cur_row == "front" else "front")
		row_btn.pressed.connect(_on_row_toggle_pressed.bind(uid))
		row.add_child(row_btn)
		# Ian: jumping to attack stays the default, running is a per-unit
		# option -- shown once the unit's art has a run animation.
		var frames = load("res://sprites/units/%s.tres" % Appearance.sprite_set(g, uid))
		if frames is SpriteFrames and frames.has_animation("run"):
			var cur_ap: String = str((g.get("approach", {}) as Dictionary).get(uid, "jump"))
			var ap_btn := Button.new()
			ap_btn.text = "Run" if cur_ap == "run" else "Jump"
			ap_btn.tooltip_text = "How this unit reaches its target -- tap to switch"
			ap_btn.pressed.connect(func():
				if not g.has("approach") or g["approach"] == null:
					g["approach"] = {}
				g["approach"][uid] = "jump" if cur_ap == "run" else "run"
				_refresh_roster())
			row.add_child(ap_btn)
	var btn := Button.new()
	btn.text = action_text
	btn.disabled = disabled
	btn.pressed.connect(callback.bind(uid))
	row.add_child(btn)
	return row

## Flips the roster definition's own row field (not a per-party-instance
## copy) -- matches how the real JS's own row-toggle tag mutates BOTH the
## live unit AND C.ROSTER's def (farroad-ui.js:1740-1745), a mechanic that
## already existed in the real game but had no Godot UI surface until now.
## Also pushed onto any matching LIVE g["units"] entry for correctness, and
## (post-Milestone-3 APK feedback, Group A1) now notifies GameController so
## the on-field sprite hops to its new slot immediately instead of waiting
## for the next wave's build_party() -- see _notify_row_changed.
func _on_row_toggle_pressed(uid: String) -> void:
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return
	var new_row: String = "back" if def.get("row", "front") == "front" else "front"
	def["row"] = new_row
	# kept in the save (it used to reset on restart) -- the cloud save and the
	# Arena team read it from there
	if not (g.get("rows") is Dictionary):
		g["rows"] = {}
	g["rows"][uid] = new_row
	for u in g.get("units", []):
		if u["id"] == uid:
			u["row"] = new_row
	_notify_row_changed(uid)
	_refresh_roster()

## 24-item batch, Group E1: "save current party as a default party you
## name. Have up to 10." A name field + Save button, then one row per
## saved preset (name, its members, Load/Delete). Loading goes through the
## same _notify_party_changed live-sync a single bench/field edit already
## uses, so a mid-fight load updates the field immediately too.
var preset_name_edit: LineEdit

func _build_presets_section(host: Container = null) -> void:
	if host == null:
		host = roster_container
	var header := Label.new()
	header.text = "PRESETS (%d/%d)" % [(g["partyPresets"] as Array).size(), FarroadProgression.PARTY_PRESET_CAP]
	header.modulate = Palette.PARTY_BLUE
	host.add_child(header)

	var save_row := HBoxContainer.new()
	preset_name_edit = LineEdit.new()
	preset_name_edit.placeholder_text = "Preset name"
	preset_name_edit.max_length = 24
	preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(preset_name_edit)
	var save_btn := Button.new()
	save_btn.text = "Save current party"
	save_btn.disabled = (g["partyPresets"] as Array).size() >= FarroadProgression.PARTY_PRESET_CAP
	if save_btn.disabled:
		save_btn.tooltip_text = "Up to %d presets -- delete one to save another." % FarroadProgression.PARTY_PRESET_CAP
	save_btn.pressed.connect(_on_save_preset_pressed)
	save_row.add_child(save_btn)
	host.add_child(save_row)

	var presets: Array = g["partyPresets"]
	for i in range(presets.size()):
		var p: Dictionary = presets[i]
		var row := HBoxContainer.new()
		var lbl := Label.new()
		var names: Array = []
		for uid in p["party"]:
			var def = FarroadCore.roster_by_id(uid)
			names.append(def["name"] if def else uid)
		lbl.text = "%s (Power %d) -- %s" % [p["name"], FarroadProgression.party_power_of(g, p["party"]), ", ".join(names)]
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		var load_btn := Button.new()
		load_btn.text = "Load"
		if FarroadProgression.preset_members_available(g, i).is_empty():
			load_btn.disabled = true
			load_btn.tooltip_text = "Every member of this preset is away on an expedition."
		load_btn.pressed.connect(_on_load_preset_pressed.bind(i))
		row.add_child(load_btn)
		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.pressed.connect(_on_delete_preset_pressed.bind(i))
		row.add_child(del_btn)
		host.add_child(row)

func _on_save_preset_pressed() -> void:
	var preset_name: String = preset_name_edit.text.strip_edges()
	if preset_name == "":
		preset_name = "Party %d" % ((g["partyPresets"] as Array).size() + 1)
	if FarroadProgression.save_party_preset(g, preset_name):
		_refresh_roster()

func _on_load_preset_pressed(index: int) -> void:
	if FarroadProgression.load_party_preset(g, index):
		_notify_party_changed()
	_refresh_roster()

func _on_delete_preset_pressed(index: int) -> void:
	if FarroadProgression.delete_party_preset(g, index):
		_refresh_roster()

func _on_bench_pressed(uid: String) -> void:
	if FarroadProgression.bench_unit(g, uid):
		_notify_party_changed()
	_refresh_roster()

func _on_field_pressed(uid: String) -> void:
	if FarroadProgression.field_unit(g, uid):
		_notify_party_changed()
	_refresh_roster()

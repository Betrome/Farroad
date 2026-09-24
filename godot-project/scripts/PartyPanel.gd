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
## GameController, the same dynamic has_method()+call() pattern
## _notify_battle_paused already uses) so the change reaches the current
## fight immediately instead of only the next wave.

var g: Dictionary
var _vp: Vector2
var _parent: Node

var toggle_button: Button
var popup: PopupPanel
var roster_container: VBoxContainer

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Called by GameController on a viewport resize -- rebuilds just the
## toggle icon at the new size/position, same limitation as the other
## sibling panels' own reflow() (see GambitsPanel.reflow's comment).
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.1367, _vp.y * 0.93), icon_size, "Party", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# 24-item batch's own Group C6 recomputed this to an 8-icon row (Shop
	# added): Units 0.0133, this one 0.1367, Marks 0.2600, Expedition
	# 0.3833, Road (GameController's own button, moved next to Expedition
	# to stay near true center) 0.5067, Quests 0.6300, Settings 0.7533,
	# Shop 0.8767 -- same 0.11*vp.x icon size/0.93*vp.y row as before, just
	# recomputed for 8 slots instead of 7 (duplicated per-file, no shared
	# base).
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.1367, _vp.y * 0.93), icon_size, "Party", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.84)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
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
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
## icon, when provided, shows a real icon texture instead of/alongside
## the placeholder text -- every EXISTING call site passes no icon
## (unchanged behavior) until real button art exists (Ian: "prepare for
## real button/icon assets").
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
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
	parent.add_child(btn)
	return btn

func _on_toggle_pressed() -> void:
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	_refresh_roster()
	popup.popup(Rect2i(Vector2i(_vp.x * 0.02, _vp.y * 0.07), Vector2i(_vp.x * 0.96, _vp.y * 0.84)))
	_notify_battle_paused(true)
	# Ian: "add tutorial pop-ups the first time each page/tab is opened" --
	# see GameController._maybe_show_tab_tutorial's own comment.
	if _parent and _parent.has_method("_maybe_show_tab_tutorial"):
		await _parent.call("_maybe_show_tab_tutorial", "party")

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as GambitsPanel/AetherPanel/LorePanel's own copy (see
## BattlePresenter.loop_paused's own comment for why this exists).
func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

## Pushes a bench/field edit onto the CURRENT fight immediately -- see this
## file's own header comment for why this needs a dedicated Godot-only
## sync path (no real-JS precedent, unlike GAMBITS/AETHER's live-sync).
func _notify_party_changed() -> void:
	if _parent and _parent.has_method("_sync_party_change"):
		_parent.call("_sync_party_change")

## Pushes a front/back row edit onto the CURRENT fight's on-field sprite
## immediately, animated -- see _on_row_toggle_pressed's own comment for
## why the "self-corrects within one wave" tradeoff was replaced with a
## real live hop (post-Milestone-3 APK feedback, Group A1).
func _notify_row_changed(uid: String) -> void:
	if _parent and _parent.has_method("_sync_row_change"):
		_parent.call("_sync_row_change", uid)

## Mirrors partyRosterHTML/wirePartyRoster (farroad-ui.js:2722-2746) --
## fielded units with a Bench button (disabled at 1 remaining), owned-and-
## benched units with a Field button (disabled at PARTY_CAP). Moved here
## unchanged from GambitsPanel, which used to own this section too.
func _refresh_roster() -> void:
	for c in roster_container.get_children():
		c.queue_free()

	_build_presets_section()

	var party_header := Label.new()
	party_header.text = "PARTY"
	party_header.modulate = Palette.PARTY_BLUE
	roster_container.add_child(party_header)
	for uid in g["party"]:
		roster_container.add_child(_roster_row(uid, "Bench", g["party"].size() <= 1, _on_bench_pressed, true))

	var bench_header := Label.new()
	bench_header.text = "BENCHED"
	bench_header.modulate = Palette.PARTY_BLUE
	roster_container.add_child(bench_header)
	var avail: Array = FarroadProgression.available_for_party(g)
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(none)"
		none_lbl.modulate = Palette.TEXT_DIM
		roster_container.add_child(none_lbl)
	for uid in avail:
		roster_container.add_child(_roster_row(uid, "Field", g["party"].size() >= FarroadProgression.PARTY_CAP, _on_field_pressed))

func _roster_row(uid: String, action_text: String, disabled: bool, callback: Callable, show_row_toggle: bool = false) -> Control:
	var row := HBoxContainer.new()
	var name_lbl := Label.new()
	var def = FarroadCore.roster_by_id(uid)
	name_lbl.text = def["name"] if def else uid
	name_lbl.custom_minimum_size = Vector2(_vp.x * 0.18, 0)
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

func _build_presets_section() -> void:
	var header := Label.new()
	header.text = "PRESETS (%d/%d)" % [(g["partyPresets"] as Array).size(), FarroadProgression.PARTY_PRESET_CAP]
	header.modulate = Palette.PARTY_BLUE
	roster_container.add_child(header)

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
	roster_container.add_child(save_row)

	var presets: Array = g["partyPresets"]
	for i in range(presets.size()):
		var p: Dictionary = presets[i]
		var row := HBoxContainer.new()
		var lbl := Label.new()
		var names: Array = []
		for uid in p["party"]:
			var def = FarroadCore.roster_by_id(uid)
			names.append(def["name"] if def else uid)
		lbl.text = "%s -- %s" % [p["name"], ", ".join(names)]
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
		roster_container.add_child(row)

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

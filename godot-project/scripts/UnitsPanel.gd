extends Node
## Post-Milestone-3 APK feedback (Group B1, redesigned again after
## real-device testing): the "Units" tab -- a single dropdown-based unit
## picker plus a sub-tab row (Summary/Gambits/Aether/Lore/Equipment)
## showing content INLINE, beneath the picker, in this SAME popup, rather
## than opening a second window. This replaces an earlier design (four
## buttons that opened GAMBITS/AETHER/LORE/EQUIPMENT's own separate
## full-screen popups) after Ian reported that closing a nested popup (the
## Group D action-info popup, shown while one of those was open) closed
## EVERY popup -- Godot's embedded-window system only tracks one exclusive
## top-level popup layer at a time, so a second stacked Window silently
## closed the first the moment it opened. He also explicitly asked for
## this shape directly: "the tabs within the unit pop-up should show up
## beneath them, not as new windows. This way you can swap between units
## easily" -- swapping the dropdown now just rebuilds content_container
## for the new uid, staying on whatever sub-tab was already showing,
## instead of closing/reopening a separate popup each time.
##
## GAMBITS/AETHER/LORE/EQUIPMENT no longer own any popup of their own --
## each exposes build_into(container, uid, host_popup), called here via
## GameController._build_unit_subpanel_content (dynamic dispatch, `_parent`
## stays untyped per this project's convention). This is also the ONLY
## popup any of that content now lives inside, so there's exactly one
## outer ScrollContainer for everything (dropdown+subtabs+content) -- no
## nested scroll containers to fight each other, directly addressing the
## "still inconsistent" scrolling complaint alongside the removed
## horizontal unit-tab-row from the previous round.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""
var current_sub_tab: String = "summary"

var toggle_button: Button
var popup: PopupPanel
var dropdown: OptionButton
var sub_tab_buttons: Dictionary = {}
var content_container: VBoxContainer

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
const SUB_TABS := [["summary", "Summary"], ["gambits", "Gambits"], ["aether", "Aether"], ["lore", "Lore"], ["equipment", "Equipment"]]

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.0288, _vp.y * 0.93), icon_size, "Units", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.0288, _vp.y * 0.93), icon_size, "Units", _on_toggle_pressed)

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
	title.text = "UNITS"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	dropdown = OptionButton.new()
	dropdown.item_selected.connect(_on_dropdown_selected)
	root_vbox.add_child(dropdown)

	var tab_row := HFlowContainer.new()
	tab_row.add_theme_constant_override("h_separation", 6)
	tab_row.add_theme_constant_override("v_separation", 6)
	for entry in SUB_TABS:
		var btn := Button.new()
		btn.text = entry[1]
		btn.pressed.connect(_on_sub_tab_pressed.bind(entry[0]))
		tab_row.add_child(btn)
		sub_tab_buttons[entry[0]] = btn
	root_vbox.add_child(tab_row)

	content_container = VBoxContainer.new()
	content_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(content_container)

## Same opaque-panel convention every sibling panel already established.
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
	_refresh()
	popup.popup(Rect2i(Vector2i(_vp.x * 0.02, _vp.y * 0.07), Vector2i(_vp.x * 0.96, _vp.y * 0.84)))
	_notify_battle_paused(true)
	# Ian: "add tutorial pop-ups the first time each page/tab is opened" --
	# shown over the tab's own already-visible content (matching every
	# other popup's own "over the live game, not a blank screen"
	# convention), only the very first time this tab is ever opened
	# (GameController owns the seen-state + content, see its own
	# _maybe_show_tab_tutorial comment).
	if _parent and _parent.has_method("_maybe_show_tab_tutorial"):
		await _parent.call("_maybe_show_tab_tutorial", "units")

func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _default_uid() -> String:
	if not g["party"].is_empty():
		return g["party"][0]
	var keys: Array = g["owned"].keys()
	return keys[0] if not keys.is_empty() else ""

func _refresh() -> void:
	if selected_uid == "" or not g["owned"].has(selected_uid):
		selected_uid = _default_uid()
	_refresh_dropdown()
	_refresh_sub_tab_styles()
	_refresh_content()

func _refresh_dropdown() -> void:
	dropdown.clear()
	var uids: Array = g["owned"].keys()
	for idx in range(uids.size()):
		var uid: String = uids[idx]
		var def = FarroadCore.roster_by_id(uid)
		var label: String = def["name"] if def else uid
		if not g["party"].has(uid):
			label += " (benched)"
		dropdown.add_item(label, idx)
		if uid == selected_uid:
			dropdown.select(idx)

## Swapping units stays on whatever sub-tab is already showing -- the
## whole point of "so you can swap between units easily" (previously each
## sub-panel had to be independently reopened per unit).
func _on_dropdown_selected(idx: int) -> void:
	var uids: Array = g["owned"].keys()
	if idx < 0 or idx >= uids.size():
		return
	selected_uid = uids[idx]
	_refresh_content()

func _on_sub_tab_pressed(tab: String) -> void:
	current_sub_tab = tab
	_refresh_sub_tab_styles()
	_refresh_content()

func _refresh_sub_tab_styles() -> void:
	for key in sub_tab_buttons.keys():
		sub_tab_buttons[key].disabled = (key == current_sub_tab)

func _refresh_content() -> void:
	for c in content_container.get_children():
		c.queue_free()
	if selected_uid == "":
		var none_lbl := Label.new()
		none_lbl.text = "(no units owned yet)"
		none_lbl.modulate = Palette.TEXT_DIM
		content_container.add_child(none_lbl)
		return
	if current_sub_tab == "summary":
		_build_summary_card()
	elif _parent and _parent.has_method("_build_unit_subpanel_content"):
		_parent.call("_build_unit_subpanel_content", current_sub_tab, content_container, selected_uid, popup)

## A static summary card -- built via FarroadProgression.build_party_unit
## (works for ANY owned uid regardless of fielded/benched status, unlike a
## live BattlePresenter status card, which only exists for a currently-
## fielded unit mid-fight) -- name/rarity color/level/row/HP/base stats.
func _build_summary_card() -> void:
	var def = FarroadCore.roster_by_id(selected_uid)
	if def == null:
		return
	var u: Dictionary = FarroadProgression.build_party_unit(g, selected_uid, 0)
	var level: int = FarroadProgression.level_of(g, selected_uid)

	var name_lbl := RichTextLabel.new()
	name_lbl.bbcode_enabled = true
	name_lbl.fit_content = true
	var rarity: String = def.get("rarity", "common")
	var color: Color = RARITY_COLOR.get(rarity, Color(1, 1, 1))
	name_lbl.text = "[b][color=#%s]%s[/color][/b]  Lv %d  ·  %s row  ·  %s" % [
		color.to_html(false), def["name"], level, def.get("row", "front"), ("Fielded" if g["party"].has(selected_uid) else "Benched")]
	content_container.add_child(name_lbl)

	var hp_lbl := Label.new()
	hp_lbl.text = "HP %d / %d" % [roundi(u["hp"]), roundi(u["maxHp"])]
	content_container.add_child(hp_lbl)

	var stat_lbl := Label.new()
	var base: Dictionary = u["base"]
	stat_lbl.text = "ATK %d   MAG %d   DEF %d   RES %d   SPD %d" % [
		roundi(base["atk"]), roundi(base["mag"]), roundi(base["def"]), roundi(base["res"]), roundi(base["spd"])]
	# Same missing-autowrap overflow class as this batch's other reported
	# popups (GameController's enemy-detail popup had the identical
	# "ATK/MAG/DEF/RES/SPD" line) -- fixed-pixel-font text that doesn't
	# shrink with a narrower _vp.x the way this container's fraction-based
	# width does.
	stat_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	stat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_container.add_child(stat_lbl)

	if def.get("chargeAction"):
		var act = FarroadCore.ACTIONS.get(def["chargeAction"])
		var charge_row := HBoxContainer.new()
		var charge_lbl := Label.new()
		charge_lbl.text = "⚡ Charge action: %s" % (act["name"] if act else def["chargeAction"])
		charge_lbl.modulate = Palette.TEXT_DIM
		charge_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		charge_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		charge_row.add_child(charge_lbl)
		# Ian: "charge actions (both ally and enemy) need inspect icons
		# next to them."
		var charge_id: String = def["chargeAction"]
		var charge_info_btn := Button.new()
		charge_info_btn.text = "ⓘ"
		charge_info_btn.custom_minimum_size = Vector2(36, 0)
		charge_info_btn.pressed.connect(func():
			if _parent and _parent.has_method("_show_action_detail_popup"):
				_parent.call("_show_action_detail_popup", charge_id))
		charge_row.add_child(charge_info_btn)
		content_container.add_child(charge_row)

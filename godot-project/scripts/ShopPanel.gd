extends Node
## 24-item batch, Group C6: the new "Shop" tab -- spend Crystal (a new
## currency, see FarroadProgression.gd's own SHOP_*_PRICE constants) on a
## fixed-price pick of gambits (conditions), actions, units, or equipment.
## Structural sibling of CataloguePanel.gd (same 4-sub-tab-row-over-a-
## scrollable-list shape, no per-unit picker) crossed with LorePanel.gd's
## purchase-row machinery (_style_purchase_button, duplicated here --
## different script, no shared base class in this project). Unlike
## Catalogue (browse-only) or Marks (random gacha), every row here is a
## deliberate pick at a known, fixed price -- Ian's own numbers, verbatim.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var current_tab: String = "gambits"

var toggle_button: Button
var popup: PopupPanel
var tab_buttons: Dictionary = {}
var list_container: VBoxContainer

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
const TABS := [["gambits", "Gambits"], ["actions", "Actions"], ["units", "Units"], ["equipment", "Equipment"]]

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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.8767, _vp.y * 0.93), icon_size, "Shop", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# 24-item batch's own Group C6 -- 8th slot in the bottom row, see
	# MarksPanel.gd's own copy of this comment for the full 8-slot layout.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.8767, _vp.y * 0.93), icon_size, "Shop", _on_toggle_pressed)

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
	title.text = "SHOP"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	crystal_label = Label.new()
	crystal_label.modulate = Palette.TEXT_DIM
	root_vbox.add_child(crystal_label)

	var tab_row := HFlowContainer.new()
	tab_row.add_theme_constant_override("h_separation", 6)
	tab_row.add_theme_constant_override("v_separation", 6)
	for entry in TABS:
		var btn := Button.new()
		btn.text = entry[1]
		btn.pressed.connect(_on_tab_pressed.bind(entry[0]))
		tab_row.add_child(btn)
		tab_buttons[entry[0]] = btn
	root_vbox.add_child(tab_row)

	list_container = VBoxContainer.new()
	list_container.add_theme_constant_override("separation", 6)
	root_vbox.add_child(list_container)

var crystal_label: Label

func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

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
	if _parent and _parent.has_method("_maybe_show_tab_tutorial"):
		await _parent.call("_maybe_show_tab_tutorial", "shop")

func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _on_tab_pressed(tab: String) -> void:
	current_tab = tab
	_refresh()

func _refresh() -> void:
	crystal_label.text = "%d Crystal" % int(g.get("crystal", 0))
	for key in tab_buttons.keys():
		tab_buttons[key].disabled = (key == current_tab)
	for c in list_container.get_children():
		c.queue_free()
	match current_tab:
		"gambits": _refresh_gambits()
		"actions": _refresh_actions()
		"units": _refresh_units()
		"equipment": _refresh_equipment()

func _rarity_name(display_name: String, rarity: String) -> String:
	var color: Color = RARITY_COLOR.get(rarity, Color(1, 1, 1))
	return "[color=#%s]%s[/color]" % [color.to_html(false), display_name]

func _rich_row(bbcode: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.text = bbcode
	return r

## Same available/unavailable color-coding convention every purchase
## screen in this project already uses (LorePanel/AetherPanel's own
## copies) -- duplicated here, different script, no shared base class.
func _style_purchase_button(btn: Button, available: bool) -> void:
	var bg := Color(0.10, 0.42, 0.46) if available else Color(0.18, 0.22, 0.23)
	var bg_hover := Color(0.14, 0.55, 0.60) if available else Color(0.22, 0.26, 0.27)
	var font := Color(0.82, 0.98, 1.0) if available else Color(0.55, 0.6, 0.6)
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = bg
	normal_style.set_corner_radius_all(4)
	normal_style.set_content_margin_all(6)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = bg_hover
	hover_style.set_corner_radius_all(4)
	hover_style.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.add_theme_stylebox_override("disabled", normal_style)
	btn.add_theme_color_override("font_color", font)
	btn.add_theme_color_override("font_disabled_color", font)
	btn.add_theme_color_override("font_hover_color", font)

func _build_buy_row(label_bbcode: String, price: int, callback: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := _rich_row(label_bbcode)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var available: bool = int(g.get("crystal", 0)) >= price
	var btn := Button.new()
	btn.text = "%d Crystal" % price
	btn.disabled = not available
	btn.custom_minimum_size.x = _vp.x * 0.24
	btn.clip_text = true
	btn.pressed.connect(callback)
	_style_purchase_button(btn, available)
	row.add_child(btn)
	return row

func _refresh_gambits() -> void:
	for cid in FarroadCore.ALL_CONDITION_IDS:
		if cid == "none" or g["conditions"].has(cid):
			continue
		list_container.add_child(_build_buy_row(FarroadCore.cond_label(cid),
			FarroadProgression.SHOP_GAMBIT_PRICE, _on_buy_gambit.bind(cid)))
	if list_container.get_child_count() == 0:
		list_container.add_child(_empty_label("Every gambit condition is already owned."))

func _on_buy_gambit(cid: String) -> void:
	if FarroadProgression.buy_shop_gambit(g, cid):
		_notify_currency_changed()
		_refresh()

func _refresh_actions() -> void:
	var mc_charges: Array = g.get("mc", {}).get("acquiredCharges", []) if g.get("mc") != null else []
	for aid in (FarroadCore.equippable() + FarroadCore.CHARGE_ACTIONS):
		var act: Dictionary = FarroadCore.ACTIONS.get(aid, {})
		var is_charge: bool = bool(act.get("isCharge", false))
		var owned: bool = mc_charges.has(aid) if is_charge else (g["actions"] as Array).has(aid)
		if owned:
			continue
		var price: int = int(FarroadProgression.SHOP_ACTION_PRICE.get(act.get("rarity", "common"), 20))
		var suffix: String = " ⚡" if is_charge else ""
		list_container.add_child(_build_buy_row(_rarity_name(act.get("name", aid), act.get("rarity", "common")) + suffix,
			price, _on_buy_action.bind(aid)))
	if list_container.get_child_count() == 0:
		list_container.add_child(_empty_label("Every action is already owned."))

func _on_buy_action(aid: String) -> void:
	if FarroadProgression.buy_shop_action(g, aid):
		_notify_currency_changed()
		_refresh()

func _refresh_units() -> void:
	for def in FarroadCore.ROSTER:
		var uid: String = def["id"]
		if g["owned"].get(uid, false):
			continue
		var price: int = int(FarroadProgression.SHOP_UNIT_PRICE.get(def.get("rarity", "common"), 100))
		list_container.add_child(_build_buy_row(_rarity_name(def["name"], def.get("rarity", "common")),
			price, _on_buy_unit.bind(uid)))
	if list_container.get_child_count() == 0:
		list_container.add_child(_empty_label("Every unit is already owned."))

func _on_buy_unit(uid: String) -> void:
	if FarroadProgression.buy_shop_unit(g, uid):
		_notify_currency_changed()
		_notify_party_changed()
		_refresh()

func _refresh_equipment() -> void:
	for iid in FarroadCore.EQUIPMENT.keys():
		var item: Dictionary = FarroadCore.EQUIPMENT[iid]
		var price: int = int(FarroadProgression.SHOP_EQUIPMENT_PRICE.get(item.get("rarity", "common"), 10))
		var owned: int = int(g["equipInv"].get(iid, 0))
		var suffix: String = " (owned %d)" % owned if owned > 0 else ""
		list_container.add_child(_build_buy_row(_rarity_name(item["name"], item.get("rarity", "common")) + suffix,
			price, _on_buy_equipment.bind(iid)))

func _on_buy_equipment(iid: String) -> void:
	if FarroadProgression.buy_shop_equipment(g, iid):
		_notify_currency_changed()
		_refresh()

func _empty_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Palette.TEXT_DIM
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	return lbl

func _notify_currency_changed() -> void:
	if _parent and _parent.has_method("_refresh_hud"):
		_parent.call("_refresh_hud")

## A Shop unit purchase joins/fields a companion the same way a gacha pull
## can -- same live mid-fight party sync every other unit-acquiring action
## in this project already triggers (PartyPanel's own field/bench edits,
## MarksPanel's pulled-companion case).
func _notify_party_changed() -> void:
	if _parent and _parent.has_method("_sync_party_change"):
		_parent.call("_sync_party_change")

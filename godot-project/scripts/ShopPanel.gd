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
var current_tab: String = "marks"

var toggle_button: Button
var popup: PopupPanel
var tab_buttons: Dictionary = {}
var list_container: VBoxContainer

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
const TABS := [["marks", "Marks"], ["gambits", "Gambits"], ["actions", "Actions"], ["units", "Units"], ["equipment", "Gear"]]

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if popup != null and _built_wide != _is_wide():
		_populate_popup()
		if popup.visible:
			_refresh()
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.7225, _vp.y * 0.93), icon_size, "Shop", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# 24-item batch's own Group C6 -- 8th slot in the bottom row, see
	# MarksPanel.gd's own copy of this comment for the full 8-slot layout.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.7225, _vp.y * 0.93), icon_size, "Shop", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	_populate_popup()

## The popup's body: the full-screen layout in a wide window (categories down
## the left, the goods in a paged grid), the portrait list otherwise. Rebuilt in
## place; the popup itself stays (the controller has hooked into it).
var _body: Control
var _built_wide := false

func _is_wide() -> bool:
	return _parent != null and bool(_parent.get("wide"))

func _populate_popup() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
	tab_buttons = {}
	_built_wide = _is_wide()
	if _built_wide:
		_populate_wide()
		return
	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.76)
	var scroll := ScrollContainer.new()
	_body = scroll
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

const SIDE_W := 190.0

func _populate_wide() -> void:
	var r: Rect2i = _parent.call("full_menu_rect")
	var root := HBoxContainer.new()
	_body = root
	root.custom_minimum_size = Vector2(r.size.x - 24, r.size.y - 24)
	root.add_theme_constant_override("separation", 16)
	popup.add_child(root)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(SIDE_W, 0)
	left.add_theme_constant_override("separation", 8)
	root.add_child(left)
	var title := Label.new()
	title.text = "SHOP"
	title.add_theme_font_size_override("font_size", 20)
	left.add_child(title)
	crystal_label = Label.new()
	crystal_label.modulate = Palette.TEXT_DIM
	left.add_child(crystal_label)
	for entry in TABS:
		var btn := Button.new()
		btn.text = entry[1]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(0, 42)
		btn.pressed.connect(_on_tab_pressed.bind(entry[0]))
		left.add_child(btn)
		tab_buttons[entry[0]] = btn
	var right := ScrollContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(right)
	list_container = VBoxContainer.new()
	list_container.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	list_container.custom_minimum_size = Vector2(r.size.x - SIDE_W - 24.0 - 16.0 - 70.0, 0)
	list_container.add_theme_constant_override("separation", 8)
	right.add_child(list_container)

## Goods go into a paged grid (no scrolling) in a wide window.
var _items: Array = []
var _page := 0
const PAGE_COLS := 3
const PAGE_ROWS := 7

func _add_item(row: Control) -> void:
	if _built_wide:
		_items.append(row)
	else:
		list_container.add_child(row)

func _item_count() -> int:
	return _items.size() if _built_wide else list_container.get_child_count()

func _finish_list() -> void:
	if not _built_wide:
		return
	var per: int = PAGE_COLS * PAGE_ROWS
	var pages: int = maxi(1, ceili(_items.size() / float(per)))
	_page = clampi(_page, 0, pages - 1)
	var grid := GridContainer.new()
	grid.columns = PAGE_COLS
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	list_container.add_child(grid)
	for i in range(_items.size()):
		var row: Control = _items[i]
		if i >= _page * per and i < (_page + 1) * per:
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var cell := PanelContainer.new()
			cell.add_theme_stylebox_override("panel", UiKit.card_style(6))
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cell.add_child(row)
			grid.add_child(cell)
		else:
			row.free()
	_items.clear()
	if pages > 1:
		var pager := HBoxContainer.new()
		pager.alignment = BoxContainer.ALIGNMENT_CENTER
		pager.add_theme_constant_override("separation", 16)
		var prev := Button.new()
		prev.text = "‹ Prev"
		prev.disabled = _page == 0
		prev.pressed.connect(func():
			_page -= 1
			_refresh())
		pager.add_child(prev)
		var lbl := Label.new()
		lbl.text = "Page %d of %d" % [_page + 1, pages]
		pager.add_child(lbl)
		var nxt := Button.new()
		nxt.text = "Next ›"
		nxt.disabled = _page >= pages - 1
		nxt.pressed.connect(func():
			_page += 1
			_refresh())
		pager.add_child(nxt)
		list_container.add_child(pager)

func _style_popup(p: PopupPanel) -> void:
	UiKit.style_popup(p)

func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	return UiKit.icon_tab(parent, pos, size, label_text, callback, icon)

func _on_toggle_pressed() -> void:
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	_refresh()
	popup.popup(_parent.call("full_menu_rect" if _is_wide() else "menu_popup_rect"))
	_notify_battle_paused(true)

func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _on_tab_pressed(tab: String) -> void:
	current_tab = tab
	_page = 0
	_refresh()

func _refresh() -> void:
	crystal_label.text = "%d Crystal" % int(g.get("crystal", 0))
	for key in tab_buttons.keys():
		tab_buttons[key].disabled = (key == current_tab)
		UiKit.tab_selected(tab_buttons[key], key == current_tab, true)
	for c in list_container.get_children():
		c.queue_free()
	crystal_label.visible = current_tab != "marks"
	match current_tab:
		"marks":   # Ian: Marks pulls live in the Shop now
			if _parent and _parent.get("marks_panel") != null:
				var host: Container = list_container
				if _built_wide:
					host = VBoxContainer.new()
					host.custom_minimum_size.x = 640.0
					host.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
					list_container.add_child(host)
				_parent.marks_panel.build_into(host)
		"gambits": _refresh_gambits()
		"actions": _refresh_actions()
		"units": _refresh_units()
		"equipment": _refresh_equipment()
	_finish_list()

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
	UiKit.purchase_button(btn, available)

func _build_buy_row(label_bbcode: String, price: int, callback: Callable, info_method: String = "", info_arg: String = "") -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := _rich_row(label_bbcode)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	# Ian: "Shop: inspection icon to see details of actions, units, etc"
	if info_method != "" and _parent and _parent.has_method(info_method):
		var info_btn := Button.new()
		info_btn.text = "ⓘ"
		info_btn.custom_minimum_size = Vector2(36, 0)
		info_btn.pressed.connect(func(): _parent.call(info_method, info_arg))
		row.add_child(info_btn)
	var available: bool = int(g.get("crystal", 0)) >= price
	var btn := Button.new()
	btn.text = "%d Crystal" % price
	btn.disabled = not available
	btn.custom_minimum_size.x = 104.0 if _built_wide else _vp.x * 0.24
	btn.clip_text = true
	btn.pressed.connect(func():
		_pending_row = row
		_pending_btn = btn
		callback.call())
	_style_purchase_button(btn, available)
	row.add_child(btn)
	return row

## The row whose buy button was just pressed (for the purchase animation).
var _pending_row: Control = null
var _pending_btn: Button = null
## True while a purchase animation plays (the menu must not rebuild under it).
var _anim_busy := false

## Ian: a bought row turns white; a gambit or unit then shrinks away and the
## rows below slide up. Gear and actions flash the same way but stay put (they
## can be bought again). Rebuilds the list once it is done.
func _after_buy(remove_in: bool) -> void:
	var remove: bool = remove_in and not _built_wide   # a grid cell just flashes
	var row: Control = _pending_row
	var pressed_btn: Button = _pending_btn
	_pending_row = null
	_pending_btn = null
	if row == null or not is_instance_valid(row) or not row.is_inside_tree():
		_refresh()
		return
	crystal_label.text = "%d Crystal" % int(g.get("crystal", 0))
	_anim_busy = true
	for ch in row.get_children():
		if ch is Button:
			(ch as Button).disabled = true
	var list: Node = row.get_parent()
	var idx: int = row.get_index()
	var h: float = row.size.y
	var w: float = row.size.x
	var scroll: ScrollContainer = null
	var p: Node = list
	while p != null and scroll == null:
		if p is ScrollContainer:
			scroll = p
		p = p.get_parent()
	var keep: int = scroll.scroll_vertical if scroll != null else 0

	# where the light starts: the middle of the button that was pressed
	var origin := Vector2(w - 40.0, h / 2.0)
	if pressed_btn != null and is_instance_valid(pressed_btn):
		origin = pressed_btn.global_position + pressed_btn.size / 2.0 - row.global_position
	var reach: float = maxf(origin.x, w - origin.x) * 1.25 + h

	# The light: a soft glow that grows out of the button until it fills the
	# row, in one clipped overlay outside the list's layout (top_level) so
	# nothing is re-laid-out while it plays.
	var light := Control.new()
	light.top_level = true
	light.clip_contents = true
	light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	light.global_position = row.global_position
	light.size = Vector2(w, h)
	light.pivot_offset = Vector2.ZERO
	light.z_index = 10
	row.add_child(light)
	var wash := ColorRect.new()
	wash.color = Color(1, 1, 1, 0.0)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wash.size = Vector2(w, h)
	light.add_child(wash)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 128
	gt.height = 128
	var glow := TextureRect.new()
	glow.texture = gt
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	light.add_child(glow)

	# the rows below, to glide up into the gap (moved by transform only)
	var below: Array = []
	var below_y: Array = []
	if remove:
		var kids: Array = list.get_children()
		for i in range(idx + 1, mini(kids.size(), idx + 41)):
			if kids[i] is Control:
				below.append(kids[i])
				below_y.append((kids[i] as Control).position.y)
		row.pivot_offset = Vector2.ZERO

	var tw := create_tween()
	# phase 1: the light expands out of the button
	tw.tween_method(func(t: float):
		var e: float = 1.0 - pow(1.0 - t, 2.0)
		var r: float = reach * e
		glow.size = Vector2(r * 2.0, r * 2.0)
		glow.position = origin - Vector2(r, r)
		wash.color.a = 0.9 * pow(t, 2.2), 0.0, 1.0, 0.17)
	if remove:
		# phase 2: the light shrinks with the row (easing out) as it disappears,
		# and the rows below move up to take its place
		tw.tween_method(func(t: float):
			var e: float = 1.0 - pow(1.0 - t, 3.0)
			var k: float = maxf(0.0001, 1.0 - e)
			row.scale = Vector2(1.0, k)
			light.scale = Vector2(1.0, k)
			var fade: float = clampf((t - 0.55) / 0.45, 0.0, 1.0)
			light.modulate.a = 1.0 - fade
			for i in below.size():
				if is_instance_valid(below[i]):
					(below[i] as Control).position.y = below_y[i] - h * e, 0.0, 1.0, 0.26)
	else:
		# gear and Lore buys: the light eases away and the row stays
		tw.tween_method(func(t: float):
			var e: float = 1.0 - pow(1.0 - t, 3.0)
			light.modulate.a = 1.0 - e, 0.0, 1.0, 0.2)
	await tw.finished
	_anim_busy = false
	_refresh()
	if scroll != null:
		await get_tree().process_frame
		await get_tree().process_frame
		if is_instance_valid(scroll):
			scroll.scroll_vertical = keep

## Ian: "Shop: Filter for actions, gambits, and equipment." Same filters
## as Catalogue/Gambits (ActionFilter), plus rarity; kept while the Shop
## stays open, so buying something doesn't reset them.
var f_target := "any"
var f_stat := "any"
var f_effect := "any"
var f_rarity := "any"
var f_group := "any"
var f_slot := "any"

func _filter_row(dropdowns: Array) -> HBoxContainer:
	var row := HBoxContainer.new()   # one line (Ian)
	row.add_theme_constant_override("separation", 6)
	for d in dropdowns:
		row.add_child(d)
	list_container.add_child(row)
	return row

func _refresh_gambits() -> void:
	_filter_row([ActionFilter.dropdown(ActionFilter.GAMBIT_GROUP_OPTIONS, f_group, func(v): f_group = v; _refresh())])
	var shown := 0
	for cid in FarroadCore.ALL_CONDITION_IDS:
		if cid == "none" or g["conditions"].has(cid):
			continue
		if f_group != "any" and not cid.begins_with(f_group + "_"):
			continue
		shown += 1
		_add_item(_build_buy_row(FarroadCore.cond_label(cid),
			FarroadProgression.SHOP_GAMBIT_PRICE, _on_buy_gambit.bind(cid), "_show_gambit_detail_popup", cid))
	if shown == 0:
		list_container.add_child(_empty_label("No gambit conditions left to buy here."))

func _on_buy_gambit(cid: String) -> void:
	if FarroadProgression.buy_shop_gambit(g, cid):
		_notify_currency_changed()
		_after_buy(true)

func _refresh_actions() -> void:
	# Unowned actions first; owned ones stay buyable and turn into Lore.
	var all_ids: Array = (FarroadCore.equippable() + FarroadCore.CHARGE_ACTIONS).filter(
		func(a): return FarroadProgression.shop_action_available(g, a))
	_filter_row([
		ActionFilter.dropdown(ActionFilter.TARGET_OPTIONS, f_target, func(v): f_target = v; _refresh()),
		ActionFilter.dropdown(ActionFilter.STAT_OPTIONS, f_stat, func(v): f_stat = v; _refresh()),
		ActionFilter.dropdown(ActionFilter.EFFECT_OPTIONS, f_effect, func(v): f_effect = v; _refresh()),
		ActionFilter.dropdown(ActionFilter.RARITY_OPTIONS, f_rarity, func(v): f_rarity = v; _refresh()),
		ActionFilter.sort_dropdown(_refresh)])
	all_ids = ActionFilter.sort_ids(g, all_ids)
	all_ids = all_ids.filter(func(a):
		var ad: Dictionary = FarroadCore.ACTIONS.get(a, {})
		return ActionFilter.passes(ad, f_target, f_stat, f_effect) and (f_rarity == "any" or ad.get("rarity", "common") == f_rarity))
	var owned_ids: Array = all_ids.filter(func(a): return FarroadProgression.shop_action_owned(g, a))
	for aid in all_ids.filter(func(a): return not owned_ids.has(a)) + owned_ids:
		var act: Dictionary = FarroadCore.ACTIONS.get(aid, {})
		var is_charge: bool = bool(act.get("isCharge", false))
		var price: int = int(FarroadProgression.SHOP_ACTION_PRICE.get(act.get("rarity", "common"), 20))
		var label: String = _rarity_name(act.get("name", aid), act.get("rarity", "common")) + (" ⚡" if is_charge else "")
		if owned_ids.has(aid):
			label += "
[font_size=12][color=#%s]Purchase for +1 Lore[/color][/font_size]" % Palette.TEXT_DIM.to_html(false)
		_add_item(_build_buy_row(label, price, _on_buy_action.bind(aid), "_show_action_detail_popup", aid))

func _on_buy_action(aid: String) -> void:
	# the first purchase of an action moves like a gambit or unit (it leaves the
	# list and reappears below as a Lore purchase); buying it again for Lore
	# flashes like gear and stays
	var was_owned: bool = FarroadProgression.shop_action_owned(g, aid)
	if FarroadProgression.buy_shop_action(g, aid):
		_notify_currency_changed()
		_after_buy(not was_owned)

func _refresh_units() -> void:
	for def in FarroadCore.ROSTER:
		var uid: String = def["id"]
		if g["owned"].get(uid, false):
			continue
		var price: int = int(FarroadProgression.SHOP_UNIT_PRICE.get(def.get("rarity", "common"), 100))
		_add_item(_build_buy_row(_rarity_name(def["name"], def.get("rarity", "common")),
			price, _on_buy_unit.bind(uid), "_show_unit_detail_popup", uid))
	if _item_count() == 0:
		list_container.add_child(_empty_label("Every unit is already owned."))

func _on_buy_unit(uid: String) -> void:
	if FarroadProgression.buy_shop_unit(g, uid):
		_notify_currency_changed()
		_notify_party_changed()
		_after_buy(true)

func _refresh_equipment() -> void:
	_filter_row([
		ActionFilter.dropdown(ActionFilter.GEAR_SLOT_OPTIONS, f_slot, func(v): f_slot = v; _refresh()),
		ActionFilter.dropdown(ActionFilter.RARITY_OPTIONS, f_rarity, func(v): f_rarity = v; _refresh()),
		ActionFilter.dropdown(ActionFilter.GEAR_STAT_OPTIONS, ActionFilter.gear_stat, func(v): ActionFilter.gear_stat = v; _refresh()),
		ActionFilter.dropdown(ActionFilter.GEAR_SORT_OPTIONS, ActionFilter.gear_sort, func(v): ActionFilter.gear_sort = v; _refresh())])
	for iid in ActionFilter.gear_ids(FarroadCore.EQUIPMENT.keys(), null, false):
		var item: Dictionary = FarroadCore.EQUIPMENT[iid]
		if f_slot != "any" and item.get("slot") != f_slot:
			continue
		if f_rarity != "any" and item.get("rarity", "common") != f_rarity:
			continue
		var price: int = int(FarroadProgression.SHOP_EQUIPMENT_PRICE.get(item.get("rarity", "common"), 10))
		var owned: int = int(g["equipInv"].get(iid, 0))
		var suffix: String = " (owned %d)" % owned if owned > 0 else ""
		_add_item(_build_buy_row(_rarity_name(item["name"], item.get("rarity", "common")) + suffix,
			price, _on_buy_equipment.bind(iid), "_show_equipment_detail_popup", iid))

func _on_buy_equipment(iid: String) -> void:
	if FarroadProgression.buy_shop_equipment(g, iid):
		_notify_currency_changed()
		_after_buy(false)

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

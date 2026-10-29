class_name CataloguePanel
extends Node
## The Catalogue tab: 5 sub-tabs (Units/Actions/Gambits/Equipment/Enemies),
## each a scrollable list over the relevant content table (FarroadCore's
## ROSTER/ACTIONS/ALL_CONDITION_IDS/EQUIPMENT/ARCH, always fully loaded),
## cross-referenced against what the player has acquired or met. An entry not
## found yet shows only "???".
##
## What counts as "found":
##   Units      -- g["owned"].has(id)
##   Actions    -- FarroadProgression.lore_action_ids(g), the same set the
##                 Lore tab uses for "has the player got this in some form"
##   Gambits    -- g["conditions"].has(id)
##   Equipment  -- g["equipInv"].has(id)
##   Enemies    -- g["seenArch"].has(key), recorded by
##                 FarroadProgression.build_enemies

var g: Dictionary
var _vp: Vector2
var _parent: GameController
var current_tab: String = "units"

var popup: PopupPanel
var tab_buttons: Dictionary = {}
var list_container: VBoxContainer

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
const TABS := [["units", "Units"], ["actions", "Actions"], ["gambits", "Gambits"], ["equipment", "Gear"], ["enemies", "Enemies"]]

## Filter options for gambits and actions (targets, scaling, effects, ...)
## cut down the scrolling. When any filter is active (not "any"), a "???"
## entry is left out entirely: a "???" row that happened to match e.g. a Heals
## filter would reveal that an unfound heal action exists.
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"
var gambit_filter_group: String = "any"

const ACTION_TARGET_OPTIONS := ActionFilter.TARGET_OPTIONS
## "camp" in the name/var is legacy -- see GambitsPanel's own identical
## copy of this comment for the full reasoning (this filters the real
## EFFECTIVE scale stat, not just the coarse phys/mag camp field).
const ACTION_CAMP_OPTIONS := ActionFilter.STAT_OPTIONS
const ACTION_EFFECT_OPTIONS := ActionFilter.EFFECT_OPTIONS
const GAMBIT_GROUP_OPTIONS := [["any", "Any group"], ["self", "Self"], ["ally", "Ally"], ["foe", "Foe"]]

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

func reflow(new_vp: Vector2) -> void:
	# The Catalogue has no bottom-row icon of its own: it is reached from a
	# "Catalogue" button in SettingsPanel's popup (GameController.open_catalogue()).
	# _vp still tracks resizes so a later open_menu() sizes the popup correctly.
	_vp = new_vp
	if popup != null and _built_wide != _is_wide():
		_populate_popup()
		if popup.visible:
			_refresh()

func _build_ui(parent: Node) -> void:
	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	_populate_popup()

var _body: Control
var _built_wide := false

func _is_wide() -> bool:
	return _parent != null and _parent.wide

## Full-screen layout (categories down the left, a paged grid) in a wide
## window, the portrait list otherwise; rebuilt in place.
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
	title.text = "CATALOGUE"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	# 5 sub-tabs fit a full popup width without needing their own scroll --
	# confirmed at the real 412px-wide budget during verification.
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

const SIDE_W := 190.0

func _populate_wide() -> void:
	var r: Rect2i = _parent.full_menu_rect()
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
	title.text = "CATALOGUE"
	title.add_theme_font_size_override("font_size", 20)
	left.add_child(title)
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

## Entries go into a paged grid (no scrolling) in a wide window.
var _items: Array = []
var _page := 0
const PAGE_COLS := 3
const PAGE_ROWS := 8

func _add_item(row: Control) -> void:
	if _built_wide:
		_items.append(row)
	else:
		list_container.add_child(row)

func _finish_list() -> void:
	if not _built_wide or _items.is_empty():
		_items.clear()
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
		var lbl2 := Label.new()
		lbl2.text = "Page %d of %d" % [_page + 1, pages]
		pager.add_child(lbl2)
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

## Called directly by GameController.open_catalogue() (
## SettingsPanel's own "Catalogue" button routes through it) now that this
## panel has no bottom-row icon of its own to click.
func open_menu() -> void:
	_parent.panel_opening(self)
	_refresh()
	popup.popup((_parent.full_menu_rect() if _is_wide() else _parent.menu_popup_rect()))

func _on_tab_pressed(tab: String) -> void:
	current_tab = tab
	_page = 0
	_refresh()

func _refresh() -> void:
	for key in tab_buttons.keys():
		tab_buttons[key].disabled = (key == current_tab)
		UiKit.tab_selected(tab_buttons[key], key == current_tab, true)
	for c in list_container.get_children():
		c.queue_free()
	match current_tab:
		"units": _refresh_units()
		"actions": _refresh_actions()
		"gambits": _refresh_gambits()
		"equipment": _refresh_equipment()
		"enemies": _refresh_enemies()
	_finish_list()

func _unknown_row() -> Label:
	var lbl := Label.new()
	lbl.text = "???"
	lbl.modulate = Palette.TEXT_DIM
	return lbl

func _rarity_name(display_name: String, rarity: String) -> String:
	var color: Color = RARITY_COLOR.get(rarity, Color(1, 1, 1))
	return "[color=#%s]%s[/color]" % [color.to_html(false), display_name]

func _rich_row(bbcode: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.text = bbcode
	return r

func _refresh_units() -> void:
	for def in FarroadCore.ROSTER:
		var uid: String = def["id"]
		if g["owned"].has(uid):
			_add_item(_rich_row("%s -- %s row" % [_rarity_name(def["name"], def.get("rarity", "common")), def.get("row", "front")]))
		else:
			_add_item(_unknown_row())

func _build_filter_dropdown(options: Array, current_value: String, on_change: Callable) -> OptionButton:
	var opt := OptionButton.new()
	for idx in range(options.size()):
		var entry: Array = options[idx]
		opt.add_item(entry[1], idx)
		if entry[0] == current_value:
			opt.select(idx)
	opt.item_selected.connect(func(idx2): on_change.call(options[idx2][0]))
	return UiKit.compact_dropdown(opt)

func _action_passes_filter(act: Dictionary) -> bool:
	return ActionFilter.passes(act, action_filter_target, action_filter_camp, action_filter_effect)

func _refresh_actions() -> void:
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	filter_row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v): action_filter_target = v; _refresh()))
	filter_row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v): action_filter_camp = v; _refresh()))
	filter_row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v): action_filter_effect = v; _refresh()))
	filter_row.add_child(ActionFilter.sort_dropdown(_refresh))
	list_container.add_child(filter_row)

	var known: Array = FarroadProgression.lore_action_ids(g)
	var filters_active: bool = action_filter_target != "any" or action_filter_camp != "any" or action_filter_effect != "any"
	var order: Array = FarroadCore.ACTIONS.keys()
	if ActionFilter.sort_mode != "default":
		# Sorted actions you know first; undiscovered ones stay at the end in
		# their usual order (sorting them by name would give names away).
		order = ActionFilter.sort_ids(g, order.filter(func(a): return known.has(a))) + order.filter(func(a): return not known.has(a))
	for aid in order:
		var act: Dictionary = FarroadCore.ACTIONS[aid]
		var is_known: bool = known.has(aid)
		if filters_active and (not is_known or not _action_passes_filter(act)):
			continue
		if is_known:
			var row := HBoxContainer.new()
			# the action's cost (time until the next turn, 100 = normal)
			var lbl := _rich_row(_rarity_name(act["name"], act.get("rarity", "common")) +
				" Lv%d  [color=#%s]cost %d[/color]" % [FarroadProgression.action_level(g, aid),
					Palette.TEXT_DIM.to_html(false), roundi(float(act["rank"]) * 100.0)])
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_action_info_pressed.bind(aid))
			row.add_child(info_btn)
			_add_item(row)
		else:
			_add_item(_unknown_row())

func _on_action_info_pressed(action_id: String) -> void:
	_parent.show_action_detail_popup(action_id)

func _refresh_gambits() -> void:
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	filter_row.add_child(_build_filter_dropdown(GAMBIT_GROUP_OPTIONS, gambit_filter_group, func(v): gambit_filter_group = v; _refresh()))
	list_container.add_child(filter_row)

	var filters_active: bool = gambit_filter_group != "any"
	for cid in FarroadCore.ALL_CONDITION_IDS:
		if cid == "none":
			continue
		var is_known: bool = g["conditions"].has(cid)
		if filters_active and (not is_known or not cid.begins_with(gambit_filter_group + "_")):
			continue
		if is_known:
			var lbl := Label.new()
			lbl.text = FarroadCore.cond_label(cid)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_add_item(lbl)
		else:
			_add_item(_unknown_row())

func _refresh_equipment() -> void:
	list_container.add_child(ActionFilter.gear_controls(_refresh))
	for iid in ActionFilter.gear_ids(FarroadCore.EQUIPMENT.keys()):
		var item: Dictionary = FarroadCore.EQUIPMENT[iid]
		if g["equipInv"].has(iid):
			var bits: Array = []
			var gmul := FarroadProgression.gear_mul(g, iid)
			for k in ["atk", "mag", "def", "res", "spd"]:
				if item.get(k):
					bits.append("%s +%s" % [k.to_upper(), str(snappedf(float(item[k]) * gmul, 0.1))])
			if item.get("evade"):
				bits.append("Evade +%s%%" % str(snappedf(float(item["evade"]) * gmul * 100.0, 0.1)))
			var owned: int = FarroadProgression.gear_level(g, iid)
			var row := HBoxContainer.new()
			var lbl := _rich_row("%s -- %s (Lv %d)" % [
				_rarity_name(item["name"], item.get("rarity", "common")), ", ".join(bits), owned])
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_equip_info_pressed.bind(iid))
			row.add_child(info_btn)
			_add_item(row)
		else:
			_add_item(_unknown_row())

func _on_equip_info_pressed(item_id: String) -> void:
	# No specific unit context here -- Catalogue browses items outside
	# any one unit's build, so the popup falls back to raw affinity
	# values instead of a per-unit marginal % (see its own comment).
	_parent.show_equipment_detail_popup(item_id, "")

func _refresh_enemies() -> void:
	var seen: Dictionary = g.get("seenArch", {})
	for key in FarroadCore.ARCH.keys():
		var a: Dictionary = FarroadCore.ARCH[key]
		if seen.has(key):
			var row := HBoxContainer.new()
			# the list shows the name (and rarity color) only; the full
			# stat/growth breakdown is in show_enemy_detail_popup
			var lbl := _rich_row(_rarity_name(a["name"], a.get("rarity", "common")))
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_enemy_info_pressed.bind(key))
			row.add_child(info_btn)
			_add_item(row)
		else:
			_add_item(_unknown_row())

	# boss variants (like the Warden) get entries of their own
	_finish_list()
	var bheader := UiKit.make_label("Boss variants", "label")
	list_container.add_child(bheader)
	for bv in BOSS_VARIANTS:
		if seen.has(bv[0]):
			var brow := HBoxContainer.new()
			var blbl := _rich_row("[b]%s[/b] — a title bestowed on enemies on The Road with great potential" % bv[1])
			blbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			brow.add_child(blbl)
			var bbtn := Button.new()
			bbtn.text = "ⓘ"
			bbtn.custom_minimum_size = Vector2(36, 0)
			var arch: String = bv[2]
			var bname: String = bv[1]
			bbtn.pressed.connect(func():
				_parent.show_enemy_detail_popup(arch, bname, true))
			brow.add_child(bbtn)
			_add_item(brow)
		else:
			_add_item(_unknown_row())

## [seen key, display name, archetype] -- bosses that are a stronger
## version of a normal enemy (the elemental bosses have their own entries).
const BOSS_VARIANTS := [["roadwarden", "Warden", "ox"]]

func _on_enemy_info_pressed(arch_key: String) -> void:
	_parent.show_enemy_detail_popup(arch_key)

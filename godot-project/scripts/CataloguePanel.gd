extends Node
## Post-Milestone-3 APK feedback (Group C1): the new "Catalogue" tab -- 5
## sub-tabs (Units/Actions/Gambits/Equipment/Enemies), each a scrollable
## list over the relevant STATIC content table (FarroadCore.ROSTER/ACTIONS/
## ALL_CONDITION_IDS/EQUIPMENT/ARCH -- always fully loaded regardless of
## what the player owns), cross-referenced against what's actually been
## acquired/encountered. An unencountered entry shows only "???".
##
## "Encountered" proxies, none of them new tracking except Enemies:
##   Units      -- g["owned"].has(id)
##   Actions    -- FarroadProgression.lore_action_ids(g) (already the exact
##                 "has the player got this in some form" set LORE's own
##                 tab pool computes -- reused directly, no new logic)
##   Gambits    -- g["conditions"].has(id)
##   Equipment  -- g["equipInv"].has(id)
##   Enemies    -- g["seenArch"].has(key) -- genuinely new, Godot-only
##                 bookkeeping written by FarroadProgression.build_enemies
##                 (see that function's own comment).

var g: Dictionary
var _vp: Vector2
var _parent: Node
var current_tab: String = "units"

var toggle_button: Button
var popup: PopupPanel
var tab_buttons: Dictionary = {}
var list_container: VBoxContainer

const RARITY_COLOR := {"common": Color(1.0, 1.0, 1.0), "rare": Color(0.35, 0.55, 1.0), "legendary": Color(1.0, 0.62, 0.15)}
const TABS := [["units", "Units"], ["actions", "Actions"], ["gambits", "Gambits"], ["equipment", "Equipment"], ["enemies", "Enemies"]]

## Post-Milestone-3 APK feedback (round 2): "add filter options for gambits
## and actions to reduce scrolling. Include such things as targets,
## scaling, effects, etc." -- when any filter dimension is active
## (!= "any"), an unencountered ("???") entry is omitted entirely rather
## than shown filtered-in-or-out -- showing a "???" row that happens to
## match e.g. a Heals filter would itself leak that an unfound heal action
## exists, a real (if small) spoiler an inactive default filter never has
## to worry about.
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"
var gambit_filter_group: String = "any"

const ACTION_TARGET_OPTIONS := [["any", "Any target"], ["foe", "Single foe"], ["allFoes", "All foes"],
	["ally", "Single ally"], ["allAllies", "All allies"], ["self", "Self"], ["deadAlly", "Dead ally"]]
const ACTION_CAMP_OPTIONS := [["any", "Any type"], ["atk", "Physical (scales ATK)"], ["mag", "Magic (scales MAG)"]]
const ACTION_EFFECT_OPTIONS := [["any", "Any effect"], ["heal", "Heals"], ["charge", "Charge action"], ["element", "Elemental"]]
const GAMBIT_GROUP_OPTIONS := [["any", "Any group"], ["self", "Self"], ["ally", "Ally"], ["foe", "Foe"]]

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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.7533, _vp.y * 0.93), icon_size, "Catalog", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.7533, _vp.y * 0.93), icon_size, "Catalog", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.89)
	var scroll := ScrollContainer.new()
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

func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable) -> Button:
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
	parent.add_child(btn)
	return btn

func _on_toggle_pressed() -> void:
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	_refresh()
	popup.popup(Rect2i(Vector2i(_vp.x * 0.02, _vp.y * 0.02), Vector2i(_vp.x * 0.96, _vp.y * 0.89)))
	_notify_battle_paused(true)

func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _on_tab_pressed(tab: String) -> void:
	current_tab = tab
	_refresh()

func _refresh() -> void:
	for key in tab_buttons.keys():
		tab_buttons[key].disabled = (key == current_tab)
	for c in list_container.get_children():
		c.queue_free()
	match current_tab:
		"units": _refresh_units()
		"actions": _refresh_actions()
		"gambits": _refresh_gambits()
		"equipment": _refresh_equipment()
		"enemies": _refresh_enemies()

func _unknown_row() -> Label:
	var lbl := Label.new()
	lbl.text = "???"
	lbl.modulate = Color(0.45, 0.45, 0.45)
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
			list_container.add_child(_rich_row("%s -- %s row" % [_rarity_name(def["name"], def.get("rarity", "common")), def.get("row", "front")]))
		else:
			list_container.add_child(_unknown_row())

func _build_filter_dropdown(options: Array, current_value: String, on_change: Callable) -> OptionButton:
	var opt := OptionButton.new()
	for idx in range(options.size()):
		var entry: Array = options[idx]
		opt.add_item(entry[1], idx)
		if entry[0] == current_value:
			opt.select(idx)
	opt.item_selected.connect(func(idx2): on_change.call(options[idx2][0]))
	return opt

func _action_passes_filter(act: Dictionary) -> bool:
	if action_filter_target != "any" and act.get("tk", "foe") != action_filter_target:
		return false
	if action_filter_camp != "any" and act.get("camp") != action_filter_camp:
		return false
	if action_filter_effect == "heal" and not act.get("heal", false):
		return false
	if action_filter_effect == "charge" and not act.get("isCharge", false):
		return false
	if action_filter_effect == "element" and not act.get("element"):
		return false
	return true

func _refresh_actions() -> void:
	var filter_row := HFlowContainer.new()
	filter_row.add_theme_constant_override("h_separation", 6)
	filter_row.add_theme_constant_override("v_separation", 6)
	filter_row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v): action_filter_target = v; _refresh_actions()))
	filter_row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v): action_filter_camp = v; _refresh_actions()))
	filter_row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v): action_filter_effect = v; _refresh_actions()))
	list_container.add_child(filter_row)

	var known: Array = FarroadProgression.lore_action_ids(g)
	var filters_active: bool = action_filter_target != "any" or action_filter_camp != "any" or action_filter_effect != "any"
	for aid in FarroadCore.ACTIONS.keys():
		var act: Dictionary = FarroadCore.ACTIONS[aid]
		var is_known: bool = known.has(aid)
		if filters_active and (not is_known or not _action_passes_filter(act)):
			continue
		if is_known:
			var row := HBoxContainer.new()
			var lbl := _rich_row(_rarity_name(act["name"], act.get("rarity", "common")))
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_action_info_pressed.bind(aid))
			row.add_child(info_btn)
			list_container.add_child(row)
		else:
			list_container.add_child(_unknown_row())

func _on_action_info_pressed(action_id: String) -> void:
	if _parent and _parent.has_method("_show_action_detail_popup"):
		_parent.call("_show_action_detail_popup", action_id)

func _refresh_gambits() -> void:
	var filter_row := HFlowContainer.new()
	filter_row.add_theme_constant_override("h_separation", 6)
	filter_row.add_theme_constant_override("v_separation", 6)
	filter_row.add_child(_build_filter_dropdown(GAMBIT_GROUP_OPTIONS, gambit_filter_group, func(v): gambit_filter_group = v; _refresh_gambits()))
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
			list_container.add_child(lbl)
		else:
			list_container.add_child(_unknown_row())

func _refresh_equipment() -> void:
	for iid in FarroadCore.EQUIPMENT.keys():
		var item: Dictionary = FarroadCore.EQUIPMENT[iid]
		if g["equipInv"].has(iid):
			var bits: Array = []
			for k in ["atk", "mag", "def", "res", "spd"]:
				if item.get(k):
					bits.append("%s +%s" % [k.to_upper(), str(item[k])])
			if item.get("evade"):
				bits.append("Evade +%s%%" % str(item["evade"] * 100))
			var owned: int = g["equipInv"].get(iid, 0)
			var row := HBoxContainer.new()
			var lbl := _rich_row("%s -- %s (owned %d)" % [
				_rarity_name(item["name"], item.get("rarity", "common")), ", ".join(bits), owned])
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_equip_info_pressed.bind(iid))
			row.add_child(info_btn)
			list_container.add_child(row)
		else:
			list_container.add_child(_unknown_row())

func _on_equip_info_pressed(item_id: String) -> void:
	if _parent and _parent.has_method("_show_equipment_detail_popup"):
		# No specific unit context here -- Catalogue browses items outside
		# any one unit's build, so the popup falls back to raw affinity
		# values instead of a per-unit marginal % (see its own comment).
		_parent.call("_show_equipment_detail_popup", item_id, "")

func _refresh_enemies() -> void:
	var seen: Dictionary = g.get("seenArch", {})
	for key in FarroadCore.ARCH.keys():
		var a: Dictionary = FarroadCore.ARCH[key]
		if seen.has(key):
			var row := HBoxContainer.new()
			var lbl := _rich_row("%s -- ATK %s  DEF %s  RES %s  SPD %s" % [
				_rarity_name(a["name"], a.get("rarity", "common")), str(a["atk"]), str(a["def"]), str(a["res"]), str(a["spd"])])
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_enemy_info_pressed.bind(key))
			row.add_child(info_btn)
			list_container.add_child(row)
		else:
			list_container.add_child(_unknown_row())

func _on_enemy_info_pressed(arch_key: String) -> void:
	if _parent and _parent.has_method("_show_enemy_detail_popup"):
		_parent.call("_show_enemy_detail_popup", arch_key)

class_name UnitsPanel
extends Node
## The Units tab: a dropdown unit picker plus a sub-tab row
## (Summary/Gambits/Aether/Lore/Equipment) whose content is shown inline,
## beneath the picker, in this same popup. Swapping the unit rebuilds
## content_container for the new uid and stays on the current sub-tab.
##
## The Gambits, Aether, Lore and Equipment panels own no popup of their own.
## Each exposes build_into(container, uid, host_popup), called through
## GameController.build_unit_subpanel_content. Opening a second popup from
## inside this one closes everything (Godot's embedded windows allow only one
## exclusive popup at a time), so all of that content lives in this one popup.
## That also means one outer ScrollContainer for everything and no nested
## scroll containers fighting each other.

var g: Dictionary
var _vp: Vector2
var _parent: GameController
var selected_uid: String = ""
var current_sub_tab: String = "summary"

var toggle_button: Button
var popup: PopupPanel
var dropdown: OptionButton
var sub_tab_buttons: Dictionary = {}
var content_container: VBoxContainer

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
const SUB_TABS := [["summary", "Summary"], ["gambits", "Gambits"], ["aether", "Aether"], ["lore", "Lore"], ["equipment", "Gear"]]

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)
	# the summary's numbers follow the game while it is open
	var live := Timer.new()
	live.wait_time = 0.5
	live.autostart = true
	live.timeout.connect(_live_summary)
	add_child(live)

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if popup != null and _built_wide != _is_wide():
		_populate_popup()
		if popup.visible:
			_refresh()
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.0288, _vp.y * 0.93), icon_size, "Units", open_menu)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.0288, _vp.y * 0.93), icon_size, "Units", open_menu)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	_populate_popup()

## The popup's body. A wide window gets the full-screen layout (a unit list on
## the left, the tabs and their page on the right); otherwise the portrait one.
## Rebuilt in place (never the popup itself, which the controller has hooked up).
var _body: Control
var _built_wide := false
var unit_list: VBoxContainer
var unit_list_scroll: ScrollContainer

func _is_wide() -> bool:
	return _parent != null and _parent.wide

func _populate_popup() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
	sub_tab_buttons = {}
	_sum.clear()
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
	title.text = "UNITS"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	# same unit filter/sort as the Party tab
	root_vbox.add_child(UnitFilter.controls(refresh_dropdown))
	dropdown = OptionButton.new()
	dropdown.item_selected.connect(_on_dropdown_selected)
	root_vbox.add_child(dropdown)

	# the five sub-tabs share one row as equal-width buttons
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	for entry in SUB_TABS:
		var btn := Button.new()
		btn.text = entry[1]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.clip_text = true
		btn.add_theme_font_size_override("font_size", maxi(9, int(_vp.x * 0.026)))
		UiKit.compact_tab(btn)
		btn.pressed.connect(_on_sub_tab_pressed.bind(entry[0]))
		tab_row.add_child(btn)
		sub_tab_buttons[entry[0]] = btn
	root_vbox.add_child(tab_row)

	content_container = VBoxContainer.new()
	content_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(content_container)

const LIST_W := 250.0

func _populate_wide() -> void:
	var r: Rect2i = _parent.full_menu_rect()
	var root := HBoxContainer.new()
	_body = root
	root.custom_minimum_size = Vector2(r.size.x - 24, r.size.y - 24)
	root.add_theme_constant_override("separation", 16)
	popup.add_child(root)
	# left: the unit list
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(LIST_W, 0)
	left.add_theme_constant_override("separation", 8)
	root.add_child(left)
	var title := Label.new()
	title.text = "UNITS"
	title.add_theme_font_size_override("font_size", 20)
	left.add_child(title)
	left.add_child(UnitFilter.controls(refresh_dropdown))
	unit_list_scroll = ScrollContainer.new()
	unit_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	unit_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(unit_list_scroll)
	unit_list = VBoxContainer.new()
	unit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	unit_list.add_theme_constant_override("separation", 4)
	unit_list_scroll.add_child(unit_list)
	# the dropdown still exists (hidden) so the rest of the panel keeps one code path
	dropdown = OptionButton.new()
	dropdown.visible = false
	dropdown.item_selected.connect(_on_dropdown_selected)
	left.add_child(dropdown)
	# right: tabs, then the page
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	root.add_child(right)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	tab_row.custom_minimum_size = Vector2(0, 44)
	for entry in SUB_TABS:
		var btn := Button.new()
		btn.text = entry[1]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.clip_text = true
		btn.add_theme_font_size_override("font_size", 15)
		UiKit.compact_tab(btn)
		btn.pressed.connect(_on_sub_tab_pressed.bind(entry[0]))
		tab_row.add_child(btn)
		sub_tab_buttons[entry[0]] = btn
	# keep clear of the always-visible close button at the top right
	var tab_wrap := MarginContainer.new()
	tab_wrap.add_theme_constant_override("margin_right", 70)
	tab_wrap.add_child(tab_row)
	right.add_child(tab_wrap)
	var page_scroll := ScrollContainer.new()
	page_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(page_scroll)
	content_container = VBoxContainer.new()
	content_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_container.custom_minimum_size = Vector2(maxf(300.0, r.size.x - LIST_W - 24.0 - 16.0 - 40.0), 0)
	content_container.add_theme_constant_override("separation", 10)
	page_scroll.add_child(content_container)

func _refresh_unit_list() -> void:
	if unit_list == null or not is_instance_valid(unit_list):
		return
	for c in unit_list.get_children():
		c.queue_free()
	var uids: Array = UnitFilter.apply(g, FarroadProgression.owned_ids(g), [selected_uid])
	for uid in uids:
		var def = FarroadCore.roster_by_id(uid)
		var label: String = def["name"] if def else uid
		label += "   Lv %d" % int(g["lvl"].get(uid, 1))
		if not g["party"].has(uid):
			label += "  (bench)"
		var b := Button.new()
		b.text = label
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.custom_minimum_size = Vector2(0, 40)
		UiKit.tab_selected(b, uid == selected_uid, false)
		b.pressed.connect(func():
			selected_uid = uid
			_refresh_unit_list()
			refresh_content())
		unit_list.add_child(b)

## What the tutorial points at to pick a unit.
func unit_pick_target() -> Control:
	return unit_list_scroll if _built_wide else dropdown

## Same opaque-panel convention every sibling panel already established.
func _style_popup(p: PopupPanel) -> void:
	UiKit.style_popup(p)

## Same icon-square style every sibling panel uses (duplicated here: no
## shared base class). `icon`, when given, shows a real icon texture instead
## of or alongside the placeholder text; no caller passes one yet.
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	return UiKit.icon_tab(parent, pos, size, label_text, callback, icon)

func open_menu() -> void:
	_parent.panel_opening(self)
	# reopening Units starts back on the main character's summary
	selected_uid = "kesh" if g["owned"].has("kesh") else ""
	current_sub_tab = "summary"
	_refresh()
	popup.popup((_parent.full_menu_rect() if _is_wide() else _parent.menu_popup_rect()))

func _default_uid() -> String:
	if not g["party"].is_empty():
		return g["party"][0]
	var keys: Array = FarroadProgression.owned_ids(g)
	return keys[0] if not keys.is_empty() else ""

func _refresh() -> void:
	if selected_uid == "" or not g["owned"].has(selected_uid):
		selected_uid = _default_uid()
	refresh_dropdown()
	_refresh_sub_tab_styles()
	refresh_content()

func refresh_dropdown() -> void:
	_refresh_unit_list()
	dropdown.clear()
	var uids: Array = UnitFilter.apply(g, FarroadProgression.owned_ids(g), [selected_uid])
	for idx in range(uids.size()):
		var uid: String = uids[idx]
		var def = FarroadCore.roster_by_id(uid)
		var label: String = def["name"] if def else uid
		label += "  Lv %d" % int(g["lvl"].get(uid, 1))
		if not g["party"].has(uid):
			label += " (benched)"
		dropdown.add_item(label, idx)
		if uid == selected_uid:
			dropdown.select(idx)

## Swapping units stays on whatever sub-tab is already showing -- the
## whole point of "so you can swap between units easily" (previously each
## sub-panel had to be independently reopened per unit).
func _on_dropdown_selected(idx: int) -> void:
	var uids: Array = UnitFilter.apply(g, FarroadProgression.owned_ids(g), [selected_uid])
	if idx < 0 or idx >= uids.size():
		return
	selected_uid = uids[idx]
	refresh_content()

## Closing (the X, or tapping outside) goes up a level: from a sub-tab to Summary.
func can_go_back() -> bool:
	return current_sub_tab != "summary"

func go_back() -> void:
	_on_sub_tab_pressed("summary")

func _on_sub_tab_pressed(tab: String) -> void:
	# a locked sub-tab says when it opens (Tutorial.gd)
	if not _parent.tab_unlocked(tab):
		if _parent.tutorial != null:
			_parent.tutorial.locked_tap(tab, sub_tab_buttons[tab])
		return
	current_sub_tab = tab
	_refresh_sub_tab_styles()
	refresh_content()

func _refresh_sub_tab_styles() -> void:
	for key in sub_tab_buttons.keys():
		# Gambits, Lore and Gear unlock with their tutorials (Tutorial.gd)
		var open: bool = _parent.tab_unlocked(key)
		sub_tab_buttons[key].disabled = key == current_sub_tab
		UiKit.tab_selected(sub_tab_buttons[key], key == current_sub_tab, true)
		sub_tab_buttons[key].modulate = Color(1, 1, 1, 1) if open else Tutorial.LOCKED_TINT

func refresh_content() -> void:
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
	else:
		_parent.build_unit_subpanel_content(current_sub_tab, content_container, selected_uid, popup)

## A static summary card -- built via FarroadProgression.build_party_unit
## (works for ANY owned uid regardless of fielded/benched status, unlike a
## live BattlePresenter status card, which only exists for a currently-
## fielded unit mid-fight) -- name/rarity color/level/row/HP/base stats.
## ---- live summary values ----
var _sum: Dictionary = {}          # key -> {"node": Label, "f": Callable, "num": float}
var _sum_uid := ""

## The numbers the summary shows, by key.
## The unit's current and maximum HP: the live values from the fight it is in
## (so damage and healing show), or full if it is not in the current battle.
func _live_hp(u: Dictionary) -> Array:
	var battle = g.get("battle")
	if battle is Dictionary:
		for bu in (battle.get("units", []) as Array):
			if str(bu.get("id", "")) == selected_uid:
				return [float(roundi(maxf(0.0, float(bu["hp"])))), float(roundi(float(bu["maxHp"])))]
	var mh: float = float(roundi(u["maxHp"]))
	return [mh, mh]

var _sum_max_hp := 0.0

func _summary_numbers(u: Dictionary) -> Dictionary:
	var base: Dictionary = u["base"]
	var aff: Dictionary = u.get("affinity", {})
	var hp_pair: Array = _live_hp(u)
	_sum_max_hp = float(hp_pair[1])
	var out := {"hp": float(hp_pair[0]), "atk": float(roundi(base["atk"])), "mag": float(roundi(base["mag"])),
		"def": float(roundi(base["def"])), "res": float(roundi(base["res"])), "spd": float(roundi(base["spd"])),
		"atkCrit": float(base.get("atkCrit", 0.0)) * 100.0, "magCrit": float(base.get("magCrit", 0.0)) * 100.0,
		"evade": float(base.get("evade", 0.0)) * 100.0, "charge": float(base.get("chargeRate", 1.0)),
		"recovery": FarroadProgression.recovery_of(g, selected_uid) * 100.0}
	for ax in ["fire", "water", "earth", "air", "light", "dark", "body", "spirit"]:
		out["aff_" + ax] = FarroadCore.affinity_mul(float(aff.get(ax, 0.0))) * 100.0
	return out

func _sum_label(key: String, nums: Dictionary, fmt: String, _unused: int, fn: Callable = Callable()) -> Label:
	var l := Label.new()
	var f: Callable = fn if fn.is_valid() else func(v: float): return fmt % v
	l.text = f.call(float(nums[key]))
	_sum[key] = {"node": l, "f": f, "num": float(nums[key])}
	return l

## Called a couple of times a second: when a value on the open summary has
## changed (a level, an upgrade, gear), it updates in place -- a rise counts
## up with an arrow.
func _live_summary() -> void:
	if popup == null or not popup.visible or current_sub_tab != "summary" or _sum.is_empty() or selected_uid == "":
		return
	_apply_live_summary()

func _apply_live_summary() -> void:
	if _sum.is_empty() or not is_instance_valid(_sum["hp"]["node"]):
		return
	var u: Dictionary = FarroadProgression.build_party_unit(g, selected_uid, 0)
	var old_max: float = _sum_max_hp
	var nums: Dictionary = _summary_numbers(u)
	if not is_equal_approx(old_max, _sum_max_hp) and is_instance_valid(_sum["hp"]["node"]):
		var hf: Callable = _sum["hp"]["f"]
		(_sum["hp"]["node"] as Label).text = hf.call(float(_sum["hp"]["num"]))
	for key in _sum:
		var entry: Dictionary = _sum[key]
		var node: Label = entry["node"]
		var new_v: float = float(nums[key])
		var old_v: float = float(entry["num"])
		if not is_instance_valid(node) or is_equal_approx(new_v, old_v):
			continue
		var f: Callable = entry["f"]
		var final_text: String = f.call(new_v)
		if new_v > old_v:
			ValueTick.animate(node, old_v, new_v, f, final_text)
		else:
			node.text = final_text
		entry["num"] = new_v

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
	name_lbl.text = "[b][color=#%s]%s[/color][/b]  %s  ·  Lv %d  ·  %s row  ·  %s" % [
		color.to_html(false), def["name"], FarroadProgression.unit_title(g, selected_uid), level,
		def.get("row", "front"), ("Fielded" if g["party"].has(selected_uid) else "Benched")]
	content_container.add_child(name_lbl)

	# the item given at wave 100: redo the main character's stats
	if selected_uid == "kesh" and g.get("mc") != null and int(g.get("mcRespecs", 0)) > 0:
		var remake := Button.new()
		remake.text = "Use the Shifted Reflection (x%d) — redo my stats" % int(g["mcRespecs"])
		remake.pressed.connect(func():
			_parent.start_mc_respec())
		content_container.add_child(remake)

	# Every number on the summary is registered so it can update live (see
	# _live_summary): a value that goes up counts up with an arrow.
	_sum.clear()
	var nums: Dictionary = _summary_numbers(u)
	var hp_lbl := _sum_label("hp", nums, "HP %d", 0, func(v: float): return "HP %d / %d" % [v, _sum_max_hp])
	content_container.add_child(hp_lbl)

	var stat_row := HFlowContainer.new()
	stat_row.add_theme_constant_override("h_separation", 16)
	stat_row.add_theme_constant_override("v_separation", 2)
	for k in [["atk", "ATK"], ["mag", "MAG"], ["def", "DEF"], ["res", "RES"], ["spd", "SPD"]]:
		stat_row.add_child(_sum_label(k[0], nums, k[1] + " %d", 0))
	content_container.add_child(stat_row)

	# Summary shows all stats: crit and evade on one row, charge rate and
	# recovery on the next
	var crit_row := HFlowContainer.new()
	crit_row.add_theme_constant_override("h_separation", 16)
	crit_row.add_theme_constant_override("v_separation", 2)
	crit_row.add_child(_sum_label("atkCrit", nums, "ATK crit %.0f%%", 0))
	crit_row.add_child(_sum_label("magCrit", nums, "MAG crit %.0f%%", 0))
	crit_row.add_child(_sum_label("evade", nums, "Evade %.0f%%", 0))
	content_container.add_child(crit_row)
	var rec_row := HBoxContainer.new()
	rec_row.add_theme_constant_override("separation", 16)
	rec_row.add_child(_sum_label("charge", nums, "Charge ×%.2f", 0))
	rec_row.add_child(_sum_label("recovery", nums, "Recovery %.0f%%", 0))
	content_container.add_child(rec_row)

	var aff_row := HFlowContainer.new()
	aff_row.add_theme_constant_override("h_separation", 14)
	aff_row.add_theme_constant_override("v_separation", 2)
	var aff_title := Label.new()
	aff_title.text = "Affinity:"
	aff_row.add_child(aff_title)
	for ax in ["fire", "water", "earth", "air", "light", "dark", "body", "spirit"]:
		aff_row.add_child(_sum_label("aff_" + ax, nums, ax.capitalize() + " %+.0f%%", 0))
	content_container.add_child(aff_row)

	if def.get("chargeAction"):
		var act = FarroadCore.ACTIONS.get(def["chargeAction"])
		var charge_row := HBoxContainer.new()
		var charge_lbl := Label.new()
		charge_lbl.text = "⚡ Charge action: %s" % (act["name"] if act else def["chargeAction"])
		charge_lbl.modulate = Palette.TEXT_DIM
		charge_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		charge_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		charge_row.add_child(charge_lbl)
		# charge actions get an inspect (info) icon next to them
		var charge_id: String = def["chargeAction"]
		var charge_info_btn := Button.new()
		charge_info_btn.text = "ⓘ"
		charge_info_btn.custom_minimum_size = Vector2(36, 0)
		charge_info_btn.pressed.connect(func():
			_parent.show_action_detail_popup(charge_id))
		charge_row.add_child(charge_info_btn)
		content_container.add_child(charge_row)

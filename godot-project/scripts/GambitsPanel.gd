extends Node
## Milestone 3, Step 3c: the GAMBITS tab -- the loadout/AI-rule editor plus
## party bench/field management. Owns its own toggle button + popup (same
## "panel owns its whole UI surface" shape BattlePresenter's Log/Status
## popups already established), given the live game-state Dictionary `g`
## once at setup() and reading/writing it directly from then on -- edits
## reach a unit mid-fight immediately via FarroadProgression.sync_loadout,
## not just on the next wave (see that function's own comment).
##
## Deliberately out of scope for this first pass (see the plan): the
## pre-existing-conflict modal a Field click can trigger in the real game
## (FarroadCore.action_held_by_earlier_fielded already makes any conflict
## safe at combat time -- silent Strike fallback, never a crash -- so this
## is UX polish, not a correctness requirement) and the MC charge-action
## swap dropdown (blocked on Step 3j, character creation).

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""

var toggle_button: Button
var popup: PopupPanel
var roster_container: VBoxContainer
var unit_tabs_container: HBoxContainer
var slots_container: VBoxContainer

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Called by GameController on a viewport resize -- rebuilds just the
## toggle icon at the new size/position. The popup's own inner content
## isn't rebuilt (same limitation BattlePresenter's Status/Log popups have)
## -- only its OUTER size (set fresh from _vp each time it's opened via
## popup_centered) tracks the new viewport; reopening after a resize is
## still correct, just not pixel-perfect on inner padding until reopened.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.18, _vp.y * 0.905), icon_size, "Gambits", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# A blank square placeholder (real art comes later) with a caption below
	# it, left slot of the bottom icon row -- AetherPanel's Aether icon
	# takes the right slot at the same fractions, duplicated there since
	# these are two different scripts with no shared base. Sits BELOW the
	# turn-order strip (cards now end at 0.90 -- see BattlePresenter's
	# reduced card_h) with real clearance, not overlapping it.
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.18, _vp.y * 0.905), icon_size, "Gambits", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "GAMBITS"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	roster_container = VBoxContainer.new()
	roster_container.add_theme_constant_override("separation", 4)
	root_vbox.add_child(roster_container)

	var tabs_label := Label.new()
	tabs_label.text = "Edit loadout for:"
	root_vbox.add_child(tabs_label)

	unit_tabs_container = HBoxContainer.new()
	unit_tabs_container.add_theme_constant_override("separation", 6)
	root_vbox.add_child(unit_tabs_container)

	slots_container = VBoxContainer.new()
	slots_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(slots_container)

## Same opaque-panel convention BattlePresenter._style_popup established --
## the default theme's PopupPanel background isn't fully opaque.
func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style BattlePresenter's own _build_icon_tab uses --
## duplicated here (different script, no shared base). Label lives ON the
## button (`btn.text`) rather than a caption below it, for now -- a caption
## below a corner-anchored square can land outside the visible window on a
## resize (confirmed live); text inside the button's own bounded rect
## can't drift off independently. See BattlePresenter's own copy for the
## fuller comment.
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
	_refresh()
	popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))

func _default_uid() -> String:
	if not g["party"].is_empty():
		return g["party"][0]
	var keys: Array = g["owned"].keys()
	return keys[0] if not keys.is_empty() else ""

func _refresh() -> void:
	if selected_uid == "" or not g["owned"].has(selected_uid):
		selected_uid = _default_uid()
	_refresh_roster()
	_refresh_unit_tabs()
	_refresh_slots()

## Mirrors partyRosterHTML/wirePartyRoster (farroad-ui.js:2722-2746) --
## fielded units with a Bench button (disabled at 1 remaining), owned-and-
## benched units with a Field button (disabled at PARTY_CAP).
func _refresh_roster() -> void:
	for c in roster_container.get_children():
		c.queue_free()

	var party_header := Label.new()
	party_header.text = "PARTY"
	party_header.modulate = Color(0.6, 0.75, 1.0)
	roster_container.add_child(party_header)
	for uid in g["party"]:
		roster_container.add_child(_roster_row(uid, "Bench", g["party"].size() <= 1, _on_bench_pressed))

	var bench_header := Label.new()
	bench_header.text = "BENCHED"
	bench_header.modulate = Color(0.6, 0.75, 1.0)
	roster_container.add_child(bench_header)
	var avail: Array = FarroadProgression.available_for_party(g)
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(none)"
		none_lbl.modulate = Color(0.55, 0.55, 0.55)
		roster_container.add_child(none_lbl)
	for uid in avail:
		roster_container.add_child(_roster_row(uid, "Field", g["party"].size() >= FarroadProgression.PARTY_CAP, _on_field_pressed))

func _roster_row(uid: String, action_text: String, disabled: bool, callback: Callable) -> Control:
	var row := HBoxContainer.new()
	var name_lbl := Label.new()
	var def = FarroadCore.roster_by_id(uid)
	name_lbl.text = def["name"] if def else uid
	name_lbl.custom_minimum_size = Vector2(_vp.x * 0.18, 0)
	row.add_child(name_lbl)
	var btn := Button.new()
	btn.text = action_text
	btn.disabled = disabled
	btn.pressed.connect(callback.bind(uid))
	row.add_child(btn)
	return row

func _on_bench_pressed(uid: String) -> void:
	FarroadProgression.bench_unit(g, uid)
	_refresh()

func _on_field_pressed(uid: String) -> void:
	FarroadProgression.field_unit(g, uid)
	_refresh()

## Mirrors renderUnitTabs(host, cb, true) as used by buildGambits
## (farroad-ui.js:2765) -- EVERY owned unit, fielded or benched, since a
## benched unit's loadout is still editable. A trailing bullet marks a
## benched unit at a glance.
func _refresh_unit_tabs() -> void:
	for c in unit_tabs_container.get_children():
		c.queue_free()
	for uid in g["owned"].keys():
		var def = FarroadCore.roster_by_id(uid)
		var btn := Button.new()
		var label: String = def["name"] if def else uid
		if not g["party"].has(uid):
			label += " •"
		btn.text = label
		btn.disabled = (uid == selected_uid)
		btn.pressed.connect(_on_unit_tab_pressed.bind(uid))
		unit_tabs_container.add_child(btn)

func _on_unit_tab_pressed(uid: String) -> void:
	selected_uid = uid
	_refresh()

## Self -> Ally -> Foe, "none" first -- mirrors sortedOwnedConditions's
## GROUP_ORDER (farroad-ui.js:2773-2780). Every condition id is prefixed
## foe_/ally_/self_ (or is exactly "none") by construction, so the group is
## derivable from the id string with no separate group field to port.
func _cond_group_rank(cond_id: String) -> int:
	if cond_id == "none":
		return 0
	if cond_id.begins_with("self_"):
		return 1
	if cond_id.begins_with("ally_"):
		return 2
	if cond_id.begins_with("foe_"):
		return 3
	return 9

func _sorted_owned_conditions() -> Array:
	var arr: Array = g["conditions"].duplicate()
	arr.sort_custom(func(a, b):
		var ga := _cond_group_rank(a)
		var gb := _cond_group_rank(b)
		if ga != gb:
			return ga < gb
		return FarroadCore.ALL_CONDITION_IDS.find(a) < FarroadCore.ALL_CONDITION_IDS.find(b))
	return arr

## Mirrors buildGambits' per-slot condition/action <select> pair
## (farroad-ui.js:2791-2840) plus the ▲/▼ reorder buttons.
func _refresh_slots() -> void:
	for c in slots_container.get_children():
		c.queue_free()
	if selected_uid == "":
		return
	var slots: Array = FarroadProgression.ensure_loadout(g, selected_uid)
	for i in range(slots.size()):
		var s: Dictionary = slots[i]
		var card := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1, 0.1, 0.12)
		style.set_content_margin_all(10)
		card.add_theme_stylebox_override("panel", style)
		slots_container.add_child(card)

		var vbox := VBoxContainer.new()
		card.add_child(vbox)

		var header := HBoxContainer.new()
		vbox.add_child(header)
		var header_lbl := Label.new()
		header_lbl.text = "Slot %d" % (i + 1)
		header_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(header_lbl)
		var up_btn := Button.new()
		up_btn.text = "▲"
		up_btn.disabled = (i == 0)
		up_btn.pressed.connect(_on_reorder.bind(i, -1))
		header.add_child(up_btn)
		var down_btn := Button.new()
		down_btn.text = "▼"
		down_btn.disabled = (i == slots.size() - 1)
		down_btn.pressed.connect(_on_reorder.bind(i, 1))
		header.add_child(down_btn)

		var if_lbl := Label.new()
		if_lbl.text = "IF"
		if_lbl.modulate = Color(0.65, 0.7, 0.65)
		vbox.add_child(if_lbl)
		vbox.add_child(_build_condition_option(i, s["cond"]))

		var then_lbl := Label.new()
		then_lbl.text = "THEN"
		then_lbl.modulate = Color(0.65, 0.7, 0.65)
		vbox.add_child(then_lbl)
		vbox.add_child(_build_action_option(i, s["action"]))

	var uid_def = FarroadCore.roster_by_id(selected_uid)
	if uid_def and uid_def.get("chargeAction"):
		var act = FarroadCore.ACTIONS.get(uid_def["chargeAction"])
		var charge_lbl := Label.new()
		charge_lbl.text = "⚡ Charge action: %s" % (act["name"] if act else uid_def["chargeAction"])
		charge_lbl.modulate = Color(0.85, 0.7, 0.15)
		slots_container.add_child(charge_lbl)

func _build_condition_option(i: int, current_cond: String) -> OptionButton:
	var opt := OptionButton.new()
	var cond_ids := _sorted_owned_conditions()
	for idx in range(cond_ids.size()):
		var cid: String = cond_ids[idx]
		opt.add_item(FarroadCore.cond_label(cid), idx)
		if cid == current_cond:
			opt.select(idx)
	opt.item_selected.connect(func(idx2): _on_cond_changed(i, cond_ids[idx2]))
	return opt

## Mirrors the action <select> build (farroad-ui.js:2798-2808) -- an
## option already held by another FIELDED unit (per
## FarroadProgression.action_holder_in_party) is disabled with a tooltip,
## except the slot's OWN current selection, which is never disabled even
## if held elsewhere (same aid!==s.action guard the real code uses).
func _build_action_option(i: int, current_action: String) -> OptionButton:
	var opt := OptionButton.new()
	var action_ids: Array = g["actions"]
	for idx in range(action_ids.size()):
		var aid: String = action_ids[idx]
		var act = FarroadCore.ACTIONS.get(aid)
		var label: String = act["name"] if act else aid
		var holder = FarroadProgression.action_holder_in_party(g, aid, selected_uid)
		var blocked: bool = holder != null and aid != current_action
		if blocked:
			label += " (used by %s)" % holder
		opt.add_item(label, idx)
		if blocked:
			opt.set_item_disabled(idx, true)
			opt.set_item_tooltip(idx, "%s is equipped by %s — non-starter actions can only be used by one unit at a time" % [
				act["name"] if act else aid, holder])
		if aid == current_action:
			opt.select(idx)
	opt.item_selected.connect(func(idx2): _on_action_changed(i, action_ids[idx2]))
	return opt

func _on_reorder(i: int, delta: int) -> void:
	var slots: Array = g["loadout"][selected_uid]
	var j := i + delta
	if j < 0 or j >= slots.size():
		return
	var tmp = slots[i]
	slots[i] = slots[j]
	slots[j] = tmp
	g["touched"][selected_uid] = true
	FarroadProgression.sync_loadout(g, selected_uid)
	_refresh_slots()

func _on_cond_changed(i: int, cond_id: String) -> void:
	g["loadout"][selected_uid][i]["cond"] = cond_id
	g["touched"][selected_uid] = true
	FarroadProgression.sync_loadout(g, selected_uid)
	_refresh_slots()

func _on_action_changed(i: int, action_id: String) -> void:
	g["loadout"][selected_uid][i]["action"] = action_id
	g["touched"][selected_uid] = true
	FarroadProgression.sync_loadout(g, selected_uid)
	_refresh_slots()

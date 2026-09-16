extends Node
## Milestone 3, Step 3c: the GAMBITS tab -- the loadout/AI-rule editor.
## Owns its own toggle button + popup (same "panel owns its whole UI
## surface" shape BattlePresenter's Log/Status popups already established),
## given the live game-state Dictionary `g` once at setup() and reading/
## writing it directly from then on -- edits reach a unit mid-fight
## immediately via FarroadProgression.sync_loadout, not just on the next
## wave (see that function's own comment).
##
## Party bench/field management used to live in this same panel; moved out
## to its own PartyPanel.gd (same live-game-Dictionary pattern, own popup).
##
## Deliberately out of scope for this first pass (see the plan): the
## pre-existing-conflict modal a Field click can trigger in the real game
## (FarroadCore.action_held_by_earlier_fielded already makes any conflict
## safe at combat time -- silent Strike fallback, never a crash -- so this
## is UX polish, not a correctness requirement).
##
## Post-Milestone-3 APK feedback (Group B1, then revised again after
## real-device testing): this panel no longer owns any UI surface of its
## own at all -- no icon, no popup. UnitsPanel is the SOLE popup owner for
## GAMBITS/AETHER/LORE/EQUIPMENT now; this panel just builds its existing
## slot-editor content directly into whatever container UnitsPanel hands
## it (build_into), reassigning slots_container each call. This replaced
## an earlier design (open_for_unit showing this panel's OWN separate
## full-screen popup) after Ian reported that closing a nested popup (the
## Group D action-info popup, shown while a GAMBITS-via-Units popup was
## already open) closed EVERY open popup -- Godot's embedded-window system
## only tracks one exclusive popup layer at a time, so a second stacked
## Window silently closed the first the moment it opened; closing the
## second then left nothing visibly open. Reusing ONE popup (UnitsPanel's)
## for all of this sidesteps that class of bug entirely, and is also what
## Ian explicitly asked for: "the tabs within the unit pop-up should show
## up beneath them, not as new windows... so you can swap between units
## easily." sync_loadout's live-sync and the Group A4 charge-action swap
## are unchanged.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""

var slots_container: Container

## Post-Milestone-3 APK feedback (round 3): "I need the filters all places
## actions and gambits show up" -- same dropdown-filter mechanism
## CataloguePanel's Actions/Gambits tabs already established, applied here
## to every slot's own condition/action OptionButton simultaneously (one
## filter row above the slot cards, not per-slot -- narrowing what's
## SELECTABLE, unlike Catalogue's own read-only browsing list). Persists
## across _refresh_slots() calls (a unit swap, a slot edit) since these are
## plain instance vars, not rebuilt each time.
var cond_filter_group: String = "any"
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"

const GAMBIT_GROUP_OPTIONS := [["any", "Any group"], ["self", "Self"], ["ally", "Ally"], ["foe", "Foe"]]
const ACTION_TARGET_OPTIONS := [["any", "Any target"], ["foe", "Single foe"], ["allFoes", "All foes"],
	["ally", "Single ally"], ["allAllies", "All allies"], ["self", "Self"], ["deadAlly", "Dead ally"]]
const ACTION_CAMP_OPTIONS := [["any", "Any type"], ["atk", "Physical (scales ATK)"], ["mag", "Magic (scales MAG)"]]
const ACTION_EFFECT_OPTIONS := [["any", "Any effect"], ["heal", "Heals"], ["charge", "Charge action"], ["element", "Elemental"]]

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp

## Called by UnitsPanel every time the GAMBITS sub-tab is shown (on first
## selection AND on every unit swap while it stays the active sub-tab) --
## `container` is UnitsPanel's own content area. `host_popup` (the Window
## this content now lives inside) is unused here -- this panel has no
## transient dialog of its own (unlike LorePanel's refund confirm) -- kept
## only for a consistent build_into(container, uid, host_popup) signature
## across all 4 folded panels.
func build_into(container: Container, uid: String, _host_popup: Window) -> void:
	selected_uid = uid
	slots_container = container
	_refresh_slots()

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
	if cond_filter_group != "any":
		arr = arr.filter(func(cid): return cid == "none" or cid.begins_with(cond_filter_group + "_"))
	arr.sort_custom(func(a, b):
		var ga := _cond_group_rank(a)
		var gb := _cond_group_rank(b)
		if ga != gb:
			return ga < gb
		return FarroadCore.ALL_CONDITION_IDS.find(a) < FarroadCore.ALL_CONDITION_IDS.find(b))
	return arr

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

func _build_filter_dropdown(options: Array, current_value: String, on_change: Callable) -> OptionButton:
	var opt := OptionButton.new()
	for idx in range(options.size()):
		var entry: Array = options[idx]
		opt.add_item(entry[1], idx)
		if entry[0] == current_value:
			opt.select(idx)
	opt.item_selected.connect(func(idx2): on_change.call(options[idx2][0]))
	return opt

## Post-Milestone-3 APK feedback (round 4): "the filters on the Gambit tab
## are currently confusing. I want them to be within the section where you
## select the gambits and actions themselves." The previous design put ALL
## 4 filter dropdowns in one unlabeled row above every slot card, with no
## visible connection to what they actually narrowed. Now each filter sits
## directly beside the control it governs -- the condition (group) filter
## right next to "IF", the action (target/type/effect) filters right next
## to "THEN" -- shown only once, on the FIRST slot (i==0), since the
## filter STATE is still shared across every slot's own dropdown (a small
## note makes that explicit) rather than repeating the same 4 controls in
## every slot card.
func _build_cond_filter_inline() -> Control:
	var col := VBoxContainer.new()
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "Filter:"
	lbl.modulate = Color(0.55, 0.55, 0.55)
	row.add_child(lbl)
	row.add_child(_build_filter_dropdown(GAMBIT_GROUP_OPTIONS, cond_filter_group, func(v): cond_filter_group = v; _refresh_slots()))
	col.add_child(row)
	var hint := Label.new()
	hint.text = "(applies to every slot's IF dropdown)"
	hint.modulate = Color(0.45, 0.45, 0.45)
	hint.add_theme_font_size_override("font_size", 11)
	col.add_child(hint)
	return col

func _build_action_filter_inline() -> Control:
	var col := VBoxContainer.new()
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 4)
	var lbl := Label.new()
	lbl.text = "Filter:"
	lbl.modulate = Color(0.55, 0.55, 0.55)
	row.add_child(lbl)
	row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v): action_filter_target = v; _refresh_slots()))
	row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v): action_filter_camp = v; _refresh_slots()))
	row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v): action_filter_effect = v; _refresh_slots()))
	col.add_child(row)
	var hint := Label.new()
	hint.text = "(applies to every slot's THEN dropdown)"
	hint.modulate = Color(0.45, 0.45, 0.45)
	hint.add_theme_font_size_override("font_size", 11)
	col.add_child(hint)
	return col

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
		if i == 0:
			vbox.add_child(_build_cond_filter_inline())
		vbox.add_child(_build_condition_option(i, s["cond"]))

		var then_lbl := Label.new()
		then_lbl.text = "THEN"
		then_lbl.modulate = Color(0.65, 0.7, 0.65)
		vbox.add_child(then_lbl)
		if i == 0:
			vbox.add_child(_build_action_filter_inline())
		var action_row := HBoxContainer.new()
		var action_opt := _build_action_option(i, s["action"])
		action_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action_row.add_child(action_opt)
		# Post-Milestone-3 APK feedback (Group D): an info icon next to each
		# slot's action, opening GameController's shared action-detail popup
		# (also used by CataloguePanel's Actions tab) -- .bind() the CURRENT
		# action id, not the slot index, since the info icon should describe
		# whatever's presently selected, same as the dropdown's own label.
		var info_btn := Button.new()
		info_btn.text = "ⓘ"
		info_btn.custom_minimum_size = Vector2(36, 0)
		info_btn.pressed.connect(_on_action_info_pressed.bind(i))
		action_row.add_child(info_btn)
		vbox.add_child(action_row)

	var uid_def = FarroadCore.roster_by_id(selected_uid)
	if uid_def and uid_def.get("chargeAction"):
		# Post-Milestone-3 APK feedback (Group A4): swappable only for the MC
		# ("kesh") with more than one acquired charge action -- mirrors the
		# real JS's own mcOwns/swappable gates (farroad-ui.js:2881,2893)
		# exactly. Every other unit (and a single-charge MC) keeps the
		# existing read-only label.
		var mc = g.get("mc")
		var acquired: Array = mc["acquiredCharges"] if (selected_uid == "kesh" and mc != null) else []
		if acquired.size() > 1:
			var swap_row := HBoxContainer.new()
			var swap_lbl := Label.new()
			swap_lbl.text = "⚡ Charge action:"
			swap_lbl.modulate = Color(0.85, 0.7, 0.15)
			swap_row.add_child(swap_lbl)
			var opt := OptionButton.new()
			for idx in range(acquired.size()):
				var aid: String = acquired[idx]
				var a = FarroadCore.ACTIONS.get(aid)
				opt.add_item(a["name"] if a else aid, idx)
				if aid == uid_def["chargeAction"]:
					opt.select(idx)
			opt.item_selected.connect(func(idx2): _on_charge_action_changed(acquired[idx2]))
			swap_row.add_child(opt)
			# Post-Milestone-3 APK feedback (round 3): "add the informational
			# popups for actions wherever they can be selected" -- this
			# dropdown IS a selectable-action control.
			var swap_info_btn := Button.new()
			swap_info_btn.text = "ⓘ"
			swap_info_btn.custom_minimum_size = Vector2(36, 0)
			swap_info_btn.pressed.connect(_on_charge_info_pressed)
			swap_row.add_child(swap_info_btn)
			slots_container.add_child(swap_row)
			var swap_note := Label.new()
			swap_note.text = "%d charge actions acquired -- swap freely, no cost." % acquired.size()
			swap_note.modulate = Color(0.55, 0.55, 0.55)
			slots_container.add_child(swap_note)
		else:
			var act = FarroadCore.ACTIONS.get(uid_def["chargeAction"])
			var charge_lbl := Label.new()
			charge_lbl.text = "⚡ Charge action: %s" % (act["name"] if act else uid_def["chargeAction"])
			charge_lbl.modulate = Color(0.85, 0.7, 0.15)
			slots_container.add_child(charge_lbl)

func _build_condition_option(i: int, current_cond: String) -> OptionButton:
	var opt := OptionButton.new()
	var cond_ids := _sorted_owned_conditions()
	# The slot's OWN current selection always stays visible/selectable even
	# if a filter would otherwise exclude it -- same "never hide what's
	# actually chosen" rule the action dropdown's own held-elsewhere
	# disable-don't-omit logic already follows.
	if not cond_ids.has(current_cond):
		cond_ids.append(current_cond)
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
	if action_filter_target != "any" or action_filter_camp != "any" or action_filter_effect != "any":
		action_ids = action_ids.filter(func(aid):
			if aid == current_action:
				return true
			var act = FarroadCore.ACTIONS.get(aid)
			return act != null and _action_passes_filter(act))
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

## Post-Milestone-3 APK feedback (Group D) -- reads the slot's CURRENT
## action fresh at press-time (not a value bound at build-time).
func _on_action_info_pressed(i: int) -> void:
	var action_id: String = g["loadout"][selected_uid][i]["action"]
	if _parent and _parent.has_method("_show_action_detail_popup"):
		_parent.call("_show_action_detail_popup", action_id)

## Post-Milestone-3 APK feedback (Group A4).
func _on_charge_action_changed(action_id: String) -> void:
	FarroadProgression.set_mc_charge_action(g, action_id)
	_refresh_slots()

## Post-Milestone-3 APK feedback (round 3) -- reads the MC's CURRENT charge
## action fresh at press-time.
func _on_charge_info_pressed() -> void:
	var uid_def = FarroadCore.roster_by_id(selected_uid)
	if uid_def == null or not uid_def.get("chargeAction"):
		return
	if _parent and _parent.has_method("_show_action_detail_popup"):
		_parent.call("_show_action_detail_popup", uid_def["chargeAction"])

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

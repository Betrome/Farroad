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

## Post-Milestone-3 APK feedback (round 3 asked for filters here at all;
## round 4 moved them beside the IF/THEN controls but still above a plain
## OptionButton; round 5: "I want the filters be in the actual drop downs
## when selecting the actions, not above them... a header at the top of
## the list you scroll through to pare it down some" -- a native
## OptionButton can't embed a filter control inside its own popup at all,
## so the condition/action pickers are no longer OptionButtons: tapping
## the current-selection button now opens GameController's shared
## _show_picker_overlay, whose scrollable list has the filter row as its
## own first entries, followed by the selectable rows -- one list you
## scroll through together. Filter STATE is still these same shared
## instance vars (persists across a unit swap or reopening the picker).
var cond_filter_group: String = "any"
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"

const GAMBIT_GROUP_OPTIONS := [["any", "Any group"], ["self", "Self"], ["ally", "Ally"], ["foe", "Foe"]]
const ACTION_TARGET_OPTIONS := [["any", "Any target"], ["foe", "Single foe"], ["allFoes", "All foes"],
	["ally", "Single ally"], ["allAllies", "All allies"], ["self", "Self"], ["deadAlly", "Dead ally"]]
## "camp" in the name/var is legacy -- this now filters on the action's
## real EFFECTIVE scale stat (act.get("scaleStat"), falling back to the
## camp-implied ATK/MAG when unset -- the exact resolution resolve_hit/
## heal_for themselves use), not just the coarse phys/mag camp field, so
## a DEF/RES/SPD-scaling action (an explicit scaleStat override) shows up
## under its own real stat instead of being lumped into "Physical".
const ACTION_CAMP_OPTIONS := [["any", "Any stat"], ["atk", "Physical (scales ATK)"], ["mag", "Magic (scales MAG)"],
	["def", "Scales DEF"], ["res", "Scales RES"], ["spd", "Scales SPD"], ["avgAtkMag", "Scales ATK+MAG avg"]]
const ACTION_EFFECT_OPTIONS := [["any", "Any effect"], ["heal", "Heals"], ["charge", "Charge action"], ["element", "Elemental"],
	["buff", "Buff effect"], ["debuff", "Debuff effect"]]

## Same swatch-icon technique EquipmentPanel.gd/LorePanel.gd already use --
## a Button (unlike an OptionButton's per-item text) can show ONE icon
## fine, so the picker trigger button and each row inside the picker both
## carry the action's own rarity color this way.
const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
static var _rarity_icon_cache: Dictionary = {}

static func _rarity_icon(rarity: String) -> Texture2D:
	if _rarity_icon_cache.has(rarity):
		return _rarity_icon_cache[rarity]
	var color: Color = RARITY_COLOR.get(rarity, Color(1, 1, 1))
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var tex := ImageTexture.create_from_image(img)
	_rarity_icon_cache[rarity] = tex
	return tex

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
	if action_filter_camp != "any":
		var eff_scale: String = act.get("scaleStat", "mag" if act.get("camp") == "mag" else "atk")
		if eff_scale != action_filter_camp:
			return false
	if action_filter_effect == "heal" and not act.get("heal", false):
		return false
	if action_filter_effect == "charge" and not act.get("isCharge", false):
		return false
	if action_filter_effect == "element" and not act.get("element"):
		return false
	if action_filter_effect == "buff" and not (act.get("applies") and FarroadCore.is_buff_status(act["applies"])):
		return false
	if action_filter_effect == "debuff" and not (act.get("applies") and not FarroadCore.is_buff_status(act["applies"])):
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

## Mirrors buildGambits' per-slot condition/action <select> pair
## (farroad-ui.js:2791-2840) plus the ▲/▼ reorder buttons.
## Group J (20-item batch): rebuilt every refresh, same "just rebuild
## everything" convention this panel already uses for its per-slot cards --
## occupies slot 0 of slots_container, so every per-slot card index below
## is offset by SLOT_CARD_OFFSET (see _on_reorder's own comment for why
## that offset matters).
const SLOT_CARD_OFFSET := 1
func _build_auto_set_row() -> void:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "First-pass suggestion, not a true optimizer -- adjust freely."
	lbl.modulate = Palette.TEXT_DIM
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)
	var btn := Button.new()
	btn.text = "Auto-set"
	btn.pressed.connect(_on_auto_set_pressed)
	row.add_child(btn)
	slots_container.add_child(row)

func _on_auto_set_pressed() -> void:
	FarroadProgression.auto_assign_loadout(g, selected_uid)
	_refresh_slots()

func _refresh_slots() -> void:
	for c in slots_container.get_children():
		c.queue_free()
	if selected_uid == "":
		return
	_build_auto_set_row()
	var slots: Array = FarroadProgression.ensure_loadout(g, selected_uid)
	for i in range(slots.size()):
		var s: Dictionary = slots[i]
		var card := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Palette.BG_PARCHMENT_DEEP
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
		if_lbl.modulate = Palette.TEXT_DIM
		vbox.add_child(if_lbl)
		var cond_btn := Button.new()
		cond_btn.text = FarroadCore.cond_label(s["cond"])
		cond_btn.pressed.connect(_open_condition_picker.bind(i, s["cond"]))
		vbox.add_child(cond_btn)

		var then_lbl := Label.new()
		then_lbl.text = "THEN"
		then_lbl.modulate = Palette.TEXT_DIM
		vbox.add_child(then_lbl)
		var action_row := HBoxContainer.new()
		var cur_act = FarroadCore.ACTIONS.get(s["action"])
		var action_btn := Button.new()
		action_btn.text = cur_act["name"] if cur_act else s["action"]
		action_btn.icon = _rarity_icon(cur_act.get("rarity", "common")) if cur_act else null
		action_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action_btn.pressed.connect(_open_action_picker.bind(i, s["action"]))
		action_row.add_child(action_btn)
		# Post-Milestone-3 APK feedback (Group D): an info icon next to each
		# slot's action, opening GameController's shared action-detail popup
		# (also used by CataloguePanel's Actions tab) -- .bind() the CURRENT
		# action id, not the slot index, since the info icon should describe
		# whatever's presently selected, same as the button's own label.
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
			swap_lbl.modulate = Palette.TEXT_DIM
			swap_row.add_child(swap_lbl)
			var opt := OptionButton.new()
			for idx in range(acquired.size()):
				var aid: String = acquired[idx]
				var a = FarroadCore.ACTIONS.get(aid)
				# 24-item batch, Group D5: same " LvN" tag the normal-action
				# picker already shows.
				opt.add_item((a["name"] if a else aid) + " Lv%d" % FarroadProgression.action_level(g, aid), idx)
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
			swap_note.modulate = Palette.TEXT_DIM
			swap_note.autowrap_mode = TextServer.AUTOWRAP_WORD
			swap_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slots_container.add_child(swap_note)
		else:
			var act = FarroadCore.ACTIONS.get(uid_def["chargeAction"])
			var charge_row := HBoxContainer.new()
			var charge_lbl := Label.new()
			charge_lbl.text = "⚡ Charge action: %s Lv%d" % [(act["name"] if act else uid_def["chargeAction"]),
				FarroadProgression.action_level(g, uid_def["chargeAction"])]
			charge_lbl.modulate = Palette.TEXT_DIM
			charge_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
			charge_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			charge_row.add_child(charge_lbl)
			# Ian: "charge actions (both ally and enemy) need inspect icons
			# next to them" -- reuses the SAME _on_charge_info_pressed the
			# swappable (acquired > 1) case above already had.
			var charge_info_btn := Button.new()
			charge_info_btn.text = "ⓘ"
			charge_info_btn.custom_minimum_size = Vector2(36, 0)
			charge_info_btn.pressed.connect(_on_charge_info_pressed)
			charge_row.add_child(charge_info_btn)
			slots_container.add_child(charge_row)

## Post-Milestone-3 APK feedback (round 5): opens a filterable picker
## overlay (GameController._show_picker_overlay) instead of a native
## OptionButton -- the filter row is the scrollable list's own first
## entry, everything scrolls together. `populate` is a self-referencing
## closure (declared, then assigned, so it can call itself from a filter
## dropdown's own on_change handler to rebuild the list in place without
## closing the overlay) -- the same recursive-closure shape GDScript
## lambdas support natively.
func _open_condition_picker(i: int, current_cond: String) -> void:
	if not (_parent and _parent.has_method("_show_picker_overlay")):
		return
	_parent.call("_show_picker_overlay", "Choose condition", func(list_container: Container, backdrop: Node):
		_populate_condition_picker(list_container, backdrop, i, current_cond))

## Rebuilds the condition picker's scrollable list (filter row first, then
## rows) -- called once when the picker opens AND again, directly by name,
## from the filter dropdown's own on_change handler below. A NAMED method
## call rather than a self-referencing local `var populate: Callable`
## closure deliberately -- GDScript lambdas capture enclosing locals by a
## snapshot tied to the lambda's own creation, which does not reliably
## survive a lambda calling ITSELF by name from inside its own body across
## re-invocations (confirmed by a real "Attempt to call function on a null
## instance" error when the filter dropdown fired) -- a plain method call
## has no such lifetime ambiguity.
func _populate_condition_picker(list_container: Container, backdrop: Node, i: int, current_cond: String) -> void:
	for c in list_container.get_children():
		c.queue_free()
	var filter_row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "Filter:"
	lbl.modulate = Palette.TEXT_DIM
	filter_row.add_child(lbl)
	filter_row.add_child(_build_filter_dropdown(GAMBIT_GROUP_OPTIONS, cond_filter_group, func(v):
		cond_filter_group = v
		_populate_condition_picker(list_container, backdrop, i, current_cond)))
	list_container.add_child(filter_row)

	var cond_ids := _sorted_owned_conditions()
	# The slot's OWN current selection always stays listed even if a
	# filter would otherwise exclude it -- same "never hide what's
	# actually chosen" rule the action picker's own held-elsewhere
	# disable-don't-omit logic follows below.
	if not cond_ids.has(current_cond):
		cond_ids.append(current_cond)
	for cid in cond_ids:
		var row_btn := Button.new()
		row_btn.text = FarroadCore.cond_label(cid)
		row_btn.disabled = (cid == current_cond)
		row_btn.pressed.connect(func():
			_on_cond_changed(i, cid)
			backdrop.queue_free())
		list_container.add_child(row_btn)

## Mirrors the action <select> build (farroad-ui.js:2798-2808) -- an
## option already held by another FIELDED unit (per
## FarroadProgression.action_holder_in_party) is disabled with a tooltip,
## except the slot's OWN current selection, which is never disabled even
## if held elsewhere (same aid!==s.action guard the real code uses). Same
## picker-overlay shape as the condition picker above.
func _open_action_picker(i: int, current_action: String) -> void:
	if not (_parent and _parent.has_method("_show_picker_overlay")):
		return
	_parent.call("_show_picker_overlay", "Choose action", func(list_container: Container, backdrop: Node):
		_populate_action_picker(list_container, backdrop, i, current_action))

## Same named-method-instead-of-self-referencing-closure reasoning as
## _populate_condition_picker's own comment.
func _populate_action_picker(list_container: Container, backdrop: Node, i: int, current_action: String) -> void:
	for c in list_container.get_children():
		c.queue_free()
	var filter_row := HFlowContainer.new()
	filter_row.add_theme_constant_override("h_separation", 6)
	filter_row.add_theme_constant_override("v_separation", 4)
	var lbl := Label.new()
	lbl.text = "Filter:"
	lbl.modulate = Palette.TEXT_DIM
	filter_row.add_child(lbl)
	filter_row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v):
		action_filter_target = v
		_populate_action_picker(list_container, backdrop, i, current_action)))
	filter_row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v):
		action_filter_camp = v
		_populate_action_picker(list_container, backdrop, i, current_action)))
	filter_row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v):
		action_filter_effect = v
		_populate_action_picker(list_container, backdrop, i, current_action)))
	list_container.add_child(filter_row)

	var action_ids: Array = g["actions"]
	var filters_active: bool = action_filter_target != "any" or action_filter_camp != "any" or action_filter_effect != "any"
	for aid in action_ids:
		var act = FarroadCore.ACTIONS.get(aid)
		if filters_active and aid != current_action and (act == null or not _action_passes_filter(act)):
			continue
		var holder = FarroadProgression.action_holder_in_party(g, aid, selected_uid)
		var blocked: bool = holder != null and aid != current_action
		var row := HBoxContainer.new()
		var row_btn := Button.new()
		var level_tag: String = " Lv%d" % FarroadProgression.action_level(g, aid) if act != null else ""
		# 24-item batch, Group D1: "(used by X)" moved out of this row's own
		# label and into the ⓘ detail popup (_show_action_detail_popup) --
		# the row still reads as disabled, and its tooltip still says why.
		row_btn.text = (act["name"] if act else aid) + level_tag
		row_btn.icon = _rarity_icon(act.get("rarity", "common")) if act else null
		row_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_btn.disabled = blocked or aid == current_action
		if blocked:
			row_btn.tooltip_text = "%s is equipped by %s — non-starter actions can only be used by one unit at a time" % [
				(act["name"] if act else aid), holder]
		row_btn.pressed.connect(func():
			_on_action_changed(i, aid)
			backdrop.queue_free())
		row.add_child(row_btn)
		var row_info_btn := Button.new()
		row_info_btn.text = "ⓘ"
		row_info_btn.custom_minimum_size = Vector2(36, 0)
		row_info_btn.pressed.connect(func():
			if _parent and _parent.has_method("_show_action_detail_popup"):
				_parent.call("_show_action_detail_popup", aid))
		row.add_child(row_info_btn)
		list_container.add_child(row)

const REORDER_TWEEN_TIME := 0.25

## Group J (20-item batch): a reorder animation -- captures the two
## affected slot cards' CURRENT screen Y (offset by SLOT_CARD_OFFSET,
## since the Auto-set row now occupies slots_container's own child 0)
## before the swap+rebuild, then after _refresh_slots() rebuilds fresh
## cards, tweens the two cards now sitting at the swapped indices from
## their old Y to their freshly laid-out resting Y. Relies on
## slots_container (a plain VBoxContainer) NOT re-sorting children again
## mid-tween -- nothing else here calls queue_sort() while the tween runs,
## so the manual position override holds for its whole duration, the same
## way this project's other tween-driven animations (BattlePresenter.gd's
## hop/shake) already rely on nothing else touching the animated node's
## position concurrently.
func _on_reorder(i: int, delta: int) -> void:
	var slots: Array = g["loadout"][selected_uid]
	var j := i + delta
	if j < 0 or j >= slots.size():
		return
	var old_y_i: float = slots_container.get_child(i + SLOT_CARD_OFFSET).position.y
	var old_y_j: float = slots_container.get_child(j + SLOT_CARD_OFFSET).position.y
	var tmp = slots[i]
	slots[i] = slots[j]
	slots[j] = tmp
	g["touched"][selected_uid] = true
	FarroadProgression.sync_loadout(g, selected_uid)
	_refresh_slots()
	await get_tree().process_frame   # let slots_container lay out the fresh cards before reading their real Y
	var new_card_i: Control = slots_container.get_child(i + SLOT_CARD_OFFSET)
	var new_card_j: Control = slots_container.get_child(j + SLOT_CARD_OFFSET)
	var target_i: float = new_card_i.position.y
	var target_j: float = new_card_j.position.y
	new_card_i.position.y = old_y_j
	new_card_j.position.y = old_y_i
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(new_card_i, "position:y", target_i, REORDER_TWEEN_TIME)
	tw.tween_property(new_card_j, "position:y", target_j, REORDER_TWEEN_TIME)

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

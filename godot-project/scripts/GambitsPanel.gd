class_name GambitsPanel
extends Node
## The Gambits card of the Units menu: the loadout / AI-rule editor. It gets
## the live game-state Dictionary `g` once, at setup(), and reads and writes it
## directly. Edits reach a unit mid-fight immediately through
## FarroadProgression.sync_loadout, not just from the next wave.
##
## This panel owns no popup of its own. UnitsPanel is the only popup owner (a
## second popup opened from inside it closed everything, because Godot's
## embedded windows allow only one exclusive popup at a time), and this panel
## builds its slot editor into the container UnitsPanel hands it (build_into),
## reassigning slots_container on each call.
##
## Party bench / field management is in PartyPanel.
##
## Not handled: a modal for pre-existing action conflicts when a unit is
## fielded. FarroadCore.action_held_by_earlier_fielded already makes any
## conflict safe in combat (a silent Strike fallback), so the modal would only
## be UX polish.

var g: Dictionary
var _vp: Vector2
var _parent: GameController
var selected_uid: String = ""

var slots_container: Container

## The filters live inside the pickers, as a header at the top of the list you
## scroll through. A native OptionButton can't embed a filter control in its
## own popup, so the condition and action pickers are not OptionButtons:
## tapping the current-selection button opens GameController's shared
## show_picker_overlay, whose scrollable list starts with the filter row,
## followed by the selectable rows. Filter state is kept in these shared
## instance vars, so it persists across a unit swap or reopening a picker.
var cond_filter_group: String = "any"
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"

const GAMBIT_GROUP_OPTIONS := [["any", "Any group"], ["self", "Self"], ["ally", "Ally"], ["foe", "Foe"]]
const ACTION_TARGET_OPTIONS := ActionFilter.TARGET_OPTIONS
## "camp" in the name/var is legacy -- this now filters on the action's
## real EFFECTIVE scale stat (act.get("scaleStat"), falling back to the
## camp-implied ATK/MAG when unset -- the exact resolution resolve_hit/
## heal_for themselves use), not just the coarse phys/mag camp field, so
## a DEF/RES/SPD-scaling action (an explicit scaleStat override) shows up
## under its own real stat instead of being lumped into "Physical".
const ACTION_CAMP_OPTIONS := ActionFilter.STAT_OPTIONS
const ACTION_EFFECT_OPTIONS := ActionFilter.EFFECT_OPTIONS

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

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
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

## Self -> Ally -> Foe, "none" first. Every condition id is prefixed
## foe_ / ally_ / self_ (or is exactly "none"), so the group comes from the id
## string and needs no separate field.
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
	# organized by most used, then by type; usage = how many gambit slots
	# across every unit's loadout currently use the condition
	var used: Dictionary = {}
	for uid in g.get("loadout", {}).keys():
		for slot in g["loadout"][uid]:
			var sc: String = str(slot.get("cond", "none"))
			used[sc] = int(used.get(sc, 0)) + 1
	arr.sort_custom(func(a, b):
		if (a == "none") != (b == "none"):
			return a == "none"
		var ua: int = int(used.get(a, 0))
		var ub: int = int(used.get(b, 0))
		if ua != ub:
			return ua > ub
		var ga := _cond_group_rank(a)
		var gb := _cond_group_rank(b)
		if ga != gb:
			return ga < gb
		return FarroadCore.ALL_CONDITION_IDS.find(a) < FarroadCore.ALL_CONDITION_IDS.find(b))
	return arr

func _action_passes_filter(act: Dictionary) -> bool:
	return ActionFilter.passes(act, action_filter_target, action_filter_camp, action_filter_effect)

func _build_filter_dropdown(options: Array, current_value: String, on_change: Callable) -> OptionButton:
	var opt := OptionButton.new()
	for idx in range(options.size()):
		var entry: Array = options[idx]
		opt.add_item(entry[1], idx)
		if entry[0] == current_value:
			opt.select(idx)
	opt.item_selected.connect(func(idx2): on_change.call(options[idx2][0]))
	return UiKit.compact_dropdown(opt)

## The header above the slot cards: Auto-set (a first-pass suggestion, not
## an optimizer), the Test button and the saved sets. It is rebuilt on every
## refresh, like the per-slot cards, and occupies slot 0 of slots_container,
## so every per-slot card index below is offset by SLOT_CARD_OFFSET (see
## _on_reorder for why that offset matters).
## A Paths run edits its own loadouts with this same panel: no training Test and no saved sets there.
var run_mode := false

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
	UiKit.primary(btn)
	btn.pressed.connect(_on_auto_set_pressed)
	row.add_child(btn)
	# test the gambits against training dummies (the same screen as the Quests tab's)
	var test_btn := Button.new()
	test_btn.text = "Test"
	test_btn.pressed.connect(func():
		_parent.open_training())
	if not run_mode:
		row.add_child(test_btn)
	else:
		test_btn.queue_free()
	# one header block (auto-set + saved sets) so the slot cards below keep
	# the same child offset
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(row)
	if not run_mode:
		head.add_child(UnitSets.build(g, selected_uid, "gambit", _refresh_slots))
	slots_container.add_child(head)

func _on_auto_set_pressed() -> void:
	FarroadProgression.auto_assign_loadout(g, selected_uid)
	_refresh_slots()

## Wide windows: a slot is one table row (no scrolling): number, IF, THEN, order.
func _build_wide_slot_row(card: PanelContainer, i: int, s: Dictionary, count: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)
	var num := Label.new()
	num.text = "%d" % (i + 1)
	num.custom_minimum_size = Vector2(24, 0)
	row.add_child(num)
	var cond_btn := Button.new()
	cond_btn.text = FarroadCore.cond_label(s["cond"])
	cond_btn.clip_text = true
	cond_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cond_btn.size_flags_stretch_ratio = 1.0
	cond_btn.pressed.connect(_open_condition_picker.bind(i, s["cond"]))
	row.add_child(cond_btn)
	var arrow := Label.new()
	arrow.text = "→"
	arrow.modulate = Palette.TEXT_DIM
	row.add_child(arrow)
	var cur_act = FarroadCore.ACTIONS.get(s["action"])
	var action_btn := Button.new()
	action_btn.text = cur_act["name"] if cur_act else s["action"]
	action_btn.icon = _rarity_icon(cur_act.get("rarity", "common")) if cur_act else null
	action_btn.clip_text = true
	action_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_btn.pressed.connect(_open_action_picker.bind(i, s["action"]))
	row.add_child(action_btn)
	var info_btn := Button.new()
	info_btn.text = "ⓘ"
	info_btn.custom_minimum_size = Vector2(36, 0)
	info_btn.pressed.connect(_on_action_info_pressed.bind(i))
	row.add_child(info_btn)
	var up_btn := Button.new()
	up_btn.text = "▲"
	up_btn.disabled = (i == 0)
	up_btn.pressed.connect(_on_reorder.bind(i, -1))
	row.add_child(up_btn)
	var down_btn := Button.new()
	down_btn.text = "▼"
	down_btn.disabled = (i == count - 1)
	down_btn.pressed.connect(_on_reorder.bind(i, 1))
	row.add_child(down_btn)

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
		card.add_theme_stylebox_override("panel", UiKit.card_style(10))
		slots_container.add_child(card)

		if _parent != null and _parent.wide:
			_build_wide_slot_row(card, i, s, slots.size())
			continue
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
		# an info icon next to each slot's action opens GameController's shared
		# action-detail popup (also used by CataloguePanel's Actions tab). It
		# binds the current action id, not the slot index, so it describes
		# whatever is selected now, like the button's own label.
		var info_btn := Button.new()
		info_btn.text = "ⓘ"
		info_btn.custom_minimum_size = Vector2(36, 0)
		info_btn.pressed.connect(_on_action_info_pressed.bind(i))
		action_row.add_child(info_btn)
		vbox.add_child(action_row)

	var uid_def = FarroadCore.roster_by_id(selected_uid)
	if uid_def and uid_def.get("chargeAction"):
		# swappable only for the main character ("kesh") with more than one
		# acquired charge action; every other unit (and a single-charge main
		# character) keeps the read-only label
		var mc = g.get("mc")
		var acquired: Array = mc["acquiredCharges"] if (selected_uid == "kesh" and mc != null) else []
		if acquired.size() > 1:
			var swap_row := HBoxContainer.new()
			var swap_lbl := Label.new()
			swap_lbl.text = "⚡ Charge action:"
			swap_lbl.modulate = Palette.TEXT_DIM
			swap_row.add_child(swap_lbl)
			# a trigger button (rarity icon, name, level) that opens the same
			# filterable picker overlay as a normal action
			var cur_c = FarroadCore.ACTIONS.get(uid_def["chargeAction"])
			var charge_btn := Button.new()
			charge_btn.text = (cur_c["name"] if cur_c else uid_def["chargeAction"]) + " Lv%d" % FarroadProgression.action_level(g, uid_def["chargeAction"])
			charge_btn.icon = _rarity_icon(cur_c.get("rarity", "common")) if cur_c else null
			charge_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			charge_btn.pressed.connect(_open_charge_picker.bind(acquired, uid_def["chargeAction"]))
			swap_row.add_child(charge_btn)
			# this is a selectable-action control, so it gets the info icon too
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
			# charge actions get an inspect icon too, using the same
			# _on_charge_info_pressed as the swappable (acquired > 1) case above
			var charge_info_btn := Button.new()
			charge_info_btn.text = "ⓘ"
			charge_info_btn.custom_minimum_size = Vector2(36, 0)
			charge_info_btn.pressed.connect(_on_charge_info_pressed)
			charge_row.add_child(charge_info_btn)
			slots_container.add_child(charge_row)

## Opens a filterable picker overlay (GameController.show_picker_overlay)
## instead of a native OptionButton. The filter row is the first entry of the
## scrollable list, so everything scrolls together.
func _open_condition_picker(i: int, current_cond: String) -> void:
	_parent.show_picker_overlay("Choose condition", func(list_container: Container, backdrop: Node):
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

	# only the conditions that apply to this slot's action (see FarroadCore.condition_fits_action)
	var slot_act = FarroadCore.ACTIONS.get(str(g["loadout"][selected_uid][i]["action"]))
	var cond_ids := _sorted_owned_conditions().filter(func(cid): return FarroadCore.condition_fits_action(str(cid), slot_act))
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

## Opens the action picker, in the same overlay shape as the condition picker
## above. An action already held by another fielded unit (per
## FarroadProgression.action_holder_in_party) is disabled with a tooltip,
## except this slot's own current selection, which is never disabled even if
## held elsewhere.
func _open_action_picker(i: int, current_action: String) -> void:
	_parent.show_picker_overlay("Choose action", func(list_container: Container, backdrop: Node):
		_populate_action_picker(list_container, backdrop, i, current_action))

## Same named-method-instead-of-self-referencing-closure reasoning as
## _populate_condition_picker's own comment.
func _populate_action_picker(list_container: Container, backdrop: Node, i: int, current_action: String) -> void:
	for c in list_container.get_children():
		c.queue_free()
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
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
	filter_row.add_child(ActionFilter.sort_dropdown(func():
		_populate_action_picker(list_container, backdrop, i, current_action)))
	list_container.add_child(filter_row)

	var action_ids: Array = ActionFilter.sort_ids(g, g["actions"])
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
		# "(used by X)" is in the info detail popup (show_action_detail_popup)
		# rather than in this row's label; the row still reads as disabled, and
		# its tooltip still says why.
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
			_parent.show_action_detail_popup(aid))
		row.add_child(row_info_btn)
		list_container.add_child(row)

func _open_charge_picker(acquired: Array, current: String) -> void:
	_parent.show_picker_overlay("Choose charge action", func(list_container: Container, backdrop: Node):
		_populate_charge_picker(list_container, backdrop, acquired, current))

func _populate_charge_picker(list_container: Container, backdrop: Node, acquired: Array, current: String) -> void:
	for c in list_container.get_children():
		c.queue_free()
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "Filter:"
	lbl.modulate = Palette.TEXT_DIM
	filter_row.add_child(lbl)
	filter_row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v):
		action_filter_target = v
		_populate_charge_picker(list_container, backdrop, acquired, current)))
	filter_row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v):
		action_filter_camp = v
		_populate_charge_picker(list_container, backdrop, acquired, current)))
	filter_row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v):
		action_filter_effect = v
		_populate_charge_picker(list_container, backdrop, acquired, current)))
	filter_row.add_child(ActionFilter.sort_dropdown(func():
		_populate_charge_picker(list_container, backdrop, acquired, current)))
	list_container.add_child(filter_row)
	for aid in ActionFilter.sort_ids(g, acquired):
		var act = FarroadCore.ACTIONS.get(aid)
		if aid != current and (act == null or not _action_passes_filter(act)):
			continue
		var row := HBoxContainer.new()
		var row_btn := Button.new()
		row_btn.text = (act["name"] if act else aid) + " Lv%d" % FarroadProgression.action_level(g, aid)
		row_btn.icon = _rarity_icon(act.get("rarity", "common")) if act else null
		row_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_btn.disabled = aid == current
		row_btn.pressed.connect(func():
			_on_charge_action_changed(aid)
			backdrop.queue_free())
		row.add_child(row_btn)
		var info := Button.new()
		info.text = "ⓘ"
		info.custom_minimum_size = Vector2(36, 0)
		info.pressed.connect(func():
			_parent.show_action_detail_popup(aid))
		row.add_child(info)
		list_container.add_child(row)

const REORDER_TWEEN_TIME := 0.25

## Reorder with an animation. It captures the two affected slot cards' current
## screen Y (offset by SLOT_CARD_OFFSET, since the Auto-set row is
## slots_container's child 0) before the swap and rebuild. After
## _refresh_slots() rebuilds fresh cards, it tweens the two cards now at the
## swapped indices from their old Y to their laid-out resting Y. This relies
## on slots_container (a plain VBoxContainer) not re-sorting its children
## mid-tween: nothing else here calls queue_sort() while the tween runs, so
## the manual position override holds for its whole duration. BattlePresenter's
## hop and shake tweens rely on the same thing.
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

## Reads the slot's current action at press time (not a value bound at build
## time).
func _on_action_info_pressed(i: int) -> void:
	var action_id: String = g["loadout"][selected_uid][i]["action"]
	_parent.show_action_detail_popup(action_id)

## Swaps the main character's active charge action.
func _on_charge_action_changed(action_id: String) -> void:
	FarroadProgression.set_mc_charge_action(g, action_id)
	_refresh_slots()

## Reads the main character's current charge action at press time.
func _on_charge_info_pressed() -> void:
	var uid_def = FarroadCore.roster_by_id(selected_uid)
	if uid_def == null or not uid_def.get("chargeAction"):
		return
	_parent.show_action_detail_popup(uid_def["chargeAction"])

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

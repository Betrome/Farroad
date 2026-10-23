class_name LorePanel
extends Node
## The Lore card of the Units menu: Lore-bonus purchase and refund, per
## action. The bonus math is in FarroadCore (apply_bonuses, bonus_price,
## bonus_applies, bonus_spend, snapshot, pristine_of, action_bonus_total, plus
## the BONUSES display table), and FarroadProgression has the orchestration
## (used_actions, action_holders, unit_active_actions, lore_action_ids,
## free_lore, unused_lore_refund, claim_lore_refund, buy_bonus, remove_bonus).
## This panel reuses AetherPanel's purchase-row machinery
## (_add_purchase_cells, _build_purchase_button, _style_purchase_button,
## PURCHASE_BTN_WIDTH_FRAC; duplicated here, no shared base class), so its
## column alignment and overflow handling are already worked out.
##
## The main character's acquired charge actions (acquiredCharges, banked, the
## "not refundable, kept as part of the party's charge pool" text) are handled
## where they apply.
##
## This panel owns no popup of its own. UnitsPanel is the only popup owner (a
## second popup opened from inside it closed everything), and this panel
## builds its card into the container UnitsPanel hands it (build_into).
##
## There is no refund button; FarroadProgression.unused_lore_refund and
## claim_lore_refund still exist but this panel does not expose them.

var g: Dictionary
var _vp: Vector2
var _parent: GameController
var selected_uid: String = ""
var selected_action_id: String = ""

var card_container: Container

## Filters for the Unequipped-actions dropdown, the same dropdown-filter
## mechanism CataloguePanel and GambitsPanel use.
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"

## Clears the action picker's filters (the guided tutorial uses this so Sear isn't hidden by a leftover filter).
func reset_filters() -> void:
	action_filter_target = "any"
	action_filter_camp = "any"
	action_filter_effect = "any"
const ACTION_TARGET_OPTIONS := ActionFilter.TARGET_OPTIONS
## "camp" in the name/var is legacy -- see GambitsPanel's own identical
## copy of this comment for the full reasoning.
const ACTION_CAMP_OPTIONS := ActionFilter.STAT_OPTIONS
const ACTION_EFFECT_OPTIONS := ActionFilter.EFFECT_OPTIONS

const PURCHASE_BTN_WIDTH_FRAC := 0.24   # of viewport width -- same convention AetherPanel.gd established
## Rarity is shown by color, not a bracketed text tag. Button and OptionButton
## can't render BBCode or per-item text color, but both support an icon, so a
## small solid-color swatch icon is used (see _rarity_icon below, the same
## technique EquipmentPanel uses). RichTextLabel sites (the action detail
## card's header) use RARITY_COLOR directly.
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

## Called by UnitsPanel every time the Lore sub-tab is shown. `host_popup` is
## unused here; it is kept for a consistent build_into(container, uid,
## host_popup) signature across the unit panels.
func build_into(container: Container, uid: String, _host_popup: Window) -> void:
	selected_uid = uid
	card_container = container
	_refresh_card()

func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Palette.PARTY_BLUE
	return lbl

## Same small BBCode-label helper AetherPanel._rich_line already established --
## duplicated here (different script, no shared base).
func _rich_line(bbcode: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.text = bbcode
	return r

## Available: a Lore-purple, distinct at a glance from AETHER's gold.
## Unavailable: a dim desaturated purple-grey. Same "visibly different from
## both the available state AND the panel's default grey" reasoning
## AetherPanel._style_purchase_button established.
func _style_purchase_button(btn: Button, available: bool) -> void:
	UiKit.purchase_button(btn, available)

func _build_purchase_button(buy_text: String, cost: int, aid: String, callback: Callable, btn_width_frac: float = PURCHASE_BTN_WIDTH_FRAC) -> Button:
	var btn := Button.new()
	btn.text = buy_text
	var available: bool = FarroadProgression.free_lore(g, aid) >= cost
	btn.disabled = not available
	btn.pressed.connect(callback)
	_style_purchase_button(btn, available)
	btn.custom_minimum_size.x = _vp.x * btn_width_frac
	btn.clip_text = true
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return btn

## Thin wrapper; see FarroadProgression.action_level (shared with
## GambitsPanel and CataloguePanel).
func _action_level(aid: String) -> int:
	return FarroadProgression.action_level(g, aid)

## Dictionary.get(key, default) only applies `default` when the KEY IS
## ABSENT -- a real GDScript/JS-semantics mismatch already flagged elsewhere
## in this port (FarroadCore.gd's own note on `if x else false`). Several
## ACTIONS fields (turns/defPierce/critBonus/chargeCost) exist as an
## explicit GDScript `null` on actions that don't use them (content-loading
## fills every field), not an absent key -- so `.get(key, 0.0)` returns that
## `null`, and both int(null)/float(null) throw ("Nonexistent 'int'/'float'
## constructor"), caught live via a debug script before this ever shipped.
func _numf(v) -> float:
	return 0.0 if v == null else float(v)

## Compares the action's current (bonus-applied) fields against its pristine
## baseline (FarroadCore.pristine_of) and summarizes what actually changed.
## It is display logic, so it lives here rather than in FarroadCore.
func _bonus_total_summary(aid: String) -> String:
	var act = FarroadCore.ACTIONS.get(aid)
	var p = FarroadCore.pristine_of(aid)
	if act == null or p == null:
		return ""
	var bits: Array = []
	if act.get("power") and p.get("power") and act["power"] != p["power"]:
		bits.append("%+d%% %s" % [roundi((_numf(act.get("power")) / _numf(p.get("power")) - 1.0) * 100.0),
			"healing" if act.get("heal") else "damage"])
	if _numf(act.get("defPierce")) != _numf(p.get("defPierce")):
		bits.append("+%d%% %s pierce" % [
			roundi((_numf(act.get("defPierce")) - _numf(p.get("defPierce"))) * 100.0),
			"DEF" if act.get("camp") == "atk" else "RES"])
	if _numf(act.get("critBonus")) != _numf(p.get("critBonus")):
		bits.append("+%d%% crit" % roundi((_numf(act.get("critBonus")) - _numf(p.get("critBonus"))) * 100.0))
	if int(_numf(act.get("turns"))) != int(_numf(p.get("turns"))):
		bits.append("+%d turn duration" % (int(_numf(act.get("turns"))) - int(_numf(p.get("turns")))))
	if _numf(act.get("rank")) != _numf(p.get("rank")):
		bits.append("×%d%% initiative" % roundi((1.0 / _numf(act.get("rank"))) / (1.0 / _numf(p.get("rank"))) * 100.0))
	if str(act.get("tk")) != str(p.get("tk")):
		bits.append("hits %s" % ActionFilter.target_label(act))
	if int(_numf(act.get("cleanse"))) != int(_numf(p.get("cleanse"))):
		bits.append("+%d debuff removed" % (int(_numf(act.get("cleanse"))) - int(_numf(p.get("cleanse")))))
	if _numf(act.get("deepen")) != _numf(p.get("deepen")):
		bits.append("+%d%% status strength" % roundi((_numf(act.get("deepen")) - _numf(p.get("deepen"))) * 100.0))
	if not act.get("isCharge") and _numf(act.get("charge")) != _numf(p.get("charge")):
		bits.append("+%d charge gain" % roundi(_numf(act.get("charge")) - _numf(p.get("charge"))))
	if act.get("isCharge") and _numf(act.get("chargeCost")) != _numf(p.get("chargeCost")):
		var delta: float = _numf(act.get("chargeCost")) - _numf(p.get("chargeCost"))
		bits.append("%s%d gauge" % ["+" if delta > 0 else "", roundi(delta)])
	return ", ".join(bits)

var unequipped_btn: Button = null

func _refresh_card() -> void:
	for c in card_container.get_children():
		c.queue_free()
	if selected_uid == "":
		return
	var uid := selected_uid
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return

	var header := Label.new()
	var row_tag: String = "" if g["party"].has(uid) else " • benched"
	header.text = "%s%s" % [def["name"], row_tag]
	header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(header)

	# Early return: checks the raw earned total across every action, not any
	# one action's free_lore(g, aid). A player who has spent everything they
	# earned (free == 0) still sees their existing purchases; only a fresh
	# total_lore(g) == 0 shows this message.
	if FarroadProgression.total_lore(g) == 0.0:
		card_container.add_child(_rich_line(
			"[font_size=12]No Lore yet. Lore comes from [b]duplicate[/b] drops, and the curated sequence never repeats itself — so it stays at zero until drops turn random after the wave-20 boss. That is by design, not a stall.[/font_size]"))
		return

	var action_ids: Array = FarroadProgression.lore_action_ids(g)
	var equipped_ids: Array = FarroadProgression.unit_active_actions(g, uid).filter(
		func(id): return FarroadCore.ACTIONS.has(id))

	# Keep selected_action_id valid, then snap it to this unit's own first
	# equipped action if the previous selection is equipped by someone else
	# (still "active" globally) but not here. An unequipped selection (nobody
	# holds it anywhere) persists across a unit switch instead.
	if selected_action_id == "" or not action_ids.has(selected_action_id):
		selected_action_id = action_ids[0] if not action_ids.is_empty() else ""
	if selected_action_id != "":
		var holders_now: Dictionary = FarroadProgression.action_holders(g, selected_action_id)
		if not (holders_now["active"] as Array).is_empty() and not equipped_ids.has(selected_action_id):
			selected_action_id = equipped_ids[0] if not equipped_ids.is_empty() else selected_action_id

	if not equipped_ids.is_empty():
		# HFlowContainer (wraps onto multiple lines), not HBoxContainer (never
		# wraps, would keep growing wider). A unit can have more than 2
		# equipped slots as it levels, and 2 short-named actions alone already
		# reached 309 of a 310 px budget.
		var eq_row := HFlowContainer.new()
		eq_row.add_theme_constant_override("h_separation", 6)
		eq_row.add_theme_constant_override("v_separation", 4)
		for aid in equipped_ids:
			var act = FarroadCore.ACTIONS[aid]
			var btn := Button.new()
			btn.text = "%s Lv%d" % [act["name"], _action_level(aid)]
			btn.icon = _rarity_icon(act.get("rarity", "common"))
			btn.disabled = (aid == selected_action_id)
			btn.pressed.connect(_on_action_selected.bind(aid))
			eq_row.add_child(btn)
		card_container.add_child(eq_row)
	else:
		var none_lbl := Label.new()
		none_lbl.text = "%s has nothing equipped." % def["name"]
		none_lbl.modulate = Palette.TEXT_DIM
		card_container.add_child(none_lbl)

	var unequipped_ids: Array = action_ids.filter(
		func(id): return (FarroadProgression.action_holders(g, id)["active"] as Array).is_empty())
	if not unequipped_ids.is_empty():
		var uneq_label := Label.new()
		uneq_label.text = "Unequipped actions"
		card_container.add_child(uneq_label)
		# A trigger button that opens GameController's shared show_picker_overlay,
		# like GambitsPanel's condition and action pickers, instead of an
		# OptionButton (which can't embed a filter control in its own popup).
		var uneq_row := HBoxContainer.new()
		var uneq_btn := Button.new()
		unequipped_btn = uneq_btn   # the tutorial points at it
		var cur_act = FarroadCore.ACTIONS.get(selected_action_id) if unequipped_ids.has(selected_action_id) else null
		if cur_act != null:
			uneq_btn.text = "%s — Lv%d" % [cur_act["name"], _action_level(selected_action_id)]
			uneq_btn.icon = _rarity_icon(cur_act.get("rarity", "common"))
		else:
			uneq_btn.text = "Choose an action..."
		uneq_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		uneq_btn.pressed.connect(_open_unequipped_picker.bind(unequipped_ids))
		uneq_row.add_child(uneq_btn)
		# an info icon opens the action's details
		var uneq_info_btn := Button.new()
		uneq_info_btn.text = "ⓘ"
		uneq_info_btn.custom_minimum_size = Vector2(36, 0)
		uneq_info_btn.pressed.connect(_on_unequipped_info_pressed)
		uneq_row.add_child(uneq_info_btn)
		card_container.add_child(uneq_row)

	if selected_action_id == "":
		return
	var aid := selected_action_id
	var act = FarroadCore.ACTIONS.get(aid)
	if act == null:
		return
	var b: Dictionary = g["bonuses"].get(aid, {})
	var holders: Dictionary = FarroadProgression.action_holders(g, aid)

	# Lore is per-action: this line shows this action's own earned / free pool,
	# and each upgrade costs a flat price.
	# The action's name with a Details button at the right edge; the full card
	# is in the usual pop-up instead of sitting open on the page
	var name_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = "%s  Lv%d" % [act["name"], _action_level(aid)]
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE,
		"legendary": Palette.RARITY_LEGENDARY}.get(str(act.get("rarity", "common")), Palette.RARITY_COMMON))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_row.add_child(name_lbl)
	var details_btn := Button.new()
	details_btn.text = "ⓘ Details"
	details_btn.pressed.connect(func():
		_parent.show_action_detail_popup(aid))
	name_row.add_child(details_btn)
	card_container.add_child(name_row)

	var free := FarroadProgression.free_lore(g, aid)
	card_container.add_child(_rich_line(
		"[b][color=#709fe8]%d[/color][/b] [font_size=12]of %d Lore free for %s — each non-broad upgrade costs a flat 1 Lore[/font_size]" % [
			int(free), floori(g["loreByAction"].get(aid, 0.0)), act["name"]]))

	var auto_btn := Button.new()
	auto_btn.text = "Auto-level"
	auto_btn.disabled = free < 1.0
	auto_btn.pressed.connect(func():
		FarroadProgression.auto_level_action(g, aid)
		_refresh_card())
	card_container.add_child(auto_btn)

	var box := VBoxContainer.new()

	var summary := _bonus_total_summary(aid)
	if summary != "":
		box.add_child(_rich_line("[font_size=12][color=#709fe8]Lore total: %s[/color][/font_size]" % summary))
	card_container.add_child(box)

	# Show only bonuses that can do something to this action (bonus_applies).
	# An upgrade that reaches its max (Broad, Piercing's cap) stays listed and
	# adjustable: bonus_applies turns false once it has taken effect, so a row
	# is also kept while any stacks are bought; only "+" is disabled when it
	# can't do anything more.
	var live_bids: Array = []
	var can_buy: Dictionary = {}
	for bid in FarroadCore.BONUSES.keys():
		var applies: bool = FarroadCore.bonus_applies(act, bid)
		if applies or int(b.get(bid, 0)) > 0:
			live_bids.append(bid)
			can_buy[bid] = applies
	var total_on_action: int = FarroadCore.action_bonus_total(b)
	var is_wide: bool = _parent != null and _parent.wide
	var bonus_list: Container
	if is_wide:
		# wide windows: the upgrades as a grid of small cards, so nothing scrolls
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		bonus_list = grid
	else:
		bonus_list = VBoxContainer.new()
		bonus_list.add_theme_constant_override("separation", 8)
	for bid in live_bids:
		var info: Dictionary = FarroadCore.BONUSES[bid]
		var n: int = int(b.get(bid, 0))
		var price: int = FarroadCore.bonus_price(act, bid, total_on_action)
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		row.add_child(_rich_line("[b]%s[/b] [color=#e4a83f]%d Lore[/color]" % [info["n"], price]))
		row.add_child(_rich_line("[font_size=12][color=#b9b3a3]%s[/color][/font_size]" % info["d"]))
		var ctl := HBoxContainer.new()
		ctl.add_theme_constant_override("separation", 10)
		var minus_btn := Button.new()
		minus_btn.text = "−"
		minus_btn.disabled = (n == 0)
		minus_btn.custom_minimum_size = Vector2(52 if is_wide else _vp.x * 0.12, 0)
		minus_btn.pressed.connect(_on_remove_bonus.bind(aid, bid))
		ctl.add_child(minus_btn)
		var count_lbl := Label.new()
		count_lbl.text = str(n)
		ctl.add_child(count_lbl)
		var plus_btn := _build_purchase_button("+ %d" % price, price, aid, _on_buy_bonus.bind(aid, bid), 0.18)
		if is_wide:
			plus_btn.custom_minimum_size.x = 100
		if not can_buy[bid]:
			plus_btn.disabled = true
			plus_btn.tooltip_text = "At its maximum"
		ctl.add_child(plus_btn)
		row.add_child(ctl)
		if is_wide:
			var cell := PanelContainer.new()
			cell.add_theme_stylebox_override("panel", UiKit.card_style(8))
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cell.add_child(row)
			bonus_list.add_child(cell)
		else:
			bonus_list.add_child(row)
	card_container.add_child(bonus_list)

	card_container.add_child(_rich_line(
		"[font_size=11][color=#b9b3a3]%d of %d upgrades apply to this action; the rest would do nothing.[/color][/font_size]" % [
			live_bids.size(), FarroadCore.BONUSES.size()]))

func _on_action_selected(aid: String) -> void:
	selected_action_id = aid
	_refresh_card()

## Opens the filterable picker overlay instead of a native OptionButton, like
## GambitsPanel's condition and action pickers.
func _open_unequipped_picker(candidate_ids: Array) -> void:
	_parent.show_picker_overlay("Choose an action", func(list_container: Container, backdrop: Node):
		_populate_unequipped_picker(list_container, backdrop, candidate_ids))

## Rebuilds the picker's scrollable list (filter row first, then rows) --
## called once when the picker opens AND again, directly by name, from a
## filter dropdown's own on_change handler. A NAMED method call rather
## than a self-referencing local `var populate: Callable` closure
## deliberately -- see GambitsPanel._populate_condition_picker's own
## comment for the real "Attempt to call function on a null instance"
## error that pattern produced.
func _populate_unequipped_picker(list_container: Container, backdrop: Node, candidate_ids: Array) -> void:
	for c in list_container.get_children():
		c.queue_free()
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	filter_row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v):
		action_filter_target = v
		_populate_unequipped_picker(list_container, backdrop, candidate_ids)))
	filter_row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v):
		action_filter_camp = v
		_populate_unequipped_picker(list_container, backdrop, candidate_ids)))
	filter_row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v):
		action_filter_effect = v
		_populate_unequipped_picker(list_container, backdrop, candidate_ids)))
	filter_row.add_child(ActionFilter.sort_dropdown(func():
		_populate_unequipped_picker(list_container, backdrop, candidate_ids)))
	list_container.add_child(filter_row)

	var filtered_ids: Array = ActionFilter.sort_ids(g, candidate_ids)
	if action_filter_target != "any" or action_filter_camp != "any" or action_filter_effect != "any":
		filtered_ids = filtered_ids.filter(func(aid): return _action_passes_filter(FarroadCore.ACTIONS[aid]))
	for aid in filtered_ids:
		var act = FarroadCore.ACTIONS[aid]
		var row_btn := Button.new()
		row_btn.text = "%s — Lv%d" % [act["name"], _action_level(aid)]
		row_btn.icon = _rarity_icon(act.get("rarity", "common"))
		row_btn.disabled = (aid == selected_action_id)
		row_btn.pressed.connect(func():
			selected_action_id = aid
			backdrop.queue_free()
			_refresh_card())
		list_container.add_child(row_btn)

## Reads selected_action_id at press time.
func _on_unequipped_info_pressed() -> void:
	if selected_action_id == "":
		return
	_parent.show_action_detail_popup(selected_action_id)

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

func _on_buy_bonus(aid: String, bid: String) -> void:
	FarroadProgression.buy_bonus(g, aid, bid)
	_refresh_card()

func _on_remove_bonus(aid: String, bid: String) -> void:
	FarroadProgression.remove_bonus(g, aid, bid)
	_refresh_card()

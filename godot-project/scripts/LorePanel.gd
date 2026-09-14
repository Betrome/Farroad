extends Node
## Milestone 3, Step 3e: the LORE tab -- Lore-bonus purchase/refund, per
## action. Engine math (apply_bonuses/bonus_price/bonus_applies/bonus_spend/
## snapshot/pristine_of/action_bonus_total, plus the BONUSES display table)
## was already fully ported (Milestone 1 Step 1d + this step's own table
## port); this step is UI + the small orchestration layer
## FarroadProgression.gd just gained (used_actions/action_holders/
## unit_active_actions/lore_action_ids/free_lore/unused_lore_refund/
## claim_lore_refund/buy_bonus/remove_bonus). Structural sibling of
## AetherPanel.gd specifically -- same tab-row button + popup shape, same
## unit-picker-including-benched pattern, and directly reuses its
## battle-tested purchase-row machinery (_add_purchase_cells/
## _build_purchase_button/_style_purchase_button/PURCHASE_BTN_WIDTH_FRAC,
## duplicated here -- different script, no shared base class in this
## project) so this screen starts with AETHER's hard-won column-alignment/
## horizontal-overflow lessons already applied.
##
## Deliberately NOT ported: G.mc-gated MC charge-action-pool branches
## (acquiredCharges/banked, the "not refundable, kept as part of the
## party's charge pool" text) -- naturally unreachable while g["mc"] is
## null (Step 3j), same pattern as GAMBITS/AETHER. Ported anyway for
## fidelity rather than dropped, since it becomes reachable once Step 3j
## lands.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""
var selected_action_id: String = ""

var toggle_button: Button
var popup: PopupPanel
var unit_tabs_container: HBoxContainer
var card_container: VBoxContainer
var refund_dialog: ConfirmationDialog
var _pending_refund_ids: Array = []

const PURCHASE_BTN_WIDTH_FRAC := 0.24   # of viewport width -- same convention AetherPanel.gd established
const RARITY_TAG := {"rare": " [RARE]", "legendary": " [LEGENDARY]"}

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Same reasoning/limitation as AetherPanel.reflow() -- see its comment.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.3833, _vp.y * 0.93), icon_size, "Lore", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# Fourth of 8 evenly-spaced icons across the bottom row: GambitsPanel
	# 0.0133, PartyPanel 0.1367, AetherPanel 0.2600, this one 0.3833,
	# EquipmentPanel 0.5067, MarksPanel 0.6300, ExpeditionPanel 0.7533,
	# QuestsPanel 0.8767 -- all other panels' own x fractions were
	# recomputed to make room for QuestsPanel's new 8th icon.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.3833, _vp.y * 0.93), icon_size, "Lore", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "LORE"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	var tabs_label := Label.new()
	tabs_label.text = "Upgrade actions for:"
	root_vbox.add_child(tabs_label)

	unit_tabs_container = HBoxContainer.new()
	unit_tabs_container.add_theme_constant_override("separation", 6)
	root_vbox.add_child(unit_tabs_container)

	card_container = VBoxContainer.new()
	card_container.add_theme_constant_override("separation", 12)
	root_vbox.add_child(card_container)

	# Godot's ConfirmationDialog stands in for the real confirm() popup --
	# a child of `popup` itself so it's freed along with everything else,
	# reused (just its dialog_text) rather than rebuilt on every refund
	# click. The confirmed signal is connected exactly ONCE here (reading
	# _pending_refund_ids when it fires) rather than per-click -- a
	# per-click bind+CONNECT_ONE_SHOT looked simpler but doesn't actually
	# disconnect on CANCEL, only on confirm, so a cancel-then-reopen cycle
	# would silently stack a second live connection.
	refund_dialog = ConfirmationDialog.new()
	refund_dialog.confirmed.connect(_on_refund_confirmed)
	popup.add_child(refund_dialog)

func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style BattlePresenter's own _build_icon_tab uses --
## duplicated here (different script, no shared base). See BattlePresenter's
## own copy for the fuller comment on why the label lives ON the button.
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
	_notify_battle_paused(true)

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as GambitsPanel/AetherPanel's own copy (see
## BattlePresenter.loop_paused's own comment for why this exists).
func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _default_uid() -> String:
	if not g["party"].is_empty():
		return g["party"][0]
	var keys: Array = g["owned"].keys()
	return keys[0] if not keys.is_empty() else ""

func _refresh() -> void:
	if selected_uid == "" or not g["owned"].has(selected_uid):
		selected_uid = _default_uid()
	_refresh_unit_tabs()
	_refresh_card()

## Same renderUnitTabs(..., true) pattern GAMBITS/AETHER already established --
## every owned unit, fielded or benched.
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

func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Color(0.6, 0.75, 1.0)
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
	var bg := Color(0.4, 0.22, 0.58) if available else Color(0.2, 0.16, 0.26)
	var bg_hover := Color(0.5, 0.3, 0.7) if available else Color(0.24, 0.19, 0.3)
	var font := Color(0.9, 0.82, 1.0) if available else Color(0.55, 0.5, 0.62)
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

func _build_purchase_button(buy_text: String, cost: int, callback: Callable, btn_width_frac: float = PURCHASE_BTN_WIDTH_FRAC) -> Button:
	var btn := Button.new()
	btn.text = buy_text
	var available: bool = FarroadProgression.free_lore(g) >= cost
	btn.disabled = not available
	btn.pressed.connect(callback)
	_style_purchase_button(btn, available)
	btn.custom_minimum_size.x = _vp.x * btn_width_frac
	btn.clip_text = true
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return btn

func _action_level(aid: String) -> int:
	var b: Dictionary = g["bonuses"].get(aid, {})
	return FarroadCore.action_bonus_total(b) + int(b.get("broad", 0))

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

## Mirrors bonusTotalSummary (farroad-ui.js:566-579) -- compares the
## action's CURRENT (bonus-applied) fields against its PRISTINE baseline
## (FarroadCore.pristine_of, already ported) and summarizes what actually
## changed. Lives here, not FarroadCore.gd -- the real function is in the
## UI layer too, not core.
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
	if act.get("isCharge") and _numf(act.get("chargeCost")) != _numf(p.get("chargeCost")):
		var delta: float = _numf(act.get("chargeCost")) - _numf(p.get("chargeCost"))
		bits.append("%s%d gauge" % ["+" if delta > 0 else "", roundi(delta)])
	return ", ".join(bits)

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

	# Mirrors renderLore()'s own early return (farroad-ui.js:2046-2048) --
	# checks the RAW earned total, not free_lore(g): a player who's spent
	# everything they've earned (free==0) still sees their existing
	# purchases; only a genuinely fresh g["lore"]==0 shows this message.
	if g.get("lore", 0) == 0:
		card_container.add_child(_rich_line(
			"[font_size=12]No Lore yet. Lore comes from [b]duplicate[/b] drops, and the curated sequence never repeats itself — so it stays at zero until drops turn random after the wave-20 boss. That is by design, not a stall.[/font_size]"))
		return

	var action_ids: Array = FarroadProgression.lore_action_ids(g)
	var equipped_ids: Array = FarroadProgression.unit_active_actions(g, uid).filter(
		func(id): return FarroadCore.ACTIONS.has(id))

	# Keep selected_action_id valid, then snap it to this unit's own first
	# equipped action if the previous selection is equipped by someone ELSE
	# (still "active" globally) but not here -- mirrors the real re-render
	# fixup exactly (farroad-ui.js:2094/2101-2102). An unequipped selection
	# (nobody holds it anywhere) persists across a unit switch instead.
	if selected_action_id == "" or not action_ids.has(selected_action_id):
		selected_action_id = action_ids[0] if not action_ids.is_empty() else ""
	if selected_action_id != "":
		var holders_now: Dictionary = FarroadProgression.action_holders(g, selected_action_id)
		if not (holders_now["active"] as Array).is_empty() and not equipped_ids.has(selected_action_id):
			selected_action_id = equipped_ids[0] if not equipped_ids.is_empty() else selected_action_id

	if not equipped_ids.is_empty():
		# HFlowContainer (wraps onto multiple lines), not HBoxContainer (never
		# wraps, would just keep growing wider) -- mirrors the real UI's own
		# `flex-wrap:wrap` on this exact element (farroad-ui.js:2106) and
		# matters here specifically: a real unit can have more than 2
		# equipped slots as it levels, and a measured debug run already
		# showed 2 short-named actions alone reaching 309 of a 310px budget.
		var eq_row := HFlowContainer.new()
		eq_row.add_theme_constant_override("h_separation", 6)
		eq_row.add_theme_constant_override("v_separation", 4)
		for aid in equipped_ids:
			var act = FarroadCore.ACTIONS[aid]
			var btn := Button.new()
			btn.text = "%s%s Lv%d" % [act["name"], RARITY_TAG.get(act.get("rarity"), ""), _action_level(aid)]
			btn.disabled = (aid == selected_action_id)
			btn.pressed.connect(_on_action_selected.bind(aid))
			eq_row.add_child(btn)
		card_container.add_child(eq_row)
	else:
		var none_lbl := Label.new()
		none_lbl.text = "%s has nothing equipped." % def["name"]
		none_lbl.modulate = Color(0.6, 0.6, 0.6)
		card_container.add_child(none_lbl)

	var unequipped_ids: Array = action_ids.filter(
		func(id): return (FarroadProgression.action_holders(g, id)["active"] as Array).is_empty())
	if not unequipped_ids.is_empty():
		var uneq_label := Label.new()
		uneq_label.text = "Unequipped actions"
		card_container.add_child(uneq_label)
		var uneq_option := OptionButton.new()
		var selected_idx := 0
		for i in range(unequipped_ids.size()):
			var aid: String = unequipped_ids[i]
			var act = FarroadCore.ACTIONS[aid]
			uneq_option.add_item("%s%s — Lv%d" % [act["name"], RARITY_TAG.get(act.get("rarity"), ""), _action_level(aid)])
			uneq_option.set_item_metadata(i, aid)
			if aid == selected_action_id:
				selected_idx = i
		uneq_option.selected = selected_idx
		uneq_option.item_selected.connect(_on_unequipped_selected.bind(uneq_option))
		card_container.add_child(uneq_option)

		var refund: Dictionary = FarroadProgression.unused_lore_refund(g)
		if not (refund["ids"] as Array).is_empty():
			var refund_btn := Button.new()
			refund_btn.text = "Refund %d Lore from %d unused action%s" % [
				refund["total"], (refund["ids"] as Array).size(), "" if (refund["ids"] as Array).size() == 1 else "s"]
			refund_btn.pressed.connect(_on_refund_pressed.bind(refund))
			card_container.add_child(refund_btn)

	var free := FarroadProgression.free_lore(g)
	card_container.add_child(_rich_line(
		"[b][color=#c9a0ff]%d[/color][/b] [font_size=12]of %d Lore free — each action's next upgrade costs one more Lore than its last[/font_size]" % [
			int(free), floori(g["lore"])]))

	if selected_action_id == "":
		return
	var aid := selected_action_id
	var act = FarroadCore.ACTIONS.get(aid)
	if act == null:
		return
	var b: Dictionary = g["bonuses"].get(aid, {})
	var holders: Dictionary = FarroadProgression.action_holders(g, aid)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(_rich_line("[b]%s%s%s[/b] [font_size=12]Lv%d[/font_size]" % [
		"⚡ " if act.get("isCharge") else "", act["name"], RARITY_TAG.get(act.get("rarity"), ""), _action_level(aid)]))

	var cost_text := "cost %d" % roundi(float(act["rank"]) * 100.0)
	if act.get("isCharge"):
		cost_text += "  ⚡ gauge %d" % roundi(FarroadCore.cost_of_charge(act))
	var cost_lbl := Label.new()
	cost_lbl.text = cost_text
	cost_lbl.modulate = Color(0.7, 0.7, 0.7)
	box.add_child(cost_lbl)

	if act.get("note"):
		var note_lbl := Label.new()
		note_lbl.text = str(act["note"])
		note_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note_lbl.modulate = Color(0.75, 0.75, 0.75)
		box.add_child(note_lbl)

	var scales_text := "scales with %s" % ("MAG" if act.get("camp") == "mag" else "ATK")
	if act.get("power"):
		scales_text += "  ·  power ×%.2f" % float(act["power"])
	var scales_lbl := Label.new()
	scales_lbl.text = scales_text
	scales_lbl.modulate = Color(0.55, 0.55, 0.6)
	box.add_child(scales_lbl)

	var used: Dictionary = FarroadProgression.used_actions(g)
	var holders_text: String
	if not (holders["active"] as Array).is_empty():
		holders_text = "used by %s" % ", ".join(holders["active"])
	elif used.has(aid):
		# Unreachable pre-Step-3j (an MC-banked-but-unequipped charge) -- see
		# used_actions' own comment; ported for fidelity rather than
		# silently dropped.
		holders_text = "unused — not refundable, kept as part of the party's charge pool"
	else:
		holders_text = "unused — refundable"
	box.add_child(_rich_line("[font_size=12][color=#%s]%s[/color][/font_size]" % [
		"8ec99a" if not (holders["active"] as Array).is_empty() else "888888", holders_text]))

	var summary := _bonus_total_summary(aid)
	if summary != "":
		box.add_child(_rich_line("[font_size=12][color=#c9a0ff]Lore total: %s[/color][/font_size]" % summary))
	card_container.add_child(box)

	# v2.4: show ONLY bonuses that can do something to this action --
	# mirrors bonus_applies' own real filtering exactly (farroad-ui.js:2175).
	var live_bids: Array = []
	for bid in FarroadCore.BONUSES.keys():
		if FarroadCore.bonus_applies(act, bid):
			live_bids.append(bid)
	var total_on_action: int = FarroadCore.action_bonus_total(b)
	var bonus_list := VBoxContainer.new()
	bonus_list.add_theme_constant_override("separation", 8)
	for bid in live_bids:
		var info: Dictionary = FarroadCore.BONUSES[bid]
		var n: int = int(b.get(bid, 0))
		var price: int = FarroadCore.bonus_price(act, bid, total_on_action)
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		row.add_child(_rich_line("[b]%s[/b] [color=#ffb347]%d Lore[/color]" % [info["n"], price]))
		row.add_child(_rich_line("[font_size=12][color=#999]%s[/color][/font_size]" % info["d"]))
		var ctl := HBoxContainer.new()
		ctl.add_theme_constant_override("separation", 10)
		var minus_btn := Button.new()
		minus_btn.text = "−"
		minus_btn.disabled = (n == 0)
		minus_btn.custom_minimum_size = Vector2(_vp.x * 0.12, 0)
		minus_btn.pressed.connect(_on_remove_bonus.bind(aid, bid))
		ctl.add_child(minus_btn)
		var count_lbl := Label.new()
		count_lbl.text = str(n)
		ctl.add_child(count_lbl)
		ctl.add_child(_build_purchase_button("+ %d" % price, price, _on_buy_bonus.bind(aid, bid), 0.18))
		row.add_child(ctl)
		bonus_list.add_child(row)
	card_container.add_child(bonus_list)

	card_container.add_child(_rich_line(
		"[font_size=11][color=#777]%d of %d upgrades apply to this action; the rest would do nothing.[/color][/font_size]" % [
			live_bids.size(), FarroadCore.BONUSES.size()]))

func _on_action_selected(aid: String) -> void:
	selected_action_id = aid
	_refresh_card()

func _on_unequipped_selected(index: int, option: OptionButton) -> void:
	selected_action_id = option.get_item_metadata(index)
	_refresh_card()

func _on_buy_bonus(aid: String, bid: String) -> void:
	FarroadProgression.buy_bonus(g, aid, bid)
	_refresh_card()

func _on_remove_bonus(aid: String, bid: String) -> void:
	FarroadProgression.remove_bonus(g, aid, bid)
	_refresh_card()

func _on_refund_pressed(refund: Dictionary) -> void:
	_pending_refund_ids = refund["ids"]
	refund_dialog.dialog_text = "Refund %d Lore from %d action%s no one currently has equipped?" % [
		refund["total"], _pending_refund_ids.size(), "" if _pending_refund_ids.size() == 1 else "s"]
	refund_dialog.popup_centered()

func _on_refund_confirmed() -> void:
	FarroadProgression.claim_lore_refund(g, _pending_refund_ids)
	_refresh_card()

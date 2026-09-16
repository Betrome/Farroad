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
##
## Post-Milestone-3 APK feedback (Group B1, then revised after real-device
## testing): this panel no longer owns any UI surface of its own -- see
## GambitsPanel.gd's own header comment for the full story of why (a
## nested-popup-closes-everything bug, plus Ian's explicit "show up
## beneath them, not as new windows" request). UnitsPanel is the sole
## popup owner now; this panel builds its existing card content directly
## into whatever container UnitsPanel hands it (build_into). refund_dialog
## is a real exception worth flagging: it's still a genuine Window
## (ConfirmationDialog), but nested as a CHILD of whatever `host_popup`
## build_into is given -- a child of an already-open Window layers
## correctly (this is exactly how it worked before this panel had its own
## popup too), unlike a SEPARATE top-level Window would.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""
var selected_action_id: String = ""

var card_container: Container
var refund_dialog: ConfirmationDialog
var _pending_refund_ids: Array = []

## Post-Milestone-3 APK feedback (round 3): "I need the filters all places
## actions and gambits show up" -- same dropdown-filter mechanism
## CataloguePanel/GambitsPanel already established, applied to the
## Unequipped-actions dropdown.
var action_filter_target: String = "any"
var action_filter_camp: String = "any"
var action_filter_effect: String = "any"
const ACTION_TARGET_OPTIONS := [["any", "Any target"], ["foe", "Single foe"], ["allFoes", "All foes"],
	["ally", "Single ally"], ["allAllies", "All allies"], ["self", "Self"], ["deadAlly", "Dead ally"]]
const ACTION_CAMP_OPTIONS := [["any", "Any type"], ["atk", "Physical (scales ATK)"], ["mag", "Magic (scales MAG)"]]
const ACTION_EFFECT_OPTIONS := [["any", "Any effect"], ["heal", "Heals"], ["charge", "Charge action"], ["element", "Elemental"]]

const PURCHASE_BTN_WIDTH_FRAC := 0.24   # of viewport width -- same convention AetherPanel.gd established
## Post-Milestone-3 APK feedback (Group B3): "have rarity text colors
## instead of text" (round 4, after Ian reported equipment's own bracket
## tag was STILL showing uncolored -- the same underlying issue existed
## here too) -- Button/OptionButton can't render BBCode/per-item text
## color, but BOTH support a per-item/per-button ICON, so the bracket tag
## is replaced with a small solid-color swatch icon instead (see
## _rarity_icon below, same technique EquipmentPanel.gd's own copy uses).
## Every RichTextLabel site (the action detail card's own header) still
## uses RARITY_COLOR directly.
const RARITY_COLOR := {"common": Color(1.0, 1.0, 1.0), "rare": Color(0.35, 0.55, 1.0), "legendary": Color(1.0, 0.62, 0.15)}
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

## Called by UnitsPanel every time the LORE sub-tab is shown. `host_popup`
## is the Window this content now lives inside -- refund_dialog (a real
## Window itself, ConfirmationDialog) needs to be reparented there (not
## left on some earlier host, and never a sibling top-level Window) so it
## layers correctly if a refund is triggered. Built once, lazily, on first
## use; the confirmed signal is connected exactly ONCE (reading
## _pending_refund_ids when it fires) rather than per-click -- a per-click
## bind+CONNECT_ONE_SHOT looked simpler but doesn't actually disconnect on
## CANCEL, only on confirm, so a cancel-then-reopen cycle would silently
## stack a second live connection.
func build_into(container: Container, uid: String, host_popup: Window) -> void:
	selected_uid = uid
	card_container = container
	if refund_dialog == null:
		refund_dialog = ConfirmationDialog.new()
		refund_dialog.confirmed.connect(_on_refund_confirmed)
	if refund_dialog.get_parent() != host_popup:
		if refund_dialog.get_parent() != null:
			refund_dialog.get_parent().remove_child(refund_dialog)
		host_popup.add_child(refund_dialog)
	_refresh_card()

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
			btn.text = "%s Lv%d" % [act["name"], _action_level(aid)]
			btn.icon = _rarity_icon(act.get("rarity", "common"))
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
		# Post-Milestone-3 APK feedback (round 3): "I need the filters all
		# places actions and gambits show up" -- same dropdown-filter
		# mechanism CataloguePanel/GambitsPanel already established.
		var filter_row := HFlowContainer.new()
		filter_row.add_theme_constant_override("h_separation", 6)
		filter_row.add_theme_constant_override("v_separation", 6)
		filter_row.add_child(_build_filter_dropdown(ACTION_TARGET_OPTIONS, action_filter_target, func(v): action_filter_target = v; _refresh_card()))
		filter_row.add_child(_build_filter_dropdown(ACTION_CAMP_OPTIONS, action_filter_camp, func(v): action_filter_camp = v; _refresh_card()))
		filter_row.add_child(_build_filter_dropdown(ACTION_EFFECT_OPTIONS, action_filter_effect, func(v): action_filter_effect = v; _refresh_card()))
		card_container.add_child(filter_row)
		var filtered_ids: Array = unequipped_ids
		if action_filter_target != "any" or action_filter_camp != "any" or action_filter_effect != "any":
			filtered_ids = unequipped_ids.filter(func(aid): return _action_passes_filter(FarroadCore.ACTIONS[aid]))
		var uneq_row := HBoxContainer.new()
		var uneq_option := OptionButton.new()
		uneq_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var selected_idx := 0
		for i in range(filtered_ids.size()):
			var aid: String = filtered_ids[i]
			var act = FarroadCore.ACTIONS[aid]
			uneq_option.add_icon_item(_rarity_icon(act.get("rarity", "common")), "%s — Lv%d" % [act["name"], _action_level(aid)], i)
			uneq_option.set_item_metadata(i, aid)
			if aid == selected_action_id:
				selected_idx = i
		uneq_option.selected = selected_idx
		uneq_option.item_selected.connect(_on_unequipped_selected.bind(uneq_option))
		uneq_row.add_child(uneq_option)
		# Post-Milestone-3 APK feedback (round 3): "add the informational
		# popups for actions wherever they can be selected."
		var uneq_info_btn := Button.new()
		uneq_info_btn.text = "ⓘ"
		uneq_info_btn.custom_minimum_size = Vector2(36, 0)
		uneq_info_btn.pressed.connect(_on_unequipped_info_pressed.bind(uneq_option))
		uneq_row.add_child(uneq_info_btn)
		card_container.add_child(uneq_row)

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
	var rarity_color: Color = RARITY_COLOR.get(act.get("rarity"), Color(1, 1, 1))
	box.add_child(_rich_line("[b]%s[color=#%s]%s[/color][/b] [font_size=12]Lv%d[/font_size]" % [
		"⚡ " if act.get("isCharge") else "", rarity_color.to_html(false), act["name"], _action_level(aid)]))

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

## Post-Milestone-3 APK feedback (round 3) -- reads the dropdown's CURRENT
## selection fresh at press-time.
func _on_unequipped_info_pressed(option: OptionButton) -> void:
	var aid = option.get_item_metadata(option.selected)
	if aid == null:
		return
	if _parent and _parent.has_method("_show_action_detail_popup"):
		_parent.call("_show_action_detail_popup", aid)

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

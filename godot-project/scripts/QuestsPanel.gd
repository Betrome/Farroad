extends Node
## Milestone 3, Step 3i: the QUESTS tab -- companion quest lines + direction
## dungeons. Structural sibling of MarksPanel.gd (single global screen, no
## unit-tab row) but for TWO sections in one popup, not split -- the real
## JS's own renderQuests() comment is explicit that this is intentional:
## both are main-party content, distinct from EXPEDITION's benched-party
## focus.
##
## Unlike every other panel, entering a quest/dungeon doesn't mutate g and
## refresh a card in place -- it hands off to GameController's own
## _attempt_quest/_enter_dungeon/_give_up_quest (dynamic has_method()+call(),
## same pattern as every other panel-to-controller call), since actually
## RUNNING the fight means parking the Road's BattlePresenter and spinning
## up a second one -- machinery only GameController owns. This panel's own
## job is just: show the DUNGEONS/COMPANION QUESTS lists, forward button
## presses, and render whatever result GameController hands back via
## _show_result() once a fight resolves.

var g: Dictionary
var _vp: Vector2
var _parent: Node

var toggle_button: Button
var popup: PopupPanel
var card_container: VBoxContainer
var last_result: Dictionary = {}

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Same reasoning/limitation as every sibling panel's own reflow() -- see
## GambitsPanel.reflow's comment.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.8767, _vp.y * 0.93), icon_size, "Quests", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# 8th of 8 evenly-spaced icons across the bottom row. Adding this icon
	# meant recomputing all 8 x-fractions -- at the prior 7-icon size
	# (0.12*vp.x), an 8th icon would squeeze the gap to a near-invisible
	# ~0.0044 (a much harder cliff than any prior icon-count transition),
	# so icon_size itself shrinks to 0.11*vp.x here, giving a ~0.0133 gap
	# (comparable squeeze ratio to the 6->7 transition, not a cliff):
	# Gambits 0.0133, Party 0.1367, Aether 0.2600, Lore 0.3833,
	# Equipment 0.5067, Marks 0.6300, Expedition 0.7533, this one 0.8767 --
	# the other 7 panels' own _build_ui/reflow fractions were updated too
	# (duplicated per file, same convention, no shared base).
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.8767, _vp.y * 0.93), icon_size, "Quests", _on_toggle_pressed)

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
	title.text = "QUESTS"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	card_container = VBoxContainer.new()
	card_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(card_container)

## Same opaque-panel convention every sibling panel already established --
## the default theme's PopupPanel background isn't fully opaque.
func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
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

## Also called by GameController (dynamic has_method()+call()) after a
## background dungeon unlock (Step 3h's expedition tick, resolve_expedition
## calling unlock_direction_dungeon) so an open popup picks up a new
## dungeon card without the player having to close and reopen it.
func _refresh() -> void:
	_refresh_card()

## Pauses the Road's BattlePresenter while this popup is open -- same
## pattern as every sibling panel's own copy (see BattlePresenter.
## loop_paused's own comment for why this exists). Harmless no-op if a
## side battle already has the Road paused+hidden -- the player can still
## reopen this panel mid-side-battle (e.g. to hit Give Up), and
## re-pausing an already-paused Road changes nothing.
func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _refresh_card() -> void:
	for c in card_container.get_children():
		c.queue_free()

	if not last_result.is_empty():
		var result_lbl := Label.new()
		result_lbl.text = _describe_result(last_result)
		result_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		result_lbl.modulate = Color(0.85, 0.85, 0.65)
		card_container.add_child(result_lbl)

	var busy: bool = g.get("sideBattle") != null

	var dungeons_header := Label.new()
	dungeons_header.text = "DUNGEONS"
	dungeons_header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(dungeons_header)

	var dungeons: Array = g.get("dungeons", [])
	if dungeons.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "None discovered yet -- expeditions uncover them as your parties push deeper."
		none_lbl.modulate = Color(0.65, 0.7, 0.65)
		none_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card_container.add_child(none_lbl)
	else:
		for d in dungeons:
			card_container.add_child(_build_dungeon_card(d, busy))

	var quests_header := Label.new()
	quests_header.text = "COMPANION QUESTS"
	quests_header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(quests_header)

	var owned: Array = g.get("owned", {}).keys()
	var any_quest := false
	for uid in owned:
		var q: Dictionary = g.get("quests", {}).get(uid, {})
		if q.is_empty() or int(q.get("stage", 0)) >= 5:
			continue
		any_quest = true
		card_container.add_child(_build_quest_card(uid, q, busy))
	if not any_quest:
		var none_lbl := Label.new()
		none_lbl.text = "Every owned companion has finished their quest line."
		none_lbl.modulate = Color(0.65, 0.7, 0.65)
		none_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card_container.add_child(none_lbl)

## Mirrors renderQuests()'s dungeon card (farroad-ui.js:2588-2609).
func _build_dungeon_card(d: Dictionary, busy: bool) -> PanelContainer:
	var card := PanelContainer.new()
	var box := VBoxContainer.new()
	card.add_child(box)

	var name_lbl := Label.new()
	name_lbl.text = d["name"]
	name_lbl.add_theme_font_size_override("font_size", 15)
	box.add_child(name_lbl)

	var info_lbl := Label.new()
	var total_waves: int = (d["waves"] as Array).size()
	info_lbl.text = "%d waves (ends in a boss) · cleared %d time%s" % [
		total_waves, int(d["clears"]), "" if int(d["clears"]) == 1 else "s"]
	info_lbl.modulate = Color(0.65, 0.7, 0.65)
	box.add_child(info_lbl)

	var enter_btn := Button.new()
	enter_btn.text = "Enter"
	enter_btn.disabled = busy
	if busy:
		enter_btn.tooltip_text = "A quest or dungeon attempt is already in progress."
	var id: String = d["id"]
	enter_btn.pressed.connect(func(): _on_enter_dungeon_pressed(id))
	box.add_child(enter_btn)
	return card

## Mirrors renderQuests()'s companion-quest card (farroad-ui.js:2610-2634).
func _build_quest_card(uid: String, q: Dictionary, busy: bool) -> PanelContainer:
	var card := PanelContainer.new()
	var box := VBoxContainer.new()
	card.add_child(box)

	var def = FarroadCore.roster_by_id(uid)
	var stage: int = int(q.get("stage", 0))
	var name_lbl := Label.new()
	name_lbl.text = def["name"] if def else uid
	name_lbl.add_theme_font_size_override("font_size", 15)
	box.add_child(name_lbl)

	var info_lbl := Label.new()
	info_lbl.text = "Stage %d of 5 · +%d Aether on clear" % [stage + 1, FarroadProgression.quest_stage_aether(stage)]
	info_lbl.modulate = Color(0.65, 0.7, 0.65)
	box.add_child(info_lbl)

	var side_battle: Dictionary = g.get("sideBattle") if g.get("sideBattle") != null else {}
	var is_this_quest: bool = (not side_battle.is_empty()) and side_battle["meta"]["kind"] == "quest" and side_battle["meta"]["uid"] == uid

	if is_this_quest:
		var give_up_btn := Button.new()
		give_up_btn.text = "Give Up"
		give_up_btn.pressed.connect(_on_give_up_pressed)
		box.add_child(give_up_btn)
	else:
		var attempt_btn := Button.new()
		attempt_btn.text = "Attempt"
		var fielded: bool = (g["party"] as Array).has(uid)
		if not fielded:
			attempt_btn.disabled = true
			attempt_btn.tooltip_text = "%s must be in your fielded party to attempt their own quest." % (def["name"] if def else uid)
		elif busy:
			attempt_btn.disabled = true
			attempt_btn.tooltip_text = "A quest or dungeon attempt is already in progress."
		else:
			attempt_btn.pressed.connect(func(): _on_attempt_quest_pressed(uid))
		box.add_child(attempt_btn)
	return card

func _on_enter_dungeon_pressed(id: String) -> void:
	if _parent and _parent.has_method("_enter_dungeon"):
		_parent.call("_enter_dungeon", id)

func _on_attempt_quest_pressed(uid: String) -> void:
	if _parent and _parent.has_method("_attempt_quest"):
		_parent.call("_attempt_quest", uid)

func _on_give_up_pressed() -> void:
	if _parent and _parent.has_method("_give_up_quest"):
		_parent.call("_give_up_quest")

## Called by GameController once a side battle fully resolves -- stores the
## event and shows one plain text line at the top of the panel next time
## it's opened, matching the plain-in-panel-text convention Expedition/
## Marks already established (no new toast/banner system exists in this
## port). Does NOT force-reopen the popup -- same "silently refresh,
## player reopens to see it" precedent every other panel already follows.
func _show_result(event: Dictionary) -> void:
	last_result = event

func _describe_result(r: Dictionary) -> String:
	match r["kind"]:
		"quest_cleared":
			var complete_txt := " Quest complete!" if r.get("questComplete") else ""
			return "Quest stage cleared — %s, stage %d of 5. +%d Aether.%s" % [r["name"], r["stageNum"], int(r["aether"]), complete_txt]
		"quest_failed":
			return "Quest attempt failed — %s, stage %d of 5. No penalty, try again anytime." % [r["name"], r["stageNum"]]
		"quest_abandoned":
			return "Quest abandoned — %s, stage %d of 5." % [r["name"], r["stageNum"]]
		"dungeon_cleared":
			return "Dungeon cleared — %s. +%d Aether, +%d Marks." % [r["name"], roundi(r["aether"]), roundi(r["marks"])]
		"dungeon_failed":
			return "Dungeon attempt failed — %s. No penalty, try again anytime." % r["name"]
		_:
			return ""

class_name QuestsPanel
extends Node
## The Quests tab: companion quest lines and direction dungeons, in two
## sections of one popup. Both use the main party, unlike expeditions, which
## send benched units.
##
## Entering a quest or dungeon doesn't change g here. It is handed to
## GameController's attempt_quest / enter_dungeon / give_up_quest, because
## running the fight means parking the Road's BattlePresenter and starting a
## second one. This panel shows the DUNGEONS and COMPANION QUESTS lists,
## forwards button presses, and shows the result GameController hands back
## through show_result() when a fight resolves.

var g: Dictionary
var _vp: Vector2
var _parent: GameController

var toggle_button: Button
var popup: PopupPanel
var card_container: VBoxContainer
var last_result: Dictionary = {}
## The tab showing: dungeons, quests (the companions' unit quests) or trials (every other game mode).
var current_tab := "dungeons"
const TABS := [["dungeons", "Dungeons"], ["quests", "Quests"], ["trials", "Trials"]]

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.4450, _vp.y * 0.93), icon_size, "Quests", open_menu)

func _build_ui(parent: Node) -> void:
	# Bottom-row slot (x as a fraction of vp.x).
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.4450, _vp.y * 0.93), icon_size, "Quests", open_menu)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.76)
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
	UiKit.style_popup(p)

## Same icon-square style every sibling panel uses (duplicated here: no
## shared base class). `icon`, when given, shows a real icon texture instead
## of or alongside the placeholder text; no caller passes one yet.
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	return UiKit.icon_tab(parent, pos, size, label_text, callback, icon)

func open_menu() -> void:
	_parent.panel_opening(self)
	refresh()
	if _parent.dock_open(self):
		return   # wide window: the quests list sits in the dock beside the fight
	popup.popup(_parent.menu_popup_rect())

## Also called by GameController after a background dungeon unlock (the
## expedition tick, via resolve_expedition and unlock_direction_dungeon) so an
## open popup shows the new dungeon card without being closed and reopened.
func refresh() -> void:
	_refresh_card()

## Pauses the Road's BattlePresenter while this popup is open -- same
## pattern as every sibling panel's own copy (see BattlePresenter.
## loop_paused's own comment for why this exists). Harmless no-op if a
## side battle already has the Road paused+hidden -- the player can still
## reopen this panel mid-side-battle (e.g. to hit Give Up), and
## re-pausing an already-paused Road changes nothing.
## Same real-wall-clock helper every sibling panel with a time-based gate
## already uses (ExpeditionPanel.gd's own copy).
func _now() -> float:
	return Time.get_unix_time_from_system()

func _refresh_card() -> void:
	for c in card_container.get_children():
		c.queue_free()

	# A completed non-repeatable quest disappears: its card is filtered out
	# below, and its result line doesn't linger at the top either, since the
	# result pop-up already announced it.
	last_result = {}

	var busy: bool = g.get("sideBattle") != null

	# the tabs across the top
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 8)
	for entry in TABS:
		var tb := Button.new()
		tb.text = entry[1]
		tb.toggle_mode = true
		tb.button_pressed = current_tab == entry[0]
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.pressed.connect(func():
			current_tab = entry[0]
			_refresh_card())
		tab_row.add_child(tb)
	card_container.add_child(tab_row)

	if current_tab == "trials":
		_build_trials_tab(busy)
		return
	if current_tab == "quests":
		_build_quests_tab(busy)
		return

	var dungeons_header := Label.new()
	dungeons_header.text = "DUNGEONS"
	dungeons_header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(dungeons_header)

	var dungeons: Array = g.get("dungeons", [])
	if dungeons.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "None discovered yet -- expeditions uncover them as your parties push deeper."
		none_lbl.modulate = Palette.TEXT_DIM
		none_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card_container.add_child(none_lbl)
	else:
		for d in dungeons:
			card_container.add_child(_build_dungeon_card(d, busy))

## The Quests tab: each companion's own quest line.
func _build_quests_tab(busy: bool) -> void:
	var quests_header := Label.new()
	quests_header.text = "COMPANION QUESTS"
	quests_header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(quests_header)

	var owned: Array = FarroadProgression.owned_ids(g)
	var any_quest := false
	for uid in owned:
		var q: Dictionary = g.get("quests", {}).get(uid, {})
		var completed: bool = int(q.get("stage", 0)) >= 5
		# rewards are credited on clear, so nothing is pending that would keep a
		# completed quest's card around
		if q.is_empty() or completed:
			continue
		any_quest = true
		card_container.add_child(_build_quest_card(uid, q, busy))
	if not any_quest:
		var none_lbl := Label.new()
		none_lbl.text = "Every owned companion has finished their quest line."
		none_lbl.modulate = Palette.TEXT_DIM
		none_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card_container.add_child(none_lbl)

## The Trials tab: where the game's other modes live (Paths, and the training dummies).
func _build_trials_tab(busy: bool) -> void:
	var paths_header := Label.new()
	paths_header.text = "PATHS"
	paths_header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(paths_header)
	var paths_note := Label.new()
	var meta: Dictionary = Paths.root(g)["meta"]
	paths_note.text = "A roguelike run: start with your main character at level 1 and build a party from what you find. 5 levels of 10 rows. 1 Crystal per level cleared.  Best: %d of %d levels." % [int(meta["bestLevel"]), Paths.LEVELS]
	paths_note.modulate = Palette.TEXT_DIM
	paths_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(paths_note)
	var paths_btn := Button.new()
	paths_btn.text = "Continue your run" if Paths.active(g) else "Open Paths"
	paths_btn.disabled = busy
	paths_btn.pressed.connect(func():
		_parent.open_paths_window())
	card_container.add_child(paths_btn)

	var header := Label.new()
	header.text = "TRAINING"
	header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(header)
	var note := Label.new()
	note.text = "Test your party's gambits against training dummies."
	note.modulate = Palette.TEXT_DIM
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(note)
	var training_btn := Button.new()
	training_btn.text = "Open training dummies"
	training_btn.disabled = busy
	training_btn.pressed.connect(func():
		_parent.open_training())
	card_container.add_child(training_btn)

## A dungeon's card.
func _build_dungeon_card(d: Dictionary, busy: bool) -> PanelContainer:
	var card := PanelContainer.new()
	var box := VBoxContainer.new()
	card.add_child(box)

	# The info line is kept short and both labels wrap, so a long dungeon name
	# can't make the card wider than the popup (no horizontal scrolling).
	var name_lbl := Label.new()
	name_lbl.text = d["name"]
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(name_lbl)

	var charges: int = FarroadProgression.dungeon_charges(d, _now())
	var info_lbl := Label.new()
	var total_waves: int = (d["waves"] as Array).size()
	info_lbl.text = "%d waves (ends in a boss) · +%d Crystal\n%s" % [total_waves, FarroadProgression.DUNGEON_CRYSTAL,
		_power_text(FarroadProgression.dungeon_power(d))]
	var d_axis: String = str(d.get("element", ""))
	if d_axis != "":
		info_lbl.text += "\n%s foes, weak to %s" % [d_axis.capitalize(), str(FarroadProgression.DUNGEON_OPPOSITE.get(d_axis, "")).capitalize()]
	info_lbl.modulate = Palette.TEXT_DIM
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(info_lbl)

	# Dungeon charges: a clear uses one, each dungeon gains one at local
	# midnight, up to DUNGEON_MAX_CHARGES, so a missed day can be made up.
	var row := HBoxContainer.new()
	box.add_child(row)
	var charge_lbl := Label.new()
	charge_lbl.text = "Charges %d/%d" % [charges, FarroadProgression.DUNGEON_MAX_CHARGES]
	charge_lbl.modulate = Palette.TEXT_FAINT if charges == 0 else Palette.TEXT_INK
	charge_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(charge_lbl)
	var enter_btn := Button.new()
	enter_btn.text = "Enter"
	UiKit.primary(enter_btn)
	enter_btn.disabled = busy or charges <= 0
	if busy:
		enter_btn.tooltip_text = "A quest or dungeon attempt is already in progress."
	elif charges <= 0:
		enter_btn.tooltip_text = "No charges left -- each dungeon gains one at midnight, your local time (up to %d)." % FarroadProgression.DUNGEON_MAX_CHARGES
	var id: String = d["id"]
	enter_btn.pressed.connect(func(): _on_enter_dungeon_pressed(id))
	row.add_child(enter_btn)
	return card

## A companion quest's card.
func _build_quest_card(uid: String, q: Dictionary, busy: bool) -> PanelContainer:
	var card := PanelContainer.new()
	var box := VBoxContainer.new()
	card.add_child(box)

	var def = FarroadCore.roster_by_id(uid)
	var stage: int = int(q.get("stage", 0))
	var name_lbl := Label.new()
	name_lbl.text = def["name"] if def else uid
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(name_lbl)

	var completed: bool = stage >= 5
	var info_lbl := Label.new()
	info_lbl.text = "Quest line complete" if completed else \
		"Stage %d of 5 · +%d Crystal\n%s" % [stage + 1, FarroadProgression.QUEST_STAGE_CRYSTAL,
			_power_text(FarroadProgression.quest_stage_power(g, uid, stage))]
	info_lbl.modulate = Palette.TEXT_DIM
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(info_lbl)

	var side_battle: Dictionary = g.get("sideBattle") if g.get("sideBattle") != null else {}
	var is_this_quest: bool = (not side_battle.is_empty()) and side_battle["meta"]["kind"] == "quest" and side_battle["meta"]["uid"] == uid

	# A completed quest line's card is never built at all now (filtered
	# out in _refresh_card, above) -- rewards auto-credit on clear, so
	# there's no longer a reason to keep showing it afterward.
	if is_this_quest:
		var give_up_btn := Button.new()
		give_up_btn.text = "Give Up"
		give_up_btn.pressed.connect(_on_give_up_pressed)
		box.add_child(give_up_btn)
	else:
		var attempt_btn := Button.new()
		attempt_btn.text = "Attempt"
		UiKit.primary(attempt_btn)
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

func _power_text(rec: int) -> String:
	return "Recommended power %d (your party: %d)" % [rec, FarroadProgression.party_power(g)]

func _on_enter_dungeon_pressed(id: String) -> void:
	_parent.enter_dungeon(id)

func _on_attempt_quest_pressed(uid: String) -> void:
	_parent.attempt_quest(uid)

func _on_give_up_pressed() -> void:
	_parent.give_up_quest()

func _notify_currency_changed() -> void:
	_parent.refresh_hud()

## Called by GameController once a side battle fully resolves -- stores the
## event and shows one plain text line at the top of the panel next time
## it's opened, matching the plain-in-panel-text convention Expedition/
## Marks already established (no new toast/banner system exists in this
## port). Does NOT force-reopen the popup -- same "silently refresh,
## player reopens to see it" precedent every other panel already follows.
func show_result(event: Dictionary) -> void:
	last_result = event

func _describe_result(r: Dictionary) -> String:
	match r["kind"]:
		"quest_cleared":
			var complete_txt := " Quest complete!" if r.get("questComplete") else ""
			return "Quest stage cleared — %s, stage %d of 5. +%d Crystal.%s" % [r["name"], r["stageNum"], int(r.get("crystal", 0)), complete_txt]
		"quest_failed":
			return "Quest attempt failed — %s, stage %d of 5. No penalty, try again anytime." % [r["name"], r["stageNum"]]
		"quest_abandoned":
			return "Quest abandoned — %s, stage %d of 5." % [r["name"], r["stageNum"]]
		"dungeon_cleared":
			return "Dungeon cleared — %s. +%d Crystal." % [r["name"], int(r.get("crystal", 0))]
		"dungeon_failed":
			return "Dungeon attempt failed — %s. No penalty, try again anytime." % r["name"]
		_:
			return ""

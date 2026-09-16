extends Node
## Milestone 3, Step 3h: the EXPEDITION tab -- real-time idle sending.
## Structural sibling of MarksPanel.gd (no per-unit tab row -- this is a
## party-selection picker instead, plus a list of currently-active
## expeditions).
##
## Sending/recalling/collecting call FarroadProgression's real functions
## directly (pure g-mutation, `now` always an explicit parameter -- see
## that file's own EXPEDITIONS section comment for why). Unlike every
## other panel this session, this one does NOT pause BattlePresenter's
## beat loop while open, and does NOT need `_sync_party_change` --
## expeditions only ever pull from the BENCH (is_on_expedition guards
## FarroadProgression.available_for_party, mirroring the real
## benchedUnits() filter exactly), so the currently-fielded Road party is
## untouched by anything on this screen, and expeditions run their own
## separate synthetic battles entirely independent of whatever
## BattlePresenter is animating.
##
## Collecting DOES call _notify_currency_changed() (Aether/Marks change).

var g: Dictionary
var _vp: Vector2
var _parent: Node

var toggle_button: Button
var popup: PopupPanel
var active_container: VBoxContainer
var send_container: VBoxContainer
var selected_uids: Array = []
var selected_direction: String = ""

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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.7533, _vp.y * 0.93), icon_size, "Exped", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# Seventh of 8 evenly-spaced icons across the bottom row: Gambits
	# 0.0133, Party 0.1367, Aether 0.2600, Lore 0.3833, Equip 0.5067, Marks
	# 0.6300, this one 0.7533, Quests 0.8767 -- adding QuestsPanel's icon
	# meant recomputing all 8 x-fractions (and shrinking icon size
	# 0.12->0.11), so the other panels' own _build_ui/reflow fractions were
	# updated too (duplicated per file, same convention, no shared base).
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.7533, _vp.y * 0.93), icon_size, "Exped", _on_toggle_pressed)

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
	title.text = "EXPEDITION"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	active_container = VBoxContainer.new()
	active_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(active_container)

	var send_label := Label.new()
	send_label.text = "Send a party:"
	root_vbox.add_child(send_label)

	send_container = VBoxContainer.new()
	send_container.add_theme_constant_override("separation", 8)
	root_vbox.add_child(send_container)

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
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	_refresh()
	popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))

func _notify_currency_changed() -> void:
	if _parent and _parent.has_method("_refresh_hud"):
		_parent.call("_refresh_hud")

func _now() -> float:
	return Time.get_unix_time_from_system()

func _refresh() -> void:
	_refresh_active()
	_refresh_send_picker()

## One card per active expedition -- party names + direction, a state
## line mirroring the real 3 states (away/heading home/arrived), a
## running banked total, a short log, and a Recall/Collect button.
func _refresh_active() -> void:
	for c in active_container.get_children():
		c.queue_free()
	if g["expeditions"].is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "No active expeditions."
		none_lbl.modulate = Color(0.55, 0.55, 0.55)
		active_container.add_child(none_lbl)
		return
	var now := _now()
	for exp in g["expeditions"]:
		active_container.add_child(_build_expedition_card(exp, now))

func _build_expedition_card(exp: Dictionary, now: float) -> Control:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12)
	style.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	var names := ""
	for uid in exp["partyIds"]:
		var def = FarroadCore.roster_by_id(uid)
		names += ("" if names == "" else ", ") + (def["name"] if def else uid)
	var header := Label.new()
	header.text = "%s — %s" % [names, FarroadProgression.direction_label(exp["direction"])]
	header.add_theme_font_size_override("font_size", 15)
	vbox.add_child(header)

	var state_lbl := Label.new()
	state_lbl.text = _state_text(exp, now)
	state_lbl.modulate = Color(0.75, 0.8, 0.7)
	vbox.add_child(state_lbl)

	var bank_lbl := Label.new()
	bank_lbl.text = "Banked %d Aether, %d Marks so far — reached wave %d." % [
		roundi(exp["bank"]["aether"]), floori(exp["bank"]["marks"]), int(exp["ew"])]
	vbox.add_child(bank_lbl)

	if exp.get("log") and not exp["log"].is_empty():
		var log_lbl := Label.new()
		log_lbl.text = String(exp["log"][0]["text"])
		log_lbl.modulate = Color(0.55, 0.55, 0.55)
		log_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(log_lbl)

	var arrived: bool = exp.get("arrivedAt") != null
	var btn := Button.new()
	btn.text = "Collect" if arrived else "Recall party"
	btn.pressed.connect(_on_collect_pressed.bind(exp["id"]) if arrived else _on_recall_pressed.bind(exp["id"]))
	vbox.add_child(btn)

	return card

## Mirrors the real 3 states exactly: "away Xs, reached wave N" / "heading
## home, back in Xs" / "returned — ready to collect".
func _state_text(exp: Dictionary, now: float) -> String:
	if exp.get("arrivedAt") != null:
		return "Returned — ready to collect."
	if exp.get("homeAt") != null:
		var remain: int = maxi(0, roundi(float(exp["homeAt"]) - now))
		return "Heading home, back in %s." % _fmt_duration(remain)
	var away: int = maxi(0, roundi(now - float(exp["startedAt"])))
	return "Away %s, reached wave %d." % [_fmt_duration(away), int(exp["ew"])]

func _fmt_duration(sec: int) -> String:
	if sec >= 3600:
		return "%dh %dm" % [sec / 3600, (sec % 3600) / 60]
	if sec >= 60:
		return "%dm %ds" % [sec / 60, sec % 60]
	return "%ds" % sec

func _on_recall_pressed(id: String) -> void:
	FarroadProgression.recall_expedition(g, id, _now())
	_refresh()

func _on_collect_pressed(id: String) -> void:
	if FarroadProgression.collect_expedition(g, id):
		_notify_currency_changed()
	_refresh()

## Mirrors the send picker: click-to-toggle benched units up to
## PARTY_CAP, 8 direction buttons (disabled if occupied), a "Send
## expedition (n/cap)" button. Shown whenever any sendable unit exists.
func _refresh_send_picker() -> void:
	for c in send_container.get_children():
		c.queue_free()
	var avail: Array = FarroadProgression.available_for_party(g)
	selected_uids = selected_uids.filter(func(uid): return avail.has(uid))
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(no benched units available to send)"
		none_lbl.modulate = Color(0.55, 0.55, 0.55)
		send_container.add_child(none_lbl)
		return

	var units_row := HFlowContainer.new()
	units_row.add_theme_constant_override("h_separation", 6)
	units_row.add_theme_constant_override("v_separation", 6)
	for uid in avail:
		var def = FarroadCore.roster_by_id(uid)
		var btn := Button.new()
		btn.text = def["name"] if def else uid
		btn.toggle_mode = true
		btn.button_pressed = selected_uids.has(uid)
		btn.pressed.connect(_on_unit_toggled.bind(uid))
		units_row.add_child(btn)
	send_container.add_child(units_row)

	var dir_row := HFlowContainer.new()
	dir_row.add_theme_constant_override("h_separation", 6)
	dir_row.add_theme_constant_override("v_separation", 6)
	var occupied := {}
	for exp in g["expeditions"]:
		occupied[exp["direction"]] = true
	for dir in FarroadProgression.direction_ids():
		var btn := Button.new()
		btn.text = FarroadProgression.direction_label(dir)
		btn.toggle_mode = true
		btn.button_pressed = (selected_direction == dir)
		btn.disabled = occupied.get(dir, false) and selected_direction != dir
		btn.pressed.connect(_on_direction_selected.bind(dir))
		dir_row.add_child(btn)
	send_container.add_child(dir_row)

	var send_btn := Button.new()
	send_btn.text = "Send expedition (%d/%d)" % [selected_uids.size(), FarroadProgression.PARTY_CAP]
	send_btn.disabled = selected_uids.is_empty() or selected_direction == ""
	send_btn.pressed.connect(_on_send_pressed)
	send_container.add_child(send_btn)

func _on_unit_toggled(uid: String) -> void:
	if selected_uids.has(uid):
		selected_uids.erase(uid)
	elif selected_uids.size() < FarroadProgression.PARTY_CAP:
		selected_uids.append(uid)
	_refresh_send_picker()

func _on_direction_selected(dir: String) -> void:
	selected_direction = "" if selected_direction == dir else dir
	_refresh_send_picker()

func _on_send_pressed() -> void:
	if FarroadProgression.send_expedition(g, selected_uids, selected_direction, _now()):
		selected_uids = []
		selected_direction = ""
	_refresh()

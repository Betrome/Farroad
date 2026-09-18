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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.5838, _vp.y * 0.93), icon_size, "Exped", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# 20-item batch's own Group H recomputed the (now 7-icon) bottom row --
	# see MarksPanel.gd's own copy of this comment for the full layout.
	# This panel now sits at 0.5838.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.5838, _vp.y * 0.93), icon_size, "Exped", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.80)
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

	# Post-Milestone-3 APK feedback (Group B5): the send picker moved ABOVE
	# the active-expeditions list -- previously it sat below, meaning it was
	# scrolled well past the fold whenever an expedition was already active,
	# exactly when a player is most likely to want to send another one.
	var send_label := Label.new()
	send_label.text = "Send a party:"
	root_vbox.add_child(send_label)

	send_container = VBoxContainer.new()
	send_container.add_theme_constant_override("separation", 8)
	root_vbox.add_child(send_container)

	active_container = VBoxContainer.new()
	active_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(active_container)

## Same opaque-panel convention every sibling panel already established --
## the default theme's PopupPanel background isn't fully opaque.
func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
## icon, when provided, shows a real icon texture instead of/alongside
## the placeholder text -- every EXISTING call site passes no icon
## (unchanged behavior) until real button art exists (Ian: "prepare for
## real button/icon assets").
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	var btn := Button.new()
	btn.text = label_text
	if icon != null:
		btn.icon = icon
		btn.expand_icon = true
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Palette.BTN_NORMAL
	normal_style.set_corner_radius_all(int(size / 2.0))
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Palette.BTN_HOVER
	hover_style.set_corner_radius_all(int(size / 2.0))
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
	popup.popup(Rect2i(Vector2i(_vp.x * 0.02, _vp.y * 0.11), Vector2i(_vp.x * 0.96, _vp.y * 0.80)))

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
		none_lbl.modulate = Palette.TEXT_DIM
		active_container.add_child(none_lbl)
		return
	var now := _now()
	for exp in g["expeditions"]:
		active_container.add_child(_build_expedition_card(exp, now))

func _build_expedition_card(exp: Dictionary, now: float) -> Control:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT_DEEP
	style.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	var names := ""
	for uid in exp["partyIds"]:
		var def = FarroadCore.roster_by_id(uid)
		names += ("" if names == "" else ", ") + (def["name"] if def else uid)
	# Every Label below can carry an arbitrarily long/variable string (a
	# full party's names, growing currency figures, a dungeon-unlock
	# sentence) -- autowrap + SIZE_EXPAND_FILL keeps each one shrinkable to
	# the card's own real width instead of forcing it (and everything else
	# in this popup) wider, the horizontal-scroll bug this was reported for.
	var header := Label.new()
	header.text = "%s — %s" % [names, FarroadProgression.direction_label(exp["direction"])]
	header.add_theme_font_size_override("font_size", 15)
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(header)

	var state_lbl := Label.new()
	state_lbl.text = _state_text(exp, now)
	state_lbl.modulate = Palette.TEXT_DIM
	state_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	state_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(state_lbl)

	var bank_lbl := Label.new()
	bank_lbl.text = "Banked %d Aether, %d Marks so far — reached wave %d." % [
		roundi(exp["bank"]["aether"]), floori(exp["bank"]["marks"]), int(exp["ew"])]
	bank_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bank_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(bank_lbl)

	if exp.get("log") and not exp["log"].is_empty():
		var log_lbl := Label.new()
		log_lbl.text = String(exp["log"][0]["text"])
		log_lbl.modulate = Palette.TEXT_DIM
		log_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		log_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(log_lbl)

	# Ian: "give each expedition you send out its own button to pop up a
	# log showing battle, events, and dungeons they encounter" -- opens the
	# FULL exp["log"] history (GameController._show_expedition_log_popup),
	# distinct from the single most-recent-entry preview line just above.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var log_btn := Button.new()
	log_btn.text = "Log"
	log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_btn.pressed.connect(_on_log_pressed.bind(exp))
	btn_row.add_child(log_btn)

	var arrived: bool = exp.get("arrivedAt") != null
	var btn := Button.new()
	btn.text = "Collect" if arrived else "Recall party"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(_on_collect_pressed.bind(exp["id"]) if arrived else _on_recall_pressed.bind(exp["id"]))
	btn_row.add_child(btn)
	vbox.add_child(btn_row)

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

func _on_log_pressed(exp: Dictionary) -> void:
	if _parent and _parent.has_method("_show_expedition_log_popup"):
		_parent.call("_show_expedition_log_popup", exp)

func _on_recall_pressed(id: String) -> void:
	FarroadProgression.recall_expedition(g, id, _now())
	_refresh()

func _on_collect_pressed(id: String) -> void:
	if FarroadProgression.collect_expedition(g, id):
		_notify_currency_changed()
	_refresh()

## Mirrors the send picker: click-to-toggle benched units up to
## PARTY_CAP, a compass-style ExpeditionMap for direction selection (8
## direction icons, disabled if occupied -- see ExpeditionMap.gd), a
## "Send expedition (n/cap)" button. Shown whenever any sendable unit
## exists.
func _refresh_send_picker() -> void:
	for c in send_container.get_children():
		c.queue_free()
	var avail: Array = FarroadProgression.available_for_party(g)
	selected_uids = selected_uids.filter(func(uid): return avail.has(uid))
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(no benched units available to send)"
		none_lbl.modulate = Palette.TEXT_DIM
		send_container.add_child(none_lbl)
		return

	# Post-Milestone-3 APK feedback (Group B5): "increase their size" -- every
	# button in this panel used to rely on plain default Button sizing (no
	# custom_minimum_size anywhere); a real ~1.35x taller floor here makes
	# them easier to tap without changing the HFlowContainer auto-layout.
	var btn_min_size := Vector2(0, 44)
	var units_row := HFlowContainer.new()
	units_row.add_theme_constant_override("h_separation", 6)
	units_row.add_theme_constant_override("v_separation", 6)
	for uid in avail:
		var def = FarroadCore.roster_by_id(uid)
		var btn := Button.new()
		btn.text = def["name"] if def else uid
		btn.custom_minimum_size = btn_min_size
		btn.toggle_mode = true
		btn.button_pressed = selected_uids.has(uid)
		btn.pressed.connect(_on_unit_toggled.bind(uid))
		units_row.add_child(btn)
	send_container.add_child(units_row)

	# Group K (20-item batch): a compass-style home-base map replacing the
	# flat 8-direction-button row -- home base at center, each direction's
	# own line radiating outward (fogged past g["directions"][dir]["maxDepth"]),
	# active expeditions shown as dots along their own line (tap to open
	# their existing Log popup), a tappable direction icon at each line's
	# end still wired to the SAME _on_direction_selected(dir) handler below
	# -- no new selection logic, just a new visual hit-target. Square, sized
	# off the same popup content width _build_ui computes (popup_size.x - 40).
	var map_size: float = _vp.x * 0.96 - 40.0
	var exp_map := ExpeditionMap.new()
	exp_map.setup(g, Vector2(map_size, map_size), selected_direction, _on_direction_selected, _on_log_pressed)
	send_container.add_child(exp_map)

	var send_btn := Button.new()
	send_btn.text = "Send expedition (%d/%d)" % [selected_uids.size(), FarroadProgression.PARTY_CAP]
	send_btn.custom_minimum_size = btn_min_size
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

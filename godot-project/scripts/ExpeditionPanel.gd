class_name ExpeditionPanel
extends Node
## The Expedition tab: send benched units out on real-time expeditions. It
## has a party picker and a list of the expeditions currently out.
##
## Sending, recalling and collecting call FarroadProgression's functions
## directly (they only change g, and take `now` as a parameter; see the
## EXPEDITIONS section there). Expeditions only ever take units from the
## bench (is_on_expedition keeps them out of available_for_party), so nothing
## here touches the fielded Road party: this panel needs no
## sync_party_change, and the battle loop isn't paused. Expeditions run their
## own separate simulated battles, independent of the one BattlePresenter is
## animating.
##
## Collecting calls _notify_currency_changed() (Aether and Marks change).

var g: Dictionary
var _vp: Vector2
var _parent: GameController

var toggle_button: Button
var popup: PopupPanel
var active_container: VBoxContainer
var send_container: VBoxContainer
var selected_uids: Array = []
var selected_direction: String = ""

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)
	# the away / heading-home times count in real time while the panel is open
	# (and the party keeps advancing), not just on reopen
	var t := Timer.new()
	t.wait_time = 1.0
	t.ignore_time_scale = true
	t.autostart = true
	t.timeout.connect(_tick_live)
	add_child(t)

## [state label, bank label, expedition, state key] per card on screen.
var _live: Array = []

func _state_key(exp: Dictionary) -> String:
	return "arrived" if exp.get("arrivedAt") != null else ("home" if exp.get("homeAt") != null else "away")

func _bank_text(exp: Dictionary) -> String:
	var t := "Banked %d Aether, %d Marks so far — reached wave %d." % [
		roundi(exp["bank"]["aether"]), floori(exp["bank"]["marks"]), int(exp["ew"])]
	var finds: Array = exp["bank"].get("finds", [])
	if not finds.is_empty():
		t += " Found: " + ", ".join(finds.map(func(f): return FarroadProgression.find_name(f))) + "."
	return t

func _tick_live() -> void:
	_update_badge()
	if popup == null or not popup.visible or _live.is_empty():
		return
	var now := _now()
	var changed := false
	for row in _live:
		var exp: Dictionary = row[2]
		if not g["expeditions"].has(exp):
			changed = true
			continue
		FarroadProgression.resolve_expedition(g, exp, now)   # advances / notices arrival
		if _state_key(exp) != row[3]:
			changed = true   # new state needs a different button
			continue
		if is_instance_valid(row[0]):
			row[0].text = _state_text(exp, now)
		if is_instance_valid(row[1]):
			row[1].text = _bank_text(exp)
	if changed:
		_refresh_active()

## Same reasoning/limitation as every sibling panel's own reflow() -- see
## GambitsPanel.reflow's comment.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if popup != null and _built_wide != _is_wide():
		_populate_popup()
		if popup.visible:
			refresh()
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.3063, _vp.y * 0.93), icon_size, "Exped", open_menu)
	_update_badge.call_deferred()

func _build_ui(parent: Node) -> void:
	# Bottom-row slot (x as a fraction of vp.x). It sits just before the Road
	# button so Road stays close to the center of the row.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.3063, _vp.y * 0.93), icon_size, "Exped", open_menu)
	_update_badge.call_deferred()

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	_populate_popup()

var _body: Control
var _built_wide := false
var map_container: VBoxContainer

func _is_wide() -> bool:
	return _parent != null and _parent.wide

## Wide window: the map on the left, sending and the active expeditions on the
## right, nothing to scroll past. Otherwise the portrait list. Rebuilt in place.
func _populate_popup() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
	_built_wide = _is_wide()
	map_container = null
	if _built_wide:
		_populate_wide()
		return
	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.76)
	var scroll := ScrollContainer.new()
	_body = scroll
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

	# the send picker sits above the active-expeditions list, so it stays in
	# view when an expedition is already out (when sending another is likely)
	var send_label := Label.new()
	send_label.text = "Send a party:"
	root_vbox.add_child(send_label)

	send_container = VBoxContainer.new()
	send_container.add_theme_constant_override("separation", 8)
	root_vbox.add_child(send_container)

	active_container = VBoxContainer.new()
	active_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(active_container)

const WIDE_MAP := 470.0

func _populate_wide() -> void:
	var r: Rect2i = _parent.full_menu_rect()
	var root := HBoxContainer.new()
	_body = root
	# the height is fixed, so no amount of content can grow the window up over the top bar
	root.custom_minimum_size = Vector2(r.size.x - 24, r.size.y - 24)
	root.clip_contents = true
	root.add_theme_constant_override("separation", 24)
	popup.add_child(root)
	var map_size: float = minf(WIDE_MAP, float(r.size.y) - 110.0)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(map_size, 0)
	left.add_theme_constant_override("separation", 8)
	root.add_child(left)
	var title := Label.new()
	title.text = "EXPEDITION"
	title.add_theme_font_size_override("font_size", 20)
	left.add_child(title)
	map_container = VBoxContainer.new()
	left.add_child(map_container)
	# the right side scrolls as a whole, whatever it holds
	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(right_scroll)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.custom_minimum_size = Vector2(r.size.x - map_size - 24.0 - 24.0 - 24.0 - 70.0, 0)
	right.add_theme_constant_override("separation", 10)
	right_scroll.add_child(right)
	var send_label := Label.new()
	send_label.text = "Send a party:"
	right.add_child(send_label)
	send_container = VBoxContainer.new()
	send_container.add_theme_constant_override("separation", 8)
	right.add_child(send_container)
	var active_label := Label.new()
	active_label.text = "On the road:"
	right.add_child(active_label)
	active_container = VBoxContainer.new()
	active_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	active_container.add_theme_constant_override("separation", 10)
	right.add_child(active_container)

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
	popup.popup((_parent.full_menu_rect() if _is_wide() else _parent.menu_popup_rect()))

func _notify_currency_changed() -> void:
	_parent.refresh_hud()

func _now() -> float:
	return Time.get_unix_time_from_system()

func refresh() -> void:
	_refresh_active()
	_refresh_send_picker()

## One card per active expedition -- party names + direction, a state
## line mirroring the real 3 states (away/heading home/arrived), a
## running banked total, a short log, and a Recall/Collect button.
func _refresh_active() -> void:
	_live.clear()
	for c in active_container.get_children():
		c.queue_free()
	if g["expeditions"].is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "No active expeditions."
		none_lbl.modulate = Palette.TEXT_DIM
		active_container.add_child(none_lbl)
		return
	var now := _now()
	var arrived: Array = g["expeditions"].filter(func(e): return e.get("arrivedAt") != null)
	if arrived.size() > 1:
		var all_btn := Button.new()
		all_btn.text = "Collect all (%d)" % arrived.size()
		all_btn.custom_minimum_size = Vector2(0, 44)
		UiKit.primary(all_btn)
		all_btn.pressed.connect(_on_collect_all_pressed)
		active_container.add_child(all_btn)
	for exp in g["expeditions"]:
		active_container.add_child(_build_expedition_card(exp, now))

func _build_expedition_card(exp: Dictionary, now: float) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiKit.card_style(10))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	var names: String = FarroadProgression.expedition_label(exp)
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
	bank_lbl.text = _bank_text(exp)
	_live.append([state_lbl, bank_lbl, exp, _state_key(exp)])
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

	# each expedition has its own Log button: it opens the full exp["log"]
	# history (GameController.show_expedition_log_popup), not just the single
	# most recent entry shown in the preview line above
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var log_btn := Button.new()
	log_btn.text = "Log"
	log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_btn.pressed.connect(_on_log_pressed.bind(exp))
	btn_row.add_child(log_btn)

	var arrived: bool = exp.get("arrivedAt") != null
	var returning: bool = exp.get("homeAt") != null and not arrived
	var btn := Button.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if arrived:
		btn.text = "Collect"
		UiKit.primary(btn)
		btn.pressed.connect(_on_collect_pressed.bind(exp["id"]))
	elif returning and exp.get("recalled", false):
		# a recalled party can be sent back out
		btn.text = "Explore"
		btn.pressed.connect(_on_explore_pressed.bind(exp["id"]))
	elif returning:
		btn.text = "Returning"   # turned back from injuries
		btn.disabled = true
	else:
		btn.text = "Recall party"
		btn.pressed.connect(_on_recall_pressed.bind(exp["id"]))
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
	_parent.show_expedition_log_popup(exp)

func _on_recall_pressed(id: String) -> void:
	FarroadProgression.recall_expedition(g, id, _now())
	refresh()

func _on_explore_pressed(id: String) -> void:
	FarroadProgression.resume_expedition(g, id, _now())
	refresh()

func _on_collect_all_pressed() -> void:
	var any := false
	for id in (g["expeditions"] as Array).filter(func(e): return e.get("arrivedAt") != null).map(func(e): return e["id"]):
		if FarroadProgression.collect_expedition(g, id):
			any = true
	if any:
		_notify_currency_changed()
	refresh()

func _on_collect_pressed(id: String) -> void:
	if FarroadProgression.collect_expedition(g, id):
		_notify_currency_changed()
	refresh()

## Mirrors the send picker: click-to-toggle benched units up to
## PARTY_CAP, a compass-style ExpeditionMap for direction selection (8
## direction icons, disabled if occupied -- see ExpeditionMap.gd), a
## "Send expedition (n/cap)" button. Shown whenever any sendable unit
## exists.
func _wide_map_size() -> float:
	var r: Rect2i = _parent.full_menu_rect()
	return minf(WIDE_MAP, float(r.size.y) - 110.0)

func _map_host() -> Container:
	return map_container if _built_wide and map_container != null else send_container

func _refresh_send_picker() -> void:
	for c in send_container.get_children():
		c.queue_free()
	if _built_wide and map_container != null:
		for c in map_container.get_children():
			c.queue_free()
	var avail: Array = FarroadProgression.available_for_party(g)
	selected_uids = selected_uids.filter(func(uid): return avail.has(uid))
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(no benched units available to send)"
		none_lbl.modulate = Palette.TEXT_DIM
		send_container.add_child(none_lbl)
		# the map still shows how far each direction has been explored
		var idle_size: float = _wide_map_size() if _built_wide else _vp.x * 0.96 - 40.0
		var idle_map := ExpeditionMap.new()
		idle_map.setup(g, Vector2(idle_size, idle_size), selected_direction, _on_direction_selected, _on_log_pressed)
		_map_host().add_child(idle_map)
		return

	# a minimum height about 1.35x the default makes the buttons easier to tap
	# without changing the HFlowContainer auto-layout
	var btn_min_size := Vector2(0, 44)

	# A dropdown of the Party tab's saved presets, above the unit toggles. Only
	# benched units that aren't already away can go out (the fielded Road party
	# never leaves), so each entry shows how many of its members are sendable
	# right now, and choosing one selects exactly those. The per-unit toggles
	# below still work for fine-tuning afterward.
	var presets: Array = g.get("partyPresets", [])
	if not presets.is_empty():
		var preset_opt := OptionButton.new()
		preset_opt.custom_minimum_size = btn_min_size
		preset_opt.add_item("Choose a saved party...", 0)
		for i in range(presets.size()):
			var sendable := _preset_sendable(presets[i], avail)
			# Power of the members that would actually go, so presets can be
			# compared before sending.
			preset_opt.add_item("%s — Power %d (%d sendable)" % [presets[i]["name"],
				FarroadProgression.party_power_of(g, sendable), sendable.size()], i + 1)
			if sendable.is_empty():
				preset_opt.set_item_disabled(i + 1, true)
		preset_opt.select(0)
		preset_opt.item_selected.connect(func(idx: int):
			if idx <= 0:
				return
			selected_uids = _preset_sendable(presets[idx - 1], avail)
			_refresh_send_picker())
		send_container.add_child(preset_opt)

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

	# A compass-style map of the home base at the center, with each direction's
	# line radiating outward (fogged past g["directions"][dir]["maxDepth"]).
	# Active expeditions are dots along their own line (tap to open their Log
	# popup), and a direction icon at each line's end calls
	# _on_direction_selected(dir) below. Square, sized off the popup content
	# width _build_ui computes (popup_size.x - 40).
	var map_size: float = _wide_map_size() if _built_wide else _vp.x * 0.96 - 40.0
	var exp_map := ExpeditionMap.new()
	exp_map.setup(g, Vector2(map_size, map_size), selected_direction, _on_direction_selected, _on_log_pressed)
	_map_host().add_child(exp_map)

	var send_btn := Button.new()
	send_btn.text = "Send expedition (%d/%d)" % [selected_uids.size(), FarroadProgression.PARTY_CAP]
	UiKit.primary(send_btn)
	if not selected_uids.is_empty():
		send_btn.text += " — Power %d" % FarroadProgression.party_power_of(g, selected_uids)
	send_btn.custom_minimum_size = btn_min_size
	send_btn.disabled = selected_uids.is_empty() or selected_direction == ""
	send_btn.pressed.connect(_on_send_pressed)
	send_container.add_child(send_btn)

func _preset_sendable(preset: Dictionary, avail: Array) -> Array:
	var out: Array = []
	for uid in preset["party"]:
		if avail.has(uid) and not out.has(uid) and out.size() < FarroadProgression.PARTY_CAP:
			out.append(uid)
	return out

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
	refresh()

## Shows an exclamation point in the corner of the Expedition button when a
## party is ready to be collected.
func _ready_to_collect() -> bool:
	for exp in g.get("expeditions", []):
		if exp.get("arrivedAt") != null:
			return true
	return false

func _update_badge() -> void:
	if toggle_button == null or not is_instance_valid(toggle_button):
		return
	var badge := toggle_button.get_node_or_null("Badge") as Label
	if badge == null:
		badge = Label.new()
		badge.name = "Badge"
		badge.text = "!"
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var d: float = maxf(16.0, toggle_button.size.x * 0.34)
		badge.custom_minimum_size = Vector2(d, d)
		badge.size = Vector2(d, d)
		badge.position = Vector2(toggle_button.size.x - d * 0.75, -d * 0.35)
		badge.add_theme_font_size_override("font_size", int(d * 0.8))
		badge.add_theme_color_override("font_color", Color.WHITE)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.85, 0.12, 0.10)
		sb.set_corner_radius_all(int(d))
		badge.add_theme_stylebox_override("normal", sb)
		toggle_button.add_child(badge)
	badge.visible = _ready_to_collect()

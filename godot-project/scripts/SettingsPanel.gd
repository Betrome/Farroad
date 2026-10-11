extends Node
## Post-Milestone-3 APK feedback (Group C2): the new "Settings" tab (bottom-
## row label now "Menu", per Ian's own later ask -- the icon/button/popup
## underneath is unchanged) -- a "Reset Game" button behind a
## ConfirmationDialog (same reuse of Godot's confirm-before-destructive-
## action pattern LorePanel's own refund flow already established),
## deleting user://save.json and reloading the scene so the player
## re-enters GameController._ready()'s own existing boot gate (no save
## found -> character creation) rather than hand-rolling a manual in-place
## teardown/rebuild of every panel and timer.
##
## Post-batch feedback: the inline Inventory readout became a button
## (opens GameController._show_inventory_popup, the same shared small-
## overlay shape every other detail popup uses), and a "Change Name"
## button was added (GameController._show_change_name_popup).

var g: Dictionary
var _vp: Vector2
var _parent: Node

var toggle_button: Button
var popup: PopupPanel
var confirm_dialog: ConfirmationDialog

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.8613, _vp.y * 0.93), icon_size, "Menu", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.8613, _vp.y * 0.93), icon_size, "Menu", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	# Ian: the same size as the other main menus (96% x 76%), scrolling
	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.76)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	popup.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# Ian: "add an inventory tab to show aether, marks, and future
	# currencies" -- then later "change the inventory section to be a
	# button." Opens the same shared small-overlay popup every other
	# detail view uses (GameController._show_inventory_popup), which
	# builds its own live readout fresh each time it's opened -- no local
	# label to keep refreshed here anymore.
	# Ian: cloud saves -- the recovery code that moves this game to another device
	var account_btn := Button.new()
	account_btn.text = "Cloud save & recovery code"
	account_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_account_popup"):
			_parent.call("_show_account_popup"))
	vbox.add_child(account_btn)

	var inventory_btn := Button.new()
	inventory_btn.text = "Inventory"
	inventory_btn.pressed.connect(_on_inventory_pressed)
	vbox.add_child(inventory_btn)

	# 24-item batch: "add a Stats button in the menu" -- opens
	# GameController._show_stats_popup, same shared detail-overlay shape
	# Inventory already uses.
	var stats_btn := Button.new()
	stats_btn.text = "Stats"
	stats_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_stats_popup"):
			_parent.call("_show_stats_popup"))
	vbox.add_child(stats_btn)

	# (Ian: the name now lives in the Customize screen.)
	# Ian: male/female main character, changeable any time.
	var body_btn := Button.new()
	body_btn.text = "Customize Character"
	body_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_change_body_popup"):
			_parent.call("_show_change_body_popup"))
	vbox.add_child(body_btn)

	# Group H (20-item batch): Catalogue folded in here so it no longer
	# needs its own bottom-row icon.
	var catalogue_btn := Button.new()
	catalogue_btn.text = "Catalogue"
	catalogue_btn.pressed.connect(_on_catalogue_pressed)
	vbox.add_child(catalogue_btn)

	var tuts_btn := Button.new()
	tuts_btn.text = "Tutorials"
	tuts_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_tutorials_popup"):
			_parent.call("_show_tutorials_popup"))
	vbox.add_child(tuts_btn)

	# Ian: "allow players to skip tutorials" -- unlocks every menu now (a
	# tutorial's own caption has a Skip for just that one).
	var skip_btn := Button.new()
	skip_btn.text = "Skip all tutorials"
	skip_btn.disabled = bool(g.get("tutorialSkip", false))
	skip_btn.pressed.connect(func():
		if _parent and _parent.has_method("_skip_tutorials"):
			_parent.call("_skip_tutorials")
		skip_btn.disabled = true)
	vbox.add_child(skip_btn)

	# Ian: a feedback button for suggestions and bug reports.
	var feedback_btn := Button.new()
	feedback_btn.text = "Send Feedback"
	feedback_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_feedback_popup"):
			_parent.call("_show_feedback_popup"))
	vbox.add_child(feedback_btn)

	# Ian: notifications for idle rewards full / an expedition back.
	var notify_btn := CheckButton.new()
	notify_btn.text = "Notifications"
	notify_btn.button_pressed = Notifier.enabled()
	vbox.add_child(notify_btn)
	var notify_sub := VBoxContainer.new()
	notify_sub.visible = Notifier.enabled()
	vbox.add_child(notify_sub)
	notify_btn.toggled.connect(func(on: bool):
		Notifier.set_enabled(on)
		notify_sub.visible = on)
	for kind in [["idle", "Idle rewards are full"], ["expedition", "An expedition party is back"]]:
		var kb := CheckButton.new()
		kb.text = "   " + kind[1]
		kb.button_pressed = Notifier.kind_enabled(kind[0]) if Notifier.enabled() else bool(Analytics.state.get("notify_" + kind[0], true))
		var kk: String = kind[0]
		kb.toggled.connect(func(on: bool): Notifier.set_kind_enabled(kk, on))
		notify_sub.add_child(kb)
	var notify_note := Label.new()
	notify_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notify_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notify_note.modulate = Palette.TEXT_DIM
	notify_note.text = {
		"android": "Sent even when the game is closed.",
		"windows": "Sent even when the game is closed.",
		"web": "Sent while this page stays open in a background tab (a closed tab can't send them).",
	}.get(Notifier.platform(), "Notifications aren't available on this device.")
	notify_sub.add_child(notify_note)
	if Notifier.platform() == "web":
		var perm_btn := Button.new()
		perm_btn.text = "Allow notifications in this browser"
		perm_btn.visible = Notifier.web_permission() == "default"
		perm_btn.pressed.connect(func():
			Notifier.web_request_permission()
			perm_btn.visible = false)
		notify_sub.add_child(perm_btn)
	var test_btn := Button.new()
	test_btn.text = "Send a test notification"
	var test_note := Label.new()
	test_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	test_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_note.modulate = Palette.TEXT_DIM
	test_btn.pressed.connect(func():
		var n = _parent.get("notifier") if _parent else null
		test_note.text = n.send_test() if n != null else "Not ready yet.")
	notify_sub.add_child(test_btn)
	notify_sub.add_child(test_note)

	# Ian: patch notes in the game, and a check for a newer version.
	var notes_btn := Button.new()
	notes_btn.text = "Patch notes"
	notes_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_patch_notes_popup"):
			_parent.call("_show_patch_notes_popup"))
	vbox.add_child(notes_btn)
	var update_btn := Button.new()
	update_btn.text = "Check for updates"
	var update_note := Label.new()
	update_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	update_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	update_note.modulate = Palette.TEXT_DIM
	update_note.text = "You have version %s." % Updates.current_version()
	update_btn.pressed.connect(func():
		update_note.text = "Checking..."
		if _parent and _parent.has_method("_check_updates"):
			_parent.call("_check_updates", true, func(msg: String): update_note.text = msg))
	vbox.add_child(update_btn)
	vbox.add_child(update_note)
	if not OS.has_feature("web"):
		var auto_btn := CheckButton.new()
		auto_btn.text = "Check for updates when the game starts"
		auto_btn.button_pressed = Updates.check_enabled()
		auto_btn.toggled.connect(func(on: bool): Updates.set_check_enabled(on))
		vbox.add_child(auto_btn)

	# Ian: the terms every player agreed to (they cover the gameplay data).
	var terms_btn := Button.new()
	terms_btn.text = "Terms of Service"
	terms_btn.pressed.connect(func():
		if _parent and _parent.has_method("_show_terms_popup"):
			_parent.call("_show_terms_popup"))
	vbox.add_child(terms_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset Game"
	reset_btn.pressed.connect(_on_reset_pressed)
	vbox.add_child(reset_btn)

	# Ian: the player ID on the Menu for easy reference (deletion requests,
	# bug reports). Tap to copy.
	var id_btn := Button.new()
	id_btn.text = "ID: " + Analytics.display_id()
	id_btn.flat = true
	id_btn.tooltip_text = "Your player ID -- tap to copy"
	id_btn.pressed.connect(func():
		if _parent: _parent.call("copy_text", Analytics.display_id())
		id_btn.text = "ID: %s  (copied)" % Analytics.display_id())
	vbox.add_child(id_btn)

	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.dialog_text = "Erase all progress and start a brand new game? This cannot be undone."
	confirm_dialog.confirmed.connect(_on_reset_confirmed)
	popup.add_child(confirm_dialog)

func _style_popup(p: PopupPanel) -> void:
	UiKit.style_popup(p)

## icon, when provided, shows a real icon texture instead of/alongside
## the placeholder text -- every EXISTING call site passes no icon
## (unchanged behavior) until real button art exists (Ian: "prepare for
## real button/icon assets").
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	return UiKit.icon_tab(parent, pos, size, label_text, callback, icon)

func _on_toggle_pressed() -> void:
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	popup.popup(Rect2i(Vector2i(_vp.x * 0.02, _vp.y * 0.125), Vector2i(_vp.x * 0.96, _vp.y * 0.76)))
	_notify_battle_paused(true)

func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _on_catalogue_pressed() -> void:
	if _parent and _parent.has_method("_open_catalogue"):
		_parent.call("_open_catalogue")

func _on_inventory_pressed() -> void:
	if _parent and _parent.has_method("_show_inventory_popup"):
		_parent.call("_show_inventory_popup")

func _on_change_name_pressed() -> void:
	if _parent and _parent.has_method("_show_change_name_popup"):
		_parent.call("_show_change_name_popup")

func _on_reset_pressed() -> void:
	confirm_dialog.popup_centered()

func _on_reset_confirmed() -> void:
	if _parent and _parent.has_method("_reset_game"):
		_parent.call("_reset_game")

class_name SettingsPanel
extends Node
## The Menu tab (bottom-row label "Menu"): settings and utilities. Its
## "Reset Game" button sits behind a ConfirmationDialog (the same
## confirm-before-destructive-action pattern LorePanel's refund uses). It
## deletes the save and reloads the scene, so the player goes back through
## GameController._ready()'s normal boot (no save found -> character creation)
## instead of tearing down and rebuilding every panel and timer by hand.
##
## The Inventory readout is a button (it opens GameController.show_inventory_popup,
## the same small overlay the other detail popups use), and a "Change Name"
## button opens GameController.show_change_name_popup.

var g: Dictionary
var _vp: Vector2
var _parent: GameController

var toggle_button: Button
var popup: PopupPanel
var confirm_dialog: ConfirmationDialog

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if popup != null and _built_wide != _is_wide():
		_populate_popup()
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.8613, _vp.y * 0.93), icon_size, "Menu", open_menu)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.8613, _vp.y * 0.93), icon_size, "Menu", open_menu)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	_populate_popup()

var _body: Control
var _built_wide := false

func _is_wide() -> bool:
	return _parent != null and _parent.wide

## Rebuilt in place when the window changes shape (the popup itself stays).
func _populate_popup() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
	_built_wide = _is_wide()
	# the same size as the other main menus (96% x 76%), scrolling
	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.76)
	if _built_wide:
		var fr: Rect2i = _parent.full_menu_rect()
		popup_size = Vector2(fr.size.x, fr.size.y)
	var scroll := ScrollContainer.new()
	_body = scroll
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	popup.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(popup_size.x - 40 - (70 if _built_wide else 0), 0)
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# Inventory (aether, marks and the other currencies): a button that opens
	# the same small overlay the other detail views use
	# (GameController.show_inventory_popup). It builds its readout fresh each
	# time, so there is no label to keep refreshed here.
	# Cloud saves: the recovery code that moves this game to another device
	var account_btn := Button.new()
	account_btn.text = "Cloud save & recovery code"
	account_btn.pressed.connect(func():
		_parent.show_account_popup())
	vbox.add_child(account_btn)

	var inventory_btn := Button.new()
	inventory_btn.text = "Inventory"
	inventory_btn.pressed.connect(_on_inventory_pressed)
	vbox.add_child(inventory_btn)

	# Stats: opens GameController.show_stats_popup, the same detail overlay
	# Inventory uses.
	var stats_btn := Button.new()
	stats_btn.text = "Stats"
	stats_btn.pressed.connect(func():
		_parent.show_stats_popup())
	vbox.add_child(stats_btn)

	# (the name now lives in the Customize screen)
	# male/female main character, changeable any time
	var body_btn := Button.new()
	body_btn.text = "Customize Character"
	body_btn.pressed.connect(func():
		_parent.show_change_body_popup())
	vbox.add_child(body_btn)

	# the Catalogue is opened from here, so it needs no bottom-row icon
	var catalogue_btn := Button.new()
	catalogue_btn.text = "Catalogue"
	catalogue_btn.pressed.connect(_on_catalogue_pressed)
	vbox.add_child(catalogue_btn)

	var tuts_btn := Button.new()
	tuts_btn.text = "Tutorials"
	tuts_btn.pressed.connect(func():
		_parent.show_tutorials_popup())
	vbox.add_child(tuts_btn)

	# skips all tutorials and unlocks every menu (a tutorial's own caption has
	# a Skip for just that one)
	var skip_btn := Button.new()
	skip_btn.text = "Skip all tutorials"
	skip_btn.disabled = bool(g.get("tutorialSkip", false))
	skip_btn.pressed.connect(func():
		_parent.skip_tutorials()
		skip_btn.disabled = true)
	vbox.add_child(skip_btn)

	# a feedback button for suggestions and bug reports
	var feedback_btn := Button.new()
	feedback_btn.text = "Send Feedback"
	feedback_btn.pressed.connect(func():
		_parent.show_feedback_popup())
	vbox.add_child(feedback_btn)

	# graphics: the sun/moon tint, sprite shading, leaning blob shadows and cave crystal lights
	var light_btn := CheckButton.new()
	light_btn.text = "Dynamic lighting"
	light_btn.button_pressed = Lighting.enabled()
	light_btn.toggled.connect(func(on: bool):
		Lighting.set_enabled(on)
		_parent.call("apply_lighting_setting"))
	vbox.add_child(light_btn)
	var light_note := Label.new()
	light_note.text = "Turn off for better battery life or a plain look on older phones."
	light_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	light_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	light_note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(light_note)

	# notifications for idle rewards full / an expedition back
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
	if Notifier.platform() == "android":
		var problem_text: String = _parent.notifier.android_problem_text() if _parent.notifier != null else ""
		if problem_text != "":
			var problem_lbl := Label.new()
			problem_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			problem_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			problem_lbl.add_theme_color_override("font_color", Color(1.0, 0.55, 0.4))
			problem_lbl.text = problem_text
			notify_sub.add_child(problem_lbl)
			var fix_btn := Button.new()
			fix_btn.text = "Fix"
			fix_btn.pressed.connect(func(): _parent.notifier.android_fix())
			notify_sub.add_child(fix_btn)
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
		var n = _parent.notifier
		test_note.text = n.send_test() if n != null else "Not ready yet.")
	notify_sub.add_child(test_btn)
	notify_sub.add_child(test_note)

	# patch notes in the game, and a check for a newer version
	var notes_btn := Button.new()
	notes_btn.text = "Patch notes"
	notes_btn.pressed.connect(func():
		_parent.show_patch_notes_popup())
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
		_parent.check_updates(true, func(msg: String): update_note.text = msg))
	vbox.add_child(update_btn)
	vbox.add_child(update_note)
	if not OS.has_feature("web"):
		var auto_btn := CheckButton.new()
		auto_btn.text = "Check for updates when the game starts"
		auto_btn.button_pressed = Updates.check_enabled()
		auto_btn.toggled.connect(func(on: bool): Updates.set_check_enabled(on))
		vbox.add_child(auto_btn)

	# the terms every player agreed to (they cover the gameplay data)
	var terms_btn := Button.new()
	terms_btn.text = "Terms of Service"
	terms_btn.pressed.connect(func():
		_parent.show_terms_popup())
	vbox.add_child(terms_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset Game"
	reset_btn.pressed.connect(_on_reset_pressed)
	vbox.add_child(reset_btn)

	# the player ID, for easy reference (deletion requests, bug reports); tap
	# to copy
	var id_btn := Button.new()
	id_btn.text = "ID: " + Analytics.display_id()
	id_btn.flat = true
	id_btn.tooltip_text = "Your player ID -- tap to copy"
	id_btn.pressed.connect(func():
		_parent.copy_text(Analytics.display_id())
		id_btn.text = "ID: %s  (copied)" % Analytics.display_id())
	vbox.add_child(id_btn)

	if _built_wide:
		_split_columns(vbox)

	if confirm_dialog != null and is_instance_valid(confirm_dialog):
		confirm_dialog.queue_free()
	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.dialog_text = "Erase all progress and start a brand new game? This cannot be undone."
	confirm_dialog.confirmed.connect(_on_reset_confirmed)
	popup.add_child(confirm_dialog)


## Wide window: the buttons in one column, the settings in another.
func _split_columns(vbox: VBoxContainer) -> void:
	var kids: Array = vbox.get_children()
	var cut := -1
	for i in range(kids.size()):
		if kids[i] is CheckButton:
			cut = i
			break
	if cut <= 1:
		return
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 40)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 5)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 5)
	for i in range(kids.size()):
		kids[i].reparent(left if i < cut else right)
	cols.add_child(left)
	cols.add_child(right)
	vbox.add_child(cols)

func _style_popup(p: PopupPanel) -> void:
	UiKit.style_popup(p)

## `icon`, when given, shows a real icon texture instead of or alongside the
## placeholder text; no caller passes one yet.
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	return UiKit.icon_tab(parent, pos, size, label_text, callback, icon)

func open_menu() -> void:
	_parent.panel_opening(self)
	popup.popup((_parent.full_menu_rect() if _is_wide() else _parent.menu_popup_rect()))

func _on_catalogue_pressed() -> void:
	_parent.open_catalogue()

func _on_inventory_pressed() -> void:
	_parent.show_inventory_popup()

func _on_change_name_pressed() -> void:
	_parent.show_change_name_popup()

func _on_reset_pressed() -> void:
	confirm_dialog.popup_centered()

func _on_reset_confirmed() -> void:
	_parent.reset_game()

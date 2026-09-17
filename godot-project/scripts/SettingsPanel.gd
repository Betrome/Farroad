extends Node
## Post-Milestone-3 APK feedback (Group C2): the new "Settings" tab -- a
## single "Reset Game" button behind a ConfirmationDialog (same reuse of
## Godot's confirm-before-destructive-action pattern LorePanel's own refund
## flow already established), deleting user://save.json and reloading the
## scene so the player re-enters GameController._ready()'s own existing
## boot gate (no save found -> character creation) rather than hand-rolling
## a manual in-place teardown/rebuild of every panel and timer.

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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.8613, _vp.y * 0.93), icon_size, "Settings", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.8613, _vp.y * 0.93), icon_size, "Settings", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(_vp.x * 0.7, 0)
	vbox.add_theme_constant_override("separation", 14)
	popup.add_child(vbox)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# Group H (20-item batch): Catalogue folded in here so it no longer
	# needs its own bottom-row icon.
	var catalogue_btn := Button.new()
	catalogue_btn.text = "Catalogue"
	catalogue_btn.pressed.connect(_on_catalogue_pressed)
	vbox.add_child(catalogue_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset Game"
	reset_btn.pressed.connect(_on_reset_pressed)
	vbox.add_child(reset_btn)

	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.dialog_text = "Erase all progress and start a brand new game? This cannot be undone."
	confirm_dialog.confirmed.connect(_on_reset_confirmed)
	popup.add_child(confirm_dialog)

func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Palette.BTN_NORMAL
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Palette.BTN_HOVER
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn

func _on_toggle_pressed() -> void:
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	popup.popup_centered(Vector2(_vp.x * 0.7, _vp.y * 0.3))
	_notify_battle_paused(true)

func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _on_catalogue_pressed() -> void:
	if _parent and _parent.has_method("_open_catalogue"):
		_parent.call("_open_catalogue")

func _on_reset_pressed() -> void:
	confirm_dialog.popup_centered()

func _on_reset_confirmed() -> void:
	if _parent and _parent.has_method("_reset_game"):
		_parent.call("_reset_game")

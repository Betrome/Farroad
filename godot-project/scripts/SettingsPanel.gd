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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.7533, _vp.y * 0.93), icon_size, "Menu", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.7533, _vp.y * 0.93), icon_size, "Menu", _on_toggle_pressed)

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

	# Ian: "add an inventory tab to show aether, marks, and future
	# currencies" -- then later "change the inventory section to be a
	# button." Opens the same shared small-overlay popup every other
	# detail view uses (GameController._show_inventory_popup), which
	# builds its own live readout fresh each time it's opened -- no local
	# label to keep refreshed here anymore.
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

	# Ian: "add a button to change our main character's name."
	var change_name_btn := Button.new()
	change_name_btn.text = "Change Name"
	change_name_btn.pressed.connect(_on_change_name_pressed)
	vbox.add_child(change_name_btn)

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
	popup.popup_centered(Vector2(_vp.x * 0.7, _vp.y * 0.3))
	_notify_battle_paused(true)
	# Ian: "add tutorial pop-ups the first time each page/tab is opened" --
	# see GameController._maybe_show_tab_tutorial's own comment.
	if _parent and _parent.has_method("_maybe_show_tab_tutorial"):
		await _parent.call("_maybe_show_tab_tutorial", "settings")

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

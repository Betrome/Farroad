extends Node
## Ian: playing means agreeing to the terms (which cover the gameplay data
## Analytics.gd sends) -- shown full-screen before the game starts, for new
## and returning players alike, and again whenever Analytics.TERMS_VERSION
## goes up. Same full-screen shape as McCreatePanel.

var _vp: Vector2
var root: Control
var _on_agree: Callable
var _note: Label

func setup(vp: Vector2, parent: Node, on_agree: Callable) -> void:
	_vp = vp
	_on_agree = on_agree
	root = Control.new()
	root.size = _vp
	parent.add_child(root)

	var background := ColorRect.new()
	background.color = Palette.BG_PARCHMENT
	background.size = _vp
	root.add_child(background)

	var box := VBoxContainer.new()
	box.position = Vector2(_vp.x * 0.05, _vp.y * 0.04)
	box.size = Vector2(_vp.x * 0.9, _vp.y * 0.92)
	box.add_theme_constant_override("separation", 10)
	root.add_child(box)

	var title := Label.new()
	title.text = "Before you play"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.scroll_active = false
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.custom_minimum_size = Vector2(_vp.x * 0.86, 0)
	text.add_theme_color_override("default_color", Palette.TEXT_INK)
	text.text = Analytics.terms_bbcode()
	scroll.add_child(text)

	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.modulate = Palette.TEXT_DIM
	_note.visible = false
	box.add_child(_note)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var decline := Button.new()
	decline.text = "Decline"
	decline.custom_minimum_size = Vector2(_vp.x * 0.3, _vp.y * 0.055)
	decline.pressed.connect(_on_decline)
	row.add_child(decline)
	var agree := Button.new()
	agree.text = "Agree and continue"
	agree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agree.custom_minimum_size = Vector2(0, _vp.y * 0.055)
	agree.pressed.connect(_on_agree_pressed)
	row.add_child(agree)

func _on_agree_pressed() -> void:
	Analytics.accept_terms()
	root.queue_free()
	queue_free()
	_on_agree.call()

func _on_decline() -> void:
	_note.text = "Farroad can't be played without agreeing to these terms. You can close the game now, or agree to continue."
	_note.visible = true

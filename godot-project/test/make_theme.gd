extends SceneTree
## Builds the project theme (theme/default_theme.tres) from the UI kit, so the
## theme file and UiKit.gd can't drift apart. Run after changing UiKit colours:
##   godot --headless --path godot-project --script test/make_theme.gd
##
## The font is Selawik (the free Segoe UI lookalike). Its few missing
## characters fall back to the engine's default font, which GameController
## sets up at start (_add_symbol_fonts), because that font can't be saved
## inside a theme file.

const FONT_DIR := "res://fonts/selawik/"

func _capsule(bg: Color, border: Color, border_w: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(20)    # a capsule at any normal button height
	s.set_border_width_all(border_w)
	s.border_color = Color(border, border.a * 0.85)
	s.anti_aliasing_size = 1.6
	s.content_margin_left = 16.0
	s.content_margin_right = 16.0
	s.content_margin_top = 8.0
	s.content_margin_bottom = 8.0
	return s

func _initialize() -> void:
	var t := Theme.new()
	var regular: Font = load(FONT_DIR + "Selawik-Regular.ttf")
	var bold: Font = load(FONT_DIR + "Selawik-Bold.ttf")
	t.default_font = regular
	t.default_font_size = 16

	# buttons: capsules with a silver rim
	var normal := _capsule(UiKit.PLATE_LIGHT, UiKit.SILVER_DIM)
	var hover := _capsule(UiKit.PLATE_LIGHT.lightened(0.10), UiKit.SILVER)
	var pressed := _capsule(UiKit.PLATE_LIGHT.darkened(0.25), UiKit.SILVER_DIM)
	var disabled := _capsule(Color(UiKit.PLATE_LIGHT, 0.4), Color(UiKit.SILVER_DIM, 0.4))
	var focus := _capsule(Color(0, 0, 0, 0), UiKit.SILVER, 2)
	focus.shadow_color = Color(UiKit.SILVER, 0.35)
	focus.shadow_size = 6
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", focus)
	t.set_color("font_color", "Button", UiKit.TEXT)
	t.set_color("font_hover_color", "Button", UiKit.TEXT)
	t.set_color("font_pressed_color", "Button", Color(UiKit.TEXT, 0.9))
	t.set_color("font_focus_color", "Button", UiKit.TEXT)
	t.set_color("font_disabled_color", "Button", UiKit.DISABLED_TEXT)

	# text
	t.set_color("font_color", "Label", UiKit.TEXT)
	t.set_color("default_color", "RichTextLabel", UiKit.TEXT)
	t.set_font("bold_font", "RichTextLabel", bold)
	t.set_color("font_color", "CheckButton", UiKit.TEXT)
	t.set_color("font_color", "CheckBox", UiKit.TEXT)
	t.set_color("font_color", "OptionButton", UiKit.TEXT)

	# plain panels
	var plate := StyleBoxFlat.new()
	plate.bg_color = Color(UiKit.PLATE, 0.96)
	plate.set_corner_radius_all(UiKit.RADIUS)
	plate.set_border_width_all(1)
	plate.border_color = UiKit.SILVER_DIM
	plate.content_margin_left = 10.0
	plate.content_margin_right = 10.0
	plate.content_margin_top = 8.0
	plate.content_margin_bottom = 8.0
	t.set_stylebox("panel", "PanelContainer", plate)

	# text boxes
	var edit := StyleBoxFlat.new()
	edit.bg_color = UiKit.PLATE_DARK
	edit.set_corner_radius_all(UiKit.RADIUS)
	edit.set_border_width_all(1)
	edit.border_color = UiKit.SILVER_DIM
	edit.content_margin_left = 10.0
	edit.content_margin_right = 10.0
	edit.content_margin_top = 6.0
	edit.content_margin_bottom = 6.0
	t.set_stylebox("normal", "LineEdit", edit)
	var edit_focus := edit.duplicate()
	edit_focus.border_color = UiKit.SILVER
	t.set_stylebox("focus", "LineEdit", edit_focus)
	t.set_color("font_color", "LineEdit", UiKit.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(UiKit.TEXT, 0.7))
	t.set_color("caret_color", "LineEdit", UiKit.TEXT)

	# thin rules
	var line := StyleBoxLine.new()
	line.color = Color(UiKit.SILVER_DIM, 0.5)
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)

	var err := ResourceSaver.save(t, "res://theme/default_theme.tres")
	print("saved theme: ", "OK" if err == OK else "ERROR %d" % err)
	quit()

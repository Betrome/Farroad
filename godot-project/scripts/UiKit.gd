class_name UiKit
extends RefCounted
## The proposed UI kit (Ian): dark olive-brown plates with a silver rim lit from
## the upper left, capsule buttons, light-band selection and recessed bars.
## Built from the Sprite Work session's FFXII/XIII/XIV/Last Remnant study
## (style only, no game assets). Nothing in the game uses this yet -- it is
## shown by UiKitMockup (res://scenes/UiKitMockup.tscn, or run the game with
## --ui-preview). If it is approved the real screens switch over to it.

# ---- palette: browner and greener than plain slate, with a silver rim ----
const PLATE := Color("38332b")          # panel body (warm brown)
const PLATE_LIGHT := Color("48423a")    # lighter capsule top / raised
const PLATE_DARK := Color("27231d")     # troughs, pressed
const SILVER := Color("c4c9cf")         # rim, lit side
const SILVER_DIM := Color("767b82")     # rim, shaded side
const PRIMARY := Color("65573b")        # the primary button's body (bronze-brown)
const TEXT := Color("eeeadf")           # body (warm white)
const TEXT_DIM := Color("b4ad9c")       # small-caps labels
const BAND := Color("c9a24a")           # selection light
const HP_GOOD := Color("1FDA6C")        # above 50% (saturation reduced)
const HP_MID := Color("F7DB4A")         # 50% and below (saturation reduced)
const HP_LOW := Color("EC5045")         # 25% and below (saturation reduced)
const MP := Color("4f86c6")
const CHARGE := Color("F98A32")          # orange
const BUFF := Color("5aa0e0")
const DEBUFF := Color("9a6ad0")
const DOT := Color("d0594e")
const BETTER := Color("0053D6")         # fills and chips (white text on it: 6.5:1)
const WORSE := Color("FFAB00")          # fills and chips (black text on it: 11:1); also fine as text

## Lighter versions of the status colours for TEXT, so every word reaches 4.5:1
## on the plate and on the dark trough. The colours above stay for fills.
const BETTER_TEXT := Color("709FE8")
const WORSE_TEXT := Color("FFAB00")
const BUFF_TEXT := Color("5DA2E1")
const DEBUFF_TEXT := Color("B28EDB")
const DOT_TEXT := Color("DD867E")
const DISABLED_TEXT := Color("CFC9B9")  # solid, not faded: the faded capsule shows "disabled"
const BAND_ALPHA := 0.40                # the brightest the selection light gets, so text on it stays >= 4.5:1

const RADIUS := 6

static func plate_style(modal: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(PLATE, 0.92)
	s.set_corner_radius_all(RADIUS)
	s.set_border_width_all(2 if modal else 1)
	s.border_color = SILVER_DIM
	s.shadow_color = Color(0, 0, 0, 0.35)
	s.shadow_size = 6
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

static func capsule_style(base: Color, rim: Color, height: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = base
	s.set_corner_radius_all(int(height / 2.0))
	s.set_border_width_all(1)
	s.border_color = rim
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s

## WCAG contrast ratio between two opaque colours.
static func contrast(a: Color, b: Color) -> float:
	var la := _luminance(a)
	var lb := _luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)

static func _luminance(c: Color) -> float:
	var f := func(v: float) -> float: return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * f.call(c.r) + 0.7152 * f.call(c.g) + 0.0722 * f.call(c.b)

## `fg` at `alpha` laid over `bg`.
static func over(fg: Color, bg: Color, alpha: float) -> Color:
	return Color(bg.r + (fg.r - bg.r) * alpha, bg.g + (fg.g - bg.g) * alpha, bg.b + (fg.b - bg.b) * alpha)

## Draws a vertical light-to-clear gradient over a rect (the "top light" of a
## capsule or bar fill).
static func top_light(c: CanvasItem, r: Rect2, color: Color, strength: float) -> void:
	var pts := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var top := Color(color, strength)
	var clear := Color(color, 0.0)
	c.draw_polygon(pts, PackedColorArray([top, top, clear, clear]))

## A capsule button in one of the kit's looks. kind: primary / secondary.
## state: normal / hover / pressed / disabled / focus -- the real Button picks
## its own at runtime; the mockup forces one to show them side by side.
static func style_button(btn: Button, kind: String = "secondary", force_state: String = "") -> void:
	var h: float = maxf(btn.custom_minimum_size.y, 40.0)
	btn.custom_minimum_size.y = h
	var primary: bool = kind == "primary"
	var base: Color = PRIMARY if primary else PLATE_LIGHT
	var normal := capsule_style(base, SILVER_DIM, h)
	var hover := capsule_style(base.lightened(0.10), SILVER, h)
	var pressed := capsule_style(base.darkened(0.25), SILVER_DIM, h)
	var disabled := capsule_style(Color(base, 0.4), Color(SILVER_DIM, 0.4), h)
	var focus := capsule_style(base, SILVER, h)
	focus.set_border_width_all(2)
	focus.shadow_color = Color(SILVER, 0.35)
	focus.shadow_size = 7
	var shown := {"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled, "focus": focus}
	btn.add_theme_stylebox_override("normal", shown[force_state] if force_state != "" else normal)
	btn.add_theme_stylebox_override("hover", shown[force_state] if force_state != "" else hover)
	btn.add_theme_stylebox_override("pressed", shown[force_state] if force_state != "" else pressed)
	btn.add_theme_stylebox_override("disabled", shown[force_state] if force_state != "" else disabled)
	btn.add_theme_stylebox_override("focus", focus if force_state == "" else StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", TEXT)
	btn.add_theme_color_override("font_pressed_color", Color(TEXT, 0.85))
	btn.add_theme_color_override("font_disabled_color", DISABLED_TEXT)
	# the top light on the capsule (not on pressed or disabled)
	btn.draw.connect(func():
		var state: String = force_state
		if state == "":
			state = "disabled" if btn.disabled else ("pressed" if btn.button_pressed or btn.is_pressed() else "normal")
		if state == "pressed" or state == "disabled":
			return
		var pts := capsule_top(btn.size.x, btn.size.y, 1.5)
		var rr: float = btn.size.y / 2.0
		var cols := PackedColorArray()
		for p in pts:
			cols.append(Color(1, 1, 1, 0.16 * clampf(1.0 - p.y / rr, 0.0, 1.0)))
		btn.draw_polygon(pts, cols)
		btn.draw_polyline(pts, Color(1, 1, 1, 0.24), 1.0, true))

## The upper half of a capsule's outline, curves included, from the left
## middle over the top to the right middle (`inset` px inside the edge).
static func capsule_top(w: float, h: float, inset: float = 0.0) -> PackedVector2Array:
	var r: float = h / 2.0
	var ri: float = maxf(1.0, r - inset)
	var pts := PackedVector2Array()
	var steps := 12
	for i in range(steps + 1):
		var a: float = PI + (PI / 2.0) * float(i) / float(steps)
		pts.append(Vector2(r + cos(a) * ri, r + sin(a) * ri))
	for i in range(steps + 1):
		var a2: float = PI * 1.5 + (PI / 2.0) * float(i) / float(steps)
		pts.append(Vector2(w - r + cos(a2) * ri, r + sin(a2) * ri))
	return pts

## The label tier ("small caps"). With a font that has true small caps
## (Alegreya SC / Alegreya Sans SC) the text keeps its case and the font makes
## the lowercase letters small capitals; with any other font it is upper-cased.
static var label_font: Font = null
static var label_small_caps := false

static func label_text(s: String) -> String:
	return s if label_small_caps else s.to_upper()

static func make_label(text: String, tier: String = "body") -> Label:
	var l := Label.new()
	match tier:
		"label":
			l.text = label_text(text)
			l.set_meta("ui_tier", "label")
			l.set_meta("ui_raw", text)
			if label_font != null:
				l.add_theme_font_override("font", label_font)
			l.add_theme_font_size_override("font_size", 12 if label_small_caps else 11)
			l.add_theme_color_override("font_color", TEXT_DIM)
		"number":
			l.text = text
			l.add_theme_font_size_override("font_size", 26)
			l.add_theme_color_override("font_color", TEXT)
			l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			l.add_theme_constant_override("outline_size", 3)
		_:
			l.text = text
			l.add_theme_font_size_override("font_size", 14)
			l.add_theme_color_override("font_color", Color(TEXT, 0.9))
	return l

## Steps, not a blend: green above 50%, yellow at 50% and below, red at 25% and below.
static func hp_color(frac: float) -> Color:
	if frac > 0.5:
		return HP_GOOD
	if frac > 0.25:
		return HP_MID
	return HP_LOW

## Filter and sort dropdowns: small, an equal share of the row, text clipped
## rather than wrapping the row onto a second line.
static func compact_dropdown(opt: OptionButton) -> OptionButton:
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.custom_minimum_size.x = 0.0
	opt.clip_text = true
	opt.fit_to_longest_item = false
	opt.add_theme_font_size_override("font_size", 13)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb: StyleBox = opt.get_theme_stylebox(state, "Button")
		if sb is StyleBoxFlat:
			var tight: StyleBoxFlat = sb.duplicate()
			tight.content_margin_left = 9.0
			tight.content_margin_right = 5.0
			tight.content_margin_top = 5.0
			tight.content_margin_bottom = 5.0
			opt.add_theme_stylebox_override(state, tight)
	return opt

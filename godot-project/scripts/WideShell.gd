extends Node
## The frame of a wide (landscape) desktop or web window: a ribbon across the
## top that always holds the menu icons, the Road button and the currencies; the
## battle column on the left; and a dock on the right that holds the Status and
## Log of the fight. GameController owns every real widget and puts them in
## place; this only builds the backgrounds and the dock's two hosts.
## Phones (and narrow windows) never build this: they keep the portrait layout.

const RIBBON_H := 64.0
const DOCK_W := 380.0
const DOCK_PAD := 10.0

var ribbon_bg: Panel
var dock_bg: Panel
var fight_box: VBoxContainer
var page_box: VBoxContainer
var page_host: VBoxContainer
var page_title: Label
var page_back: Button
var status_host: VBoxContainer
var log_host: VBoxContainer
var _status_title: Label
var _log_title: Label

func build(host: Node) -> void:
	ribbon_bg = Panel.new()
	ribbon_bg.add_theme_stylebox_override("panel", _plate(UiKit.PLATE_DARK, 0, 0, 0, 1))
	ribbon_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(ribbon_bg)
	dock_bg = Panel.new()
	dock_bg.add_theme_stylebox_override("panel", _plate(UiKit.PLATE_DARK, 1, 0, 0, 0))
	dock_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	# Above the battle's chrome (z 2, added later so it would win a tie): its turn-order strip runs
	# off the column's right edge. Everything hosted in the dock inherits this.
	dock_bg.z_index = 3
	host.add_child(dock_bg)
	var box := VBoxContainer.new()
	box.name = "DockBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = DOCK_PAD
	box.offset_right = -DOCK_PAD
	box.offset_top = DOCK_PAD
	box.offset_bottom = -DOCK_PAD
	box.add_theme_constant_override("separation", 6)
	dock_bg.add_child(box)
	# the fight (Status and Log) is the dock's home; a page (Quests...) takes its place
	fight_box = VBoxContainer.new()
	fight_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fight_box.add_theme_constant_override("separation", 6)
	box.add_child(fight_box)
	page_box = VBoxContainer.new()
	page_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_box.add_theme_constant_override("separation", 6)
	page_box.visible = false
	box.add_child(page_box)
	var head := HBoxContainer.new()
	page_box.add_child(head)
	page_title = Label.new()
	page_title.add_theme_font_size_override("font_size", 18)
	page_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(page_title)
	page_back = Button.new()
	page_back.text = "Back to fight"
	head.add_child(page_back)
	page_host = VBoxContainer.new()
	page_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_host.clip_contents = true
	page_box.add_child(page_host)
	_status_title = _title("STATUS")
	fight_box.add_child(_status_title)
	status_host = VBoxContainer.new()
	status_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	status_host.size_flags_stretch_ratio = 3.0
	status_host.clip_contents = true
	fight_box.add_child(status_host)
	fight_box.add_child(HSeparator.new())
	_log_title = _title("LOG")
	fight_box.add_child(_log_title)
	log_host = VBoxContainer.new()
	log_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_host.size_flags_stretch_ratio = 2.0
	log_host.clip_contents = true
	fight_box.add_child(log_host)

func _title(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", UiKit.SILVER_DIM)
	return l

## border widths: left, top, right, bottom
func _plate(c: Color, bl: int, bt: int, br: int, bb: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.border_width_left = bl
	sb.border_width_top = bt
	sb.border_width_right = br
	sb.border_width_bottom = bb
	sb.border_color = UiKit.SILVER_DIM
	return sb

func layout(vp: Vector2) -> void:
	ribbon_bg.position = Vector2.ZERO
	ribbon_bg.size = Vector2(vp.x, RIBBON_H)
	dock_bg.position = Vector2(vp.x - DOCK_W, RIBBON_H)
	dock_bg.size = Vector2(DOCK_W, vp.y - RIBBON_H)

func set_shown(on: bool) -> void:
	ribbon_bg.visible = on
	dock_bg.visible = on

static func battle_rect(vp: Vector2) -> Rect2:
	return Rect2(Vector2(0.0, RIBBON_H), Vector2(vp.x - DOCK_W, vp.y - RIBBON_H))

func show_page(title: String, on: bool) -> void:
	page_title.text = title
	page_box.visible = on
	fight_box.visible = not on

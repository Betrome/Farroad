class_name TouchScroll
extends Node
## 24-item batch, Group F: "can't scroll when first touch is on an element:
## drop-down, status area, text, etc. ... if long hold or drag, should
## always be scrolling."
##
## Godot's own ScrollContainer only starts a touch-drag scroll when the
## PRESS itself reaches it -- a press landing on a Button, OptionButton,
## PanelContainer card or RichTextLabel (all MOUSE_FILTER_STOP) is consumed
## there and never propagates, so the drag that follows can't scroll. This
## helper (one per ScrollContainer, attached automatically by
## GameController._on_node_added) watches raw input in _input -- BEFORE the
## GUI routes it -- so it sees every press/drag inside its container no
## matter what's under the finger:
##   * press inside the container: remembered, NOT consumed (a plain tap
##     still reaches whatever was tapped, unchanged).
##   * motion past DEADZONE_PX in a direction this container can scroll:
##     becomes a drag -- scrolls by the motion delta, consumes the motion,
##     and cancels the pressed control's click by pushing a synthetic
##     release far off-screen (Godot routes a release to whichever control
##     captured the press, which then sees it land outside its rect and
##     drops the click without firing).
##   * release after a drag: consumed, so nothing underneath fires.
## Godot's own built-in touch drag is disabled on the container
## (scroll_deadzone set huge) so the two never double-scroll. Mouse-wheel
## scrolling and the scrollbars themselves are untouched.

const DEADZONE_PX := 10.0
const OFFSCREEN := Vector2(-100000, -100000)

## Only one helper may own a drag at a time -- nested containers (e.g. a
## horizontal row inside a vertical list) each claim only drags in a
## direction they can actually scroll, and the first to claim wins.
static var _active_owner: TouchScroll = null

var sc: ScrollContainer
var _pressing := false
var _dragging := false
var _drag_axis := Vector2.ZERO
var _press_pos := Vector2.ZERO
var _synthetic := false

func _ready() -> void:
	sc = get_parent() as ScrollContainer
	if sc:
		sc.scroll_deadzone = 1000000

func _exit_tree() -> void:
	if _active_owner == self:
		_active_owner = null

func _can_scroll(axis: Vector2) -> bool:
	if axis.x != 0.0:
		return sc.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED \
			and sc.get_h_scroll_bar().max_value > sc.size.x
	return sc.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED \
		and sc.get_v_scroll_bar().max_value > sc.size.y

func _on_scrollbar(p: Vector2) -> bool:
	var vb := sc.get_v_scroll_bar()
	var hb := sc.get_h_scroll_bar()
	return (vb.visible and vb.get_global_rect().has_point(p)) or (hb.visible and hb.get_global_rect().has_point(p))

func _reset() -> void:
	_pressing = false
	_dragging = false
	_drag_axis = Vector2.ZERO
	if _active_owner == self:
		_active_owner = null

func _input(ev: InputEvent) -> void:
	if _synthetic or sc == null:
		return
	if not sc.is_visible_in_tree():
		if _pressing or _dragging:
			_reset()
		return

	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_reset()
			if sc.get_global_rect().has_point(ev.position) and not _on_scrollbar(ev.position):
				_pressing = true
				_press_pos = ev.position
		else:
			if _dragging:
				get_viewport().set_input_as_handled()
			_reset()
		return

	if ev is InputEventMouseMotion and _pressing and (ev.button_mask & MOUSE_BUTTON_MASK_LEFT):
		if not _dragging:
			var d: Vector2 = ev.position - _press_pos
			if d.length() < DEADZONE_PX:
				return
			var axis := Vector2(1, 0) if absf(d.x) > absf(d.y) else Vector2(0, 1)
			if _active_owner != null and _active_owner != self:
				return
			if not _can_scroll(axis):
				return
			_dragging = true
			_drag_axis = axis
			_active_owner = self
			_cancel_press()
		if _drag_axis.y != 0.0:
			sc.scroll_vertical -= int(round(ev.relative.y))
		else:
			sc.scroll_horizontal -= int(round(ev.relative.x))
		get_viewport().set_input_as_handled()

## Mimics a player sliding their finger off the pressed control before
## lifting it: a motion far outside every control (BaseButton decides
## "released inside?" from the LAST MOTION it saw, not from the release's
## own position -- and this helper consumes the real motions), then a
## release, both routed by Godot to whichever control captured the press.
## That control then drops its pending click instead of firing it.
func _cancel_press() -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = OFFSCREEN
	mv.global_position = OFFSCREEN
	mv.button_mask = MOUSE_BUTTON_MASK_LEFT
	_synthetic = true
	get_viewport().push_input(mv, true)
	_synthetic = false
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = OFFSCREEN
	rel.global_position = OFFSCREEN
	_synthetic = true
	get_viewport().push_input(rel, true)
	_synthetic = false

extends Node
## The PARTY tab -- bench/field management, split out of GambitsPanel (which
## originally covered both loadout editing AND roster management together).
## Structural sibling of GambitsPanel/AetherPanel/LorePanel (same "owns its
## own tab-row button + popup" shape), given the live game-state Dictionary
## `g` once at setup() and reading/writing it directly from then on.
##
## Unlike a GAMBITS slot edit (already live via sync_loadout) or an AETHER
## purchase (live via refresh_live_stats), a bench/field change here has no
## real-JS precedent for live-syncing a fight already in progress (confirmed
## by reading the real benchUnit/fieldUnit -- neither touches G.units
## either), so this is a Godot-only enhancement:
## FarroadProgression.refresh_live_party(g) is called after every bench/
## field edit, then BattlePresenter.sync_live_party() is notified (through
## GameController, the same dynamic has_method()+call() pattern
## _notify_battle_paused already uses) so the change reaches the current
## fight immediately instead of only the next wave.

var g: Dictionary
var _vp: Vector2
var _parent: Node

var toggle_button: Button
var popup: PopupPanel
var roster_container: VBoxContainer

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Called by GameController on a viewport resize -- rebuilds just the
## toggle icon at the new size/position, same limitation as the other
## sibling panels' own reflow() (see GambitsPanel.reflow's comment).
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.328, _vp.y * 0.93), icon_size, "Party", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# Four evenly-spaced 0.12x vp.x icons across the bottom row now (was
	# three): Gambits 0.104, Party 0.328, Aether 0.552, Lore 0.776 --
	# margins and gaps both ~0.104 of vp.x, computed the same way the prior
	# 3-icon row's fractions were. The other three panels' own x fractions
	# were updated to match (duplicated per-file, no shared base).
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.328, _vp.y * 0.93), icon_size, "Party", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "PARTY"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	roster_container = VBoxContainer.new()
	roster_container.add_theme_constant_override("separation", 4)
	root_vbox.add_child(roster_container)

## Same opaque-panel convention every sibling panel already established --
## the default theme's PopupPanel background isn't fully opaque.
func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.24, 0.24, 0.29)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(0.32, 0.32, 0.38)
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn

func _on_toggle_pressed() -> void:
	_refresh_roster()
	popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))
	_notify_battle_paused(true)

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as GambitsPanel/AetherPanel/LorePanel's own copy (see
## BattlePresenter.loop_paused's own comment for why this exists).
func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

## Pushes a bench/field edit onto the CURRENT fight immediately -- see this
## file's own header comment for why this needs a dedicated Godot-only
## sync path (no real-JS precedent, unlike GAMBITS/AETHER's live-sync).
func _notify_party_changed() -> void:
	if _parent and _parent.has_method("_sync_party_change"):
		_parent.call("_sync_party_change")

## Mirrors partyRosterHTML/wirePartyRoster (farroad-ui.js:2722-2746) --
## fielded units with a Bench button (disabled at 1 remaining), owned-and-
## benched units with a Field button (disabled at PARTY_CAP). Moved here
## unchanged from GambitsPanel, which used to own this section too.
func _refresh_roster() -> void:
	for c in roster_container.get_children():
		c.queue_free()

	var party_header := Label.new()
	party_header.text = "PARTY"
	party_header.modulate = Color(0.6, 0.75, 1.0)
	roster_container.add_child(party_header)
	for uid in g["party"]:
		roster_container.add_child(_roster_row(uid, "Bench", g["party"].size() <= 1, _on_bench_pressed))

	var bench_header := Label.new()
	bench_header.text = "BENCHED"
	bench_header.modulate = Color(0.6, 0.75, 1.0)
	roster_container.add_child(bench_header)
	var avail: Array = FarroadProgression.available_for_party(g)
	if avail.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(none)"
		none_lbl.modulate = Color(0.55, 0.55, 0.55)
		roster_container.add_child(none_lbl)
	for uid in avail:
		roster_container.add_child(_roster_row(uid, "Field", g["party"].size() >= FarroadProgression.PARTY_CAP, _on_field_pressed))

func _roster_row(uid: String, action_text: String, disabled: bool, callback: Callable) -> Control:
	var row := HBoxContainer.new()
	var name_lbl := Label.new()
	var def = FarroadCore.roster_by_id(uid)
	name_lbl.text = def["name"] if def else uid
	name_lbl.custom_minimum_size = Vector2(_vp.x * 0.18, 0)
	row.add_child(name_lbl)
	var btn := Button.new()
	btn.text = action_text
	btn.disabled = disabled
	btn.pressed.connect(callback.bind(uid))
	row.add_child(btn)
	return row

func _on_bench_pressed(uid: String) -> void:
	if FarroadProgression.bench_unit(g, uid):
		_notify_party_changed()
	_refresh_roster()

func _on_field_pressed(uid: String) -> void:
	if FarroadProgression.field_unit(g, uid):
		_notify_party_changed()
	_refresh_roster()

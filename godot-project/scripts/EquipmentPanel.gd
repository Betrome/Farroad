extends Node
## Milestone 3, Step 3f: the EQUIPMENT tab -- per-unit gear management.
## Structural sibling of GambitsPanel.gd specifically (a per-unit editor,
## no currency-gated purchase rows to reuse from Aether/Lore) -- same
## "panel owns its own tab-row button + popup" shape, same unit-picker-
## including-benched pattern, given the live game-state Dictionary `g`
## once at setup() and reading/writing it directly from then on.
##
## Equipping is free once owned in the real game -- the only constraint is
## copy count (FarroadProgression.equip_available_count). An equip/unequip
## change reaches a unit already mid-fight immediately via
## FarroadProgression.refresh_live_stats(g) (already ported -- it already
## calls apply_equipment_stats internally, so no new plumbing was needed
## there), and this popup pauses BattlePresenter's beat loop while open,
## same as every sibling panel.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""

var toggle_button: Button
var popup: PopupPanel
var unit_tabs_container: HBoxContainer
var card_container: VBoxContainer

## Same small per-file duplication convention every sibling panel already
## uses (no shared base class in this project).
const RARITY_TAG := {"rare": " [RARE]", "legendary": " [LEGENDARY]"}
const AFFINITY_AXIS_LABELS := {"fire": "Fire", "water": "Water", "earth": "Earth", "air": "Air",
	"light": "Light", "dark": "Dark", "body": "Body", "spirit": "Spirit"}
## Mirrors EQUIP_SLOT_ICON/EQUIP_SLOT_LABEL (farroad-ui.js:556, :1955).
const EQUIP_SLOT_ICON := {"head": "🪖", "body": "🛡️", "legs": "🥾", "hand1": "🖐️", "hand2": "🖐️"}
const EQUIP_SLOT_LABEL := {"head": "Head", "body": "Body", "legs": "Legs", "hand1": "Hand (left)", "hand2": "Hand (right)"}

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Same reasoning/limitation as every sibling panel's own reflow() -- see
## GambitsPanel.reflow's comment.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.813, _vp.y * 0.93), icon_size, "Equip", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# Fifth of 5 evenly-spaced icons across the bottom row: Gambits 0.067,
	# Party 0.253, Aether 0.440, Lore 0.627, this one 0.813 -- adding this
	# icon meant recomputing all 5 x-fractions for even spacing (the prior
	# 4-icon layout's 0.104 margin/gap doesn't divide evenly by 5), so the
	# other four panels' own _build_ui/reflow fractions were updated too
	# (duplicated per file, same convention, no shared base).
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.813, _vp.y * 0.93), icon_size, "Equip", _on_toggle_pressed)

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
	title.text = "EQUIPMENT"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	unit_tabs_container = HBoxContainer.new()
	unit_tabs_container.add_theme_constant_override("separation", 6)
	root_vbox.add_child(unit_tabs_container)

	card_container = VBoxContainer.new()
	card_container.add_theme_constant_override("separation", 12)
	root_vbox.add_child(card_container)

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
	_refresh()
	popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))
	_notify_battle_paused(true)

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as every sibling panel's own copy (see
## BattlePresenter.loop_paused's own comment for why this exists).
func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

func _default_uid() -> String:
	if not g["party"].is_empty():
		return g["party"][0]
	var keys: Array = g["owned"].keys()
	return keys[0] if not keys.is_empty() else ""

func _refresh() -> void:
	if selected_uid == "" or not g["owned"].has(selected_uid):
		selected_uid = _default_uid()
	_refresh_unit_tabs()
	_refresh_card()

## Same renderUnitTabs(..., true) pattern every sibling panel already
## established -- every owned unit, fielded or benched.
func _refresh_unit_tabs() -> void:
	for c in unit_tabs_container.get_children():
		c.queue_free()
	for uid in g["owned"].keys():
		var def = FarroadCore.roster_by_id(uid)
		var btn := Button.new()
		var label: String = def["name"] if def else uid
		if not g["party"].has(uid):
			label += " •"
		btn.text = label
		btn.disabled = (uid == selected_uid)
		btn.pressed.connect(_on_unit_tab_pressed.bind(uid))
		unit_tabs_container.add_child(btn)

func _on_unit_tab_pressed(uid: String) -> void:
	selected_uid = uid
	_refresh()

## Mirrors describeEquipment's body line (farroad-ui.js:557-565) --
## "<Slot> · <stat bits> · <affinity bits>". UI-layer display logic (the
## real function lives in farroad-ui.js, not farroad-core.js), so it
## belongs here, not FarroadCore.gd/FarroadProgression.gd -- same split
## every other panel already follows for its own display helpers.
func _describe_equipment(item_id: String) -> String:
	var item = FarroadCore.EQUIPMENT.get(item_id)
	if item == null:
		return ""
	var bits: Array = []
	for k in ["atk", "mag", "def", "res", "spd"]:
		if item.get(k):
			bits.append("%s +%d" % [k.to_upper(), item[k]])
	if item.get("evade"):
		bits.append("Evade +%d%%" % roundi(item["evade"] * 100.0))
	var affinity: Dictionary = item.get("affinity", {})
	for ax in AFFINITY_AXIS_LABELS.keys():
		if affinity.get(ax):
			bits.append("%s affinity +%d" % [AFFINITY_AXIS_LABELS[ax], affinity[ax]])
	var slot_label: String = item["slot"].capitalize()
	return "%s · %s" % [slot_label, " · ".join(bits)] if not bits.is_empty() else slot_label

func _refresh_card() -> void:
	for c in card_container.get_children():
		c.queue_free()
	if selected_uid == "":
		return
	var uid := selected_uid
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return

	var header := Label.new()
	header.text = "%s%s" % [def["name"], RARITY_TAG.get(def.get("rarity"), "")]
	header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(header)

	for slot in FarroadCore.EQUIPMENT_SLOTS:
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)

		var slot_lbl := Label.new()
		slot_lbl.text = "%s %s" % [EQUIP_SLOT_ICON.get(slot, ""), EQUIP_SLOT_LABEL.get(slot, slot)]
		row.add_child(slot_lbl)
		row.add_child(_build_slot_option(uid, slot))

		var cur_id = g.get("equipped", {}).get(uid, {}).get(slot)
		if cur_id != null:
			var desc_lbl := Label.new()
			desc_lbl.text = _describe_equipment(cur_id)
			desc_lbl.modulate = Color(0.65, 0.7, 0.65)
			desc_lbl.add_theme_font_size_override("font_size", 12)
			row.add_child(desc_lbl)

		card_container.add_child(row)

## Mirrors the per-slot <select> build (farroad-ui.js:1968-1980) -- lists
## "— empty —" first, then every OWNED item matching this slot's kind
## (equip_owned_count>0), each reading "<name><rarity tag> (owned N, M
## available)". An option with equip_available_count<=0 is disabled (NOT
## omitted -- the label text alone already explains why) unless it's this
## slot's own current occupant, the exact same "disable, don't hide" rule
## GAMBITS' own action <select> already uses for a held-elsewhere action.
func _build_slot_option(uid: String, slot: String) -> OptionButton:
	var opt := OptionButton.new()
	var kind := FarroadProgression.equip_kind_for_slot(slot)
	var cur_id = g.get("equipped", {}).get(uid, {}).get(slot)
	opt.add_item("— empty —", 0)
	var item_ids: Array = ["" as String]
	var idx := 1
	for item_id in FarroadCore.EQUIPMENT.keys():
		var item: Dictionary = FarroadCore.EQUIPMENT[item_id]
		if item["slot"] != kind:
			continue
		if FarroadProgression.equip_owned_count(g, item_id) <= 0:
			continue
		var is_cur: bool = item_id == cur_id
		var available := FarroadProgression.equip_available_count(g, item_id)
		var label: String = "%s%s (owned %d, %d available)" % [
			item["name"], RARITY_TAG.get(item.get("rarity"), ""), FarroadProgression.equip_owned_count(g, item_id), available]
		opt.add_item(label, idx)
		if available <= 0 and not is_cur:
			opt.set_item_disabled(idx, true)
		if is_cur:
			opt.select(idx)
		item_ids.append(item_id)
		idx += 1
	if cur_id == null:
		opt.select(0)
	opt.item_selected.connect(func(sel_idx): _on_slot_selected(uid, slot, item_ids[sel_idx]))
	return opt

func _on_slot_selected(uid: String, slot: String, item_id: String) -> void:
	if item_id == "":
		FarroadProgression.unequip_item(g, uid, slot)
	else:
		FarroadProgression.equip_item(g, uid, slot, item_id)
	FarroadProgression.refresh_live_stats(g)
	_refresh_card()

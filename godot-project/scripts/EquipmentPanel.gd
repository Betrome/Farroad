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
##
## Post-Milestone-3 APK feedback (Group B1, then revised after real-device
## testing): this panel no longer owns any UI surface of its own -- see
## GambitsPanel.gd's own header comment for the full story of why (a
## nested-popup-closes-everything bug, plus Ian's explicit "show up
## beneath them, not as new windows" request). UnitsPanel is the sole
## popup owner now; this panel builds its existing card content directly
## into whatever container UnitsPanel hands it (build_into).

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""

var card_container: Container

## Same small per-file duplication convention every sibling panel already
## uses (no shared base class in this project).
## Post-Milestone-3 APK feedback (Group B3, then round 4 after Ian reported
## the [LEGENDARY] text was STILL showing, uncolored): OptionButton items
## genuinely cannot render BBCode/per-item text color in Godot -- but they
## CAN carry a per-item ICON (add_icon_item), so the rarity bracket tag is
## replaced here with a small solid-color swatch icon instead, actually
## achieving "color instead of text" within a real dropdown rather than
## falling back to a text tag. _rarity_icon() below generates/caches these.
const RARITY_COLOR := {"common": Color(1.0, 1.0, 1.0), "rare": Color(0.35, 0.55, 1.0), "legendary": Color(1.0, 0.62, 0.15)}
static var _rarity_icon_cache: Dictionary = {}

static func _rarity_icon(rarity: String) -> Texture2D:
	if _rarity_icon_cache.has(rarity):
		return _rarity_icon_cache[rarity]
	var color: Color = RARITY_COLOR.get(rarity, Color(1, 1, 1))
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var tex := ImageTexture.create_from_image(img)
	_rarity_icon_cache[rarity] = tex
	return tex
const AFFINITY_AXIS_LABELS := {"fire": "Fire", "water": "Water", "earth": "Earth", "air": "Air",
	"light": "Light", "dark": "Dark", "body": "Body", "spirit": "Spirit"}
## Mirrors EQUIP_SLOT_ICON/EQUIP_SLOT_LABEL (farroad-ui.js:556, :1955).
const EQUIP_SLOT_ICON := {"head": "🪖", "body": "🛡️", "legs": "🥾", "hand1": "🖐️", "hand2": "🖐️"}
const EQUIP_SLOT_LABEL := {"head": "Head", "body": "Body", "legs": "Legs", "hand1": "Hand (left)", "hand2": "Hand (right)"}

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp

## Called by UnitsPanel every time the EQUIPMENT sub-tab is shown.
## `host_popup` unused here (no transient dialog of its own) -- kept for a
## consistent signature across all 4 folded panels.
func build_into(container: Container, uid: String, _host_popup: Window) -> void:
	selected_uid = uid
	card_container = container
	_refresh_card()

## Mirrors describeEquipment's body line (farroad-ui.js:557-565) --
## "<Slot> · <stat bits> · <affinity bits>". UI-layer display logic (the
## real function lives in farroad-ui.js, not farroad-core.js), so it
## belongs here, not FarroadCore.gd/FarroadProgression.gd -- same split
## every other panel already follows for its own display helpers.
## `uid` is needed to show the item's affinity contribution as a real %
## instead of a raw CSV point value -- affinity_mul's log curve is
## nonlinear in the TOTAL raw affinity, not additive per-source, so an
## item's own raw value can't just be run through affinity_mul in
## isolation and called "this item's %". The well-defined number: the
## MARGINAL % this item's own contribution is worth on top of the
## unit's baseline+purchased affinity (deliberately excluding whatever
## else is equipped, so items stay comparable to each other regardless
## of loadout) -- affinity_mul(base+purchased+item) minus
## affinity_mul(base+purchased), as a percentage-point delta.
func _describe_equipment(item_id: String, uid: String) -> String:
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
	if not affinity.is_empty():
		var base := FarroadProgression.affinity_baseline(uid)
		var purchased := FarroadProgression.affinity_purchased(g, uid)
		for ax in AFFINITY_AXIS_LABELS.keys():
			var item_ax: float = affinity.get(ax, 0.0)
			if item_ax != 0.0:
				var without: float = base.get(ax, 0.0) + purchased.get(ax, 0.0)
				var with_item: float = without + item_ax
				var delta_pct: float = (FarroadCore.affinity_mul(with_item) - FarroadCore.affinity_mul(without)) * 100.0
				bits.append("%s affinity %+.0f%%" % [AFFINITY_AXIS_LABELS[ax], delta_pct])
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

	var header := RichTextLabel.new()
	header.bbcode_enabled = true
	header.fit_content = true
	var rarity_color: Color = RARITY_COLOR.get(def.get("rarity"), Color(1, 1, 1))
	header.text = "[font_size=16][color=#%s]%s[/color][/font_size]" % [rarity_color.to_html(false), def["name"]]
	card_container.add_child(header)

	for slot in FarroadCore.EQUIPMENT_SLOTS:
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)

		var slot_lbl := Label.new()
		slot_lbl.text = "%s %s" % [EQUIP_SLOT_ICON.get(slot, ""), EQUIP_SLOT_LABEL.get(slot, slot)]
		row.add_child(slot_lbl)

		var option_row := HBoxContainer.new()
		var slot_opt := _build_slot_option(uid, slot)
		slot_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		option_row.add_child(slot_opt)
		# Post-Milestone-3 APK feedback (round 3): "add the informational
		# popups for actions wherever they can be selected... change
		# enemies and equipment to have similar popups" -- an info icon
		# next to the slot's own OptionButton, reading whatever's CURRENTLY
		# equipped there at press-time (not bound at build-time), matching
		# GambitsPanel's own action-info-icon pattern exactly.
		var cur_id_now = g.get("equipped", {}).get(uid, {}).get(slot)
		if cur_id_now != null:
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_on_equip_info_pressed.bind(slot))
			option_row.add_child(info_btn)
		row.add_child(option_row)

		var cur_id = g.get("equipped", {}).get(uid, {}).get(slot)
		if cur_id != null:
			var desc_lbl := Label.new()
			desc_lbl.text = _describe_equipment(cur_id, uid)
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
		var label: String = "%s (owned %d, %d available)" % [
			item["name"], FarroadProgression.equip_owned_count(g, item_id), available]
		opt.add_icon_item(_rarity_icon(item.get("rarity", "common")), label, idx)
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

## Post-Milestone-3 APK feedback (round 3) -- reads the slot's CURRENT
## occupant fresh at press-time.
func _on_equip_info_pressed(slot: String) -> void:
	var item_id = g.get("equipped", {}).get(selected_uid, {}).get(slot)
	if item_id == null:
		return
	if _parent and _parent.has_method("_show_equipment_detail_popup"):
		_parent.call("_show_equipment_detail_popup", item_id, selected_uid)

func _on_slot_selected(uid: String, slot: String, item_id: String) -> void:
	if item_id == "":
		FarroadProgression.unequip_item(g, uid, slot)
	else:
		FarroadProgression.equip_item(g, uid, slot, item_id)
	FarroadProgression.refresh_live_stats(g)
	_refresh_card()

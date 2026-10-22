class_name EquipmentPanel
extends Node
## The Gear card of the Units menu: per-unit gear management. It is a per-unit
## editor and gets the live game-state Dictionary `g` once, at setup().
##
## Equipping is free once owned; the only limit is the number of copies
## (FarroadProgression.equip_available_count). An equip or unequip reaches a
## unit already mid-fight immediately through
## FarroadProgression.refresh_live_stats(g), which calls apply_equipment_stats.
##
## This panel owns no popup of its own. UnitsPanel is the only popup owner (a
## second popup opened from inside it closed everything), and this panel
## builds its card into the container UnitsPanel hands it (build_into).

var g: Dictionary
var _vp: Vector2
var _parent: GameController
var selected_uid: String = ""

var card_container: Container

## Duplicated per file, like the sibling panels (no shared base class).
## OptionButton items can't render BBCode or per-item text color in Godot, but
## they can carry a per-item icon (add_icon_item). So rarity is shown as a
## small solid-color swatch icon instead of a bracketed text tag.
## _rarity_icon() below generates and caches these.
const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
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
## Icon and label for each equipment slot.
const EQUIP_SLOT_ICON := {"head": "🪖", "body": "🛡️", "legs": "🥾", "hand1": "🖐️", "hand2": "🖐️"}
const EQUIP_SLOT_LABEL := {"head": "Head", "body": "Body", "legs": "Legs", "hand1": "Hand (left)", "hand2": "Hand (right)"}

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
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

## The description line for an item: "<Slot> - <stat bits> - <affinity bits>".
## `uid` is needed to show the item's affinity contribution as a real % instead
## of a raw point value. affinity_mul is nonlinear in the TOTAL raw affinity,
## not additive per source, so an item's own raw value can't just be run
## through it in isolation. The number shown is the marginal %: what this
## item's contribution adds on top of the unit's baseline plus purchased
## affinity, ignoring whatever else is equipped so items stay comparable
## whatever the loadout: affinity_mul(base + purchased + item) minus
## affinity_mul(base + purchased), as a percentage-point delta.
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

	# fits the unit with the best free gear: rarity first, then its natural affinities
	var auto_btn := Button.new()
	auto_btn.text = "Auto-set gear"
	auto_btn.tooltip_text = "Picks the best owned gear by rarity and the unit's natural affinities"
	auto_btn.pressed.connect(func():
		FarroadProgression.auto_assign_gear(g, uid)
		FarroadProgression.refresh_live_stats(g)
		_refresh_card())
	card_container.add_child(auto_btn)

	# gear filtering and sorting by stat (applies to every slot's list)
	card_container.add_child(ActionFilter.gear_controls(_refresh_card))
	card_container.add_child(UnitSets.build(g, uid, "gear", func():
		FarroadProgression.refresh_live_stats(g)
		_refresh_card()))

	# wide windows: the five slots in two columns, so nothing scrolls
	var slot_host: Container = card_container
	if _parent != null and _parent.wide:
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 10)
		card_container.add_child(grid)
		slot_host = grid
	for slot in FarroadCore.EQUIPMENT_SLOTS:
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var slot_lbl := Label.new()
		slot_lbl.text = "%s %s" % [EQUIP_SLOT_ICON.get(slot, ""), EQUIP_SLOT_LABEL.get(slot, slot)]
		row.add_child(slot_lbl)

		var option_row := HBoxContainer.new()
		var slot_opt := _build_slot_option(uid, slot)
		slot_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		option_row.add_child(slot_opt)
		# an info icon next to the slot's OptionButton. It reads whatever is
		# equipped there at press time (not bound at build time), like
		# GambitsPanel's action info icon.
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
			desc_lbl.modulate = Palette.TEXT_DIM
			desc_lbl.add_theme_font_size_override("font_size", 12)
			# A stacked stat + affinity description (e.g. "Body -- ATK +5 --
			# DEF +3 -- Fire affinity +12% -- Water affinity -8%") can run
			# long, so it autowraps instead of overflowing the popup.
			desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
			desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(desc_lbl)

		slot_host.add_child(row)

## One slot's dropdown: "- empty -" first, then every OWNED item matching the
## slot's kind (equip_owned_count > 0), each reading "<name> (M/N)", available
## over owned. An option with equip_available_count <= 0 is disabled, not
## omitted (the label already explains why), unless it is this slot's own
## current occupant. It is the same "disable, don't hide" rule the Gambits
## action dropdown uses for an action held elsewhere.
func _build_slot_option(uid: String, slot: String) -> OptionButton:
	var opt := OptionButton.new()
	opt.set_meta("gear_slot", slot)   # the Gear tutorial points at these, not at the rarity/sort filters above them
	var kind := FarroadProgression.equip_kind_for_slot(slot)
	var cur_id = g.get("equipped", {}).get(uid, {}).get(slot)
	opt.add_item("— empty —", 0)
	var item_ids: Array = ["" as String]
	var idx := 1
	for item_id in ActionFilter.gear_ids(FarroadCore.EQUIPMENT.keys(), cur_id):
		var item: Dictionary = FarroadCore.EQUIPMENT[item_id]
		if item["slot"] != kind:
			continue
		if FarroadProgression.equip_owned_count(g, item_id) <= 0:
			continue
		var is_cur: bool = item_id == cur_id
		var available := FarroadProgression.equip_available_count(g, item_id)
		# a compact "(M/N)" (available/owned, e.g. "(0/3)") keeps each option
		# row short
		var label: String = "%s (%d/%d)" % [
			item["name"], available, FarroadProgression.equip_owned_count(g, item_id)]
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

## Reads the slot's current occupant at press time.
func _on_equip_info_pressed(slot: String) -> void:
	var item_id = g.get("equipped", {}).get(selected_uid, {}).get(slot)
	if item_id == null:
		return
	_parent.show_equipment_detail_popup(item_id, selected_uid)

func _on_slot_selected(uid: String, slot: String, item_id: String) -> void:
	if item_id == "":
		FarroadProgression.unequip_item(g, uid, slot)
	else:
		FarroadProgression.equip_item(g, uid, slot, item_id)
	FarroadProgression.refresh_live_stats(g)
	_refresh_card()

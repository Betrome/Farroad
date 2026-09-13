extends Node
## Milestone 3, Step 3d: the AETHER tab -- leveling (feed Aether), Recovery,
## Evade/ATK-Crit/MAG-Crit investment, and the 8-axis Affinity investment.
## Unlike GAMBITS/LORE's separate concerns, the real renderAether()
## (farroad-ui.js:1816-1938) is ONE function covering all four -- so this is
## one panel, structurally a sibling of GambitsPanel.gd (same "owns its own
## tab-row button + popup" shape, same unit-picker-including-benched
## pattern), not four separate ones.
##
## Deliberately NOT ported: refreshLiveStats()'s push of a fresh purchase
## onto a unit's LIVE mid-fight stats. A purchase still fully applies --
## just starting next wave's build_party() (which already recomputes every
## one of these fresh from g["lvl"]/g["statInvest"]/g["affinities"] every
## time) rather than instantly mid-fight. Flagged, not silently skipped --
## same class of deliberate trim as GAMBITS' deferred conflict modal.

var g: Dictionary
var _vp: Vector2
var _parent: Node
var selected_uid: String = ""

var toggle_button: Button
var popup: PopupPanel
var unit_tabs_container: HBoxContainer
var card_container: VBoxContainer

const AFFINITY_AXIS_LABELS := {"fire": "Fire", "water": "Water", "earth": "Earth", "air": "Air",
	"light": "Light", "dark": "Dark", "body": "Body", "spirit": "Spirit"}
const PCT_STAT_LABELS := {"evade": "Evade", "atkCrit": "ATK Crit", "magCrit": "MAG Crit"}

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Same reasoning/limitation as GambitsPanel.reflow() -- see its comment.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.62, _vp.y * 0.905), icon_size, "Aether", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# A blank square placeholder (real art comes later) with a caption below
	# it, right slot of the bottom icon row next to GambitsPanel's own icon
	# at the same fractions (duplicated there too -- different script, no
	# shared base). Sits BELOW the turn-order strip (cards now end at 0.90)
	# with real clearance, not overlapping it.
	var icon_size: float = _vp.x * 0.12
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.62, _vp.y * 0.905), icon_size, "Aether", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "AETHER"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	var tabs_label := Label.new()
	tabs_label.text = "Invest in:"
	root_vbox.add_child(tabs_label)

	unit_tabs_container = HBoxContainer.new()
	unit_tabs_container.add_theme_constant_override("separation", 6)
	root_vbox.add_child(unit_tabs_container)

	card_container = VBoxContainer.new()
	card_container.add_theme_constant_override("separation", 12)
	root_vbox.add_child(card_container)

func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style BattlePresenter's own _build_icon_tab uses --
## duplicated here (different script, no shared base). Label lives ON the
## button (`btn.text`) rather than a caption below it, for now -- a caption
## below a corner-anchored square can land outside the visible window on a
## resize (confirmed live); text inside the button's own bounded rect
## can't drift off independently. See BattlePresenter's own copy for the
## fuller comment.
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

## Same renderUnitTabs(..., true) pattern GAMBITS already established --
## every owned unit, fielded or benched.
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

func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Color(0.6, 0.75, 1.0)
	return lbl

## One purchase row: a description label immediately followed by its buy
## Button (NOT pushed to the far edge -- sits right next to the stat it
## affects), colored to read as available/unavailable at a glance rather
## than relying on the default theme's flat grey for both states.
func _purchase_row(desc: String, buy_text: String, cost: int, maxed: bool, callback: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var desc_lbl := Label.new()
	desc_lbl.text = desc
	row.add_child(desc_lbl)
	var btn := Button.new()
	btn.text = "MAXED" if maxed else "%s (%d)" % [buy_text, cost]
	var available: bool = not maxed and g.get("aether", 0) >= cost
	btn.disabled = not available
	btn.pressed.connect(callback)
	_style_purchase_button(btn, available)
	row.add_child(btn)
	return row

## Available: warm gold (matches the real UI's own --aether color theme),
## clearly readable as "you can afford this". Unavailable (unaffordable OR
## maxed): a dim, desaturated red-grey -- visibly different from both the
## available state AND the rest of the panel's default grey buttons, not
## just a slightly darker grey the eye glosses over.
func _style_purchase_button(btn: Button, available: bool) -> void:
	var bg := Color(0.55, 0.42, 0.08) if available else Color(0.22, 0.13, 0.13)
	var bg_hover := Color(0.7, 0.55, 0.12) if available else Color(0.26, 0.15, 0.15)
	var font := Color(1.0, 0.93, 0.72) if available else Color(0.6, 0.45, 0.45)
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = bg
	normal_style.set_corner_radius_all(4)
	normal_style.set_content_margin_all(6)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = bg_hover
	hover_style.set_corner_radius_all(4)
	hover_style.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.add_theme_stylebox_override("disabled", normal_style)
	btn.add_theme_color_override("font_color", font)
	btn.add_theme_color_override("font_disabled_color", font)
	btn.add_theme_color_override("font_hover_color", font)

func _refresh_card() -> void:
	for c in card_container.get_children():
		c.queue_free()
	if selected_uid == "":
		return
	var uid := selected_uid
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return
	var level := FarroadProgression.level_of(g, uid)

	# Header + XP.
	var header := Label.new()
	var row_tag: String = "" if g["party"].has(uid) else " • benched"
	header.text = "%s — %s — LV %d%s" % [def["name"], def.get("role", ""), level, row_tag]
	header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(header)

	var xp_lbl := Label.new()
	var need := FarroadProgression.cost_next(g, uid)
	var have := FarroadProgression.exp_of(g, uid)
	xp_lbl.text = "%d / %d Aether to LV %d" % [int(have), need, level + 1]
	xp_lbl.modulate = Color(0.7, 0.7, 0.7)
	card_container.add_child(xp_lbl)

	# Stats + per-level growth.
	var st: Dictionary = FarroadProgression.stats_at(uid, def["stats"], def["hp"], level)
	var growth: Dictionary = FarroadProgression.GROWTH.get(uid, FarroadProgression.GROWTH["kesh"])
	var stat_lbl := Label.new()
	stat_lbl.text = "HP %d (+%s/lvl)  ATK %d (+%s/lvl)  MAG %d (+%s/lvl)\nDEF %d (+%s/lvl)  RES %d (+%s/lvl)  SPD %d (+%s/lvl)" % [
		st["hp"], growth["hp"], st["atk"], growth["atk"], st["mag"], growth["mag"],
		st["def"], growth["def"], st["res"], growth["res"], st["spd"], growth["spd"]]
	card_container.add_child(stat_lbl)

	var slots_lbl := Label.new()
	var next_slot = FarroadProgression.next_slot_at(level)
	slots_lbl.text = "%d gambit slots%s" % [FarroadProgression.slots_at(level),
		(" (next at LV %d)" % next_slot) if next_slot != null else " (max)"]
	slots_lbl.modulate = Color(0.65, 0.7, 0.65)
	card_container.add_child(slots_lbl)

	# Recovery.
	card_container.add_child(_section_label("RECOVERY — %d%% (cap %d%%)" % [
		roundi(FarroadProgression.recovery_of(g, uid) * 100), roundi(FarroadProgression.REST_CAP * 100)]))
	card_container.add_child(_purchase_row(
		"Between-wave HP carried over", "+%d%%" % roundi(FarroadProgression.REST_STEP * 100),
		FarroadProgression.recovery_cost(g, uid), FarroadProgression.recovery_maxed(g, uid),
		_on_recovery_pressed.bind(uid)))

	# Feed / leveling.
	card_container.add_child(_section_label("LEVEL"))
	var level_desc := Label.new()
	level_desc.text = "Level up"
	card_container.add_child(level_desc)
	var feed_row := HBoxContainer.new()
	feed_row.add_theme_constant_override("separation", 10)
	for amt in [50, 250]:
		var btn := Button.new()
		btn.text = "+%d" % amt
		var available: bool = g.get("aether", 0) >= amt
		btn.disabled = not available
		btn.pressed.connect(_on_feed_pressed.bind(uid, amt))
		_style_purchase_button(btn, available)
		feed_row.add_child(btn)
	var exact := maxi(0, int(ceil(need - have)))
	var next_btn := Button.new()
	next_btn.text = "→ LV %d (%d)" % [level + 1, exact]
	var next_available: bool = g.get("aether", 0) >= exact
	next_btn.disabled = not next_available
	next_btn.pressed.connect(_on_feed_pressed.bind(uid, exact))
	_style_purchase_button(next_btn, next_available)
	feed_row.add_child(next_btn)
	card_container.add_child(feed_row)

	# Evade / ATK-Crit / MAG-Crit.
	card_container.add_child(_section_label("EVADE / CRIT"))
	for stat in FarroadProgression.PCT_STAT_KEYS:
		var steps: int = FarroadProgression.pct_stat_purchased(g, uid, stat)
		var cur := FarroadProgression.pct_stat_value(g, uid, stat)
		var cost := FarroadProgression.pct_stat_cost(stat, steps)
		var maxed := FarroadProgression.pct_stat_maxed(g, uid, stat)
		card_container.add_child(_purchase_row(
			"%s — %s%%" % [PCT_STAT_LABELS[stat], snapped(cur * 100.0, 0.1)],
			"+%s%%" % snapped(FarroadProgression.PCT_STAT[stat]["step"] * 100.0, 0.1),
			cost, maxed, _on_pct_stat_pressed.bind(uid, stat)))

	# Affinities.
	card_container.add_child(_section_label("AFFINITIES"))
	for axis in FarroadProgression.AFFINITY_AXES:
		var raw := FarroadProgression.affinity_raw(g, uid, axis)
		var mul := FarroadCore.affinity_mul(raw)
		var cost := FarroadProgression.affinity_cost_to_next(FarroadProgression.affinity_purchased(g, uid).get(axis, 0))
		var maxed := FarroadProgression.affinity_maxed(g, uid, axis)
		card_container.add_child(_purchase_row(
			"%s — %s (×%s)" % [AFFINITY_AXIS_LABELS[axis], snapped(raw, 0.1), snapped(mul, 0.01)],
			"+1", cost, maxed, _on_affinity_pressed.bind(uid, axis)))

func _on_recovery_pressed(uid: String) -> void:
	FarroadProgression.spend_recovery(g, uid)
	_refresh_card()

func _on_feed_pressed(uid: String, amount: int) -> void:
	if amount <= 0:
		return
	FarroadProgression.spend_feed(g, uid, amount)
	_refresh_card()

func _on_pct_stat_pressed(uid: String, stat: String) -> void:
	FarroadProgression.spend_pct_stat(g, uid, stat)
	_refresh_card()

func _on_affinity_pressed(uid: String, axis: String) -> void:
	FarroadProgression.spend_affinity(g, uid, axis)
	_refresh_card()

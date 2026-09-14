extends Node
## Milestone 3, Step 3d: the AETHER tab -- leveling (feed Aether), Recovery,
## Evade/ATK-Crit/MAG-Crit investment, and the 8-axis Affinity investment.
## Unlike GAMBITS/LORE's separate concerns, the real renderAether()
## (farroad-ui.js:1816-1938) is ONE function covering all four -- so this is
## one panel, structurally a sibling of GambitsPanel.gd (same "owns its own
## tab-row button + popup" shape, same unit-picker-including-benched
## pattern), not four separate ones.
##
## Every purchase handler calls FarroadProgression.refresh_live_stats(g)
## (mirrors refreshLiveStats(), farroad-ui.js:1991-2003) so a purchase
## reaches a unit already mid-fight immediately, the same way GAMBITS'
## sync_loadout does for a slot edit -- not just starting next wave.

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
# Every purchase button (Recovery/Level/Evade-Crit/Affinity) shares this
# width so they all visually line up regardless of section -- see
# _style_purchase_button.
const PURCHASE_BTN_WIDTH_FRAC := 0.24   # of viewport width

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
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.2600, _vp.y * 0.93), icon_size, "Aether", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# A blank square placeholder (real art comes later) with its label on the
	# button itself, third of 8 evenly-spaced icons across the bottom row:
	# GambitsPanel 0.0133, PartyPanel 0.1367, this one 0.2600, LorePanel
	# 0.3833, EquipmentPanel 0.5067, MarksPanel 0.6300, ExpeditionPanel
	# 0.7533, QuestsPanel 0.8767, duplicated there too (different scripts,
	# no shared base). Sits BELOW the turn-order strip's frame (frame
	# bottom ~0.91) with real clearance, not overlapping it.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.2600, _vp.y * 0.93), icon_size, "Aether", _on_toggle_pressed)

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
	_notify_battle_paused(true)

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as GambitsPanel/LorePanel's own copy (see
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

## Same small BBCode-label helper BattlePresenter._rich_line already
## established -- duplicated here (different script, no shared base) for the
## bold current-stat value below.
func _rich_line(bbcode: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.text = bbcode
	return r

## One cell of the stats grid: the stat's bold current value with its
## per-level growth stacked directly below it (smaller, dimmed), wrapped in
## its own VBoxContainer so the pair adds as ONE child of the GridContainer
## -- two direct children (as _add_purchase_cells uses) would instead put
## the growth text in the NEXT column, beside the stat rather than under it.
## cell_width, when >0, gives the cell a width floor -- a GridContainer sizes
## each column to its widest cell's own NATURAL (unconstrained) width and
## nothing more, so without this the whole grid only ever claims as much
## width as its content strictly needs and left-aligns, leaving the rest of
## the popup's width empty rather than actually spanning it.
func _add_stat_cell(grid: GridContainer, label: String, value, growth, cell_width: float = 0.0) -> void:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	if cell_width > 0.0:
		cell.custom_minimum_size.x = cell_width
	var val_lbl := _rich_line("[b]%s %s[/b]" % [label, value])
	cell.add_child(val_lbl)
	var growth_lbl := Label.new()
	growth_lbl.text = "+%s/lvl" % growth
	growth_lbl.add_theme_font_size_override("font_size", 10)
	growth_lbl.modulate = Color(0.6, 0.6, 0.6)
	cell.add_child(growth_lbl)
	grid.add_child(cell)

## Adds one description Label + buy Button pair as two direct children of a
## GridContainer -- a GridContainer sizes each COLUMN to its widest cell,
## which is what actually lines several rows' buttons up at the same x
## regardless of how long any one row's own label text happens to be (a
## fixed button width alone doesn't accomplish that when labels vary in
## length). Every purchase button shares btn_width_frac (so they read as the
## same size at a glance) EXCEPT the two-column Affinities grid, which passes
## a smaller one -- there isn't room on a real phone-width screen for two
## side-by-side columns of the same wide buttons Level/Recovery/Evade-Crit
## use; flagging this one deliberate exception rather than silently
## special-casing it. desc_lbl gets a matching width floor (autowrap
## catching anything longer, so a long description wraps to a 2nd line
## instead of pushing the row wider than the popup). font_size, when >0,
## overrides both cells' font size -- used by the Affinities grid to stay
## compact enough for two columns; every other section leaves it default.
func _add_purchase_cells(grid: GridContainer, desc: String, buy_text: String, cost: int, maxed: bool, callback: Callable,
		font_size: int = 0, btn_width_frac: float = PURCHASE_BTN_WIDTH_FRAC, desc_width_frac: float = 0.42) -> void:
	var desc_lbl := Label.new()
	desc_lbl.text = desc
	desc_lbl.custom_minimum_size.x = _vp.x * desc_width_frac
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if font_size > 0:
		desc_lbl.add_theme_font_size_override("font_size", font_size)
	grid.add_child(desc_lbl)
	grid.add_child(_build_purchase_button(buy_text, cost, maxed, callback, font_size, btn_width_frac))

## Same idea as _add_purchase_cells, but splits the description into a
## separate LABEL cell and VALUE cell (three direct children total: label,
## value, button) instead of one combined string -- a GridContainer sizes
## each column to its widest cell, so the current value itself lines up in
## its own column across rows, not just wherever it happens to land after a
## label of varying length (e.g. "Evade" vs "ATK Crit"). label_width_frac/
## value_width_frac, when >0, give those cells a width floor the same way
## _add_purchase_cells' desc_width_frac does -- only the compact two-column
## Affinities grid needs this; Evade/Crit's own natural auto-sizing already
## fits comfortably.
func _add_labeled_purchase_cells(grid: GridContainer, label: String, value: String, buy_text: String, cost: int, maxed: bool, callback: Callable,
		font_size: int = 0, btn_width_frac: float = PURCHASE_BTN_WIDTH_FRAC, label_width_frac: float = 0.0, value_width_frac: float = 0.0) -> void:
	var label_lbl := Label.new()
	label_lbl.text = label
	if label_width_frac > 0.0:
		label_lbl.custom_minimum_size.x = _vp.x * label_width_frac
		label_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if font_size > 0:
		label_lbl.add_theme_font_size_override("font_size", font_size)
	grid.add_child(label_lbl)
	var value_lbl := Label.new()
	value_lbl.text = value
	if value_width_frac > 0.0:
		value_lbl.custom_minimum_size.x = _vp.x * value_width_frac
	if font_size > 0:
		value_lbl.add_theme_font_size_override("font_size", font_size)
	grid.add_child(value_lbl)
	grid.add_child(_build_purchase_button(buy_text, cost, maxed, callback, font_size, btn_width_frac))

func _build_purchase_button(buy_text: String, cost: int, maxed: bool, callback: Callable, font_size: int, btn_width_frac: float) -> Button:
	var btn := Button.new()
	btn.text = "MAXED" if maxed else "%s (%d)" % [buy_text, cost]
	var available: bool = not maxed and g.get("aether", 0) >= cost
	btn.disabled = not available
	btn.pressed.connect(callback)
	_style_purchase_button(btn, available)
	btn.custom_minimum_size.x = _vp.x * btn_width_frac
	btn.clip_text = true
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	if font_size > 0:
		btn.add_theme_font_size_override("font_size", font_size)
	return btn

## A single desc+button pair, standalone rather than part of a larger grid --
## built as its own one-row, 2-column GridContainer so it shares the exact
## same cell-building logic (and therefore styling/width) as the grid-based
## sections below, colored to read as available/unavailable at a glance
## rather than relying on the default theme's flat grey for both states.
func _purchase_row(desc: String, buy_text: String, cost: int, maxed: bool, callback: Callable) -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	_add_purchase_cells(grid, desc, buy_text, cost, maxed, callback)
	return grid

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

	var need := FarroadProgression.cost_next(g, uid)
	var have := FarroadProgression.exp_of(g, uid)

	# Stats + per-level growth -- a real 3-column, 2-row grid (not a single
	# long line of text left to wrap on its own) so it can't bleed a stat's
	# value onto the next line or off the popup's edge the way free-flowing
	# text did; each cell stacks its growth directly below its own stat,
	# bold value on top, growth noticeably smaller and dimmed underneath.
	var st: Dictionary = FarroadProgression.stats_at(uid, def["stats"], def["hp"], level)
	var growth: Dictionary = FarroadProgression.GROWTH.get(uid, FarroadProgression.GROWTH["kesh"])
	var stat_grid := GridContainer.new()
	stat_grid.columns = 3
	var stat_h_sep: float = 16.0
	stat_grid.add_theme_constant_override("h_separation", int(stat_h_sep))
	stat_grid.add_theme_constant_override("v_separation", 4)
	# Divide the popup's own real inner width evenly across the 3 columns --
	# a GridContainer only ever claims as much width as its widest cells
	# actually need and left-aligns, so without an explicit width floor per
	# cell the grid would sit bunched on the left with empty space to its
	# right instead of actually spanning the popup.
	var popup_inner_w: float = _vp.x * 0.85 - 40.0
	var stat_cell_w: float = (popup_inner_w - stat_h_sep * 2.0) / 3.0
	_add_stat_cell(stat_grid, "HP", st["hp"], growth["hp"], stat_cell_w)
	_add_stat_cell(stat_grid, "ATK", st["atk"], growth["atk"], stat_cell_w)
	_add_stat_cell(stat_grid, "MAG", st["mag"], growth["mag"], stat_cell_w)
	_add_stat_cell(stat_grid, "DEF", st["def"], growth["def"], stat_cell_w)
	_add_stat_cell(stat_grid, "RES", st["res"], growth["res"], stat_cell_w)
	_add_stat_cell(stat_grid, "SPD", st["spd"], growth["spd"], stat_cell_w)
	card_container.add_child(stat_grid)

	var slots_lbl := Label.new()
	var next_slot = FarroadProgression.next_slot_at(level)
	slots_lbl.text = "%d gambit slots%s" % [FarroadProgression.slots_at(level),
		(" (next at LV %d)" % next_slot) if next_slot != null else " (max)"]
	slots_lbl.modulate = Color(0.65, 0.7, 0.65)
	card_container.add_child(slots_lbl)

	# Feed / leveling -- moved above Recovery per direct request. Only the
	# exact-cost-to-next-level button remains; the flat +50/+250 feed
	# buttons were dropped, also per direct request.
	var exact := maxi(0, int(ceil(need - have)))
	card_container.add_child(_purchase_row(
		"Level up", "→ LV %d" % (level + 1), exact, false, _on_feed_pressed.bind(uid, exact)))

	# Recovery/Evade/Crit share the SAME label/value/button column widths
	# (explicit floors, not auto-sized) even though Recovery has its own
	# GridContainer separate from Evade/Crit's -- that's what actually puts
	# all 4 buttons at the identical x position down the page, not just
	# giving them the same WIDTH (which alone doesn't align them if the
	# columns before the button differ between the two grids). Narrower than
	# every other section's own defaults specifically so label+value+button+
	# separations comfortably fit within the popup's real width with no
	# horizontal scroll -- a real overflow this popup previously had once
	# the value column was added, caught from a real screenshot, not
	# something the earlier per-cell-only width check had actually verified
	# against the TOTAL row width.
	var label_col_frac: float = 0.28
	var value_col_frac: float = 0.11
	var btn_col_frac: float = 0.20

	# Recovery -- now second, after Level.
	var recovery_grid := GridContainer.new()
	recovery_grid.columns = 3
	recovery_grid.add_theme_constant_override("h_separation", 10)
	_add_labeled_purchase_cells(recovery_grid, "Post-combat Recovery",
		"%d%%" % roundi(FarroadProgression.recovery_of(g, uid) * 100),
		"+%d%%" % roundi(FarroadProgression.REST_STEP * 100),
		FarroadProgression.recovery_cost(g, uid), FarroadProgression.recovery_maxed(g, uid),
		_on_recovery_pressed.bind(uid), 0, btn_col_frac, label_col_frac, value_col_frac)
	card_container.add_child(recovery_grid)

	# Evade / ATK-Crit / MAG-Crit -- one GridContainer, not 3 separate rows,
	# so every button lines up at the same x regardless of how long its own
	# row's label happens to be. Label and current value are separate cells
	# (not one combined string) so the values themselves line up in their
	# own column too, not wherever they land after a label of varying length.
	var pct_grid := GridContainer.new()
	pct_grid.columns = 3
	pct_grid.add_theme_constant_override("h_separation", 10)
	pct_grid.add_theme_constant_override("v_separation", 6)
	for stat in FarroadProgression.PCT_STAT_KEYS:
		var steps: int = FarroadProgression.pct_stat_purchased(g, uid, stat)
		var cur := FarroadProgression.pct_stat_value(g, uid, stat)
		var cost := FarroadProgression.pct_stat_cost(stat, steps)
		var maxed := FarroadProgression.pct_stat_maxed(g, uid, stat)
		_add_labeled_purchase_cells(pct_grid, PCT_STAT_LABELS[stat], "%s%%" % snapped(cur * 100.0, 0.1),
			"+%s%%" % snapped(FarroadProgression.PCT_STAT[stat]["step"] * 100.0, 0.1),
			cost, maxed, _on_pct_stat_pressed.bind(uid, stat), 0, btn_col_frac,
			label_col_frac, value_col_frac)
	card_container.add_child(pct_grid)

	# Affinities -- two columns (left: fire/water/earth/air, right:
	# light/dark/body/spirit), same GridContainer column-alignment trick as
	# above but with 6 columns (label,value,btn,label,value,btn) so both
	# button AND value columns line up independently on each side. Shows the
	# actual total combat effect (the affinity_mul-derived %, rounded to a
	# whole percent) instead of the old raw point value + a confusingly-named
	# "×" figure that was actually a bonus FRACTION, not a real multiplier --
	# whole-percent both because that's plenty of precision for this display
	# and because it keeps these two-column rows narrow enough to fit side by
	# side; a smaller font here for the same reason (every other section
	# keeps the default size).
	card_container.add_child(_section_label("AFFINITIES"))
	var aff_grid := GridContainer.new()
	aff_grid.columns = 6
	aff_grid.add_theme_constant_override("h_separation", 4)
	aff_grid.add_theme_constant_override("v_separation", 6)
	for i in range(4):
		for col in range(2):
			var axis: String = FarroadProgression.AFFINITY_AXES[i + col * 4]
			var raw := FarroadProgression.affinity_raw(g, uid, axis)
			var pct: float = FarroadCore.affinity_mul(raw) * 100.0
			var cost := FarroadProgression.affinity_cost_to_next(FarroadProgression.affinity_purchased(g, uid).get(axis, 0))
			var maxed := FarroadProgression.affinity_maxed(g, uid, axis)
			_add_labeled_purchase_cells(aff_grid, AFFINITY_AXIS_LABELS[axis], "%+.0f%%" % pct,
				"+1", cost, maxed, _on_affinity_pressed.bind(uid, axis), 12, 0.13, 0.09, 0.08)
	card_container.add_child(aff_grid)

## GameController's own top-strip currency line (Aether/Lore/Marks) only
## refreshed on a wave transition -- fine for Marks (nothing spends it yet),
## wrong for Aether, which every purchase below actually changes right now,
## not next wave. _parent IS the GameController (setup()'s own `parent` arg
## -- see GameController._ready()), but typed as plain Node here (this panel
## has no compile-time dependency on it), so a dynamic has_method()+call()
## is used rather than a direct method call, which static analysis would
## reject against Node's own declared interface.
func _notify_currency_changed() -> void:
	if _parent and _parent.has_method("_refresh_hud"):
		_parent.call("_refresh_hud")

func _on_recovery_pressed(uid: String) -> void:
	if FarroadProgression.spend_recovery(g, uid):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
	_refresh_card()

func _on_feed_pressed(uid: String, amount: int) -> void:
	if amount <= 0:
		return
	if FarroadProgression.spend_feed(g, uid, amount):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
	_refresh_card()

func _on_pct_stat_pressed(uid: String, stat: String) -> void:
	if FarroadProgression.spend_pct_stat(g, uid, stat):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
	_refresh_card()

func _on_affinity_pressed(uid: String, axis: String) -> void:
	if FarroadProgression.spend_affinity(g, uid, axis):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
	_refresh_card()

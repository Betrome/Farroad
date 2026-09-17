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

const AFFINITY_AXIS_LABELS := {"fire": "Fire", "water": "Water", "earth": "Earth", "air": "Air",
	"light": "Light", "dark": "Dark", "body": "Body", "spirit": "Spirit"}
const PCT_STAT_LABELS := {"evade": "Evade", "atkCrit": "ATK Crit", "magCrit": "MAG Crit"}

## Ian: "add a small icon like with actions next to each of the stats and
## affinities to pop-up a smaller window that states what the stat does."
const LEVEL_INFO := "Feeds Aether to raise this unit's level -- increases every base stat and its own per-level growth, and unlocks more gambit slots at certain levels."
const RECOVERY_INFO := "Raises the % of missing HP this unit carries over and heals between waves, up to a cap."
const PCT_STAT_INFO := {
	"evade": "Raises this unit's chance to dodge an incoming hit entirely.",
	"atkCrit": "Raises this unit's chance to land a critical hit with physical (ATK-scaling) actions.",
	"magCrit": "Raises this unit's chance to land a critical hit with magic (MAG-scaling) actions.",
}
# Every purchase button (Recovery/Level/Evade-Crit/Affinity) shares this
# width so they all visually line up regardless of section -- see
# _style_purchase_button.
const PURCHASE_BTN_WIDTH_FRAC := 0.24   # of viewport width

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent

func reflow(new_vp: Vector2) -> void:
	_vp = new_vp

## Called by UnitsPanel every time the AETHER sub-tab is shown. `host_popup`
## unused here (no transient dialog of its own) -- kept for a consistent
## signature across all 4 folded panels.
func build_into(container: Container, uid: String, _host_popup: Window) -> void:
	selected_uid = uid
	card_container = container
	_refresh_card()

func _affinity_info(axis: String) -> String:
	var label: String = AFFINITY_AXIS_LABELS[axis]
	return "%s affinity boosts the power of this unit's own %s-aligned actions, and reduces incoming %s-aligned damage/effects from enemies." % [
		label, label, label]

## A small, lightweight popup anchored right next to the icon that opened
## it -- deliberately NOT the shared full-screen detail overlay
## (GameController._build_detail_overlay), which is centered/larger by
## design; this reads as a small tooltip beside the exact stat inspected,
## per Ian's own "keep it small" ask. Added as a child of the icon's own
## Window (whatever popup this card currently lives inside -- UnitsPanel's,
## via get_window()) so it layers correctly without needing to route
## through GameController's own overlay-nesting machinery.
func _show_stat_info_popup(anchor: Control, text: String) -> void:
	var host: Window = anchor.get_window()
	if host == null:
		return
	var p := PopupPanel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT_DEEP
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", style)
	host.add_child(p)
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	lbl.custom_minimum_size = Vector2(minf(_vp.x * 0.5, 220.0), 0)
	p.add_child(lbl)
	p.popup_hide.connect(p.queue_free)
	await get_tree().process_frame   # let the panel size itself to lbl's real content before positioning
	var pos := Vector2i(anchor.global_position) + Vector2i(int(anchor.size.x) + 6, -4)
	pos.x = mini(pos.x, int(host.size.x - p.size.x - 4))
	pos.y = clampi(pos.y, 4, int(host.size.y - p.size.y - 4))
	p.popup(Rect2i(pos, p.size))

## Small "ⓘ" button, same shape as every other info-icon in this project,
## but with the project theme's own Button style (an 8px content margin
## on ALL sides -- fine for a real button, way too much for a single
## glyph shoehorned into an already-budgeted row) overridden down to a
## minimal margin -- direct measurement at the real 412px width showed
## even a custom_minimum_size-28 button was really costing ~44px once the
## theme's own padding was counted, overflowing every row it touched.
## compact=true shrinks it further still, for the 2-column Affinities
## grid specifically, where the per-row budget is tightest of all.
func _info_icon(info_text: String, compact: bool = false) -> Button:
	var btn := Button.new()
	btn.text = "ⓘ"
	btn.custom_minimum_size = Vector2(14 if compact else 20, 0)
	btn.add_theme_font_size_override("font_size", 9 if compact else 12)
	for state in ["normal", "hover", "pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Palette.BTN_NORMAL if state != "hover" else Palette.BTN_HOVER
		style.set_content_margin_all(1 if compact else 2)
		btn.add_theme_stylebox_override(state, style)
	btn.pressed.connect(func(): _show_stat_info_popup(btn, info_text))
	return btn

func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Palette.PARTY_BLUE
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
	growth_lbl.modulate = Palette.TEXT_DIM
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
		font_size: int = 0, btn_width_frac: float = PURCHASE_BTN_WIDTH_FRAC, desc_width_frac: float = 0.42,
		show_cost_in_button: bool = true, info_text: String = "") -> void:
	var desc_lbl := Label.new()
	desc_lbl.text = desc
	desc_lbl.custom_minimum_size.x = _vp.x * desc_width_frac
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if font_size > 0:
		desc_lbl.add_theme_font_size_override("font_size", font_size)
	if info_text != "":
		var desc_row := HBoxContainer.new()
		desc_row.add_child(desc_lbl)
		desc_row.add_child(_info_icon(info_text))
		grid.add_child(desc_row)
	else:
		grid.add_child(desc_lbl)
	grid.add_child(_build_purchase_button(buy_text, cost, maxed, callback, font_size, btn_width_frac, show_cost_in_button))

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
		font_size: int = 0, btn_width_frac: float = PURCHASE_BTN_WIDTH_FRAC, label_width_frac: float = 0.0, value_width_frac: float = 0.0,
		info_text: String = "") -> void:
	var label_lbl := Label.new()
	label_lbl.text = label
	if label_width_frac > 0.0:
		label_lbl.custom_minimum_size.x = _vp.x * label_width_frac
		label_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if font_size > 0:
		label_lbl.add_theme_font_size_override("font_size", font_size)
	if info_text != "":
		var label_row := HBoxContainer.new()
		label_row.add_theme_constant_override("separation", 1)
		label_row.add_child(label_lbl)
		# font_size>0 is what the compact 2-column Affinities grid always
		# passes (every other section leaves it 0) -- reused here as the
		# same signal to shrink the icon to match that grid's real budget.
		label_row.add_child(_info_icon(info_text, font_size > 0))
		grid.add_child(label_row)
	else:
		grid.add_child(label_lbl)
	var value_lbl := Label.new()
	value_lbl.text = value
	if value_width_frac > 0.0:
		value_lbl.custom_minimum_size.x = _vp.x * value_width_frac
	if font_size > 0:
		value_lbl.add_theme_font_size_override("font_size", font_size)
	grid.add_child(value_lbl)
	grid.add_child(_build_purchase_button(buy_text, cost, maxed, callback, font_size, btn_width_frac))

func _build_purchase_button(buy_text: String, cost: int, maxed: bool, callback: Callable, font_size: int, btn_width_frac: float, show_cost_in_button: bool = true) -> Button:
	var btn := Button.new()
	if maxed:
		btn.text = "MAXED"
	elif show_cost_in_button:
		btn.text = "%s (%d)" % [buy_text, cost]
	else:
		btn.text = buy_text
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
## `show_cost_in_button`, when false, leaves the cost out of the BUTTON's
## own text entirely (the caller is expected to have put it in `desc`
## instead) -- used by the Level-up row specifically, whose cost can run
## into the thousands at high levels and was overflowing/clipping the
## fixed-width button (Recovery/Evade/Crit/Affinity costs all stay small
## enough that showing them on the button is fine, so they keep the
## default).
func _purchase_row(desc: String, buy_text: String, cost: int, maxed: bool, callback: Callable, show_cost_in_button: bool = true, info_text: String = "") -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	_add_purchase_cells(grid, desc, buy_text, cost, maxed, callback, 0, PURCHASE_BTN_WIDTH_FRAC, 0.42, show_cost_in_button, info_text)
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
	slots_lbl.modulate = Palette.TEXT_DIM
	card_container.add_child(slots_lbl)

	# Feed / leveling -- moved above Recovery per direct request. Only the
	# exact-cost-to-next-level button remains; the flat +50/+250 feed
	# buttons were dropped, also per direct request.
	var exact := maxi(0, int(ceil(need - have)))
	card_container.add_child(_purchase_row(
		"Level up — %d Aether" % exact, "→ LV %d" % (level + 1), exact, false,
		_on_feed_pressed.bind(uid, exact), false, LEVEL_INFO))

	# Recovery/Evade/Crit share the SAME label/value/button column widths
	# (explicit floors, not auto-sized) even though Recovery has its own
	# GridContainer separate from Evade/Crit's -- that's what actually puts
	# all 4 buttons at the identical x position down the page, not just
	# giving them the same WIDTH (which alone doesn't align them if the
	# columns before the button differ between the two grids).
	# btn_col_frac measured directly against real worst-case button text
	# (a 5-digit cost, "+1.5% (99999)") at the real default font/padding --
	# the PRIOR 0.20 was narrower than that real text needed (~106px of
	# text + 12px button padding vs. the 82px it was given), clipping it;
	# 0.32 comfortably fits the measured worst case with room to spare.
	# label_col_frac trimmed 0.28 -> 0.24 to make room for the new info icon
	# (post-batch feedback) sharing this same column -- the label already
	# autowraps at this floor (AUTOWRAP_WORD_SMART, set whenever a width
	# floor is given), so a slightly narrower floor just wraps a long label
	# like "Post-combat Recovery" a little earlier rather than overflowing.
	var label_col_frac: float = 0.24
	var value_col_frac: float = 0.11
	var btn_col_frac: float = 0.30

	# Recovery -- now second, after Level.
	var recovery_grid := GridContainer.new()
	recovery_grid.columns = 3
	recovery_grid.add_theme_constant_override("h_separation", 10)
	_add_labeled_purchase_cells(recovery_grid, "Post-combat Recovery",
		"%d%%" % roundi(FarroadProgression.recovery_of(g, uid) * 100),
		"+%d%%" % roundi(FarroadProgression.REST_STEP * 100),
		FarroadProgression.recovery_cost(g, uid), FarroadProgression.recovery_maxed(g, uid),
		_on_recovery_pressed.bind(uid), 0, btn_col_frac, label_col_frac, value_col_frac, RECOVERY_INFO)
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
			label_col_frac, value_col_frac, PCT_STAT_INFO[stat])
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
			# btn_width_frac trimmed 0.16 -> 0.13 to make room for the new
			# compact info icon sharing the label column (post-batch feedback)
			# -- "+1 (999)" style button text stays comfortably short enough.
			_add_labeled_purchase_cells(aff_grid, AFFINITY_AXIS_LABELS[axis], "%+.0f%%" % pct,
				"+1", cost, maxed, _on_affinity_pressed.bind(uid, axis), 12, 0.13, 0.09, 0.08, _affinity_info(axis))
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

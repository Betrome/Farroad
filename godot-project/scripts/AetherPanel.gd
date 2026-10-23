class_name AetherPanel
extends Node
## The Aether card of the Units menu: leveling (feed Aether), Recovery,
## Evade/ATK-Crit/MAG-Crit investment, and the 8-axis Affinity investment,
## all in one card.
##
## Every purchase handler calls FarroadProgression.refresh_live_stats(g), so a
## purchase reaches a unit already mid-fight immediately, the way GAMBITS'
## sync_loadout does for a slot edit, not just from the next wave.
##
## This panel owns no popup of its own. UnitsPanel is the only popup owner (a
## second popup opened from inside it closed everything), and this panel
## builds its card into the container UnitsPanel hands it (build_into).

var g: Dictionary
var _vp: Vector2
var _parent: GameController
var selected_uid: String = ""

var card_container: Container

const AFFINITY_AXIS_LABELS := {"fire": "Fire", "water": "Water", "earth": "Earth", "air": "Air",
	"light": "Light", "dark": "Dark", "body": "Body", "spirit": "Spirit"}
const PCT_STAT_LABELS := {"evade": "Evade", "atkCrit": "ATK Crit", "magCrit": "MAG Crit"}

## Each stat and affinity has a small info icon that pops up a small window
## saying what the stat does.
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

func setup(new_g: Dictionary, vp: Vector2, parent: GameController) -> void:
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
	_shown.clear()           # opening the screen shows the numbers as they are; only changes animate
	_refresh_card()

## ---- values that tick up (Ian) ----
## Every number the Aether screen shows (a stat, Recovery, Evade/crit, an
## affinity) is registered as it is built. When a purchase raises one, it
## counts up from its old value to the new one and a green arrow rises beside
## it. `_shown` holds what was on screen last, per value.
var _shown: Dictionary = {}
var _shown_uid := ""
var _ticks: Array = []

func _track(key: String, number: float, node: Control, fmt: Callable) -> void:
	_ticks.append({"key": key, "num": number, "node": node, "fmt": fmt, "final": node.text})

func _run_ticks(uid: String) -> void:
	if uid != _shown_uid:
		_shown.clear()
		_shown_uid = uid
	for t in _ticks:
		var key: String = t["key"]
		var num: float = float(t["num"])
		var node: Control = t["node"]
		if _shown.has(key) and num > float(_shown[key]) + 0.0001 and is_instance_valid(node):
			_animate_value(node, float(_shown[key]), num, t["fmt"], str(t["final"]))
		_shown[key] = num
	_ticks.clear()

func _animate_value(node: Control, from_v: float, to_v: float, fmt: Callable, final_text: String) -> void:
	ValueTick.animate(node, from_v, to_v, fmt, final_text)

func _fmt_num(v: float) -> String:
	return str(int(roundf(v))) if is_equal_approx(v, roundf(v)) else str(snappedf(v, 0.1))

## The Body and Spirit pop-ups mention physical attacks (Body) and
## buffs/debuffs (Spirit) rather than the generic affinity text. They don't
## work like the 6 elemental axes (there are no element-tagged actions for
## them): affinity_factor reads "body" only when act.camp == "atk" (physical),
## and apply_status / heal_for read "spirit" for buff and heal potency
## (symmetric aff_boost) and, for debuffs, an asymmetric caster-potency /
## target-resist formula (aff_boost_resist). The "X-aligned actions" text the
## other 6 axes use would be wrong for either.
const BODY_INFO := "Body affinity boosts the power of this unit's own physical attacks (on top of any element they also carry), and reduces incoming physical damage from enemies."
const SPIRIT_INFO := "Spirit affinity boosts this unit's own healing (including drain/lifesteal) given and received, and how strongly its buffs and debuffs land, both as caster and as target. Doesn't affect Recovery, the separate between-wave stat."

func _affinity_info(axis: String) -> String:
	if axis == "body":
		return BODY_INFO
	if axis == "spirit":
		return SPIRIT_INFO
	var label: String = AFFINITY_AXIS_LABELS[axis]
	return "%s affinity boosts the power of this unit's own %s-aligned actions, and reduces incoming %s-aligned damage/effects from enemies." % [
		label, label, label]

## A small popup anchored next to the icon that opened it, like a tooltip
## beside the stat being inspected. It is deliberately not the shared
## full-screen detail overlay (GameController._build_detail_overlay), which is
## larger and centered. It is added as a child of the icon's own Window
## (whatever popup this card lives inside, UnitsPanel's, via get_window()), so
## it layers correctly without going through GameController's overlay code.
func _show_stat_info_popup(anchor: Control, text: String) -> void:
	var host: Window = anchor.get_window()
	if host == null:
		return
	var p := PopupPanel.new()
	UiKit.style_popup(p)
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
	UiKit.info_button(btn, compact)
	btn.pressed.connect(func(): _show_stat_info_popup(btn, info_text))
	return btn

func _section_label(text: String) -> Label:
	return UiKit.make_label(text, "label")

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
	if str(value).is_valid_float():
		_track("stat:" + label, float(str(value)), val_lbl, func(v: float): return "[b]%s %s[/b]" % [label, _fmt_num(v)])
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
		info_text: String = "", track_key: String = "", track_num: float = 0.0, track_fmt: Callable = Callable()) -> void:
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
	if track_key != "" and track_fmt.is_valid():
		_track(track_key, track_num, value_lbl, track_fmt)
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
	UiKit.purchase_button(btn, available)

func _refresh_card() -> void:
	_ticks.clear()
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
	header.text = "%s — %s — LV %d%s" % [def["name"], FarroadProgression.unit_title(g, uid), level, row_tag]
	header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(header)
	# the level itself ticks up too
	var head_name: String = str(def["name"])
	var head_title: String = FarroadProgression.unit_title(g, uid)
	_track("level", float(level), header, func(v: float): return "%s — %s — LV %d%s" % [head_name, head_title, int(roundf(v)), row_tag])

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

	# Smarter auto-spend: buys whatever adds the most strength per Aether (see AutoInvest.gd).
	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 8)
	for entry in [["Auto-invest", false], ["Auto-invest party", true]]:
		var ab := Button.new()
		ab.text = entry[0]
		ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ab.disabled = float(g.get("aether", 0)) < 1.0
		ab.pressed.connect(_show_auto_invest.bind(bool(entry[1])))
		auto_row.add_child(ab)
	card_container.add_child(auto_row)

	# Feed / leveling -- moved above Recovery per direct request. Only the
	# exact-cost-to-next-level button remains; the flat +50/+250 feed
	# buttons were dropped, also per direct request.
	var exact := maxi(0, int(ceil(need - have)))
	card_container.add_child(_purchase_row(
		"Level up — %d Aether" % exact, "→ LV %d" % (level + 1), exact, false,
		_on_feed_pressed.bind(uid, exact), false, LEVEL_INFO))
	# Distilled Aether (an Arena season reward): one level without the Aether, when you are short.
	var distilled: int = int(g.get("distilled", 0))
	if distilled > 0:
		var dbtn := Button.new()
		dbtn.text = "Use Distilled Aether: +1 level (%d left)" % distilled
		dbtn.disabled = not FarroadProgression.can_use_distilled(g, uid)
		dbtn.tooltip_text = "Raises this unit one level for free. Available when you don't have enough Aether for the next level."
		dbtn.pressed.connect(_on_distilled_pressed.bind(uid))
		card_container.add_child(dbtn)

	# Recovery and Evade/Crit use the same label / value / button column widths
	# (explicit floors, not auto-sized) even though they are separate grids.
	# That is what puts all 4 buttons at the same x position down the page;
	# equal button widths alone wouldn't align them if the columns before the
	# button differed between the grids.
	# btn_col_frac fits the worst-case button text (a 5-digit cost, "+1.5%
	# (99999)", about 106 px of text plus 12 px of button padding) at the
	# default font; a narrower column clips it.
	# label_col_frac leaves room for the info icon sharing the label column.
	# The label autowraps at this floor (AUTOWRAP_WORD_SMART, set whenever a
	# width floor is given), so a long label like "Post-combat Recovery" wraps
	# earlier instead of overflowing.
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
		_on_recovery_pressed.bind(uid), 0, btn_col_frac, label_col_frac, value_col_frac, RECOVERY_INFO,
		"recovery", FarroadProgression.recovery_of(g, uid) * 100.0, func(v: float): return "%d%%" % roundi(v))
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
			label_col_frac, value_col_frac, PCT_STAT_INFO[stat],
			"pct:" + stat, cur * 100.0, func(v: float): return "%s%%" % snapped(v, 0.1))
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
			# btn_width_frac leaves room for the compact info icon sharing the
			# label column; "+1 (999)" style button text is short enough.
			_add_labeled_purchase_cells(aff_grid, AFFINITY_AXIS_LABELS[axis], "%+.0f%%" % pct,
				"+1", cost, maxed, _on_affinity_pressed.bind(uid, axis), 12, 0.13, 0.09, 0.08, _affinity_info(axis),
				"aff:" + axis, pct, func(v: float): return "%+.0f%%" % v)
	card_container.add_child(aff_grid)
	_run_ticks(uid)

## GameController's own top-strip currency line (Aether/Lore/Marks) only
## refreshed on a wave transition -- fine for Marks (nothing spends it yet),
## wrong for Aether, which every purchase below actually changes right now,
## not next wave.
## Shows what Auto-invest would buy (for the selected unit, or split evenly over the fielded party)
## and buys it on confirm.
func _show_auto_invest(party: bool) -> void:
	var uids: Array = g["party"].duplicate() if party else [selected_uid]
	if uids.is_empty() or selected_uid == "":
		return
	var budget_each: float = floorf(float(g["aether"]) / float(uids.size()))
	var plans := {}
	var any := false
	for uid in uids:
		plans[uid] = AutoInvest.plan(g, uid, budget_each)
		if not (plans[uid]["steps"] as Array).is_empty():
			any = true
	var o := _parent.build_overlay_window(false)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "AUTO-INVEST" + (" (PARTY)" if party else "")
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	var intro := Label.new()
	intro.text = "Buys what adds the most strength for each Aether: levels, Recovery, Evade and crit, and affinities." 		+ (" Your Aether is split evenly across the party." if party else "")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.modulate = Palette.TEXT_DIM
	vbox.add_child(intro)
	var total := 0.0
	for uid in uids:
		var p: Dictionary = plans[uid]
		var def = FarroadCore.roster_by_id(uid)
		var name_lbl := Label.new()
		name_lbl.text = "%s — spends %s Aether (Power %d to %d)" % [def["name"] if def else uid, _fmt_num(float(p["spent"])), int(p["power_before"]), int(p["power_after"])]
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(name_lbl)
		var lines := AutoInvest.describe(g, uid, p)
		var detail := Label.new()
		detail.text = "Nothing affordable." if lines.is_empty() else ", ".join(lines)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.modulate = Palette.TEXT_DIM
		vbox.add_child(detail)
		total += float(p["spent"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)
	var buy := Button.new()
	buy.text = "Spend %s Aether" % _fmt_num(total)
	buy.disabled = not any
	buy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(buy)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cancel)
	var backdrop: ColorRect = o["backdrop"]
	cancel.pressed.connect(func(): backdrop.queue_free())
	buy.pressed.connect(func():
		var levels_before := {}
		for uid in uids:
			levels_before[uid] = FarroadProgression.level_of(g, uid)
		for uid in uids:
			AutoInvest.apply(g, uid, plans[uid])
		backdrop.queue_free()
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
		for uid in uids:
			var after: int = FarroadProgression.level_of(g, uid)
			if after > int(levels_before[uid]):
				_parent.level_up_fx(uid, after)
		_refresh_card())
	await _parent.finish_overlay_window(o)

func _notify_currency_changed() -> void:
	_parent.refresh_hud()

func _on_recovery_pressed(uid: String) -> void:
	if FarroadProgression.spend_recovery(g, uid):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
	_refresh_card()

func _on_feed_pressed(uid: String, amount: int) -> void:
	if amount <= 0:
		return
	var lv_before: int = FarroadProgression.level_of(g, uid)
	if FarroadProgression.spend_feed(g, uid, amount):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
		var lv_after: int = FarroadProgression.level_of(g, uid)
		if lv_after > lv_before:
			_parent.level_up_fx(uid, lv_after)
	_refresh_card()

func _on_distilled_pressed(uid: String) -> void:
	var lv_before: int = FarroadProgression.level_of(g, uid)
	if FarroadProgression.use_distilled(g, uid):
		_notify_currency_changed()
		FarroadProgression.refresh_live_stats(g)
		var lv_after: int = FarroadProgression.level_of(g, uid)
		if lv_after > lv_before:
			_parent.level_up_fx(uid, lv_after)
		_parent.save_game()
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

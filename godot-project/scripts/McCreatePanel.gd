extends Node
## Milestone 3, Step 3j (final roadmap item): the character-creation
## screen -- MC point-buy + charge-action picker. Mirrors #mcCreate
## (src/shell.html:266-301) and its handlers (src/farroad-ui.js:3159-3236).
##
## Unlike every other *Panel.gd, this is NOT a toggle-button/PopupPanel --
## it is shown unconditionally, full-screen, the moment GameController
## decides no save exists, and it is what the rest of GameController's
## _ready() (HUD, the other 8 panels, the first fight) waits on. See
## GameController._on_mc_confirmed()/_start_game().

var _vp: Vector2
var _parent: Node
var _on_confirm: Callable

var mc_points: Dictionary = {}        # {atk,mag,def,res,spd,hp: int 0..15}
var mc_charge_choice: String = ""

var root: Control
var name_edit: LineEdit
var points_label: Label
var stat_point_labels: Dictionary = {}    # k -> Label (current point value)
var stat_display_labels: Dictionary = {}  # k -> Label (computed stat + growth)
var charge_buttons: Dictionary = {}       # id -> Button
var confirm_btn: Button

const MC_STAT_LABELS := {"atk": "ATK", "mag": "MAG", "def": "DEF", "res": "RES", "spd": "SPD", "hp": "HP"}

func setup(vp: Vector2, parent: Node, on_confirm: Callable) -> void:
	_vp = vp
	_parent = parent
	_on_confirm = on_confirm
	for k in FarroadProgression.MC_STAT_KEYS:
		mc_points[k] = FarroadProgression.MC_POINT_MIN
	_build_ui(parent)

func _build_ui(parent: Node) -> void:
	# root is the single node freed on confirm -- everything else (the
	# background, the scroll view) is a child of it, so one queue_free()
	# tears down the whole screen cleanly.
	root = Control.new()
	root.position = Vector2.ZERO
	root.size = _vp
	parent.add_child(root)

	var background := ColorRect.new()
	background.color = Color(0.06, 0.06, 0.08, 1.0)
	background.position = Vector2.ZERO
	background.size = _vp
	root.add_child(background)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(_vp.x * 0.05, _vp.y * 0.04)
	scroll.custom_minimum_size = Vector2(_vp.x * 0.9, _vp.y * 0.92)
	root.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(_vp.x * 0.86, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "Farroad"
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.045))
	root_vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Before the road begins — build your character."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root_vbox.add_child(subtitle)

	_build_name_block(root_vbox)
	_build_stats_block(root_vbox)
	_build_charges_block(root_vbox)

	confirm_btn = Button.new()
	confirm_btn.text = "Begin the road"
	confirm_btn.disabled = true
	confirm_btn.pressed.connect(_on_confirm_pressed)
	root_vbox.add_child(confirm_btn)

	_refresh_stats()
	_refresh_charges()

func _build_name_block(parent: VBoxContainer) -> void:
	var label := Label.new()
	label.text = "Name"
	label.add_theme_font_size_override("font_size", 16)
	parent.add_child(label)

	name_edit = LineEdit.new()
	name_edit.max_length = 20
	name_edit.placeholder_text = "Your character's name"
	name_edit.custom_minimum_size = Vector2(_vp.x * 0.6, 0)
	name_edit.text_changed.connect(func(_t): _update_confirm_state())
	parent.add_child(name_edit)

func _build_stats_block(parent: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	var stats_lbl := Label.new()
	stats_lbl.text = "Stats"
	stats_lbl.add_theme_font_size_override("font_size", 16)
	stats_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(stats_lbl)
	points_label = Label.new()
	header.add_child(points_label)
	parent.add_child(header)

	for k in FarroadProgression.MC_STAT_KEYS:
		parent.add_child(_build_stat_row(k))

	var footnote := Label.new()
	footnote.text = ("ATK/MAG/DEF/RES/SPD/HP also raise that stat's growth per level. " +
		"Block, Evade and the crit rates aren't offered here — like elemental affinities, " +
		"you start neutral in all four and buy them up with Aether in the AETHER tab instead.")
	footnote.modulate = Color(0.65, 0.7, 0.65)
	footnote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(footnote)

func _build_stat_row(k: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_lbl := Label.new()
	name_lbl.text = MC_STAT_LABELS[k]
	name_lbl.custom_minimum_size = Vector2(_vp.x * 0.12, 0)
	row.add_child(name_lbl)

	var minus_btn := Button.new()
	minus_btn.text = "−"
	minus_btn.pressed.connect(func(): _on_stat_minus(k))
	row.add_child(minus_btn)

	var point_lbl := Label.new()
	point_lbl.custom_minimum_size = Vector2(_vp.x * 0.08, 0)
	point_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stat_point_labels[k] = point_lbl
	row.add_child(point_lbl)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.pressed.connect(func(): _on_stat_plus(k))
	row.add_child(plus_btn)

	var display_lbl := Label.new()
	display_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	display_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stat_display_labels[k] = display_lbl
	row.add_child(display_lbl)

	return row

func _on_stat_minus(k: String) -> void:
	if mc_points[k] > FarroadProgression.MC_POINT_MIN:
		mc_points[k] -= 1
	_refresh_stats()
	_update_confirm_state()

## The + guard is a PER-CLICK check against the running total, not just a
## per-stat 0-15 clamp -- matches updateMcConfirm's own real gate exactly
## (farroad-ui.js:3183-3185): a stat already below MC_POINT_MAX can still
## refuse a click once the whole 45-point pool is spent elsewhere.
func _on_stat_plus(k: String) -> void:
	if mc_points[k] < FarroadProgression.MC_POINT_MAX and FarroadProgression.mc_points_spent(mc_points) < FarroadProgression.MC_POINTS_TOTAL:
		mc_points[k] += 1
	_refresh_stats()
	_update_confirm_state()

func _refresh_stats() -> void:
	var spent: int = FarroadProgression.mc_points_spent(mc_points)
	points_label.text = "%d points remaining" % (FarroadProgression.MC_POINTS_TOTAL - spent)
	for k in FarroadProgression.MC_STAT_KEYS:
		stat_point_labels[k].text = str(mc_points[k])
		var stat_val: int = roundi(FarroadProgression.mc_lerp(FarroadProgression.MC_STAT_RANGE[k], float(mc_points[k])))
		var growth_val: float = roundi(FarroadProgression.mc_lerp(FarroadProgression.MC_GROWTH_RANGE[k], float(mc_points[k])) * 10.0) / 10.0
		stat_display_labels[k].text = "%d (+%.1f/lvl)" % [stat_val, growth_val]

func _build_charges_block(parent: VBoxContainer) -> void:
	var header := Label.new()
	header.text = "Charge action"
	header.add_theme_font_size_override("font_size", 16)
	parent.add_child(header)

	var footnote := Label.new()
	footnote.text = "Fills as you act in battle and fires on its own for a big effect. Pick one."
	footnote.modulate = Color(0.65, 0.7, 0.65)
	footnote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(footnote)

	for id in FarroadProgression.MC_STARTER_CHARGES:
		var btn := Button.new()
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(_vp.x * 0.8, 0)
		btn.pressed.connect(func():
			mc_charge_choice = id
			_refresh_charges()
			_update_confirm_state())
		charge_buttons[id] = btn
		parent.add_child(btn)

## Mirrors describeAction's name/body/note shape for just the 3 starters --
## not a full describeAction() port, which handles many more action shapes
## this 3-item picker never needs.
func _describe_starter_charge(id: String) -> String:
	var a: Dictionary = FarroadCore.ACTIONS[id]
	var shape: String = {"allFoes": "all foes", "allAllies": "whole party", "ally": "one ally",
		"self": "self", "deadAlly": "a fallen ally"}.get(a.get("tk"), "one foe")
	var bits := ["%s · hits %s" % [("physical" if a.get("camp") == "atk" else "magic"), shape]]
	if a.get("power"):
		bits.append("power ×%s" % a["power"])
	if a.get("heal"):
		bits.append("HEALS")
	var body := " · ".join(bits)
	var applies_count := 0
	for bid in FarroadCore.BONUSES.keys():
		if FarroadCore.bonus_applies(a, bid):
			applies_count += 1
	return "⚡ %s\n%s\n%s\n%d of %d Lore upgrades apply to this action" % \
		[a["name"], body, a.get("note", ""), applies_count, FarroadCore.BONUSES.size()]

func _refresh_charges() -> void:
	for id in FarroadProgression.MC_STARTER_CHARGES:
		var btn: Button = charge_buttons[id]
		btn.text = _describe_starter_charge(id)
		btn.add_theme_stylebox_override("normal", _charge_style(id == mc_charge_choice))

## A StyleBoxFlat border-highlight for the currently-chosen card (closer
## to the real .slot.mcc.on CSS class) rather than disabled=true --
## "disabled" reads as unavailable, not chosen, and this screen's whole
## point is letting the player pick exactly one of three available options.
func _charge_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.22, 0.20, 0.10) if selected else Color(0.14, 0.14, 0.17)
	style.border_color = Color(0.85, 0.7, 0.15) if selected else Color(0.3, 0.3, 0.34)
	style.set_border_width_all(2 if selected else 1)
	style.set_content_margin_all(10)
	return style

func _sanitize_name(raw: String) -> String:
	var re := RegEx.new()
	re.compile("[<>&\"']")
	return re.sub(raw, "", true).strip_edges().substr(0, 20)

func _update_confirm_state() -> void:
	var name_ok: bool = _sanitize_name(name_edit.text).length() > 0
	var points_ok: bool = FarroadProgression.mc_points_spent(mc_points) == FarroadProgression.MC_POINTS_TOTAL
	confirm_btn.disabled = not (name_ok and points_ok and mc_charge_choice != "")

func _on_confirm_pressed() -> void:
	var name := _sanitize_name(name_edit.text)
	if name == "" or FarroadProgression.mc_points_spent(mc_points) != FarroadProgression.MC_POINTS_TOTAL or mc_charge_choice == "":
		return
	var built: Dictionary = FarroadProgression.mc_build_stats(mc_points)
	var mc := {"name": name, "stats": built["stats"], "hp": built["hp"], "growth": built["growth"],
		"chargeAction": mc_charge_choice, "acquiredCharges": [mc_charge_choice]}
	root.queue_free()
	_on_confirm.call(mc)

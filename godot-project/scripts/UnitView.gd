class_name UnitView
extends Node2D
## One unit's on-field visual: a placeholder shape (no sprite art in the repo
## yet -- Ian's own call), a name label, an HP bar, and a thin charge bar
## just below it. Built entirely in code (setup()), not a hand-authored
## .tscn sub-scene -- the battle field's unit count varies per fight, so
## constructing views programmatically from FarroadCore's own unit dicts is
## the natural fit, not just easier to author reliably by hand.
##
## Sized from the caller's OWN viewport-relative size, not a fixed pixel
## constant -- meant to run on phones, where the visible viewport varies by
## device aspect ratio (see BattlePresenter's stretch/aspect="expand" note).

var unit: Dictionary
var rest_position: Vector2
var size: float

var shape: Polygon2D   # public -- BattlePresenter animates ONLY this during a hop/shake, not the whole UnitView, so the name/HP/charge bars below (siblings, not children of shape) stay put at the unit's rest position
var _hp_bg: ColorRect
var _hp_fg: ColorRect
var _charge_bg: ColorRect
var _charge_fg: ColorRect

func setup(u: Dictionary, unit_size: float) -> void:
	unit = u
	size = unit_size
	var half := size / 2.0
	var bar_h: float = max(4.0, size * 0.12)
	var charge_h: float = max(2.0, bar_h * 0.5)

	shape = Polygon2D.new()
	shape.polygon = PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	shape.color = Color(0.30, 0.55, 0.95) if u["isParty"] else Color(0.85, 0.30, 0.28)
	add_child(shape)

	var name_label := Label.new()
	name_label.text = u["name"]
	name_label.position = Vector2(-half - size * 0.2, -half - size * 0.45)
	name_label.add_theme_font_size_override("font_size", int(size * 0.25))
	add_child(name_label)

	_hp_bg = ColorRect.new()
	_hp_bg.size = Vector2(size, bar_h)
	_hp_bg.position = Vector2(-half, half + bar_h)
	_hp_bg.color = Color(0.15, 0.15, 0.15)
	add_child(_hp_bg)

	_hp_fg = ColorRect.new()
	_hp_fg.size = Vector2(size, bar_h)
	_hp_fg.position = Vector2(-half, half + bar_h)
	_hp_fg.color = Color(0.25, 0.85, 0.30)
	add_child(_hp_fg)

	# Thin charge bar, directly below the HP bar -- fills toward whichever
	# charge action the unit itself has (costOfCharge), or the generic
	# CHARGE_FULL if it has none, so it never visually overflows past full.
	var charge_y: float = half + bar_h * 2.0 + 2.0
	_charge_bg = ColorRect.new()
	_charge_bg.size = Vector2(size, charge_h)
	_charge_bg.position = Vector2(-half, charge_y)
	_charge_bg.color = Color(0.12, 0.12, 0.16)
	add_child(_charge_bg)

	_charge_fg = ColorRect.new()
	_charge_fg.size = Vector2(0, charge_h)
	_charge_fg.position = Vector2(-half, charge_y)
	_charge_fg.color = Color(0.85, 0.7, 0.15)
	add_child(_charge_fg)

	update_hp()
	update_charge()

## Re-reads unit["hp"]/["maxHp"] -- FarroadCore.step() mutates the unit dict
## in place, so this always reflects the live value, no separate sync needed.
func update_hp() -> void:
	var frac: float = clamp(float(unit["hp"]) / float(unit["maxHp"]), 0.0, 1.0)
	var bar_h: float = _hp_bg.size.y
	_hp_fg.size = Vector2(size * frac, bar_h)
	_hp_fg.color = Color(0.25, 0.85, 0.30) if frac > 0.3 else Color(0.90, 0.70, 0.15) if frac > 0.0 else Color(0.5, 0.1, 0.1)
	# A dead enemy disappears outright (there's no reviving one mid-fight, so
	# nothing is lost by removing it from view). A dead PARTY member stays
	# visible, just dimmed -- a fallen ally isn't gone the way a kill is, and
	# a vanishing party sprite would read as a bug, not a death.
	if frac <= 0.0 and not unit["isParty"]:
		visible = false
	else:
		visible = true
		modulate.a = 1.0 if frac > 0.0 else 0.35

## Re-reads unit["charge"] against its own chargeAction's costOfCharge --
## same "live dict, no separate sync" reasoning as update_hp(). A unit
## with no chargeAction at all (most non-boss enemies) has nothing to
## ever spend charge on, so the bar is hidden outright rather than shown
## clamped-at-some-fraction-of-a-generic-fallback, which used to read as
## "this enemy is charging something" when it never was.
func update_charge() -> void:
	if not unit.get("chargeAction"):
		_charge_bg.visible = false
		_charge_fg.visible = false
		return
	_charge_bg.visible = true
	_charge_fg.visible = true
	var act = FarroadCore.ACTIONS.get(unit["chargeAction"])
	var max_charge: float = FarroadCore.cost_of_charge(act)
	var frac: float = clamp(float(unit.get("charge", 0.0)) / max_charge, 0.0, 1.0)
	_charge_fg.size = Vector2(size * frac, _charge_bg.size.y)

## World-space point a floating damage number should spawn from.
func damage_spawn_position() -> Vector2:
	return global_position + Vector2(0, -size / 2.0 - size * 0.18)

## A quick decaying left-right shake -- played when this unit takes a
## non-evaded hit. Shakes only `shape` (the colored square), not the whole
## UnitView, so the name/HP/charge bars stay put instead of shaking along
## with it. Safe to fire without awaiting: targets never move during the
## ATTACKER's own hop/projectile animation, so this never fights another
## tween over `shape.position`.
func shake() -> void:
	var base := shape.position
	var amt: float = size * 0.14
	var tw := create_tween()
	tw.tween_property(shape, "position", base + Vector2(amt, 0), 0.035)
	tw.tween_property(shape, "position", base + Vector2(-amt, 0), 0.06)
	tw.tween_property(shape, "position", base + Vector2(amt * 0.4, 0), 0.06)
	tw.tween_property(shape, "position", base, 0.05)

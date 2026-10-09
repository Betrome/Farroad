class_name ActionFilter
extends RefCounted
## The action filter shared by Catalogue, Gambits and the Shop (it used to
## be copied into each). Ian: "Action Filter: remove 'elemental' and add in
## each of the different affinities." An action's affinity is its element
## (fire/water/earth/air/light/dark/spirit), and physical actions also use
## Body (FarroadCore.affinity_factor).

const TARGET_OPTIONS := [["any", "Any target"], ["foe", "Single foe"], ["allFoes", "All foes"],
	["ally", "Single ally"], ["allAllies", "All allies"], ["self", "Self"], ["deadAlly", "Dead ally"]]
## Filters the action's real scale stat (scaleStat, else its camp's ATK/MAG).
const STAT_OPTIONS := [["any", "Any stat"], ["atk", "Scales ATK"], ["mag", "Scales MAG"],
	["def", "Scales DEF"], ["res", "Scales RES"], ["spd", "Scales SPD"], ["lowAtkMag", "Scales lower of ATK/MAG"]]
const EFFECT_OPTIONS := [["any", "Any effect"], ["heal", "Heals"], ["charge", "Charge action"],
	["buff", "Buff effect"], ["debuff", "Debuff effect"],
	["fire", "Fire"], ["water", "Water"], ["earth", "Earth"], ["air", "Air"],
	["light", "Light"], ["dark", "Dark"], ["body", "Body (physical)"], ["spirit", "Spirit"]]
const GAMBIT_GROUP_OPTIONS := [["any", "Any group"], ["self", "Self"], ["ally", "Ally"], ["foe", "Foe"]]
const GEAR_SLOT_OPTIONS := [["any", "Any slot"], ["head", "Head"], ["body", "Body"], ["legs", "Legs"], ["hand", "Hand"]]
const RARITY_OPTIONS := [["any", "Any rarity"], ["common", "Common"], ["rare", "Rare"], ["legendary", "Legendary"]]

## Ian: action lists can be sorted A-Z or by level. One choice shared by
## every action list (Gambits, Lore, Catalogue, Shop) for the session.
const SORT_OPTIONS := [["default", "Default order"], ["alpha", "Sort: A–Z"], ["level", "Sort: Level"]]
static var sort_mode: String = "default"

static func sort_dropdown(on_change: Callable) -> OptionButton:
	return dropdown(SORT_OPTIONS, sort_mode, func(v):
		sort_mode = v
		on_change.call())

## `ids` in the chosen order (a new array). Level is the action's Lore
## level, highest first; ties fall back to A-Z.
static func sort_ids(g: Dictionary, ids: Array) -> Array:
	var out := ids.duplicate()
	if sort_mode == "default":
		return out
	var name_of := func(aid) -> String:
		var a = FarroadCore.ACTIONS.get(aid)
		return str(a["name"]).to_lower() if a else str(aid)
	out.sort_custom(func(x, y):
		if sort_mode == "level":
			var lx := FarroadProgression.action_level(g, x)
			var ly := FarroadProgression.action_level(g, y)
			if lx != ly:
				return lx > ly
		return name_of.call(x) < name_of.call(y))
	return out

static func scale_stat(act: Dictionary) -> String:
	var s = act.get("scaleStat")
	if s == "avgAtkMag":
		return "lowAtkMag"
	return s if s else ("mag" if act.get("camp") == "mag" else "atk")

static func scale_label(act: Dictionary) -> String:
	match scale_stat(act):
		"lowAtkMag": return "the lower of ATK/MAG"
		var k: return String(k).to_upper()

## "scales with X · power ×N" for an action that deals damage or heals; an
## action with no power (a pure buff/debuff like Bulwark) has a fixed effect
## that no stat changes, so it says so instead of naming a stat.
static func scales_text(act: Dictionary) -> String:
	if not act.get("power"):
		return "no stat scaling (fixed effect)"
	return "scales with %s  ·  %s" % [scale_label(act), power_text(act)]

## Who an action hits, in plain words.
static func target_label(act: Dictionary) -> String:
	return {"foe": "one foe", "allFoes": "all foes", "ally": "one ally", "allAllies": "the whole party",
		"self": "self", "deadAlly": "a fallen ally"}.get(str(act.get("tk", "foe")), "one foe")

## Player-facing lines for what an action does beyond its damage/heal and
## status, built from its real numbers (Ian: the CSV design notes were
## internal and are no longer shown).
## Power as shown to the player. Actions whose power depends on HP or turn
## count show their real low-high range (read from the engine's own
## formulas, so the text can't drift from what they actually do).
static func power_text(act: Dictionary) -> String:
	var r := _power_range(act)
	if not r.is_empty():
		return "power ×%.2f–%.2f" % [r[0], r[1]]
	return "power ×%.2f" % float(act["power"]) if act.get("power") else ""

## [low, high] power for an action with a power formula, else [].
static func _power_range(act: Dictionary) -> Array:
	match act.get("powerFnId"):
		"vengeance":
			return [FarroadCore.eval_power_fn(act, {"hp": 1.0, "maxHp": 1.0}, null),
				FarroadCore.eval_power_fn(act, {"hp": 0.0, "maxHp": 1.0}, null)]
		"onslaught":
			var later := FarroadCore.eval_power_fn(act, {"turnsTaken": 1}, null)
			var first := FarroadCore.eval_power_fn(act, {"turnsTaken": 0}, null)
			return [minf(first, later), maxf(first, later)]
		"reckoning", "execute":
			return [FarroadCore.eval_power_fn(act, {}, {"hp": 1.0, "maxHp": 1.0}),
				FarroadCore.eval_power_fn(act, {}, {"hp": 0.0, "maxHp": 1.0})]
	return []

## Plain-words lines for actions whose strength depends on HP or turns.
static func _scaling_lines(act: Dictionary) -> Array:
	var r := _power_range(act)
	match act.get("powerFnId"):
		"vengeance":
			return ["Stronger the more HP the user has lost: power ×%.2f at full HP, rising evenly to ×%.2f near 0 HP." % [r[0], r[1]]]
		"onslaught":
			var first := FarroadCore.eval_power_fn(act, {"turnsTaken": 0}, null)
			var later := FarroadCore.eval_power_fn(act, {"turnsTaken": 1}, null)
			return ["Power ×%.2f on the user's first turn of a fight, ×%.2f on every turn after." % [first, later]]
		"reckoning", "execute":
			return ["Stronger the less HP the target has left: power ×%.2f against a full-HP target, rising evenly to ×%.2f near 0 HP." % [r[0], r[1]]]
	return []

static func effect_lines(act: Dictionary) -> Array:
	var out: Array = _scaling_lines(act)
	var hits := int(act.get("hits", 1)) if act.get("hits") else 1
	if hits > 1:
		out.append("Hits %d times." % hits)
	var pierce := float(act.get("defPierce", 0.0)) if act.get("defPierce") else 0.0
	var guard := "RES" if act.get("camp") == "mag" else "DEF"
	if pierce >= 0.999:
		out.append("True damage: ignores the target's %s." % guard)
	elif pierce > 0.0:
		out.append("Ignores %d%% of the target's %s." % [roundi(pierce * 100.0), guard])
	var crit := float(act.get("critBonus", 0.0)) if act.get("critBonus") else 0.0
	if crit > 0.0:
		out.append("+%d%% crit chance." % roundi(crit * 100.0))
	var ls := float(act.get("lifesteal", 0.0)) if act.get("lifesteal") else 0.0
	if ls > 0.0:
		out.append("Heals the user for %d%% of the damage dealt." % roundi(ls * 100.0))
	var rv := float(act.get("revive", 0.0)) if act.get("revive") else 0.0
	if rv > 0.0:
		out.append("Revives a fallen ally with %d%% HP." % roundi(rv * 100.0))
	var cl := int(act.get("cleanse", 0)) if act.get("cleanse") else 0
	if cl > 0:
		out.append("Removes %d debuff%s from each target." % [cl, "" if cl == 1 else "s"])
	var tt := int(act.get("selfTaunt", 0)) if act.get("selfTaunt") else 0
	if tt > 0:
		out.append("Taunts: draws foes' attacks for %d turns." % tt)
	var sc := float(act.get("stealCharge", 0.0)) if act.get("stealCharge") else 0.0
	if sc > 0.0:
		out.append("Steals %d charge from each target hit." % roundi(sc))
	var gc := float(act.get("giveCharge", 0.0)) if act.get("giveCharge") else 0.0
	if gc > 0.0:
		out.append("Gives each target %d charge (never the user)." % roundi(gc))
	var sp := float(act.get("siphonCharge", 0.0)) if act.get("siphonCharge") else 0.0
	if sp > 0.0:
		out.append("Shares up to %d of the user's own charge, split evenly among the other targets." % roundi(sp))
	return out

static func passes(act: Dictionary, target: String, stat: String, effect: String) -> bool:
	if target != "any" and act.get("tk", "foe") != target:
		return false
	if stat != "any" and scale_stat(act) != stat:
		return false
	match effect:
		"any":
			return true
		"heal":
			return bool(act.get("heal", false))
		"charge":
			return bool(act.get("isCharge", false))
		"buff":
			return act.get("applies") != null and FarroadCore.is_buff_status(act["applies"])
		"debuff":
			return act.get("applies") != null and not FarroadCore.is_buff_status(act["applies"])
		"body":
			return act.get("camp") == "atk" and not act.get("heal", false)
		_:
			return act.get("element") == effect

static func dropdown(options: Array, current_value: String, on_change: Callable) -> OptionButton:
	var opt := OptionButton.new()
	for idx in range(options.size()):
		opt.add_item(options[idx][1], idx)
		if options[idx][0] == current_value:
			opt.select(idx)
	opt.item_selected.connect(func(i): on_change.call(options[i][0]))
	return opt

## ===== gear filter + sort (Ian: "gear filtering and sorting by stat") =====
const GEAR_SORT_OPTIONS := [["default", "Default order"], ["name", "Sort: A–Z"], ["rarity", "Sort: Rarity"],
	["atk", "Sort: ATK"], ["mag", "Sort: MAG"], ["def", "Sort: DEF"], ["res", "Sort: RES"],
	["spd", "Sort: SPD"], ["evade", "Sort: Evade"]]
const GEAR_STAT_OPTIONS := [["any", "Any stats"], ["atk", "Has ATK"], ["mag", "Has MAG"], ["def", "Has DEF"],
	["res", "Has RES"], ["spd", "Has SPD"], ["evade", "Has Evade"], ["affinity", "Has affinity"]]
const GEAR_RARITY_RANK := {"common": 0, "rare": 1, "legendary": 2}
static var gear_sort: String = "default"
static var gear_rarity: String = "any"
static var gear_stat: String = "any"

static func _gear_has_stat(item: Dictionary, stat: String) -> bool:
	if stat == "affinity":
		for v in (item.get("affinity", {}) as Dictionary).values():
			if float(v) != 0.0:
				return true
		return false
	return item.get(stat) != null and float(item.get(stat)) != 0.0

## Three dropdowns (rarity / stat / sort) wired to the shared gear settings.
static func gear_controls(on_change: Callable) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 4)
	row.add_child(dropdown(RARITY_OPTIONS, gear_rarity, func(v):
		gear_rarity = v
		on_change.call()))
	row.add_child(dropdown(GEAR_STAT_OPTIONS, gear_stat, func(v):
		gear_stat = v
		on_change.call()))
	row.add_child(dropdown(GEAR_SORT_OPTIONS, gear_sort, func(v):
		gear_sort = v
		on_change.call()))
	return row

## `ids` filtered and sorted per the shared gear settings; `keep` (an item
## id that must stay listed, e.g. what's already worn) is never filtered out.
static func gear_ids(ids: Array, keep = null, with_rarity: bool = true) -> Array:
	var out: Array = ids.filter(func(id):
		if id == keep:
			return true
		var item: Dictionary = FarroadCore.EQUIPMENT.get(id, {})
		if with_rarity and gear_rarity != "any" and str(item.get("rarity", "common")) != gear_rarity:
			return false
		return gear_stat == "any" or _gear_has_stat(item, gear_stat))
	if gear_sort == "default":
		return out
	out.sort_custom(func(x, y):
		var ix: Dictionary = FarroadCore.EQUIPMENT.get(x, {})
		var iy: Dictionary = FarroadCore.EQUIPMENT.get(y, {})
		match gear_sort:
			"name":
				return str(ix.get("name", x)).to_lower() < str(iy.get("name", y)).to_lower()
			"rarity":
				var rx: int = GEAR_RARITY_RANK.get(str(ix.get("rarity", "common")), 0)
				var ry: int = GEAR_RARITY_RANK.get(str(iy.get("rarity", "common")), 0)
				if rx != ry:
					return rx > ry
			_:
				var vx: float = float(ix.get(gear_sort, 0.0)) if ix.get(gear_sort) != null else 0.0
				var vy: float = float(iy.get(gear_sort, 0.0)) if iy.get(gear_sort) != null else 0.0
				if vx != vy:
					return vx > vy
		return str(ix.get("name", x)).to_lower() < str(iy.get("name", y)).to_lower())
	return out

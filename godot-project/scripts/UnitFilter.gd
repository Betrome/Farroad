class_name UnitFilter
extends RefCounted
## Filter + sort for lists of owned units (the Party tab's rosters and the
## Units tab's unit picker). Ian: "filter and sort for units, including
## physical or magic focus." One setting shared by both screens for the
## session.

const FOCUS_OPTIONS := [["any", "Any focus"], ["physical", "Physical"], ["magic", "Magic"], ["hybrid", "Balanced"]]
const RARITY_OPTIONS := [["any", "Any rarity"], ["common", "Common"], ["rare", "Rare"], ["legendary", "Legendary"]]
const SORT_OPTIONS := [["default", "Default order"], ["alpha", "Sort: A–Z"], ["level", "Sort: Level"],
	["rarity", "Sort: Rarity"], ["atk", "Sort: ATK"], ["mag", "Sort: MAG"], ["spd", "Sort: SPD"]]
const RARITY_RANK := {"common": 0, "rare": 1, "legendary": 2}
## A unit leans physical/magic when that stat is at least this much higher.
const FOCUS_GAP := 1.15

static var focus: String = "any"
static var rarity: String = "any"
static var sort_mode: String = "default"

## "physical", "magic" or "hybrid" from the unit's stats at level 100 (the
## same yardstick the titles use).
static func focus_of(uid: String) -> String:
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return "hybrid"
	var st: Dictionary = FarroadProgression.stats_at(uid, def["stats"], float(def["hp"]), 100)
	var a: float = float(st["atk"])
	var m: float = float(st["mag"])
	if a >= m * FOCUS_GAP:
		return "physical"
	if m >= a * FOCUS_GAP:
		return "magic"
	return "hybrid"

static func controls(on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()   # one line (Ian)
	row.add_theme_constant_override("separation", 6)
	row.add_child(ActionFilter.dropdown(FOCUS_OPTIONS, focus, func(v):
		focus = v
		on_change.call()))
	row.add_child(ActionFilter.dropdown(RARITY_OPTIONS, rarity, func(v):
		rarity = v
		on_change.call()))
	row.add_child(ActionFilter.dropdown(SORT_OPTIONS, sort_mode, func(v):
		sort_mode = v
		on_change.call()))
	return row

## `uids` filtered and ordered; ids in `keep` always stay (e.g. the
## currently selected unit).
static func apply(g: Dictionary, uids: Array, keep: Array = []) -> Array:
	var out: Array = uids.filter(func(uid):
		if keep.has(uid):
			return true
		var def = FarroadCore.roster_by_id(uid)
		if def == null:
			return true
		if rarity != "any" and str(def.get("rarity", "common")) != rarity:
			return false
		return focus == "any" or focus_of(uid) == focus)
	if sort_mode == "default":
		return out
	var key_of := func(uid: String) -> float:
		var def = FarroadCore.roster_by_id(uid)
		if def == null:
			return 0.0
		match sort_mode:
			"level": return float(FarroadProgression.level_of(g, uid))
			"rarity": return float(RARITY_RANK.get(str(def.get("rarity", "common")), 0))
			"atk", "mag", "spd":
				return float(FarroadProgression.stats_at(uid, def["stats"], float(def["hp"]), FarroadProgression.level_of(g, uid))[sort_mode])
		return 0.0
	var name_of := func(uid: String) -> String:
		var def = FarroadCore.roster_by_id(uid)
		return str(def["name"]).to_lower() if def else uid
	out.sort_custom(func(x, y):
		if sort_mode != "alpha":
			var kx: float = key_of.call(x)
			var ky: float = key_of.call(y)
			if kx != ky:
				return kx > ky
		return name_of.call(x) < name_of.call(y))
	return out

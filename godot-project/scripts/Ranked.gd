class_name Ranked
extends RefCounted
## Ranked PvP, shared by the game and the PvP server (Ian: option 2 -- the
## Godot game itself runs headless on a server and decides every fight).
##
## A ranked team is uploaded as BUILD INPUTS, never as finished stats: unit
## ids, levels, gear, Aether investments, gambits, Lore, and the main
## character's creation points. The server rebuilds the units from those
## with the game's own formulas (FarroadProgression.build_party_unit), so a
## team with edited stats simply can't exist. A fight is then run from the
## two teams and a seed the server picks; the game replays the very same
## fight from the same inputs (FarroadCore is deterministic for a given
## seed), so what the player watches is what the server decided.

## Bump when the team format or the fight rules change in a way that would
## make an older game replay a fight differently.
const PROTOCOL := 2
const MAX_UNITS := 5
const MAX_LEVEL := 5000
const MAX_LORE_STACKS := 99
const MAX_INVEST_STEPS := 200
## Turns before a fight that hasn't ended counts as a loss for the attacker.
const TURN_LIMIT := 3000

## The game build a fight belongs to: the version plus a fingerprint of the
## content (actions, units, gear...). Server and game must match exactly, or
## the same seed could play out differently.
static var _version_cache: String = ""
static func game_version() -> String:
	if _version_cache != "":
		return _version_cache
	var content := ""
	var f := FileAccess.open("res://data/content.json", FileAccess.READ)
	if f != null:
		content = f.get_as_text()
		f.close()
	_version_cache = "%s-p%d-%08x" % [str(ProjectSettings.get_setting("application/config/version", "0")),
		PROTOCOL, absi(content.hash())]
	return _version_cache

## ===== the main character's creation points =====

## The points the main character was made with. Saves from before points
## were stored get them worked back out from the stats (each stat is a
## straight line in its points, so this is exact when the stats are real).
static func mc_points_of(mc: Dictionary) -> Dictionary:
	if mc.get("points") is Dictionary:
		return (mc["points"] as Dictionary).duplicate()
	var pts := {}
	for k in FarroadProgression.MC_STAT_KEYS:
		var rng: Array = FarroadProgression.MC_STAT_RANGE[k]
		var v: float = float(mc["hp"]) if k == "hp" else float(mc["stats"].get(k, rng[0]))
		pts[k] = clampi(roundi((v - rng[0]) / (rng[1] - rng[0]) * FarroadProgression.MC_POINT_MAX), 0, FarroadProgression.MC_POINT_MAX)
	return pts

## Characters made before creation points were kept (and before some stat
## ranges changed) can't be rebuilt from points: their stats go up as they
## are ("legacy"). The server accepts them only within these generous
## bounds and only unchanged from the first time it saw them.
const LEGACY_STAT_CAP := {"atk": 60.0, "mag": 60.0, "def": 90.0, "res": 80.0, "spd": 140.0}
const LEGACY_HP_CAP := 1700.0
const LEGACY_GROWTH_CAP := {"atk": 5.5, "mag": 5.5, "def": 5.0, "res": 3.5, "spd": 3.5, "hp": 70.0}

## True when these points rebuild exactly the character's saved stats.
static func _points_match(mc: Dictionary, pts: Dictionary) -> bool:
	var built := FarroadProgression.mc_build_stats(pts)
	if float(built["hp"]) != float(mc.get("hp", -1)):
		return false
	for k in built["stats"]:
		if float(built["stats"][k]) != float(mc["stats"].get(k, -1)):
			return false
	for k in built["growth"]:
		if absf(float(built["growth"][k]) - float(mc.get("growth", {}).get(k, -1))) > 0.001:
			return false
	return true

## ===== uploading =====

## The player's fielded party as a ranked team (build inputs only).
static func team_from_game(g: Dictionary) -> Dictionary:
	var units: Array = []
	var used := {}
	for uid in g["party"]:
		var slots: Array = FarroadProgression.ensure_loadout(g, uid).map(func(s): return {"cond": s["cond"], "action": s["action"]})
		for s in slots:
			used[s["action"]] = true
		var def = FarroadCore.roster_by_id(uid)
		var ch = def.get("chargeAction") if def else null
		if ch != null:
			used[ch] = true
		units.append({"id": uid, "level": FarroadProgression.level_of(g, uid),
			"equipped": (g.get("equipped", {}).get(uid, {}) as Dictionary).duplicate(),
			"statInvest": (g.get("statInvest", {}).get(uid, {}) as Dictionary).duplicate(),
			"affinities": (g.get("affinities", {}).get(uid, {}) as Dictionary).duplicate(),
			"slots": slots, "row": str((g.get("rows", {}) as Dictionary).get(uid, def.get("row", "front") if def else "front")),
			"look": Appearance.look(g, uid)})
	var bonuses := {}
	for aid in used:
		var b = (g.get("bonuses", {}) as Dictionary).get(aid)
		if b is Dictionary and not b.is_empty():
			bonuses[aid] = (b as Dictionary).duplicate()
	var team := {"v": 2, "game": game_version(), "units": units, "bonuses": bonuses}
	if g.get("mc") != null:
		var mc: Dictionary = g["mc"]
		team["mc"] = {"name": str(mc.get("name", "Traveler")), "chargeAction": str(mc.get("chargeAction", "heavystrike"))}
		var pts := mc_points_of(mc)
		if mc.get("points") is Dictionary or _points_match(mc, pts):
			team["mc"]["points"] = pts
		else:
			team["mc"]["legacy"] = {"stats": (mc["stats"] as Dictionary).duplicate(), "hp": float(mc["hp"]),
				"growth": (mc.get("growth", {}) as Dictionary).duplicate()}
	return team

## The ranked team from a cloud save (on the server: the Arena team always
## comes from the player's last accepted save, so it can't differ from
## their real game). Works on the save's own fields, on a copy.
static func team_from_save(snap: Dictionary) -> Dictionary:
	var sg: Dictionary = snap.duplicate(true)
	for k in ["loadout", "lvl", "equipped", "statInvest", "affinities", "bonuses", "rows", "appearance"]:
		if not (sg.get(k) is Dictionary):
			sg[k] = {}
	for k in ["party", "actions", "conditions"]:
		if not (sg.get(k) is Array):
			sg[k] = []
	if (sg["party"] as Array).is_empty():
		return {}
	return team_from_game(sg)

## ===== checking (the server's anti-cheat; the game uses it too) =====

static func _is_whole(v, lo: int, hi: int) -> bool:
	return (v is int or v is float) and float(v) == floor(float(v)) and int(v) >= lo and int(v) <= hi

## "" if the team is something the game could have produced, else why not.
static func validate(team) -> String:
	if not (team is Dictionary) or int(team.get("v", 0)) != 2:
		return "bad_format"
	if str(team.get("game", "")) != game_version():
		return "wrong_version"
	var units = team.get("units")
	if not (units is Array) or units.is_empty() or units.size() > MAX_UNITS:
		return "bad_party_size"
	var seen := {}
	var held := {}
	for u in units:
		if not (u is Dictionary):
			return "bad_unit"
		var uid := str(u.get("id", ""))
		var def = FarroadCore.roster_by_id(uid)
		if def == null or seen.has(uid):
			return "bad_unit"
		seen[uid] = true
		if not _is_whole(u.get("level"), 1, MAX_LEVEL):
			return "bad_level"
		var lvl := int(u["level"])
		var slots = u.get("slots")
		if not (slots is Array) or slots.is_empty() or slots.size() > FarroadProgression.slots_at(lvl):
			return "bad_slots"
		for s in slots:
			if not (s is Dictionary):
				return "bad_slots"
			var aid := str(s.get("action", ""))
			var cid := str(s.get("cond", ""))
			if not FarroadCore.equippable().has(aid):
				return "bad_action"
			if cid != "none" and not FarroadCore.ALL_CONDITION_IDS.has(cid):
				return "bad_gambit"
			# units can't share an action, apart from the starters
			if not FarroadProgression.STARTER_ACTIONS.has(aid):
				if held.has(aid) and held[aid] != uid:
					return "shared_action"
				held[aid] = uid
		var eq = u.get("equipped", {})
		if not (eq is Dictionary):
			return "bad_gear"
		for slot in eq:
			var item = FarroadCore.EQUIPMENT.get(str(eq[slot]))
			if not FarroadCore.EQUIPMENT_SLOTS.has(str(slot)) or item == null or item["slot"] != FarroadProgression.equip_kind_for_slot(str(slot)):
				return "bad_gear"
		var inv = u.get("statInvest", {})
		if not (inv is Dictionary):
			return "bad_invest"
		for k in inv:
			if not FarroadProgression.PCT_STAT_KEYS.has(str(k)) or not _is_whole(inv[k], 0, MAX_INVEST_STEPS):
				return "bad_invest"
		var aff = u.get("affinities", {})
		if not (aff is Dictionary):
			return "bad_affinity"
		for k in aff:
			if not FarroadProgression.AFFINITY_AXES.has(str(k)) or not _is_whole(aff[k], 0, MAX_INVEST_STEPS):
				return "bad_affinity"
		if not (str(u.get("row", "front")) in ["front", "back"]):
			return "bad_row"
	if seen.has("kesh"):
		var mc = team.get("mc")
		if not (mc is Dictionary):
			return "bad_mc"
		if mc.get("points") is Dictionary:
			var spent := 0
			for k in FarroadProgression.MC_STAT_KEYS:
				var p = mc["points"].get(k)
				if not _is_whole(p, FarroadProgression.MC_POINT_MIN, FarroadProgression.MC_POINT_MAX):
					return "bad_mc"
				spent += int(p)
			if spent != FarroadProgression.MC_POINTS_TOTAL:
				return "bad_mc"
		elif mc.get("legacy") is Dictionary:
			var lg: Dictionary = mc["legacy"]
			if not (lg.get("stats") is Dictionary) or not (lg.get("growth") is Dictionary):
				return "bad_mc"
			for k in LEGACY_STAT_CAP:
				var v = lg["stats"].get(k)
				if not (v is float or v is int) or float(v) < 1.0 or float(v) > LEGACY_STAT_CAP[k]:
					return "bad_mc"
			for k in LEGACY_GROWTH_CAP:
				var v = lg["growth"].get(k)
				if not (v is float or v is int) or float(v) < 0.0 or float(v) > LEGACY_GROWTH_CAP[k]:
					return "bad_mc"
			var hp = lg.get("hp")
			if not (hp is float or hp is int) or float(hp) < 1.0 or float(hp) > LEGACY_HP_CAP:
				return "bad_mc"
		else:
			return "bad_mc"
		if not FarroadCore.CHARGE_ACTIONS.has(str(mc.get("chargeAction", ""))):
			return "bad_mc"
	var bonuses = team.get("bonuses", {})
	if not (bonuses is Dictionary):
		return "bad_lore"
	for aid in bonuses:
		var act = FarroadCore.CLEAN_ACTIONS.get(str(aid))
		if act == null or not (bonuses[aid] is Dictionary):
			return "bad_lore"
		for bid in bonuses[aid]:
			if not FarroadCore.BONUSES.has(str(bid)) or not _is_whole(bonuses[aid][bid], 0, MAX_LORE_STACKS):
				return "bad_lore"
			if int(bonuses[aid][bid]) > 0 and not FarroadCore.bonus_applies(act, str(bid)):
				return "bad_lore"
			if str(bid) == "broad" and int(bonuses[aid][bid]) > 1:
				return "bad_lore"
	return ""

## ===== building the fight =====

## A throwaway game holding just what build_party_unit reads for this team.
static func _team_game(team: Dictionary) -> Dictionary:
	var tg := {"lvl": {}, "statInvest": {}, "affinities": {}, "equipped": {}, "loadout": {}, "touched": {},
		"hpCarry": {}, "chargeCarry": {}, "recovery": {}, "party": [], "mc": null,
		"actions": FarroadCore.equippable().duplicate(), "conditions": FarroadCore.ALL_CONDITION_IDS.duplicate()}
	for u in team["units"]:
		var uid := str(u["id"])
		tg["party"].append(uid)
		tg["lvl"][uid] = int(u["level"])
		tg["statInvest"][uid] = (u.get("statInvest", {}) as Dictionary).duplicate()
		tg["affinities"][uid] = (u.get("affinities", {}) as Dictionary).duplicate()
		tg["equipped"][uid] = (u.get("equipped", {}) as Dictionary).duplicate()
		tg["loadout"][uid] = (u["slots"] as Array).map(func(s): return {"cond": str(s["cond"]), "action": str(s["action"])})
		tg["touched"][uid] = true
	var mc = team.get("mc")
	if mc is Dictionary and mc.get("legacy") is Dictionary:
		var lg: Dictionary = mc["legacy"]
		tg["mc"] = {"name": str(mc.get("name", "Traveler")), "stats": (lg["stats"] as Dictionary).duplicate(),
			"hp": float(lg["hp"]), "growth": (lg["growth"] as Dictionary).duplicate(),
			"chargeAction": str(mc.get("chargeAction", "heavystrike")), "acquiredCharges": [str(mc.get("chargeAction", "heavystrike"))]}
	elif mc is Dictionary and mc.get("points") is Dictionary:
		var built := FarroadProgression.mc_build_stats(mc["points"])
		tg["mc"] = {"name": str(mc.get("name", "Traveler")), "stats": built["stats"], "hp": built["hp"],
			"growth": built["growth"], "chargeAction": str(mc.get("chargeAction", "heavystrike")),
			"acquiredCharges": [str(mc.get("chargeAction", "heavystrike"))]}
	return tg

## The team's units, built with the game's own formulas. The main
## character's roster entry is borrowed for the build and put back after.
static func build_units(team: Dictionary) -> Array:
	var tg := _team_game(team)
	var kesh = FarroadCore.roster_by_id("kesh")
	var kesh_saved: Dictionary = (kesh as Dictionary).duplicate(true) if kesh != null else {}
	var growth_saved: Dictionary = (FarroadProgression.GROWTH.get("kesh", {}) as Dictionary).duplicate()
	var rows_saved := {}
	for u in team["units"]:
		var d = FarroadCore.roster_by_id(str(u["id"]))
		rows_saved[str(u["id"])] = d.get("row")
		d["row"] = str(u.get("row", "front"))
	FarroadProgression.apply_custom_mc(tg)
	var out: Array = []
	for i in tg["party"].size():
		out.append(FarroadProgression.build_party_unit(tg, tg["party"][i], i))
	if kesh != null:
		kesh.clear()
		kesh.merge(kesh_saved)
		FarroadProgression.GROWTH["kesh"] = growth_saved
	for uid in rows_saved:
		FarroadCore.roster_by_id(uid)["row"] = rows_saved[uid]
	return out

## Power for a ranked team (the same yardstick as the Arena's rivals).
static func power_of(team: Dictionary) -> int:
	var tg := _team_game(team)
	var kesh = FarroadCore.roster_by_id("kesh")
	var kesh_saved: Dictionary = (kesh as Dictionary).duplicate(true) if kesh != null else {}
	var growth_saved: Dictionary = (FarroadProgression.GROWTH.get("kesh", {}) as Dictionary).duplicate()
	FarroadProgression.apply_custom_mc(tg)
	var total := 0.0
	for uid in tg["party"]:
		total += FarroadProgression.unit_power_stats(tg, uid)
	if kesh != null:
		kesh.clear()
		kesh.merge(kesh_saved)
		FarroadProgression.GROWTH["kesh"] = growth_saved
	return maxi(1, roundi(total / FarroadProgression.POWER_STAT_DIVISOR))

## The fight between `attacker` (the player's side) and `defender`, ready to
## step. Afterwards call end_battle() so every action is put back as it was.
## The attacker's Lore goes on the real actions, the defender's on copies,
## exactly as an Arena fight already does.
## The wave a fight is scaled at (damage depends on it through the defence
## constant): the average level of every unit in it, so both sides and the
## server always agree, whatever wave the player happens to be on.
static func fight_wave(attacker: Dictionary, defender: Dictionary) -> int:
	var total := 0
	var n := 0
	for t in [attacker, defender]:
		for u in t["units"]:
			total += int(u["level"])
			n += 1
	return clampi(roundi(float(total) / maxf(1.0, float(n))), 1, MAX_LEVEL)

static func build_battle(attacker: Dictionary, defender: Dictionary, seed: int) -> Dictionary:
	FarroadCore.set_wave(fight_wave(attacker, defender))
	FarroadCore.apply_bonuses(attacker.get("bonuses", {}))
	var party := build_units(attacker)
	var foe_units := build_units(defender)
	var enemies := _as_opponents(foe_units, defender, party)
	var b := FarroadCore.make_battle(party + enemies, {"rng": FarroadCore.make_rng(seed), "enrage": true})
	b["enrageAll"] = true
	b["healDecay"] = PvP.HEAL_DECAY
	b["enrageAfter"] = PvP.ENRAGE_AFTER
	b["enragePct"] = PvP.ENRAGE_PCT
	b["ranked"] = true   # the game replays it without the player's live controls
	return b

## Puts every action back: drops the defender's copies and restores
## `own_bonuses` (the player's Lore in the game; {} on the server).
static func end_battle(own_bonuses: Dictionary) -> void:
	PvP.clear_actions()
	FarroadCore.apply_bonuses(own_bonuses)

## The defender's built units as an Arena opponent: their Lore on "pvp:"
## copies of the actions, names kept apart from the attacker's.
static func _as_opponents(units: Array, defender: Dictionary, party: Array) -> Array:
	var shell := {"party": []}
	var team := {"bonuses": defender.get("bonuses", {}), "units": []}
	for i in units.size():
		var u: Dictionary = units[i]
		team["units"].append({"id": str(u["id"]), "name": str(u["name"]), "level": int(u["level"]),
			"stats": (u["base"] as Dictionary).duplicate(), "maxHp": float(u["maxHp"]), "row": u.get("row"),
			"affinity": (u["affinity"] as Dictionary).duplicate(), "slots": u["slots"],
			"chargeAction": u.get("chargeAction"), "look": (defender["units"][i] as Dictionary).get("look", {})})
	var opp := PvP.build_opponent(shell, team)
	# names already on the attacker's side get told apart
	var taken := {}
	for p in party:
		taken[str(p["name"])] = true
	for o in opp:
		var nm := str(o["name"])
		if taken.has(nm):
			nm = "Rival " + nm
		while taken.has(nm):
			nm += "'"
		taken[nm] = true
		o["name"] = nm
	return opp

## Runs the whole fight at once (the server's judgement). true = the
## attacker won; a fight that hits the turn limit is a loss.
static func simulate(attacker: Dictionary, defender: Dictionary, seed: int) -> Dictionary:
	var saved_wave: int = FarroadCore.current_wave
	var b := build_battle(attacker, defender, seed)
	var turns := 0
	while b["over"] == null and turns < TURN_LIMIT:
		if FarroadCore.step(b) == null:
			break
		turns += 1
	var won: bool = b["over"] == "party"
	end_battle({})
	FarroadCore.set_wave(saved_wave)
	return {"won": won, "turns": turns}

## ===== rating =====
const START_RATING := 1000
const K_FACTOR := 32.0

## New ratings after `a` beat (or lost to) `b`.
static func elo(a: float, b: float, a_won: bool) -> Array:
	var ea: float = 1.0 / (1.0 + pow(10.0, (b - a) / 400.0))
	var sa: float = 1.0 if a_won else 0.0
	var na: float = a + K_FACTOR * (sa - ea)
	var nb: float = b + K_FACTOR * ((1.0 - sa) - (1.0 - ea))
	return [roundi(na), roundi(nb)]

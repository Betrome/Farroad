class_name PvP
extends RefCounted
## Ian: PvP to give something shareable some interactivity. First version:
## share codes and bragging rights. A player's fielded team (levels, gear,
## gambits, affinities, Lore on the actions it uses, and the MC's look)
## packs into a text code; anyone pastes it and fights that team, with the
## game's own AI running both sides. No server yet, so a code can be edited
## and wins pay nothing; a server can verify the same codes later.
##
## Code: PREFIX + "<json byte size>.<deflated json, base64url>.<check>".
## The check only catches a code mangled in copy/paste, not tampering.

const PREFIX := "FARROAD-PVP1."
const MAX_UNITS := 5
const MAX_STAT := 10000000.0
const HISTORY_CAP := 20
const ID_PREFIX := "pvp:"   # opponent units, and their Lore'd action copies

## The fielded team as a share code.
static func export_code(g: Dictionary) -> String:
	var units: Array = []
	var used := {}
	for i in (g["party"] as Array).size():
		var uid: String = g["party"][i]
		var u := FarroadProgression.build_party_unit(g, uid, i)
		units.append({"id": uid, "name": u["name"], "level": u["level"], "stats": u["base"],
			"maxHp": u["maxHp"], "affinity": u["affinity"], "slots": u["slots"],
			"chargeAction": u["chargeAction"], "row": u["row"], "look": Appearance.look(g, uid)})
		for s in u["slots"]:
			used[s["action"]] = true
		if u["chargeAction"] != null:
			used[u["chargeAction"]] = true
	var bonuses := {}
	for aid in used:
		var b = (g.get("bonuses", {}) as Dictionary).get(aid)
		if b is Dictionary and not b.is_empty():
			bonuses[aid] = b
	var owner = FarroadCore.roster_by_id("kesh")
	var team := {"v": 1, "owner": owner["name"] if owner else "Traveler",
		"power": FarroadProgression.party_power(g), "units": units, "bonuses": bonuses}
	var json := JSON.stringify(team)
	var raw := json.to_utf8_buffer()
	var packed := Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_DEFLATE))
	packed = packed.replace("+", "-").replace("/", "_").replace("=", "")
	return "%s%d.%s.%s" % [PREFIX, raw.size(), packed, _check(json)]

static func _check(json: String) -> String:
	return "%04x" % (absi(json.hash()) % 65536)

## A pasted code -> {"team": {...}} or {"error": "why"}.
static func import_code(text: String) -> Dictionary:
	var code := text.strip_edges().replace("\n", "").replace(" ", "")
	if not code.begins_with(PREFIX):
		return {"error": "That isn't a Farroad team code."}
	var parts := code.substr(PREFIX.length()).split(".")
	if parts.size() != 3 or not parts[0].is_valid_int():
		return {"error": "The code looks cut off. Copy the whole thing."}
	var b64 := parts[1].replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var size := int(parts[0])
	if size <= 0 or size > 200000:
		return {"error": "The code looks damaged."}
	var raw := Marshalls.base64_to_raw(b64).decompress(size, FileAccess.COMPRESSION_DEFLATE)
	var json := raw.get_string_from_utf8()
	if raw.size() != size or _check(json) != parts[2]:
		return {"error": "The code looks damaged. Copy it again."}
	var team = JSON.parse_string(json)
	var err := _validate(team)
	if err != "":
		return {"error": err}
	return {"team": team}

## Enough checking that a bad or edited code can't break the game.
static func _validate(team) -> String:
	if not (team is Dictionary) or int(team.get("v", 0)) != 1:
		return "This code is from a different version of the game."
	var units = team.get("units")
	if not (units is Array) or units.is_empty() or units.size() > MAX_UNITS:
		return "The code's team is empty or too big."
	for u in units:
		if not (u is Dictionary) or FarroadCore.roster_by_id(str(u.get("id", ""))) == null:
			return "The code has a unit this game doesn't know."
		if not (u.get("stats") is Dictionary) or not (u.get("slots") is Array) or (u["slots"] as Array).is_empty():
			return "The code's team is incomplete."
		for k in u["stats"]:
			if not (u["stats"][k] is float or u["stats"][k] is int) or absf(float(u["stats"][k])) > MAX_STAT:
				return "The code's stats don't look right."
		for s in u["slots"]:
			if not (s is Dictionary) or not FarroadCore.ACTIONS.has(str(s.get("action", ""))):
				return "The code has an action this game doesn't know."
			var c := str(s.get("cond", ""))
			if c != "none" and not FarroadCore.ALL_CONDITION_IDS.has(c):
				return "The code has a gambit this game doesn't know."
		var ch = u.get("chargeAction")
		if ch != null and not FarroadCore.ACTIONS.has(str(ch)):
			return "The code has an action this game doesn't know."
	var bonuses = team.get("bonuses", {})
	if not (bonuses is Dictionary):
		return "The code's Lore doesn't look right."
	for aid in bonuses:
		if not FarroadCore.ACTIONS.has(aid) or not (bonuses[aid] is Dictionary):
			return "The code's Lore doesn't look right."
		for bid in bonuses[aid]:
			var n = bonuses[aid][bid]
			if not FarroadCore.BONUSES.has(bid) or not (n is float or n is int) or n < 0 or n > 999:
				return "The code's Lore doesn't look right."
	return ""

## One line about a team: "Betrome's team - Power 103: Betrome, Dorrek".
static func describe(team: Dictionary) -> String:
	var names: Array = (team["units"] as Array).map(func(u): return str(u.get("name", "?")))
	return "%s's team - Power %d: %s" % [str(team.get("owner", "?")), int(team.get("power", 0)), ", ".join(names)]

## The opponent's units for a fight against `g`'s party. Their Lore lives on
## copies of their actions ("pvp:<id>"), so it never touches the player's.
static func build_opponent(g: Dictionary, team: Dictionary) -> Array:
	clear_actions()
	var bonuses: Dictionary = team.get("bonuses", {})
	var remap := {}
	if not bonuses.is_empty():
		# apply the opponent's Lore to clean copies (from the content as
		# loaded), then put every action back exactly as it was, so none of
		# it can leak into the player's own actions
		var acts: Dictionary = FarroadCore.ACTIONS
		var before := {}
		for aid in acts:
			before[aid] = (acts[aid] as Dictionary).duplicate(true)
		var originals := {}
		for aid in bonuses:
			originals[aid] = acts[aid]
			acts[aid] = (FarroadCore.CLEAN_ACTIONS.get(aid, acts[aid]) as Dictionary).duplicate(true)
		FarroadCore.apply_bonuses(bonuses)
		var copies := {}
		for aid in bonuses:
			var copy: Dictionary = (acts[aid] as Dictionary).duplicate(true)
			copy["id"] = ID_PREFIX + aid
			copies[ID_PREFIX + aid] = copy
			remap[aid] = ID_PREFIX + aid
		for aid in originals:
			acts[aid] = originals[aid]
		for aid in before:
			if not originals.has(aid):
				(acts[aid] as Dictionary).clear()
				(acts[aid] as Dictionary).merge(before[aid])
		acts.merge(copies)
	var taken := {}
	for uid in g["party"]:
		var d = FarroadCore.roster_by_id(uid)
		if d:
			taken[d["name"]] = true
	var out: Array = []
	var units: Array = team["units"]
	for i in units.size():
		var u: Dictionary = units[i]
		var name := str(u.get("name", "Rival"))
		if taken.has(name):
			name = "Rival " + name
		while taken.has(name):
			name += "'"
		taken[name] = true
		var slots: Array = (u["slots"] as Array).map(func(s):
			return {"cond": str(s.get("cond", "none")), "action": remap.get(str(s["action"]), str(s["action"]))})
		var ch = u.get("chargeAction")
		var mh := float(u.get("maxHp", u["stats"].get("hp", 100.0)))
		var unit := FarroadCore.make_unit({"id": ID_PREFIX + str(u["id"]) + str(i), "name": name,
			"isParty": false, "level": int(u.get("level", 1)), "slotIndex": i, "stats": u["stats"],
			"maxHp": mh, "hp": mh, "row": u.get("row"), "affinity": u.get("affinity", {}),
			"chargeAction": remap.get(str(ch), str(ch)) if ch != null else null, "slots": slots})
		unit["pvp"] = true
		unit["look"] = u.get("look", {"body": "male", "colors": {}})
		out.append(unit)
	return out

## Drops the opponent's action copies once a fight is over.
static func clear_actions() -> void:
	for aid in FarroadCore.ACTIONS.keys():
		if str(aid).begins_with(ID_PREFIX):
			FarroadCore.ACTIONS.erase(aid)

## Win/loss record (g["pvp"]).
static func record(g: Dictionary, won: bool, team_owner: String, their_power: int, turns: int, now: int) -> void:
	if not (g.get("pvp") is Dictionary):
		g["pvp"] = {"wins": 0, "losses": 0, "history": []}
	var r: Dictionary = g["pvp"]
	r["wins" if won else "losses"] = int(r.get("wins" if won else "losses", 0)) + 1
	var h: Array = r.get("history", [])
	h.push_front({"owner": team_owner, "won": won, "power": their_power,
		"myPower": FarroadProgression.party_power(g), "turns": turns, "at": now})
	r["history"] = h.slice(0, HISTORY_CAP)

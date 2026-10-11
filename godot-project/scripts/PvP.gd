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
const ID_PREFIX := "pvp:"
## Ian: in PvP only, healing (heals, regen, lifesteal) shrinks gradually
## as enrage rises -- 1/(1 + enrage), so half at +100% enrage, but never
## zero, so healers stay useful.
const HEAL_DECAY := "inverse"
## Ian: PvP fights should last no more than a minute -- both teams enrage
## from the first turn, 5% per turn (normal fights: 2.5% from turn 20).
const ENRAGE_AFTER := 0
const ENRAGE_PCT := 0.05   # opponent units, and their Lore'd action copies

## Ian: ready-made rival teams in the Arena, at varying power and styles,
## for anyone to fight without a code. Each is built like a shared team:
## roster units at a level (stats from the same growth table), their own
## charge actions, gambits from the player pool (no action twice in a team)
## and some Lore. `wave` sets the Power shown, as a player's farthest does.
const RIVALS := [
	{"id": "rookies", "name": "Roadside Rookies", "level": 8, "wave": 30,
		"blurb": "A fresh crew off the road: straightforward hitters and one healer.",
		"units": [
			{"id": "tovan", "slots": [["foe_lowest_hp", "cinderstrike"], ["none", "strike"]]},
			{"id": "wren", "slots": [["foe_hp_lte_30", "quickslash"], ["none", "strike"]]},
			{"id": "ilse", "slots": [["ally_hp_lte_50", "mend"], ["none", "waterjet"]]}],
		"lore": {}},
	{"id": "ironwall", "name": "The Iron Wall", "level": 15, "wave": 50,
		"blurb": "Tanks behind shields and a healer: slow, but very hard to break.",
		"units": [
			{"id": "dorrek", "slots": [["self_hp_lte_50", "ironwall"], ["foe_lacks_debuff", "guardbreak"], ["none", "shieldbash"]]},
			{"id": "garrow", "slots": [["self_first_turn", "brace"], ["foe_lacks_debuff", "bulwarkslam"], ["none", "rockfist"]]},
			{"id": "ansa", "slots": [["ally_hp_lte_50", "greatermend"], ["ally_lacks_buff", "bulwark"], ["none", "lightbolt"]]}],
		"lore": {"shieldbash": {"potent": 2}, "greatermend": {"potent": 2}}},
	{"id": "glasscannons", "name": "Glass Cannons", "level": 22, "wave": 80,
		"blurb": "All-out magic from the back row: devastating if left alone, fragile once reached.",
		"units": [
			{"id": "mirel", "slots": [["foe_2plus", "tempest"], ["foe_lacks_debuff", "sear"], ["none", "firebrand"]]},
			{"id": "sael", "slots": [["foe_2plus", "gale"], ["foe_lowest_hp", "zephyrbolt"], ["none", "windbolt"]]},
			{"id": "lumen", "slots": [["ally_hp_lte_50", "massmend"], ["foe_lowest_hp", "sunlance"], ["none", "lightbolt"]]}],
		"lore": {"tempest": {"potent": 3}, "firebrand": {"potent": 2}, "sunlance": {"potent": 2}}},
	{"id": "venomcourt", "name": "The Venom Court", "level": 30, "wave": 110,
		"blurb": "Poison, curses and confusion: wins slowly by wearing you down.",
		"units": [
			{"id": "vesh", "slots": [["foe_lacks_debuff", "viperfang"], ["foe_hp_lte_30", "execute"], ["none", "shadecut"]]},
			{"id": "vey", "slots": [["foe_lacks_debuff", "venomstrike"], ["foe_fast", "pindown"], ["none", "strike"]]},
			{"id": "nyra", "slots": [["foe_lacks_debuff", "curse"], ["foe_most_dangerous", "bewilder"], ["none", "umbralbolt"]]},
			{"id": "ilse", "slots": [["foe_lacks_debuff", "smother"], ["ally_lacks_buff", "rejuvenate"], ["none", "waterjet"]]}],
		"lore": {"viperfang": {"lasting": 2}, "curse": {"deepening": 2}, "venomstrike": {"lasting": 1}}},
	{"id": "stormriders", "name": "Storm Riders", "level": 45, "wave": 160,
		"blurb": "Speed above all: hasted, relentless, striking before you can move.",
		"units": [
			{"id": "zephyra", "slots": [["foe_lowest_hp", "blitz"], ["foe_hp_lte_50", "lightningstep"], ["none", "quickslash"]]},
			{"id": "skarn", "slots": [["self_first_turn", "rally"], ["foe_hp_lte_30", "execute"], ["none", "gustslash"]]},
			{"id": "wren", "slots": [["foe_lacks_debuff", "hamstring"], ["foe_lowest_hp", "tempestedge"], ["none", "squallstrike"]]},
			{"id": "sael", "slots": [["ally_lacks_buff", "haste"], ["foe_2plus", "stormfront"], ["none", "windbolt"]]}],
		"lore": {"blitz": {"swift": 3, "potent": 2}, "tempestedge": {"potent": 2}, "haste": {"lasting": 2}}},
	{"id": "legends", "name": "The Legends", "level": 60, "wave": 230,
		"blurb": "Five legendary heroes at the top of their game. The ultimate test.",
		"units": [
			{"id": "kaldor", "slots": [["foe_hp_lte_30", "execute"], ["foe_lacks_debuff", "crushingblow"], ["none", "infernocleaver"]]},
			{"id": "bastian", "slots": [["self_hp_lte_50", "ironwall"], ["foe_most_dangerous", "fortresscrush"], ["none", "shieldbash"]]},
			{"id": "sorin", "slots": [["foe_lowest_hp", "shadowrend"], ["foe_weak_light", "dawnblade"], ["none", "stoneshatter"]]},
			{"id": "seraphine", "slots": [["foe_2plus", "stormfront"], ["foe_lowest_hp", "solarflare"], ["none", "abyssalruin"]]},
			{"id": "morwen", "slots": [["ally_hp_lte_50", "radiantmend"], ["foe_lacks_debuff", "curse"], ["none", "sanctumray"]]}],
		"lore": {"infernocleaver": {"potent": 5, "piercing": 2}, "solarflare": {"potent": 5},
			"radiantmend": {"potent": 3, "cleansing": 2}, "shadowrend": {"potent": 3}}},
	# Ian: a Power ~1000 team for players to test their builds against. The
	# Legends line-up at levels 103-106 adds up to exactly 1000.
	{"id": "proving", "name": "The Proving Ground", "level": 104, "wave": 330, "rating": 1400,
		"blurb": "A Power 1000 team to test your build against.",
		"units": [
			{"id": "kaldor", "level": 103, "slots": [["foe_hp_lte_30", "execute"], ["foe_lacks_debuff", "crushingblow"], ["none", "infernocleaver"]]},
			{"id": "bastian", "level": 104, "slots": [["self_hp_lte_50", "ironwall"], ["foe_most_dangerous", "fortresscrush"], ["none", "shieldbash"]]},
			{"id": "sorin", "level": 105, "slots": [["foe_lowest_hp", "shadowrend"], ["foe_weak_light", "dawnblade"], ["none", "stoneshatter"]]},
			{"id": "seraphine", "level": 104, "slots": [["foe_2plus", "stormfront"], ["foe_lowest_hp", "solarflare"], ["none", "abyssalruin"]]},
			{"id": "morwen", "level": 106, "slots": [["ally_hp_lte_50", "radiantmend"], ["foe_lacks_debuff", "curse"], ["none", "sanctumray"]]}],
		"lore": {"infernocleaver": {"potent": 5, "piercing": 2}, "solarflare": {"potent": 5},
			"radiantmend": {"potent": 3, "cleansing": 2}, "shadowrend": {"potent": 3}}},
]

static func rival(id: String) -> Dictionary:
	for r in RIVALS:
		if r["id"] == id:
			return r
	return {}

## A rival as a team, the same shape a share code imports to.
static func rival_team(r: Dictionary) -> Dictionary:
	var units: Array = []
	var total := 0.0
	for spec in r["units"]:
		var def = FarroadCore.roster_by_id(spec["id"])
		var lv: int = int(spec.get("level", r["level"]))
		var st := FarroadProgression.stats_at(spec["id"], def["stats"], def["hp"], lv)
		total += float(st["hp"] + st["atk"] + st["mag"] + st["def"] + st["res"] + st["spd"])
		units.append({"id": spec["id"], "name": def["name"], "level": lv, "stats": st,
			"maxHp": float(st["hp"]), "affinity": def.get("affinity", {}),
			"slots": (spec["slots"] as Array).map(func(s): return {"cond": s[0], "action": s[1]}),
			"chargeAction": def.get("chargeAction"), "row": def.get("row"), "look": Appearance.look({}, spec["id"])})
	var power := maxi(1, roundi(total / FarroadProgression.POWER_STAT_DIVISOR))
	return {"v": 1, "owner": r["name"], "team": r["name"], "rival": r["id"], "power": power,
		"units": units, "bonuses": (r["lore"] as Dictionary).duplicate(true)}

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
			copy["loreLevel"] = FarroadCore.bonus_spend({aid: bonuses[aid]})   # shown as the action's level
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
static func record(g: Dictionary, won: bool, team_owner: String, their_power: int, turns: int, now: int, rival_id: String = "") -> void:
	if not (g.get("pvp") is Dictionary):
		g["pvp"] = {"wins": 0, "losses": 0, "history": []}
	var r: Dictionary = g["pvp"]
	r["wins" if won else "losses"] = int(r.get("wins" if won else "losses", 0)) + 1
	var h: Array = r.get("history", [])
	h.push_front({"owner": team_owner, "won": won, "power": their_power, "rival": rival_id,
		"myPower": FarroadProgression.party_power(g), "turns": turns, "at": now})
	r["history"] = h.slice(0, HISTORY_CAP)

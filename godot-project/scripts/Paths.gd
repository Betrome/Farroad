class_name Paths
extends RefCounted
## Paths (Ian): a roguelike run, separate from the main game (Quests > Trials).
##
## You start with your main character at level 1 and nothing else: no levels, gear, actions or gambits
## carry in. A run is LEVELS (5) of ROWS (10) rows each. Every row but the last offers 2-3 nodes; each node
## leads to one or two nodes of the next row, so routes branch and rejoin. The last row of a level is its boss.
##
## Nodes: a Fight in one of three difficulties (Easy / Medium / Hard), an Event (a choice that can help or
## hurt), or the Boss.
##
## Drops (all stay in the run): every fight an action, a gambit and some Aether, with the chance of a rare
## action rising with the difficulty; medium and hard fights can also bring a unit. A boss drops a unit, a
## legendary action, a gambit and Aether. Aether levels your units between nodes. Units that fall in a fight
## are lost for the run; if your main character falls, or the whole party does, the run is over.
##
## Outside the run: 1 Crystal per level cleared (each level paid once a day).
##
## The run's own state is g["path"]["run"] (saved with the game); g["path"]["meta"] holds what outlives a run.
## Fights are built from the run's state with the main game's own engine (a throwaway game dictionary per
## battle), so everything about a battle is the same as anywhere else in the game.

const LEVELS := 5
const ROWS := 10
const MAX_PARTY := 5
## The wave of a node: level L, row r (0-9) is wave (L-1)*20 + 2*(r+1), so a level's boss (r = 9) is a boss wave.
const WAVE_PER_LEVEL := 20
const DIFF_NAMES := ["Easy", "Medium", "Hard"]
const DIFF_STAT_MUL := [0.9, 1.0, 1.2]
const DIFF_AETHER_MUL := [1.0, 1.3, 1.8]
const DIFF_RARE_CHANCE := [0.10, 0.30, 0.60]    # the chance a fight's action is rare (otherwise common)
const DIFF_UNIT_CHANCE := [0.0, 0.05, 0.10]     # the chance a fight also brings a unit
const FIGHT_REGEN := 0.25                        # survivors heal this much of their max HP after a fight
const BOSS_AETHER_MUL := 3.0
const CRYSTAL_PER_LEVEL := 1
## The main game's per-fight Aether is small (it relies on repeating waves and idle income); a run is a single pass,
## so its Aether is scaled up to keep pace with the levels a run needs.
static var AETHER_MUL := 32.0

## ===== the map =====

## Row r's nodes are [{"t": "fight"|"event"|"boss", "d": 0-2, "next": [indexes into row r+1]}].
static func gen_map(seed: int, level: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("path-map-%d-%d" % [seed, level]).hash()
	var widths: Array = []
	for r in ROWS - 1:
		widths.append(rng.randi_range(2, 3))
	widths.append(1)
	var rows: Array = []
	for r in ROWS:
		var row: Array = []
		for c in int(widths[r]):
			if r == ROWS - 1:
				row.append({"t": "boss", "d": 2, "next": []})
				continue
			var roll := rng.randf()
			if roll < 0.18:
				row.append({"t": "event", "d": 0, "next": []})
			else:
				# harder fights get likelier later in a level
				var late := float(r) / float(ROWS - 2)
				var w_easy: float = 0.5 - 0.35 * late
				var w_hard: float = 0.15 + 0.35 * late
				var f := rng.randf()
				row.append({"t": "fight", "d": 0 if f < w_easy else (2 if f > 1.0 - w_hard else 1), "next": []})
		rows.append(row)
	for r in ROWS - 1:
		_link_rows(rows[r], rows[r + 1], rng)
	return rows

## Connects two rows left to right without crossing: every node leads somewhere, and every node of the
## next row can be reached from the one before it.
static func _link_rows(a: Array, b: Array, rng: RandomNumberGenerator) -> void:
	var na := a.size()
	var nb := b.size()
	for i in na:
		var lo: int = int(floor(float(i) * float(nb - 1) / float(maxi(1, na - 1)))) if na > 1 else 0
		(a[i]["next"] as Array).append(lo)
		if lo + 1 < nb and rng.randf() < 0.5:
			(a[i]["next"] as Array).append(lo + 1)
	# any next-row node nobody reaches is linked from the nearest node
	for j in nb:
		var reached := false
		for i in na:
			if (a[i]["next"] as Array).has(j):
				reached = true
		if not reached:
			var nearest := 0
			var best := 1000.0
			for i in na:
				var d: float = absf(float(i) / float(maxi(1, na - 1)) - float(j) / float(maxi(1, nb - 1)))
				if d < best:
					best = d
					nearest = i
			(a[nearest]["next"] as Array).append(j)
			(a[nearest]["next"] as Array).sort()

static func node_wave(level: int, row: int) -> int:
	return (level - 1) * WAVE_PER_LEVEL + 2 * (row + 1)

## ===== the run's state =====

static func root(g: Dictionary) -> Dictionary:
	if not (g.get("path") is Dictionary):
		g["path"] = {}
	var p: Dictionary = g["path"]
	if not (p.get("meta") is Dictionary):
		p["meta"] = {"runs": 0, "bestLevel": 0, "paidDay": -1, "paidLevels": 0}
	return p

static func run(g: Dictionary) -> Dictionary:
	var r = root(g).get("run")
	return r if r is Dictionary else {}

static func active(g: Dictionary) -> bool:
	return not run(g).is_empty() and bool(run(g).get("active", false))

## Starts a fresh run: the main character at level 1, two starter actions, no gambits.
static func new_run(g: Dictionary, now) -> Dictionary:
	var seed: int = int(now) ^ (int(g.get("seed", 7)) * 2654435761)
	var r := {"active": true, "seed": seed, "n": 0, "level": 1, "row": -1, "col": -1, "map": gen_map(seed, 1),
		"trail": [], "party": ["kesh"], "lost": [], "lvl": {"kesh": 1}, "bank": {"kesh": 0}, "hp": {"kesh": 1.0},
		"actions": (FarroadProgression.STARTER_ACTIONS as Array).duplicate(), "conditions": ["none"],
		"loadout": {}, "aether": 0.0, "cleared": 0, "rowsDone": 0, "event": null, "log": []}
	root(g)["run"] = r
	root(g)["meta"]["runs"] = int(root(g)["meta"]["runs"]) + 1
	_default_loadout(g, r, "kesh")
	return r

## The run's own random numbers: seeded from the run's seed and a counter, so a saved run continues the same way.
static func _rng(r: Dictionary) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("path-%d-%d" % [int(r["seed"]), int(r["n"])]).hash()
	r["n"] = int(r["n"]) + 1
	return rng

## The nodes you can go to now: [[row, col], ...].
static func options(r: Dictionary) -> Array:
	var out: Array = []
	var map: Array = r["map"]
	if int(r["row"]) < 0:
		for c in (map[0] as Array).size():
			out.append([0, c])
	else:
		var node: Dictionary = map[int(r["row"])][int(r["col"])]
		for c in node["next"]:
			out.append([int(r["row"]) + 1, int(c)])
	return out

static func node_at(r: Dictionary, row: int, col: int) -> Dictionary:
	return r["map"][row][col]

static func node_text(n: Dictionary) -> String:
	match String(n["t"]):
		"event": return "Event"
		"boss": return "Boss"
		_: return "Fight (%s)" % DIFF_NAMES[int(n["d"])]

## ===== the run's game dictionary =====

## A throwaway game dictionary built from the run's state, so the main game's own functions (stats, loadouts,
## enemies, the battle engine) work on it unchanged. Nothing in it outlives a call.
static func make_run_game(g: Dictionary, r: Dictionary, wave: int) -> Dictionary:
	var pg := FarroadProgression.new_game(int(r["seed"]) + int(r["n"]), g.get("mc"))
	pg["wave"] = wave
	pg["farthest"] = wave
	pg["party"] = (r["party"] as Array).duplicate()
	pg["owned"] = {}
	pg["lvl"] = {}
	pg["bank"] = {}
	pg["hpCarry"] = {}
	pg["loadout"] = (r["loadout"] as Dictionary).duplicate(true)
	pg["actions"] = (r["actions"] as Array).duplicate()
	pg["conditions"] = (r["conditions"] as Array).duplicate()
	var top := 1
	for uid in r["party"]:
		pg["owned"][uid] = 1
		pg["lvl"][uid] = int(r["lvl"].get(uid, 1))
		pg["bank"][uid] = int(r["bank"].get(uid, 0))
		pg["hpCarry"][uid] = float(r["hp"].get(uid, 1.0))
		pg["affinities"][uid] = {}
		pg["statInvest"][uid] = {}
		pg["equipped"][uid] = {}
		top = maxi(top, int(pg["lvl"][uid]))
		pg["touched"][uid] = true
	pg["maxLevelEver"] = top
	return pg

static func _default_loadout(g: Dictionary, r: Dictionary, uid: String) -> void:
	var pg := make_run_game(g, r, node_wave(int(r["level"]), maxi(0, int(r["row"]))))
	FarroadProgression.auto_assign_loadout(pg, uid)
	r["loadout"][uid] = (FarroadProgression.ensure_loadout(pg, uid) as Array).duplicate(true)

## Slots a unit has at its level (more at higher levels).
static func slot_count(g: Dictionary, r: Dictionary, uid: String) -> int:
	return FarroadProgression.slots_at(int(r["lvl"].get(uid, 1)))

static func loadout_of(g: Dictionary, r: Dictionary, uid: String) -> Array:
	var pg := make_run_game(g, r, node_wave(int(r["level"]), maxi(0, int(r["row"]))))
	var slots: Array = (FarroadProgression.ensure_loadout(pg, uid) as Array).duplicate(true)
	r["loadout"][uid] = slots
	return slots

static func set_slot(g: Dictionary, r: Dictionary, uid: String, idx: int, cond: String, action: String) -> void:
	var slots := loadout_of(g, r, uid)
	if idx < 0 or idx >= slots.size():
		return
	if (r["conditions"] as Array).has(cond) and (r["actions"] as Array).has(action):
		slots[idx] = {"cond": cond, "action": action}
		r["loadout"][uid] = slots

static func auto_equip(g: Dictionary, r: Dictionary, uid: String) -> void:
	var pg := make_run_game(g, r, node_wave(int(r["level"]), maxi(0, int(r["row"]))))
	FarroadProgression.auto_assign_loadout(pg, uid)
	r["loadout"][uid] = (FarroadProgression.ensure_loadout(pg, uid) as Array).duplicate(true)

## ===== levelling (with the run's Aether) =====

static func level_cost(g: Dictionary, r: Dictionary, uid: String) -> int:
	var pg := make_run_game(g, r, 1)
	return maxi(1, FarroadProgression.cost_next(pg, uid) - int(FarroadProgression.exp_of(pg, uid)))

static func level_up(g: Dictionary, r: Dictionary, uid: String) -> bool:
	if not (r["party"] as Array).has(uid):
		return false
	var cost := level_cost(g, r, uid)
	if float(r["aether"]) < float(cost):
		return false
	var pg := make_run_game(g, r, 1)
	FarroadProgression.feed_unit(pg, uid, cost)
	r["aether"] = float(r["aether"]) - float(cost)
	r["lvl"][uid] = int(pg["lvl"][uid])
	r["bank"][uid] = int(pg["bank"].get(uid, 0))
	return true

## ===== a fight =====

## Builds a node's fight: {"battle", "wave", "meta"} for the side-battle machinery (the battle arrives prebuilt).
static func build_fight(g: Dictionary, r: Dictionary, row: int, col: int) -> Dictionary:
	var node := node_at(r, row, col)
	var wave := node_wave(int(r["level"]), row)
	var pg := make_run_game(g, r, wave)
	FarroadCore.set_wave(wave)
	# the actions are global and carry your main game's Lore: a run starts without any
	# (finish_side_battle puts it back)
	FarroadCore.apply_bonuses({})
	var party: Array = []
	for i in (r["party"] as Array).size():
		party.append(FarroadProgression.build_party_unit(pg, String(r["party"][i]), i))
	var enemies: Array = FarroadProgression.build_enemies(pg, wave, true)
	if String(node["t"]) == "fight":
		enemies = FarroadProgression.apply_stat_mul(enemies, float(DIFF_STAT_MUL[int(node["d"])]))
	var battle := FarroadCore.make_battle(party + enemies, {"rng": pg["rng"], "enrage": true})
	return {"battle": battle, "wave": wave,
		"meta": {"kind": "path", "row": row, "col": col, "diff": int(node["d"]), "boss": String(node["t"]) == "boss",
			"level": int(r["level"]), "name": "Path %d-%d" % [int(r["level"]), row + 1], "enemies": enemies.size()}}

## What a finished battle left each of your units: [{id, hp, maxHp}].
static func snapshot_battle(battle: Dictionary) -> Array:
	var out: Array = []
	for u in battle["units"]:
		if u["isParty"]:
			out.append({"id": String(u["id"]), "hp": float(u["hp"]), "maxHp": float(u["maxHp"])})
	return out

## Applies a finished fight to the run. `result` is "party" for a win. Returns the event for the popup:
## {kind: "path_node", ok, drops: [text], ended, victory, crystal, levelCleared, lost: [names]}
static func finish_fight(g: Dictionary, meta: Dictionary, result: String, snap: Array, enemy_count: int, now) -> Dictionary:
	var r := run(g)
	if not r.is_empty():
		r.erase("fight")
	var ev := {"kind": "path_node", "ok": false, "drops": [], "ended": false, "victory": false, "crystal": 0,
		"levelCleared": false, "lost": [], "boss": bool(meta["boss"])}
	if r.is_empty():
		return ev
	var lost_now: Array = []
	var hp: Dictionary = r["hp"]
	for s in snap:
		var uid := String(s["id"])
		if float(s["hp"]) <= 0.0:
			lost_now.append(uid)
		else:
			hp[uid] = float(s["hp"]) / maxf(1.0, float(s["maxHp"]))
	for uid in lost_now:
		_remove_unit(r, uid)
		ev["lost"].append(_name_of(uid))
	var mc_alive: bool = (r["party"] as Array).has("kesh")
	if result != "party" or not mc_alive or (r["party"] as Array).is_empty():
		ev["ended"] = true
		_end(g, r, now, ev)
		return ev
	ev["ok"] = true
	# survivors recover a little after every fight (fully after a boss)
	var boss := bool(meta["boss"])
	for uid in r["party"]:
		hp[uid] = 1.0 if boss else minf(1.0, float(hp.get(uid, 1.0)) + FIGHT_REGEN)
	r["row"] = int(meta["row"])
	r["col"] = int(meta["col"])
	(r["trail"] as Array).append([int(meta["row"]), int(meta["col"])])
	r["rowsDone"] = int(r["rowsDone"]) + 1
	_drops(g, r, meta, enemy_count, ev)
	if boss:
		r["cleared"] = int(r["cleared"]) + 1
		ev["levelCleared"] = true
		if int(r["level"]) >= LEVELS:
			ev["victory"] = true
			ev["ended"] = true
			_end(g, r, now, ev)
		else:
			r["level"] = int(r["level"]) + 1
			r["row"] = -1
			r["col"] = -1
			r["trail"] = []
			r["map"] = gen_map(int(r["seed"]), int(r["level"]))
	return ev

static func _name_of(uid: String) -> String:
	var def = FarroadCore.roster_by_id(uid)
	return String(def["name"]) if def != null else uid

static func _remove_unit(r: Dictionary, uid: String) -> void:
	(r["party"] as Array).erase(uid)
	if not (r["lost"] as Array).has(uid):
		(r["lost"] as Array).append(uid)

## ===== drops =====

static func _drops(g: Dictionary, r: Dictionary, meta: Dictionary, enemy_count: int, ev: Dictionary) -> void:
	var wave := node_wave(int(r["level"]), int(meta["row"]))
	var boss := bool(meta["boss"])
	var diff := int(meta["diff"])
	var rng := _rng(r)
	var texts: Array = ev["drops"]
	# Aether
	var base: float = float(FarroadProgression.kill_reward(wave, maxi(1, enemy_count))["aether"])
	var aether: float = base * AETHER_MUL * (BOSS_AETHER_MUL if boss else float(DIFF_AETHER_MUL[diff]))
	r["aether"] = float(r["aether"]) + aether
	texts.append("%d Aether" % roundi(aether))
	# an action: rare chance by difficulty; a boss always drops a legendary one
	var act := _pick_action(r, "legendary" if boss else ("rare" if rng.randf() < float(DIFF_RARE_CHANCE[diff]) else "common"), rng)
	if act != "":
		(r["actions"] as Array).append(act)
		texts.append("Action: %s (%s)" % [FarroadCore.ACTIONS[act]["name"], FarroadCore.ACTIONS[act].get("rarity", "common")])
	# a gambit
	var cond := _pick_condition(r, rng)
	if cond != "":
		(r["conditions"] as Array).append(cond)
		texts.append("Gambit: %s" % FarroadCore.cond_label(cond))
	# a unit: always from a boss, sometimes from a medium or hard fight
	if boss or rng.randf() < float(DIFF_UNIT_CHANCE[diff]):
		var uid := recruit(g, r, rng)
		if uid != "":
			texts.append("%s joins you!" % _name_of(uid))
		elif boss:
			r["aether"] = float(r["aether"]) + aether
			texts.append("(your party is full: +%d Aether instead)" % roundi(aether))
	# a new action may deserve a slot
	for uid in r["party"]:
		auto_equip(g, r, String(uid))

static func _pick_action(r: Dictionary, rarity: String, rng: RandomNumberGenerator) -> String:
	var owned: Array = r["actions"]
	var pool: Array = []
	for id in FarroadCore.equippable():
		var a: Dictionary = FarroadCore.ACTIONS[id]
		if not owned.has(id) and not bool(a.get("isCharge", false)) and String(a.get("rarity", "common")) == rarity:
			pool.append(id)
	if pool.is_empty() and rarity == "legendary":
		return _pick_action(r, "rare", rng)
	if pool.is_empty() and rarity == "rare":
		return _pick_action(r, "common", rng)
	return String(pool[rng.randi_range(0, pool.size() - 1)]) if not pool.is_empty() else ""

static func _pick_condition(r: Dictionary, rng: RandomNumberGenerator) -> String:
	var owned: Array = r["conditions"]
	var pool: Array = []
	for id in FarroadCore.ALL_CONDITION_IDS:
		if not owned.has(id) and id != "none":
			pool.append(id)
	return String(pool[rng.randi_range(0, pool.size() - 1)]) if not pool.is_empty() else ""

## A new unit joins the run (at the main character's level), if there is room. Returns its id or "".
static func recruit(g: Dictionary, r: Dictionary, rng: RandomNumberGenerator) -> String:
	if (r["party"] as Array).size() >= MAX_PARTY:
		return ""
	var pool: Array = []
	var weights: Array = []
	for def in FarroadCore.ROSTER:
		var uid := String(def["id"])
		if uid == "kesh" or (r["party"] as Array).has(uid) or (r["lost"] as Array).has(uid):
			continue
		pool.append(uid)
		weights.append({"common": 70.0, "rare": 25.0, "legendary": 5.0}.get(String(def.get("rarity", "common")), 50.0))
	if pool.is_empty():
		return ""
	var total := 0.0
	for w in weights:
		total += float(w)
	var roll := rng.randf() * total
	var pick: String = String(pool[pool.size() - 1])
	for i in pool.size():
		roll -= float(weights[i])
		if roll <= 0.0:
			pick = String(pool[i])
			break
	var lvl: int = int(r["lvl"].get("kesh", 1))
	(r["party"] as Array).append(pick)
	r["lvl"][pick] = lvl
	r["bank"][pick] = 0
	r["hp"][pick] = 1.0
	_default_loadout(g, r, pick)
	return pick

## ===== events =====

const EVENTS: Array = [
	{"id": "healer", "title": "A wandering healer", "text": "A traveller offers to tend your wounds.",
		"opts": [{"label": "Accept their help", "fx": [{"t": "heal", "frac": 0.6}]},
			{"label": "Decline and move on", "fx": [{"t": "aether", "mul": 1.5}]}]},
	{"id": "cache", "title": "An abandoned cache", "text": "A crate sits half-buried by the road. It might be trapped.",
		"opts": [{"label": "Open it", "fx": [{"t": "chance", "p": 0.7, "yes": [{"t": "aether", "mul": 4.0}], "no": [{"t": "hurt", "frac": 0.25}]}]},
			{"label": "Leave it", "fx": []}]},
	{"id": "shrine", "title": "A roadside shrine", "text": "A small shrine glows faintly.",
		"opts": [{"label": "Pray", "fx": [{"t": "level"}]},
			{"label": "Leave an offering (lose a quarter of your Aether)", "fx": [{"t": "aether_lose", "frac": 0.25}, {"t": "heal", "frac": 1.0}]}]},
	{"id": "stranger", "title": "A stranger asks to join", "text": "Someone steps out of the trees, weapon lowered.",
		"opts": [{"label": "Welcome them", "fx": [{"t": "unit"}]},
			{"label": "Send them away", "fx": [{"t": "aether", "mul": 1.5}]}]},
	{"id": "rack", "title": "A rack of weapons", "text": "Abandoned gear, some of it still good.",
		"opts": [{"label": "Take a weapon", "fx": [{"t": "action", "rarity": "rare"}]},
			{"label": "Take a manual", "fx": [{"t": "gambit"}]}]},
	{"id": "ambush", "title": "Ambush!", "text": "Bandits step out of the brush.",
		"opts": [{"label": "Fight your way through", "fx": [{"t": "hurt", "frac": 0.35}]},
			{"label": "Pay them off (lose 40% of your Aether)", "fx": [{"t": "aether_lose", "frac": 0.4}]}]},
	{"id": "idol", "title": "A cursed idol", "text": "A dark idol hums with power. Taking it will cost you.",
		"opts": [{"label": "Take it", "fx": [{"t": "action", "rarity": "rare"}, {"t": "hurt", "frac": 0.2}]},
			{"label": "Smash it", "fx": [{"t": "chance", "p": 0.5, "yes": [{"t": "aether", "mul": 2.0}], "no": [{"t": "lose_unit"}]}]}]},
	{"id": "bridge", "title": "A collapsing bridge", "text": "The only crossing is giving way.",
		"opts": [{"label": "Rush across", "fx": [{"t": "hurt", "frac": 0.25}]},
			{"label": "Take the long way (lose 20% of your Aether)", "fx": [{"t": "aether_lose", "frac": 0.2}]}]},
	{"id": "plague", "title": "A plague wagon", "text": "Someone inside is calling for help.",
		"opts": [{"label": "Help them", "fx": [{"t": "chance", "p": 0.5, "yes": [{"t": "gambit"}, {"t": "heal", "frac": 0.3}], "no": [{"t": "hurt", "frac": 0.4}]}]},
			{"label": "Pass by", "fx": []}]},
	{"id": "gambler", "title": "A roadside gambler", "text": "\"Double or nothing?\"",
		"opts": [{"label": "Bet half your Aether", "fx": [{"t": "chance", "p": 0.5, "yes": [{"t": "aether_gain_frac", "frac": 0.5}], "no": [{"t": "aether_lose", "frac": 0.5}]}]},
			{"label": "Walk away", "fx": []}]},
]

static func event_by_id(id: String) -> Dictionary:
	for e in EVENTS:
		if String(e["id"]) == id:
			return e
	return {}

## Picks the event for an event node (and stores it as the run's open event).
static func open_event(r: Dictionary, row: int, col: int) -> Dictionary:
	if r.get("event") != null:
		return event_by_id(String(r["event"]))   # already open (the window was closed mid-event)
	var rng := _rng(r)
	var e: Dictionary = EVENTS[rng.randi_range(0, EVENTS.size() - 1)]
	r["event"] = String(e["id"])
	r["eventNode"] = [row, col]
	return e

## Takes option `opt` of the open event. Returns the lines to show.
static func resolve_event(g: Dictionary, r: Dictionary, opt: int) -> Array:
	var e := event_by_id(String(r.get("event", "")))
	if e.is_empty() or opt < 0 or opt >= (e["opts"] as Array).size():
		return []
	var row: int = int(r["eventNode"][0])
	var col: int = int(r["eventNode"][1])
	var rng := _rng(r)
	var lines: Array = []
	_apply_fx(g, r, e["opts"][opt]["fx"], rng, lines, node_wave(int(r["level"]), row))
	r["event"] = null
	r["eventNode"] = null
	r["row"] = row
	r["col"] = col
	(r["trail"] as Array).append([row, col])
	r["rowsDone"] = int(r["rowsDone"]) + 1
	for uid in (r["party"] as Array).duplicate():
		if not (r["party"] as Array).is_empty() and float(r["hp"].get(uid, 1.0)) <= 0.0:
			_remove_unit(r, uid)
	return lines

static func _apply_fx(g: Dictionary, r: Dictionary, fx: Array, rng: RandomNumberGenerator, lines: Array, wave: int) -> void:
	for f in fx:
		match String(f["t"]):
			"heal":
				for uid in r["party"]:
					r["hp"][uid] = minf(1.0, float(r["hp"].get(uid, 1.0)) + float(f["frac"]))
				lines.append("Your party recovers.")
			"hurt":
				for uid in r["party"]:
					r["hp"][uid] = maxf(0.05, float(r["hp"].get(uid, 1.0)) - float(f["frac"]))
				lines.append("Your party is hurt.")
			"aether":
				var amt: float = float(FarroadProgression.kill_reward(wave, 3)["aether"]) * AETHER_MUL * float(f["mul"])
				r["aether"] = float(r["aether"]) + amt
				lines.append("+%d Aether." % roundi(amt))
			"aether_lose":
				var loss: float = float(r["aether"]) * float(f["frac"])
				r["aether"] = float(r["aether"]) - loss
				lines.append("-%d Aether." % roundi(loss))
			"aether_gain_frac":
				var gain: float = float(r["aether"]) * float(f["frac"])
				r["aether"] = float(r["aether"]) + gain
				lines.append("+%d Aether." % roundi(gain))
			"level":
				var cost := level_cost(g, r, "kesh")
				var pg := make_run_game(g, r, 1)
				FarroadProgression.feed_unit(pg, "kesh", cost)
				r["lvl"]["kesh"] = int(pg["lvl"]["kesh"])
				r["bank"]["kesh"] = int(pg["bank"].get("kesh", 0))
				lines.append("%s gains a level." % _name_of("kesh"))
			"unit":
				var uid := recruit(g, r, rng)
				lines.append("%s joins you!" % _name_of(uid) if uid != "" else "Your party is full.")
			"action":
				var act := _pick_action(r, String(f["rarity"]), rng)
				if act != "":
					(r["actions"] as Array).append(act)
					lines.append("Action: %s." % FarroadCore.ACTIONS[act]["name"])
					for uid in r["party"]:
						auto_equip(g, r, String(uid))
			"gambit":
				var cond := _pick_condition(r, rng)
				if cond != "":
					(r["conditions"] as Array).append(cond)
					lines.append("Gambit: %s." % FarroadCore.cond_label(cond))
			"lose_unit":
				var others: Array = (r["party"] as Array).filter(func(u): return u != "kesh")
				if not others.is_empty():
					var gone := String(others[rng.randi_range(0, others.size() - 1)])
					_remove_unit(r, gone)
					lines.append("%s is lost." % _name_of(gone))
				else:
					lines.append("Nothing happens.")
			"chance":
				_apply_fx(g, r, f["yes"] if rng.randf() < float(f["p"]) else f["no"], rng, lines, wave)

## ===== the end of a run =====

static func _end(g: Dictionary, r: Dictionary, now, ev: Dictionary) -> void:
	r["active"] = false
	var meta: Dictionary = root(g)["meta"]
	meta["bestLevel"] = maxi(int(meta["bestLevel"]), int(r["cleared"]))
	ev["crystal"] = pay_depth(g, int(r["cleared"]), now)
	r["result"] = {"cleared": int(r["cleared"]), "rows": int(r["rowsDone"]), "victory": bool(ev.get("victory", false)), "crystal": int(ev["crystal"])}

## 1 Crystal per level cleared, each level paid once a day (local days, like the goals).
static func pay_depth(g: Dictionary, cleared: int, now) -> int:
	var meta: Dictionary = root(g)["meta"]
	var day := Goals.local_day(now)
	if int(meta.get("paidDay", -1)) != day:
		meta["paidDay"] = day
		meta["paidLevels"] = 0
	var fresh := maxi(0, cleared - int(meta["paidLevels"]))
	meta["paidLevels"] = maxi(int(meta["paidLevels"]), cleared)
	var crystal := fresh * CRYSTAL_PER_LEVEL
	g["crystal"] = int(g.get("crystal", 0)) + crystal
	return crystal

## Ends the run if nobody is left (or the main character is gone). Returns whether it did.
static func end_if_wiped(g: Dictionary, now) -> bool:
	var r := run(g)
	if r.is_empty() or not bool(r.get("active", false)):
		return false
	if (r["party"] as Array).is_empty() or not (r["party"] as Array).has("kesh"):
		_end(g, r, now, {"victory": false, "crystal": 0})
		return true
	return false

## Ends the run now (retreat). Levels cleared so far still pay.
static func retreat(g: Dictionary, now) -> Dictionary:
	var r := run(g)
	var ev := {"kind": "path_node", "ok": false, "drops": [], "ended": true, "victory": false, "crystal": 0, "levelCleared": false, "lost": [], "boss": false}
	if r.is_empty() or not bool(r.get("active", false)):
		return ev
	_end(g, r, now, ev)
	return ev

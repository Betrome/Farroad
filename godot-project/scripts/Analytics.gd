class_name Analytics
extends RefCounted
## Anonymous gameplay stats, sent about once a day (Ian: "track player
## behaviors to help with balancing and creating new content"). Counters
## build up locally in user://analytics.json while playing -- nothing goes
## over the network until a daily report. Each report is the counters since
## the last report plus a snapshot of the save (units, loadouts, Lore...),
## posted to Ian's Google Sheet (an Apps Script web app); the in-house
## parser in tools/analytics/ turns the rows into a dashboard.
##
## Reports carry no personal data: a random install id, game version,
## platform and gameplay numbers only. Players can turn it off in Menu.

## The Apps Script web app's /exec URL. Empty: stats are still counted but
## never sent.
const ENDPOINT := ""
## Where reports go (ENDPOINT; a test can point it elsewhere).
static var endpoint: String = ENDPOINT
const FILE := "user://analytics.json"
const SEND_EVERY_SEC := 24 * 3600
## Reports bigger than this are cut down (a Sheet cell holds 50,000 chars).
const MAX_REPORT_CHARS := 45000
const SCHEMA := 1

static var state: Dictionary = {}   # id, enabled, noticeShown, lastSent, periodStart, c (counters)
static var _loaded := false
static var _dirty := false
static var _sending := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(FILE):
		var f := FileAccess.open(FILE, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				state = parsed
	if not state.has("id"):
		var bytes := Crypto.new().generate_random_bytes(8)
		state["id"] = bytes.hex_encode()
	for k in [["enabled", true], ["noticeShown", false], ["lastSent", 0.0], ["c", {}]]:
		if not state.has(k[0]):
			state[k[0]] = k[1]
	if not state.has("periodStart"):
		state["periodStart"] = Time.get_unix_time_from_system()
		# A first install doesn't wait a whole day for its first report.
		state["lastSent"] = 0.0

static func save() -> void:
	if not _loaded or not _dirty:
		return
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state))
		_dirty = false

static func enabled() -> bool:
	_ensure()
	return bool(state["enabled"])

static func set_enabled(on: bool) -> void:
	_ensure()
	state["enabled"] = on
	if not on:
		state["c"] = {}   # nothing kept for a player who opted out
	_dirty = true
	save()

static func notice_shown() -> bool:
	_ensure()
	return bool(state["noticeShown"])

static func mark_notice_shown() -> void:
	_ensure()
	state["noticeShown"] = true
	_dirty = true
	save()

## ---- counting ----

## counters[group][key] += n
static func add(group: String, key, n: float = 1.0) -> void:
	_ensure()
	if not state["enabled"]:
		return
	var c: Dictionary = state["c"]
	if not c.has(group):
		c[group] = {}
	var k := str(key)
	c[group][k] = float(c[group].get(k, 0.0)) + n
	_dirty = true

## Per-wave stats: [seconds spent, clears, wipes].
static func wave(w: int, seconds: float, cleared: bool) -> void:
	_ensure()
	if not state["enabled"]:
		return
	var c: Dictionary = state["c"]
	if not c.has("waves"):
		c["waves"] = {}
	var k := str(w)
	var row: Array = c["waves"].get(k, [0.0, 0, 0])
	row[0] = snappedf(float(row[0]) + seconds, 0.1)
	if cleared:
		row[1] = int(row[1]) + 1
	else:
		row[2] = int(row[2]) + 1
	c["waves"][k] = row
	_dirty = true

## One battle beat. `ctx` is where it happened: road / quest / dungeon / pvp.
static func battle_event(e: Dictionary, ctx: String) -> void:
	if not e.get("isParty", false):
		return
	var aid = e.get("actionId")
	if aid == null or aid == "none":
		return
	add("actionUse", aid)
	add("actionUse_" + ctx, aid)
	var cond = e.get("condId")
	if cond != null:
		add("condFired", cond)
	add("unitTurns", e.get("actorId", "?"))
	add("damageByAction", aid, float(e.get("totalDamage", 0)))

## A finished fight: who fought and which actions they used, tagged win or
## loss and by where it happened -- what the dashboard's win-contribution
## tables are built from. `actions` is action id -> times used this fight.
static func fight_end(ctx: String, won: bool, actions: Dictionary, units: Array) -> void:
	_ensure()
	if not state["enabled"]:
		return
	var res := "win" if won else "loss"
	add("fights", ctx + ":" + res)
	for aid in actions.keys():
		add("fightActions_" + res, aid)
		add("fightActions_%s_%s" % [ctx, res], aid)
	for uid in units:
		add("fightUnits_" + res, uid)
		add("fightUnits_%s_%s" % [ctx, res], uid)

## ---- reporting ----

static func _platform() -> String:
	if OS.has_feature("web"):
		return "web"
	if OS.has_feature("android"):
		return "android"
	if OS.has_feature("ios"):
		return "ios"
	return OS.get_name().to_lower()

static func _row_of(uid: String):
	var d = FarroadCore.roster_by_id(uid)
	return d.get("row") if d != null else null

## What a player has set up right now (the counters say what they did).
static func snapshot(g: Dictionary) -> Dictionary:
	var units := {}
	for uid in g.get("owned", {}).keys():
		var lo: Array = []
		for s in (g.get("loadout", {}).get(uid, []) as Array):
			lo.append([s.get("cond"), s.get("action")])
		var eq := {}
		for slot in (g.get("equipped", {}).get(uid, {}) as Dictionary).keys():
			eq[slot] = g["equipped"][uid][slot]
		units[uid] = {"lvl": FarroadProgression.level_of(g, uid), "loadout": lo, "equip": eq,
			"aff": g.get("affinities", {}).get(uid, {}), "pct": g.get("statInvest", {}).get(uid, {}),
			"rec": g.get("recovery", {}).get(uid, 0), "row": _row_of(uid)}
	var mc = g.get("mc")
	var quests := {}
	for uid in g.get("quests", {}).keys():
		quests[uid] = int(g["quests"][uid].get("stage", 0))
	var dungeons: Array = []
	for d in g.get("dungeons", []):
		dungeons.append([d.get("direction", ""), int(d.get("tier", 0)), int(d.get("clears", 0))])
	var depth := {}
	for dir in g.get("directions", {}).keys():
		depth[dir] = int(g["directions"][dir].get("maxDepth", 0))
	return {"wave": int(g.get("wave", 1)), "farthest": int(g.get("farthest", 1)),
		"bosses": int(g.get("bossesCleared", 0)), "power": FarroadProgression.party_power(g),
		"accountPower": FarroadProgression.power_level(g), "party": g.get("party", []), "units": units,
		"mcCharge": mc.get("chargeAction") if mc != null else null,
		"mcCharges": mc.get("acquiredCharges", []) if mc != null else [],
		"mcStats": mc.get("stats", {}) if mc != null else {},
		"bonuses": g.get("bonuses", {}), "actions": (g.get("actions", []) as Array).size(),
		"conditions": (g.get("conditions", []) as Array).size(),
		"aether": int(g.get("aether", 0)), "marks": int(g.get("marks", 0)), "crystal": int(g.get("crystal", 0)),
		"quests": quests, "dungeons": dungeons, "expeditionDepth": depth,
		"expeditionsOut": (g.get("expeditions", []) as Array).size(),
		"pvp": {"w": int(g.get("pvp", {}).get("wins", 0)), "l": int(g.get("pvp", {}).get("losses", 0))},
		"tutorials": g.get("tutorials", {})}

static func build_report(g: Dictionary) -> Dictionary:
	_ensure()
	var now := Time.get_unix_time_from_system()
	var ver := str(ProjectSettings.get_setting("application/config/version", "dev"))
	return {"schema": SCHEMA, "id": state["id"], "version": ver, "platform": _platform(),
		"from": int(state.get("periodStart", now)), "to": int(now),
		"counters": state["c"], "snapshot": snapshot(g)}

static func due() -> bool:
	_ensure()
	return state["enabled"] and endpoint != "" and not _sending \
		and Time.get_unix_time_from_system() - float(state["lastSent"]) >= SEND_EVERY_SEC

## Sends a report if one is due. `host` owns the HTTPRequest node.
static func maybe_send(g: Dictionary, host: Node) -> void:
	if not due() or g.is_empty():
		return
	var report := build_report(g)
	var body := JSON.stringify(report)
	if body.length() > MAX_REPORT_CHARS:
		# Drop the biggest optional parts first.
		(report["counters"] as Dictionary).erase("waves")
		(report["snapshot"] as Dictionary).erase("bonuses")
		body = JSON.stringify(report)
	_sending = true
	var sent_until := float(report["to"])
	var http := HTTPRequest.new()
	http.timeout = 30.0
	host.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h, _b):
		http.queue_free()
		_sending = false
		if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 400:
			state["c"] = {}
			state["lastSent"] = sent_until
			state["periodStart"] = sent_until
			_dirty = true
			save())
	# text/plain keeps the browser build's request "simple" (no CORS preflight).
	var err := http.request(endpoint, ["Content-Type: text/plain;charset=utf-8"], HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		_sending = false

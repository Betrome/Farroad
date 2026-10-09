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
## Reports carry no personal details: a random install id, game version,
## platform and gameplay numbers only. Ian: required, not optional -- it's
## part of the terms every player agrees to before playing (TermsPanel).
## A player can ask for their data to be deleted via Send Feedback, quoting
## the install id the terms screen shows.

## The Apps Script web app's /exec URL. Empty: stats are still counted but
## never sent.
const ENDPOINT := "https://script.google.com/macros/s/AKfycbxFolLGYINZayvEHLZfRekGPSyDZYBnkBAQZPDZmuorv8l_8bu9T_i5HseN2-lmqj4m/exec"
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
	if not valid_id(str(state.get("id", ""))):
		state["id"] = new_id()
		_dirty = true
	for k in [["lastSent", 0.0], ["c", {}]]:
		if not state.has(k[0]):
			state[k[0]] = k[1]
	state["enabled"] = true   # part of the terms; no opt-out
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

## ---- terms ----
## Bump TERMS_VERSION whenever the text below changes in a way players
## should see; everyone is asked to agree again on their next launch.
const TERMS_VERSION := 1

static func terms_accepted() -> bool:
	_ensure()
	return int(state.get("terms", 0)) >= TERMS_VERSION

static func accept_terms() -> void:
	_ensure()
	state["terms"] = TERMS_VERSION
	state["termsAt"] = int(Time.get_unix_time_from_system())
	_dirty = true
	save()

static func install_id() -> String:
	_ensure()
	return str(state["id"])

## Player IDs (Ian: standardized, shown in the Menu as "ID: XXX-XXX-XXX"):
## 9 characters from an alphabet without look-alikes (no 0/O, 1/I/L, U),
## stored without dashes, shown in three groups. 30^9 ~ 2e13 possible IDs.
const ID_ALPHABET := "23456789ABCDEFGHJKMNPQRSTVWXYZ"
const ID_LEN := 9

static func new_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(ID_LEN)
	var out := ""
	for i in ID_LEN:
		out += ID_ALPHABET[bytes[i] % ID_ALPHABET.length()]
	return out

static func valid_id(id: String) -> bool:
	if id.length() != ID_LEN:
		return false
	for ch in id:
		if not ID_ALPHABET.contains(ch):
			return false
	return true

## "K7Q-M2X-9PD"
static func display_id() -> String:
	var id := install_id()
	return "%s-%s-%s" % [id.substr(0, 3), id.substr(3, 3), id.substr(6, 3)]

## DRAFT for Ian to review -- not legal advice; worth a check before release.
static func terms_bbcode() -> String:
	return """[b]Farroad Terms of Service[/b]
[i]Version %d[/i]

[b]1. Playing Farroad[/b]
Farroad is provided as is, and may change over time as it's updated.

[b]2. Game data[/b]
To balance the game, plan new content, fix problems and keep the Arena fair (including spotting cheating), Farroad collects data about how the game is played. This includes:
• which units, actions, gambits and gear you use, and how fights, waves, quests, dungeons, expeditions and Arena matches go
• what you spend Aether, Lore, Marks and Crystal on
• your progress, play time, game version and the kind of device (Android, Windows or web)

It's linked to a random player ID made on this device (shown in the Menu), not to your name, email or any account, and sent to the developer about once a day. Like any internet connection, your device's IP address is seen when a report arrives, but it's never saved. The data is used only to run and improve Farroad; it isn't sold or shared for advertising.

[b]3. Your data[/b]
To ask for your data to be deleted, use Menu > Send Feedback and include your player ID: [b]%s[/b]
Uninstalling the game (or clearing a browser's site data) stops any further reports.

[b]4. Fair play[/b]
Don't use cheats, modified game files or tools that give an unfair advantage, especially in the Arena. Arena results that look tampered with may be ignored or removed.

[b]5. Changes[/b]
If these terms change, you'll be asked to agree again before playing.

By tapping Agree and continue, you agree to these terms.""" % [TERMS_VERSION, display_id()]

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

## Waves fought while the game was closed (the offline catch-up replays them):
## wave -> [clears, wipes]. Counted in the same rows as live play, but with no
## seconds, so a 4th number keeps how many of those attempts were untimed.
static func waves_offline(results: Dictionary) -> void:
	_ensure()
	if not state["enabled"] or results.is_empty():
		return
	var c: Dictionary = state["c"]
	if not c.has("waves"):
		c["waves"] = {}
	for w in results.keys():
		var k := str(w)
		var row: Array = c["waves"].get(k, [0.0, 0, 0])
		while row.size() < 4:
			row.append(0)
		row[1] = int(row[1]) + int(results[w][0])
		row[2] = int(row[2]) + int(results[w][1])
		row[3] = int(row[3]) + int(results[w][0]) + int(results[w][1])
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
static func fight_end(ctx: String, won: bool, actions: Dictionary, units: Array, info: Dictionary = {}) -> void:
	_ensure()
	if not state["enabled"]:
		return
	_log_fight(ctx, won, actions, units, info)
	var res := "win" if won else "loss"
	add("fights", ctx + ":" + res)
	for aid in actions.keys():
		add("fightActions_" + res, aid)
		add("fightActions_%s_%s" % [ctx, res], aid)
	for uid in units:
		add("fightUnits_" + res, uid)
		add("fightUnits_%s_%s" % [ctx, res], uid)
	# win rate by title (Ian): each fielded unit's title counts once per fight
	for t in info.get("titles", []):
		if str(t) != "":
			add("fightTitles_" + res, str(t))
			add("fightTitles_%s_%s" % [ctx, res], str(t))

## Per-fight records (Ian: to relate actions/units/combinations to clear
## time, specific waves and enemy types). Each is a short array:
##   [ctx, key, won 1/0, turns, seconds, fast 1/0, [units], {action: uses},
##    [enemy archetypes], [fallen units]]
## `key` is the Road wave, "uid#stage" for a quest, "dir#tN#wN" for a
## dungeon wave, the rival id (or "code") for the Arena.
## Every quest/dungeon/Arena fight, Road wipe and Road boss wave goes in
## the "key" pool; ordinary Road clears go in a random sample. Both are
## capped (reservoir sampling), with how many were seen, so a report stays
## small however much someone plays.
const KEY_FIGHTS_CAP := 100
const ROAD_SAMPLE_CAP := 60

static func _log_fight(ctx: String, won: bool, actions: Dictionary, units: Array, info: Dictionary) -> void:
	var rec := [ctx, str(info.get("key", "")), 1 if won else 0, int(info.get("turns", 0)),
		snappedf(float(info.get("secs", 0.0)), 0.1), 1 if info.get("fast", false) else 0,
		units, actions, info.get("enemies", []), info.get("fallen", [])]
	var important: bool = ctx != "road" or not won or bool(info.get("boss", false))
	var pool := "fightsKey" if important else "fightsRoad"
	var cap := KEY_FIGHTS_CAP if important else ROAD_SAMPLE_CAP
	var c: Dictionary = state["c"]
	var seen: Dictionary = c.get_or_add("fightsSeen", {})
	seen[pool] = int(seen.get(pool, 0)) + 1
	var log: Array = c.get_or_add(pool, [])
	if log.size() < cap:
		log.append(rec)
	else:
		var j := randi() % int(seen[pool])
		if j < cap:
			log[j] = rec
	_dirty = true

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
	# Only real exported builds report: runs from the Godot editor (Claude's
	# headless tests among them) never send -- they were landing in the
	# Sheet as fake players.
	if OS.has_feature("editor") and endpoint == ENDPOINT:
		return false
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
		# then halve the fight records until it fits
		for pool in ["fightsRoad", "fightsKey"]:
			while body.length() > MAX_REPORT_CHARS and (report["counters"].get(pool, []) as Array).size() > 10:
				var arr: Array = report["counters"][pool]
				report["counters"][pool] = arr.slice(0, arr.size() / 2)
				body = JSON.stringify(report)
	_sending = true
	var sent_until := float(report["to"])
	var http := HTTPRequest.new()
	http.timeout = 30.0
	# Apps Script answers a POST with a 302 once the row is stored; following
	# it would re-send the report as another POST. (Browsers follow it as a
	# GET on their own, which is fine.)
	http.max_redirects = 0
	host.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h, _b):
		http.queue_free()
		_sending = false
		# The 302 (not followed, see below) comes back as "redirect limit
		# reached" -- it still means the report was stored.
		var ok_result := result == HTTPRequest.RESULT_SUCCESS or result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED
		if ok_result and code >= 200 and code < 400:
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

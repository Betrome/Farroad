extends Node
## The Farroad PvP server: the game itself, run headless.
## Start it with:  Farroad --headless -- --server [--port 8910] [--data DIR]
## (or any export with the "dedicated_server" feature). It speaks plain HTTP
## with JSON bodies; HTTPS comes from what's in front of it (Cloud Run).
##
## On Google Cloud Run: the PORT environment variable sets the port, and
## FARROAD_STORE=firestore keeps players in Firestore (the server's own disk
## is wiped whenever it sleeps). Run it with at most one instance, so fights
## never update the same ratings at once.
##
## Every fight is decided here with the game's own engine (Ranked.simulate),
## from teams uploaded as build inputs and checked by Ranked.validate, so a
## player can't fake a result or bring edited stats. The game replays the
## fight from the same seed for the player to watch.
##
## Accounts: the player ID the game already has plus a secret key the game
## makes on first use. The server only keeps a hash of the key.
##
## Endpoints (POST, JSON):
##   /hello     {id, key, name}            -> your rating and record
##   /team      {id, key, team}            -> stores your ranked team
##   /opponents {id, key}                  -> teams near your rating
##   /fight     {id, key, opponent}        -> the fight's seed, both teams, result
##   /leaderboard {}                       -> the top players
##   /season/claim {id, key, season}       -> takes a finished season's reward off your record (only with seasons on)
##   /version   {}                         -> the game build fights need
##   /stats     {}                         -> {bossAvg, players}: the average highest-cleared
##                                            boss wave of players who have cleared one (the
##                                            game's new-player catch-up fades out there)

const DEFAULT_PORT := 8910
const MAX_BODY := 65536
const OPPONENT_COUNT := 20
const FIGHTS_PER_DAY := 60
const LEADERBOARD_SIZE := 20
## Fights kept per player (attacks and defences), newest first.
const HISTORY_SIZE := 50
const REQUEST_TIMEOUT_MS := 20000

var port := DEFAULT_PORT
## Weekly seasons (see Seasons.gd) run only when the server is started with FARROAD_SEASONS=1 (or
## --seasons). Off, the server behaves exactly as it did before seasons existed.
var seasons_enabled := false
## The community raid boss (see Raids.gd) runs only with FARROAD_RAIDS=1 (or --raids). Off, /raid/* answers "raids_off".
var raids_enabled := false
## Tests only (--time-offset=SECONDS): moves the server's clock.
var time_offset := 0
var _season_current := -1
var _season_loaded := false
var _season_first := -1   # the first season ever run (season 1), so seasons can be shown as 1, 2, 3...
var server := TCPServer.new()
var clients: Array = []   # [{peer, buf, started, busy}]
var store: ArenaStore
## Requests are handled one at a time (a fight reads and writes two players).
var _working := false

func _ready() -> void:
	FarroadCore.load_real_content()
	var args := OS.get_cmdline_user_args()
	var env_port := OS.get_environment("PORT")
	if env_port.is_valid_int():
		port = int(env_port)
	seasons_enabled = OS.get_environment("FARROAD_SEASONS") == "1" or args.has("--seasons")
	raids_enabled = OS.get_environment("FARROAD_RAIDS") == "1" or args.has("--raids")
	for a in args:
		if a.begins_with("--time-offset="):
			time_offset = int(a.substr(14))
	var use_firestore := OS.get_environment("FARROAD_STORE") == "firestore" or args.has("--firestore")
	store = FirestoreStore.new() if use_firestore else ArenaStore.new()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif args[i] == "--data" and i + 1 < args.size():
			store.data_dir = args[i + 1]
	add_child(store)
	if not await store.open():
		printerr("Farroad server: storage didn't open")
		get_tree().quit(1)
		return
	await _seed_rivals()
	await _backfill_boss_stats()
	if seasons_enabled:
		await _season_tick()
	var bind := "127.0.0.1" if args.has("--local-only") else "*"
	var err := server.listen(port, bind)
	if err != OK:
		printerr("Farroad server: can't listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	print("Farroad server %s listening on port %d, players in %s" % [Ranked.game_version(), port, store.describe()])

## ===== the ready-made rival teams (listed with everyone else) =====

## Each rival from PvP.RIVALS is a server player that only defends. Its team
## is rebuilt every start (so it follows the game version); its rating and
## record carry on. A new rival starts at a rating that fits its level.
func _seed_rivals() -> void:
	for r in PvP.RIVALS:
		var id: String = "rival_" + str(r["id"])
		var team := _rival_team(r)
		var why := Ranked.validate(team)
		if why != "":
			printerr("Farroad server: rival %s isn't a valid team (%s)" % [r["id"], why])
			continue
		var rec = await store.get_player(id)
		if rec == null:
			rec = {"id": id, "keyHash": "", "rival": true, "rating": int(r.get("rating", 700 + int(r["level"]) * 10)),
				"wins": 0, "losses": 0, "defWins": 0, "defLosses": 0, "created": _now(),
				"fightDay": 0, "fightsToday": 0, "history": [], "flags": []}
		rec["name"] = str(r["name"])
		rec["team"] = team
		rec["power"] = Ranked.power_of(team)
		await store.put_player(rec)

func _rival_team(r: Dictionary) -> Dictionary:
	var units: Array = []
	for spec in r["units"]:
		var def = FarroadCore.roster_by_id(spec["id"])
		units.append({"id": spec["id"], "level": int(spec.get("level", r["level"])), "equipped": {}, "statInvest": {}, "affinities": {},
			"slots": (spec["slots"] as Array).map(func(s): return {"cond": s[0], "action": s[1]}),
			"row": def.get("row", "front") if def else "front", "look": Appearance.look({}, spec["id"])})
	return {"v": 2, "game": Ranked.game_version(), "units": units, "bonuses": (r["lore"] as Dictionary).duplicate(true)}

## ===== HTTP (just enough of HTTP/1.1 for small JSON requests) =====

func _process(_delta: float) -> void:
	while server.is_listening() and server.is_connection_available():
		var peer := server.take_connection()
		clients.append({"peer": peer, "buf": PackedByteArray(), "started": Time.get_ticks_msec(), "busy": false})
	for c in clients.duplicate():
		if c["busy"]:
			continue
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - int(c["started"]) > REQUEST_TIMEOUT_MS:
			peer.disconnect_from_host()
			clients.erase(c)
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_data(avail)
			if got[0] == OK:
				c["buf"].append_array(got[1])
		var req := _parse(c["buf"])
		if req.is_empty():
			if c["buf"].size() > MAX_BODY + 8192:
				_respond(peer, 413, {"error": "too_big"})
				clients.erase(c)
			continue
		c["busy"] = true
		_serve(c, req)

func _serve(c: Dictionary, req: Dictionary) -> void:
	while _working:
		await get_tree().process_frame
	_working = true
	var res: Array = await _route(req)
	_working = false
	_respond(c["peer"], res[0], res[1])
	clients.erase(c)

## {method, path, body} once a whole request has arrived, else {}.
func _parse(buf: PackedByteArray) -> Dictionary:
	var text := buf.get_string_from_utf8()
	var head_end := text.find("\r\n\r\n")
	if head_end < 0:
		return {}
	var lines := text.substr(0, head_end).split("\r\n")
	var first := lines[0].split(" ")
	if first.size() < 2:
		return {"method": "BAD", "path": "", "body": ""}
	var length := 0
	for i in range(1, lines.size()):
		var l := lines[i].to_lower()
		if l.begins_with("content-length:"):
			length = int(l.substr(15).strip_edges())
	if length > MAX_BODY:
		return {"method": "BIG", "path": "", "body": ""}
	# the body is counted in bytes, not characters
	var head_bytes := text.substr(0, head_end + 4).to_utf8_buffer().size()
	if buf.size() < head_bytes + length:
		return {}
	var body := buf.slice(head_bytes, head_bytes + length).get_string_from_utf8()
	return {"method": first[0], "path": first[1].split("?")[0], "body": body}

func _respond(peer: StreamPeerTCP, code: int, data: Dictionary) -> void:
	var body := JSON.stringify(data).to_utf8_buffer()
	var reason: String = {200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
		409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"}.get(code, "OK")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n" % [code, reason, 0 if code == 204 else body.size()]
	head += "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
	head += "Access-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
	peer.put_data(head.to_utf8_buffer())
	if code != 204:
		peer.put_data(body)
	peer.disconnect_from_host()

## [status code, response body]
func _route(req: Dictionary) -> Array:
	if req["method"] == "OPTIONS":
		return [204, {}]
	if req["method"] == "BIG":
		return [413, {"error": "too_big"}]
	if req["path"] == "/version" or req["path"] == "/":
		return [200, {"game": Ranked.game_version()}]
	if req["method"] != "POST":
		return [404, {"error": "not_found"}]
	var body = JSON.parse_string(req["body"]) if req["body"] != "" else {}
	if not (body is Dictionary):
		return [400, {"error": "bad_json"}]
	if seasons_enabled:
		await _season_tick()
	match req["path"]:
		"/leaderboard": return [200, await _leaderboard()]
		"/stats": return [200, await _stats()]
		"/hello": return await _hello(body)
		"/team": return await _team(body)
		"/opponents": return await _opponents(body)
		"/fight": return await _fight(body)
		"/save/put": return await _save_put(body)
		"/save/get": return await _save_get(body)
		"/season/claim": return await _season_claim(body)
		"/raid/state": return await _raid_state(body)
		"/raid/report": return await _raid_report(body)
	return [404, {"error": "not_found"}]

## ===== accounts =====

func _hash(key: String) -> String:
	return key.sha256_text()

func _now() -> int:
	return int(Time.get_unix_time_from_system()) + time_offset

## The caller's record (created on first use when `create`), or null.
func _auth(body: Dictionary, create: bool = false):
	var id := str(body.get("id", ""))
	var key := str(body.get("key", ""))
	if not Analytics.valid_id(id) or key.length() < 32 or key.length() > 128:
		return null
	var rec = await store.get_player(id)
	if rec != null:
		return rec if str(rec.get("keyHash", "")) != "" and rec["keyHash"] == _hash(key) else null
	if not create:
		return null
	rec = {"id": id, "keyHash": _hash(key), "name": "Traveler", "rating": Ranked.START_RATING,
		"wins": 0, "losses": 0, "defWins": 0, "defLosses": 0, "team": null, "power": 0,
		"created": _now(), "fightDay": 0, "fightsToday": 0, "history": [], "flags": []}
	await store.put_player(rec)
	return rec

func _flag(rec: Dictionary, why: String) -> void:
	var f: Array = rec.get("flags", [])
	f.append({"at": _now(), "why": why})
	rec["flags"] = f.slice(-50)

## Wins and losses count fights both made and defended (a team that only ever
## defended would otherwise show 0 wins).
func _public(rec: Dictionary) -> Dictionary:
	return {"id": rec["id"], "name": rec["name"], "rating": int(rec["rating"]),
		"wins": int(rec["wins"]) + int(rec.get("defWins", 0)), "losses": int(rec["losses"]) + int(rec.get("defLosses", 0)),
		"power": int(rec.get("power", 0)), "rival": bool(rec.get("rival", false))}

func _clean_name(n) -> String:
	var s := str(n).strip_edges().substr(0, 20)
	for ch in ["<", ">", "&", "\"", "'", "[", "]", "\n", "\r"]:
		s = s.replace(ch, "")
	# the game refuses these names too; this covers older or edited clients
	if NameFilter.is_blocked(s):
		return "Traveler"
	return s if s != "" else "Traveler"

func _hello(body: Dictionary) -> Array:
	var rec = await _auth(body, true)
	if rec == null:
		return [403, {"error": "bad_key"}]
	if body.has("name"):
		rec["name"] = _clean_name(body["name"])
		await store.put_player(rec)
	var out := {"me": _public(rec), "game": Ranked.game_version(), "hasTeam": rec.get("team") != null,
		"history": rec.get("history", [])}
	if seasons_enabled:
		out["season"] = _season_info(rec)
	return [200, out]

func _team(body: Dictionary) -> Array:
	var rec = await _auth(body)
	if rec == null:
		return [403, {"error": "bad_key"}]
	# with a cloud save, the team is built here from the last accepted save (so
	# the Arena always matches the real game); a team sent in the request is
	# only used by players who have never uploaded a save
	var team = Ranked.team_from_save(rec["save"]) if rec.get("save") is Dictionary else body.get("team")
	var why := Ranked.validate(team)
	if why != "":
		# kept for review: repeated impossible teams are what a cheat looks like
		if why != "wrong_version":
			_flag(rec, why)
			await store.put_player(rec)
		return [400, {"error": why}]
	# a legacy main character (from before creation points were kept) is
	# accepted as first seen and can't change afterwards
	if team.get("mc") is Dictionary and team["mc"].get("legacy") is Dictionary:
		var lg: Dictionary = team["mc"]["legacy"]
		if rec.get("mcLegacy") == null:
			rec["mcLegacy"] = lg
			_flag(rec, "legacy_mc")
		elif JSON.stringify(rec["mcLegacy"]) != JSON.stringify(lg):
			_flag(rec, "mc_changed")
			await store.put_player(rec)
			return [400, {"error": "mc_changed"}]
	rec["team"] = team
	rec["power"] = Ranked.power_of(team)
	if team.get("mc") is Dictionary:
		rec["name"] = _clean_name(team["mc"].get("name", rec["name"]))
	await store.put_player(rec)
	return [200, {"me": _public(rec)}]

func _opponents(body: Dictionary) -> Array:
	var rec = await _auth(body)
	if rec == null:
		return [403, {"error": "bad_key"}]
	var pool: Array = (await store.with_team(Ranked.game_version())).filter(func(p): return p["id"] != rec["id"])
	pool.sort_custom(func(a, b): return absi(int(a["rating"]) - int(rec["rating"])) < absi(int(b["rating"]) - int(rec["rating"])))
	var out: Array = []
	for p in pool.slice(0, OPPONENT_COUNT):
		var o := _public(p)
		o["units"] = (p["team"]["units"] as Array).map(func(u): return {"id": u["id"], "level": u["level"]})
		out.append(o)
	return [200, {"opponents": out}]

func _fight(body: Dictionary) -> Array:
	var rec = await _auth(body)
	if rec == null:
		return [403, {"error": "bad_key"}]
	if rec.get("team") == null:
		return [409, {"error": "no_team"}]
	if str(rec["team"].get("game", "")) != Ranked.game_version():
		return [409, {"error": "wrong_version"}]
	var opp_id := str(body.get("opponent", ""))
	var opp = null if opp_id == rec["id"] else await store.get_player(opp_id)
	if opp == null or opp.get("team") == null:
		return [404, {"error": "no_opponent"}]
	if str(opp["team"].get("game", "")) != Ranked.game_version():
		return [409, {"error": "opponent_outdated"}]
	var day := int(_now() / 86400.0)
	if int(rec.get("fightDay", 0)) != day:
		rec["fightDay"] = day
		rec["fightsToday"] = 0
	if int(rec["fightsToday"]) >= FIGHTS_PER_DAY:
		return [429, {"error": "daily_limit"}]
	rec["fightsToday"] = int(rec["fightsToday"]) + 1
	var seed := randi()
	var result := Ranked.simulate(rec["team"], opp["team"], seed)
	var won: bool = result["won"]
	var before := int(rec["rating"])
	var opp_before := int(opp["rating"])
	var ratings := Ranked.elo(float(rec["rating"]), float(opp["rating"]), won)
	rec["rating"] = ratings[0]
	opp["rating"] = ratings[1]
	rec["wins" if won else "losses"] = int(rec["wins" if won else "losses"]) + 1
	if seasons_enabled:
		_season_touch(rec)
		rec["seasonFights"] = int(rec["seasonFights"]) + 1
	opp["defLosses" if won else "defWins"] = int(opp["defLosses" if won else "defWins"]) + 1
	# each side's record notes the other side's Power at the time
	_log(rec, {"at": _now(), "vs": opp["name"], "power": int(opp.get("power", 0)), "attack": true, "won": won, "delta": int(rec["rating"]) - before})
	_log(opp, {"at": _now(), "vs": rec["name"], "power": int(rec.get("power", 0)), "attack": false, "won": not won, "delta": int(opp["rating"]) - opp_before})
	await store.put_player(rec)
	await store.put_player(opp)
	return [200, {"seed": seed, "won": won, "turns": result["turns"], "me": rec["team"], "them": opp["team"],
		"themName": opp["name"], "rating": int(rec["rating"]), "delta": int(rec["rating"]) - before}]

## ===== weekly seasons (only when seasons_enabled; see Seasons.gd) =====

const SEASON_DOC := "season"

## A player's season counters belong to one season; a new season starts them at zero.
func _season_touch(rec: Dictionary) -> void:
	if int(rec.get("seasonId", -1)) != _season_current:
		rec["seasonId"] = _season_current
		rec["seasonFights"] = 0

func _season_info(rec: Dictionary) -> Dictionary:
	var fights: int = int(rec.get("seasonFights", 0)) if int(rec.get("seasonId", -1)) == _season_current else 0
	return {"id": _season_current, "number": _season_current - _season_first + 1, "endsAt": Seasons.season_end(_season_current), "minFights": Seasons.MIN_FIGHTS,
		"fights": fights, "pending": rec.get("seasonPending", [])}

## Notices when the clock has moved into a new season and closes the one that ended.
func _season_tick() -> void:
	var now_season := Seasons.season_of(_now())
	if _season_loaded and now_season == _season_current:
		return
	var doc: Dictionary = await store.get_meta_doc(SEASON_DOC)
	var stored := int(doc.get("current", -1))
	_season_first = int(doc.get("first", now_season))
	if stored >= 0 and stored < now_season:
		_season_current = now_season
		await _close_season(stored)
	_season_current = now_season
	_season_loaded = true
	if stored != now_season:
		await store.put_meta_doc(SEASON_DOC, {"current": now_season, "first": _season_first})

## Ranks everyone who fought enough in season `old`, leaves each a pending reward, and pulls every
## real player's rating part of the way back to the starting rating.
func _close_season(old: int) -> void:
	var players: Array = await store.all_players()
	var qualifiers: Array = players.filter(func(p):
		return not bool(p.get("rival", false)) and p.get("team") != null and int(p.get("seasonId", -1)) == old 			and int(p.get("seasonFights", 0)) >= Seasons.MIN_FIGHTS)
	qualifiers.sort_custom(func(a, b): return int(a["rating"]) > int(b["rating"]))
	var rank_of := {}
	for i in qualifiers.size():
		rank_of[qualifiers[i]["id"]] = i + 1
	for p in players:
		if bool(p.get("rival", false)):
			continue
		if rank_of.has(p["id"]):
			var tier := Seasons.tier_for(int(p["rating"]), int(rank_of[p["id"]]))
			var pend: Array = p.get("seasonPending", [])
			pend.append({"season": old, "number": old - _season_first + 1, "tier": tier["id"], "rank": int(rank_of[p["id"]]), "of": qualifiers.size(),
				"rating": int(p["rating"]), "fights": int(p.get("seasonFights", 0))})
			p["seasonPending"] = pend.slice(-8)
		p["rating"] = Seasons.carried_rating(float(p["rating"]), float(Ranked.START_RATING))
		p["seasonFights"] = 0
		p["seasonId"] = old + 1
		await store.put_player(p)
	print("Farroad server: season %d closed, %d qualified" % [old, qualifiers.size()])

func _season_claim(body: Dictionary) -> Array:
	var rec = await _auth(body)
	if rec == null:
		return [403, {"error": "bad_key"}]
	var want := int(body.get("season", -1))
	var pend: Array = rec.get("seasonPending", [])
	for i in pend.size():
		if int(pend[i]["season"]) == want:
			var entry: Dictionary = pend[i]
			pend.remove_at(i)
			rec["seasonPending"] = pend
			# what this pays shows up in the player's next upload: it is credited so that upload passes
			var credit: Dictionary = rec["credit"] if rec.get("credit") is Dictionary else SaveCheck.new_credit(_now())
			SaveCheck.accrue(credit, _now())
			var t := Seasons.tier_by_id(String(entry["tier"]))
			SaveCheck.add_claim(credit, float(t["crystal"]), float(int(t["pulls"]) * FarroadProgression.pull_cost(1)), float(t["distilled"]))
			rec["credit"] = credit
			await store.put_player(rec)
			return [200, {"claimed": entry}]
	return [404, {"error": "nothing_to_claim"}]

## ===== the community raid boss (only when raids_enabled; see Raids.gd) =====

## (Requests are handled strictly one at a time -- see _working in _serve -- so reading and writing this document
## across awaits can't interleave with another request, as long as the server stays a single instance.)
func _raid_doc(week: int, create: bool) -> Dictionary:
	var name := "raid-%d" % week
	var doc: Dictionary = await store.get_meta_doc(name)
	if doc.is_empty() and create:
		# the community boss is sized by the players who are around: a save upload or a fight in the last 4 weeks
		var n := 0
		var recent := _now() - Raids.ACTIVE_WEEKS * 7 * 86400
		for p in await store.all_players():
			if bool(p.get("rival", false)):
				continue
			var last := int(p.get("saveAt", 0))
			for h in p.get("history", []):
				last = maxi(last, int(h.get("at", 0)))
			if last >= recent:
				n += 1
		doc = {"week": week, "shares": 0.0, "target": Raids.community_target(n), "players": {}, "att": {}}
		await store.put_meta_doc(name, doc)
	return doc

func _raid_view(doc: Dictionary, id: String) -> Dictionary:
	var shares := float(doc.get("shares", 0.0))
	var target := float(doc.get("target", Raids.COMMUNITY_MIN_TARGET))
	return {"week": int(doc["week"]), "shares": shares, "target": target, "mine": float((doc.get("players", {}) as Dictionary).get(id, 0.0)),
		"reached": Raids.milestones_reached(shares, target), "contributors": (doc.get("players", {}) as Dictionary).size()}

func _raid_state(body: Dictionary) -> Array:
	if not raids_enabled:
		return [200, {"error": "raids_off"}]
	var rec = await _auth(body, true)   # (the account is made on first use, as for cloud saves)
	if rec == null:
		return [403, {"error": "bad_key"}]
	var current := Seasons.season_of(_now())
	var week := int(body.get("week", current))
	var doc := await _raid_doc(week, week == current)
	if doc.is_empty():
		return [404, {"error": "no_such_week"}]
	return [200, _raid_view(doc, str(rec["id"]))]

## An attempt's share of the player's own boss, with the UTC day it was played (an attempt made offline is told
## later). A player adds at most one whole boss per week, and at most ATTEMPTS_PER_DAY attempts count per player per day. Only what a real game can't
## send is flagged: a day in the future.
func _raid_report(body: Dictionary) -> Array:
	if not raids_enabled:
		return [200, {"error": "raids_off"}]
	var rec = await _auth(body, true)   # (the account is made on first use, as for cloud saves)
	if rec == null:
		return [403, {"error": "bad_key"}]
	var current := Seasons.season_of(_now())
	if int(body.get("week", -1)) != current:
		return [200, {"error": "wrong_week"}]
	var today := int(floor(float(_now()) / 86400.0))
	var day := int(body.get("day", today))
	if day > today:
		_flag(rec, "raid_future_day")
		await store.put_player(rec)
		return [200, {"error": "bad_day"}]
	if Seasons.season_of(day * 86400) != current:
		return [200, {"error": "bad_day"}]   # played in an earlier week: that week is closed
	var doc := await _raid_doc(current, true)
	var id := str(rec["id"])
	var view := _raid_view(doc, id)
	if float(doc["shares"]) >= float(doc["target"]):
		return [200, view]   # the boss is already down
	var players: Dictionary = doc.get("players", {})
	# at most one whole boss per player per week (the share is of their OWN boss: they can't have taken more)
	var share: float = minf(clampf(float(body.get("pct", 0.0)), 0.0, 1.0), maxf(0.0, Raids.PLAYER_WEEK_CAP - float(players.get(id, 0.0))))
	var att: Dictionary = doc.get("att", {})
	var mine: Dictionary = att.get(id, {})
	var key := str(day)
	if int(mine.get(key, 0)) >= Raids.ATTEMPTS_PER_DAY:
		var full := view.duplicate()
		full["error"] = "day_full"
		return [200, full]
	mine[key] = int(mine.get(key, 0)) + 1
	att[id] = mine
	doc["att"] = att
	doc["shares"] = float(doc["shares"]) + share
	players[id] = float(players.get(id, 0.0)) + share
	doc["players"] = players
	await store.put_meta_doc("raid-%d" % current, doc)
	return [200, _raid_view(doc, id)]

## ===== cloud saves =====
const SAVE_MAX_BYTES := 400000

## Stores the player's save if it's possible after their last accepted one
## (SaveCheck); an impossible save is refused and flagged, and the last good
## one stays.
func _save_put(body: Dictionary) -> Array:
	var rec = await _auth(body, true)
	if rec == null:
		return [403, {"error": "bad_key"}]
	var snap = body.get("save")
	if not (snap is Dictionary) or JSON.stringify(snap).length() > SAVE_MAX_BYTES:
		return [400, {"error": "bad_save"}]
	var prev: Dictionary = rec["save"] if rec.get("save") is Dictionary else {}
	var elapsed: float = float(_now() - int(rec.get("saveAt", _now())))
	var credit: Dictionary = rec["credit"] if rec.get("credit") is Dictionary else SaveCheck.new_credit(_now())
	SaveCheck.accrue(credit, _now())
	var why := SaveCheck.check(prev, snap, elapsed, credit)
	if why != "":
		_flag(rec, "save_" + why)
		await store.put_player(rec)
		return [409, {"error": "save_refused", "why": why}]
	SaveCheck.spend_credit(credit, prev, snap, elapsed)
	rec["credit"] = credit
	rec["save"] = snap
	rec["saveAt"] = _now()
	if snap.get("mc") is Dictionary:
		rec["name"] = _clean_name(snap["mc"].get("name", rec["name"]))
	await _count_boss_wave(rec, boss_wave_of(snap))
	await store.put_player(rec)
	return [200, {"at": rec["saveAt"]}]

## ===== the average highest-cleared boss wave =====
## One running total ({sum, count}) over every player who has cleared a boss.
## Each player's own last counted value sits on their record ("bossWave"), so
## an improving player changes the total by the difference instead of being
## counted again -- the average stays exact. Requests are handled one at a
## time and the server runs as one instance, so the total never races.

const BOSS_STATS := "bossAvg"

## The boss wave a save last cleared (0 if none yet).
static func boss_wave_of(snap: Dictionary) -> int:
	var n := int(snap.get("bossesCleared", 0))
	return FarroadProgression.boss_wave_at(n - 1) if n > 0 else 0

## Moves the total from this player's counted value to `bw`. Does not write
## the player (the caller does).
func _count_boss_wave(rec: Dictionary, bw: int) -> void:
	var old := int(rec.get("bossWave", 0))
	if old == bw:
		return
	var st: Dictionary = await store.get_meta_doc(BOSS_STATS)
	var sum := int(st.get("sum", 0))
	var count := int(st.get("count", 0))
	if old > 0:
		sum -= old
		count -= 1
	if bw > 0:
		sum += bw
		count += 1
	rec["bossWave"] = bw
	sum = maxi(0, sum)
	count = maxi(0, count)
	await store.put_meta_doc(BOSS_STATS, {"sum": sum, "count": count})
	_sync_catchup_ref(sum, count)

## SaveCheck's first-upload ceilings assume the same catch-up the players get,
## so the server follows the average too -- with room for players whose game
## hasn't refreshed it yet, and never below the starting value.
func _sync_catchup_ref(sum: int, count: int) -> void:
	var ref := FarroadProgression.CATCHUP_REF_WAVE_DEFAULT
	if count >= CatchupRef.MIN_PLAYERS:
		ref = maxf(ref, 1.5 * float(sum) / float(count))
	FarroadProgression.catchup_ref_wave = ref

## First start with this feature: totals up the saves already stored.
func _backfill_boss_stats() -> void:
	var st: Dictionary = await store.get_meta_doc(BOSS_STATS)
	if not st.is_empty():
		_sync_catchup_ref(int(st.get("sum", 0)), int(st.get("count", 0)))
		return
	var sum := 0
	var count := 0
	for p in await store.all_players():
		var bw := boss_wave_of(p["save"]) if p.get("save") is Dictionary else 0
		if int(p.get("bossWave", 0)) != bw:
			p["bossWave"] = bw
			await store.put_player(p)
		if bw > 0:
			sum += bw
			count += 1
	await store.put_meta_doc(BOSS_STATS, {"sum": sum, "count": count})
	_sync_catchup_ref(sum, count)
	print("Farroad server: boss-wave total filled in from %d players" % count)

func _stats() -> Dictionary:
	var st: Dictionary = await store.get_meta_doc(BOSS_STATS)
	var count := int(st.get("count", 0))
	return {"bossAvg": float(st.get("sum", 0)) / float(count) if count > 0 else 0.0, "players": count}

func _save_get(body: Dictionary) -> Array:
	var rec = await _auth(body)
	if rec == null:
		return [403, {"error": "bad_key"}]
	if not (rec.get("save") is Dictionary):
		return [404, {"error": "no_save"}]
	return [200, {"save": rec["save"], "at": int(rec.get("saveAt", 0))}]

func _log(rec: Dictionary, entry: Dictionary) -> void:
	var h: Array = rec.get("history", [])
	h.push_front(entry)
	rec["history"] = h.slice(0, HISTORY_SIZE)

func _leaderboard() -> Dictionary:
	var top: Array = await store.top(LEADERBOARD_SIZE)
	return {"top": top.map(func(p): return _public(p))}

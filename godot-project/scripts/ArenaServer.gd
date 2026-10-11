extends Node
## The Farroad PvP server (Ian: option 2 -- the game itself, run headless).
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
##   /version   {}                         -> the game build fights need

const DEFAULT_PORT := 8910
const MAX_BODY := 65536
const OPPONENT_COUNT := 20
const FIGHTS_PER_DAY := 60
const LEADERBOARD_SIZE := 20
## Fights kept per player (attacks and defences), newest first.
const HISTORY_SIZE := 50
const REQUEST_TIMEOUT_MS := 20000

var port := DEFAULT_PORT
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
	var bind := "127.0.0.1" if args.has("--local-only") else "*"
	var err := server.listen(port, bind)
	if err != OK:
		printerr("Farroad server: can't listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	print("Farroad server %s listening on port %d, players in %s" % [Ranked.game_version(), port, store.describe()])

## ===== the ready-made rival teams (Ian: listed with everyone else) =====

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
	match req["path"]:
		"/leaderboard": return [200, await _leaderboard()]
		"/hello": return await _hello(body)
		"/team": return await _team(body)
		"/opponents": return await _opponents(body)
		"/fight": return await _fight(body)
		"/save/put": return await _save_put(body)
		"/save/get": return await _save_get(body)
	return [404, {"error": "not_found"}]

## ===== accounts =====

func _hash(key: String) -> String:
	return key.sha256_text()

func _now() -> int:
	return int(Time.get_unix_time_from_system())

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

## Wins and losses count fights both made and defended (Ian: a team that
## only ever defended used to show 0 wins).
func _public(rec: Dictionary) -> Dictionary:
	return {"id": rec["id"], "name": rec["name"], "rating": int(rec["rating"]),
		"wins": int(rec["wins"]) + int(rec.get("defWins", 0)), "losses": int(rec["losses"]) + int(rec.get("defLosses", 0)),
		"power": int(rec.get("power", 0)), "rival": bool(rec.get("rival", false))}

func _clean_name(n) -> String:
	var s := str(n).strip_edges().substr(0, 20)
	for ch in ["<", ">", "&", "\"", "'", "[", "]", "\n", "\r"]:
		s = s.replace(ch, "")
	return s if s != "" else "Traveler"

func _hello(body: Dictionary) -> Array:
	var rec = await _auth(body, true)
	if rec == null:
		return [403, {"error": "bad_key"}]
	if body.has("name"):
		rec["name"] = _clean_name(body["name"])
		await store.put_player(rec)
	return [200, {"me": _public(rec), "game": Ranked.game_version(), "hasTeam": rec.get("team") != null,
		"history": rec.get("history", [])}]

func _team(body: Dictionary) -> Array:
	var rec = await _auth(body)
	if rec == null:
		return [403, {"error": "bad_key"}]
	# with a cloud save, the team is built here from the last accepted save
	# (Ian: so the Arena always matches the real game); a team sent in the
	# request is only used by players who have never uploaded a save
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
	opp["defLosses" if won else "defWins"] = int(opp["defLosses" if won else "defWins"]) + 1
	# each side's record notes the other side's Power at the time
	_log(rec, {"at": _now(), "vs": opp["name"], "power": int(opp.get("power", 0)), "attack": true, "won": won, "delta": int(rec["rating"]) - before})
	_log(opp, {"at": _now(), "vs": rec["name"], "power": int(rec.get("power", 0)), "attack": false, "won": not won, "delta": int(opp["rating"]) - opp_before})
	await store.put_player(rec)
	await store.put_player(opp)
	return [200, {"seed": seed, "won": won, "turns": result["turns"], "me": rec["team"], "them": opp["team"],
		"themName": opp["name"], "rating": int(rec["rating"]), "delta": int(rec["rating"]) - before}]

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
	var why := SaveCheck.check(prev, snap, elapsed)
	if why != "":
		_flag(rec, "save_" + why)
		await store.put_player(rec)
		return [409, {"error": "save_refused", "why": why}]
	rec["save"] = snap
	rec["saveAt"] = _now()
	if snap.get("mc") is Dictionary:
		rec["name"] = _clean_name(snap["mc"].get("name", rec["name"]))
	await store.put_player(rec)
	return [200, {"at": rec["saveAt"]}]

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

class_name RankedClient
extends Node
## The game's side of ranked PvP: talks to the Farroad PvP server
## (ArenaServer.gd) over HTTPS with small JSON requests.
##
## The account is the player ID the game already shows plus a secret key
## made on this device the first time (kept in user://arena_account.json,
## never shown). The server stores only a hash of it.

## Where the PvP server lives (Google Cloud Run). For testing against a
## server on this PC, start the game with "-- --arena http://127.0.0.1:8910".
const DEFAULT_URL := "https://farroad-arena-226468542723.us-central1.run.app"
const ACCOUNT_FILE := "user://arena_account.json"
const TIMEOUT_SEC := 15.0

static func server_url() -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--arena")
	if i >= 0 and i + 1 < args.size():
		return str(args[i + 1]).trim_suffix("/")
	return DEFAULT_URL

static func online() -> bool:
	return server_url() != ""

static func _key() -> String:
	if FileAccess.file_exists(ACCOUNT_FILE):
		var f := FileAccess.open(ACCOUNT_FILE, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text())
		f.close()
		if d is Dictionary and str(d.get("key", "")).length() >= 32:
			return str(d["key"])
	var crypto := Crypto.new()
	var key := crypto.generate_random_bytes(24).hex_encode()
	var w := FileAccess.open(ACCOUNT_FILE, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify({"key": key}))
		w.close()
	return key

## One request. Returns the server's JSON, or {"error": "..."} when the
## server can't be reached ("offline") or answered with an error.
func call_api(path: String, body: Dictionary = {}) -> Dictionary:
	if not online():
		return {"error": "offline"}
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT_SEC
	add_child(req)
	var payload := body.duplicate()
	payload["id"] = Analytics.install_id()
	payload["key"] = _key()
	var err := req.request(server_url() + path, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		req.queue_free()
		return {"error": "offline"}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"error": "offline"}
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if not (data is Dictionary):
		return {"error": "bad_reply"}
	if int(res[1]) != 200 and not data.has("error"):
		data["error"] = "http_%d" % int(res[1])
	return data

## Player-facing words for an error code.
static func explain(code: String) -> String:
	match code:
		"offline": return "Can't reach the Arena server. Check your connection and try again."
		"wrong_version", "opponent_outdated": return "This fight needs the latest version of Farroad on both sides. Update the game and try again."
		"daily_limit": return "That's all the ranked fights for today. Come back tomorrow."
		"no_team": return "Your team hasn't reached the server yet. Open the Arena again."
		"no_opponent": return "That opponent isn't available any more."
		"bad_key": return "This device's Arena account doesn't match the server's."
		"shared_action": return "Two of your units use the same action. Give each its own and try again."
	return "The Arena server turned the team down (%s)." % code

class_name CloudSave
extends Node
## Cloud saves (Ian): the game keeps a copy of the save on the Farroad
## server, uploaded a few minutes after it changes and whenever the game is
## closed or put in the background. The server checks each upload against
## the last one (SaveCheck) and builds the Arena team from it. Opening the
## game offers a newer save from another device, and a recovery code moves
## the account (and its save) to a new device.

const UPLOAD_EVERY_SEC := 180.0

var _client: RankedClient
var _dirty := false
var _busy := false
## While true nothing is uploaded: set until the game has compared this device's save with the cloud copy
## (and, if the cloud copy is further along, until the player has chosen). The 3-minute timer, the
## app-paused upload and every other caller all go through upload(), so one flag covers them all.
var held := false
## True when the last fetch() failed for a reason other than 'nothing stored' (offline, server error).
var fetch_failed := false
var get_snapshot: Callable   # -> the save as a Dictionary (GameController's)

func setup(client: RankedClient, snapshot: Callable) -> void:
	_client = client
	get_snapshot = snapshot
	var t := Timer.new()
	t.wait_time = UPLOAD_EVERY_SEC
	t.autostart = true
	t.ignore_time_scale = true
	t.timeout.connect(func():
		if _dirty:
			upload())
	add_child(t)

func mark_dirty() -> void:
	_dirty = true

## Sends the current save. Returns "" when stored, else the error code
## ("offline", "save_refused", ...).
func upload() -> String:
	if held:
		return "held"   # _dirty stays set, so the save goes up once the hold is lifted
	if _busy or not RankedClient.online() or not get_snapshot.is_valid():
		return "busy"
	_busy = true
	_dirty = false
	var res := await _client.call_api("/save/put", {"save": get_snapshot.call()})
	_busy = false
	if res.has("error"):
		if str(res["error"]) == "offline":
			_dirty = true   # try again next time
		return str(res["error"])
	return ""

## The save stored on the server for this account, or {} if none.
func fetch() -> Dictionary:
	var res := await _client.call_api("/save/get")
	fetch_failed = false
	if res.has("error"):
		# "no_save" / "bad_key": nothing is stored for this account yet. Anything else is a failure.
		var e := str(res["error"])
		fetch_failed = e != "no_save" and e != "bad_key"
		return {}
	if not (res.get("save") is Dictionary):
		return {}
	return res["save"]

## ===== recovery codes =====

## This device's account as one code to type or paste elsewhere:
## "<player ID>-<secret key>".
static func recovery_code() -> String:
	return "%s-%s" % [Analytics.install_id(), RankedClient._key()]

## Switches this device to the account in `code`. Returns "" or why not.
static func use_recovery_code(code: String) -> String:
	var c := code.strip_edges().replace(" ", "")
	var dash := c.find("-")
	if dash < 0:
		return "That doesn't look like a recovery code."
	var id := c.substr(0, dash).replace("-", "").to_upper()
	var key := c.substr(dash + 1).to_lower()
	if not Analytics.valid_id(id) or key.length() < 32 or key.length() > 128 or not key.is_valid_hex_number():
		return "That doesn't look like a recovery code."
	Analytics.enabled()   # loads the device settings
	Analytics.state["id"] = id
	Analytics._dirty = true
	Analytics.save()
	var f := FileAccess.open(RankedClient.account_file(), FileAccess.WRITE)
	if f == null:
		return "Couldn't store the account on this device."
	f.store_string(JSON.stringify({"key": key}))
	f.close()
	return ""

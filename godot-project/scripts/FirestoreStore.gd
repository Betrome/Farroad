class_name FirestoreStore
extends ArenaStore
## The PvP server's players in Google Firestore, through its REST API.
##
## On Cloud Run the server logs in as its own Google service account: it asks
## the metadata server for a short-lived token, so no key is stored anywhere.
## For local testing against the Firestore emulator, set
## FIRESTORE_EMULATOR_HOST (e.g. "127.0.0.1:8080") and a project id.
##
## Each player is one document in "players" (id = player ID). The full
## record is kept as JSON text in "data"; "rating", "hasTeam" and "game"
## sit beside it so the database can sort and filter on them.

const COLLECTION := "players"
const METADATA := "http://metadata.google.internal/computeMetadata/v1"

var project := ""
var _base := ""
var _token := ""
var _token_until := 0.0
var _emulator := ""

func open() -> bool:
	_emulator = OS.get_environment("FIRESTORE_EMULATOR_HOST")
	project = OS.get_environment("GOOGLE_CLOUD_PROJECT")
	if project == "" and _emulator == "":
		var r := await _http(METADATA + "/project/project-id", ["Metadata-Flavor: Google"], HTTPClient.METHOD_GET, "")
		if r["code"] == 200:
			project = r["text"].strip_edges()
	if project == "":
		project = "farroad-local" if _emulator != "" else ""
	if project == "":
		printerr("Farroad server: no Google Cloud project found")
		return false
	var host := ("http://" + _emulator) if _emulator != "" else "https://firestore.googleapis.com"
	_base = "%s/v1/projects/%s/databases/(default)/documents" % [host, project]
	return true

func describe() -> String:
	return "Firestore, project %s%s" % [project, " (emulator)" if _emulator != "" else ""]

## ===== plumbing =====

func _http(url: String, headers: Array, method: int, body: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	var err := req.request(url, PackedStringArray(headers), method, body)
	if err != OK:
		req.queue_free()
		printerr("Farroad server: request to %s didn't start (%d)" % [url.split("?")[0], err])
		return {"code": 0, "text": ""}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		printerr("Farroad server: request to %s failed (result %d)" % [url.split("?")[0], int(res[0])])
	return {"code": int(res[1]) if int(res[0]) == HTTPRequest.RESULT_SUCCESS else 0,
		"text": (res[3] as PackedByteArray).get_string_from_utf8()}

func _auth_headers() -> Array:
	if _emulator != "":
		return ["Authorization: Bearer owner", "Content-Type: application/json"]
	if _token == "" or Time.get_unix_time_from_system() > _token_until - 60.0:
		var r := await _http(METADATA + "/instance/service-accounts/default/token", ["Metadata-Flavor: Google"], HTTPClient.METHOD_GET, "")
		var d = JSON.parse_string(r["text"]) if r["code"] == 200 else null
		if d is Dictionary:
			_token = str(d.get("access_token", ""))
			_token_until = Time.get_unix_time_from_system() + float(d.get("expires_in", 0))
		else:
			printerr("Farroad server: no access token (%d): %s" % [r["code"], r["text"].substr(0, 200)])
	return ["Authorization: Bearer " + _token, "Content-Type: application/json"]

func _to_doc(rec: Dictionary) -> Dictionary:
	return {"fields": {
		"data": {"stringValue": JSON.stringify(rec)},
		"rating": {"integerValue": str(int(rec.get("rating", 0)))},
		"hasTeam": {"booleanValue": rec.get("team") != null},
		"game": {"stringValue": str(rec["team"].get("game", "")) if rec.get("team") is Dictionary else ""}}}

func _from_doc(doc) -> Variant:
	if not (doc is Dictionary) or not (doc.get("fields") is Dictionary):
		return null
	var data = JSON.parse_string(str(doc["fields"].get("data", {}).get("stringValue", "")))
	return data if data is Dictionary else null

func _query(structured: Dictionary) -> Array:
	var r := await _http(_base + ":runQuery", await _auth_headers(), HTTPClient.METHOD_POST,
		JSON.stringify({"structuredQuery": structured}))
	var out: Array = []
	var rows = JSON.parse_string(r["text"]) if r["code"] == 200 else null
	if rows is Array:
		for row in rows:
			var rec = _from_doc(row.get("document")) if row is Dictionary else null
			if rec != null:
				out.append(rec)
	return out

## ===== the calls =====

func get_player(id: String):
	var r := await _http("%s/%s/%s" % [_base, COLLECTION, id.uri_encode()], await _auth_headers(), HTTPClient.METHOD_GET, "")
	if r["code"] != 200:
		return null
	return _from_doc(JSON.parse_string(r["text"]))

func put_player(rec: Dictionary) -> bool:
	var r := await _http("%s/%s/%s" % [_base, COLLECTION, str(rec["id"]).uri_encode()], await _auth_headers(),
		HTTPClient.METHOD_PATCH, JSON.stringify(_to_doc(rec)))
	if r["code"] != 200:
		printerr("Farroad server: Firestore write failed (%d): %s" % [r["code"], r["text"].substr(0, 300)])
	return r["code"] == 200

func with_team(version: String) -> Array:
	return await _query({"from": [{"collectionId": COLLECTION}],
		"where": {"fieldFilter": {"field": {"fieldPath": "game"}, "op": "EQUAL", "value": {"stringValue": version}}},
		"limit": 500})

func top(n: int) -> Array:
	var rows: Array = await _query({"from": [{"collectionId": COLLECTION}],
		"orderBy": [{"field": {"fieldPath": "rating"}, "direction": "DESCENDING"}], "limit": n * 3})
	return rows.filter(func(p): return p.get("team") != null).slice(0, n)

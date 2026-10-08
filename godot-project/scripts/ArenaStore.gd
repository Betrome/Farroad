class_name ArenaStore
extends Node
## Where the PvP server keeps its players. Two kinds, same calls:
## - FILES (this base class): one JSON file per player in a folder. Used for
##   testing on a PC.
## - FIRESTORE (FirestoreStore.gd): Google's database, used on Cloud Run,
##   where the server's own disk is wiped whenever it sleeps.
## Every call is awaited, so both kinds can be swapped freely.

var data_dir := "user://arena"
var _players: Dictionary = {}   # id -> record

func open() -> bool:
	DirAccess.make_dir_recursive_absolute(data_dir + "/players")
	var dir := DirAccess.open(data_dir + "/players")
	if dir == null:
		return false
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var fa := FileAccess.open(data_dir + "/players/" + f, FileAccess.READ)
		if fa == null:
			continue
		var rec = JSON.parse_string(fa.get_as_text())
		fa.close()
		if rec is Dictionary and rec.has("id"):
			_players[str(rec["id"])] = rec
	return true

func describe() -> String:
	return "files in %s (%d players)" % [ProjectSettings.globalize_path(data_dir), _players.size()]

## A player's record, or null.
func get_player(id: String):
	await get_tree().process_frame
	return _players.get(id)

func put_player(rec: Dictionary) -> bool:
	await get_tree().process_frame
	_players[str(rec["id"])] = rec
	var path := data_dir + "/players/" + str(rec["id"]) + ".json"
	var tmp := path + ".tmp"
	var fa := FileAccess.open(tmp, FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_string(JSON.stringify(rec))
	fa.close()
	DirAccess.rename_absolute(tmp, path)
	return true

## Every player with a team for this game version.
func with_team(version: String) -> Array:
	await get_tree().process_frame
	return _players.values().filter(func(p): return p.get("team") != null and str(p["team"].get("game", "")) == version)

## The highest-rated players with a team, best first.
func top(n: int) -> Array:
	await get_tree().process_frame
	var all: Array = _players.values().filter(func(p): return p.get("team") != null)
	all.sort_custom(func(a, b): return int(a["rating"]) > int(b["rating"]))
	return all.slice(0, n)

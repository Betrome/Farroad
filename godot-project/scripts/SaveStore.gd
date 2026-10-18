extends RefCounted
## Where the game's files live and how the save is written and read.
##
## Writing is crash-safe: the new save is written to a temp file, checked by
## reading it back, and only then moved over the real one; the last good save
## is kept next to it as a .bak. Reading falls back to that .bak, and if
## neither file can be read it says so (the caller must not start a new game
## silently, nor upload one over the cloud copy).
##
## Debug builds (the editor, debug exports) use their own files, prefixed
## "debug_", so testing never touches a real player's save, analytics or
## Arena account.

const SUFFIX_TMP := ".tmp"
const SUFFIX_BAK := ".bak"
const SUFFIX_CORRUPT := ".corrupt"

## "user://<name>", or "user://debug_<name>" in a debug build.
static func user_file(name: String) -> String:
	return "user://" + ("debug_" + name if OS.is_debug_build() else name)

static func save_path() -> String:
	return user_file("save.json")

## The parsed snapshot in `path`, or {} when the file is missing or unreadable.
static func _parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

## Save `snap` safely. Returns false (and leaves the existing save alone) when it couldn't be written.
static func write(snap: Dictionary, path: String = "") -> bool:
	if path == "":
		path = save_path()
	var tmp := path + SUFFIX_TMP
	var bak := path + SUFFIX_BAK
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("SaveStore: failed to open %s for writing" % tmp)
		return false
	f.store_string(JSON.stringify(snap))
	f.flush()
	f.close()
	# the temp file must read back as a whole save before it replaces anything
	if _parse_file(tmp).is_empty():
		push_error("SaveStore: %s did not read back; keeping the existing save" % tmp)
		DirAccess.remove_absolute(tmp)
		return false
	# keep the current save as the backup, but only if it is itself a good one
	if FileAccess.file_exists(path) and not _parse_file(path).is_empty():
		DirAccess.copy_absolute(path, bak)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		# some platforms won't rename over an existing file: remove it (the .bak holds it) and retry
		DirAccess.remove_absolute(path)
		err = DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_error("SaveStore: could not move %s into place (error %d)" % [tmp, err])
		return false
	return true

## What is on disk:
##   {"state": "none"}                          no save at all (a genuinely new player)
##   {"state": "ok", "data": snap}              the save read normally
##   {"state": "restored", "data": snap}        the save was damaged; the backup was used
##   {"state": "unreadable"}                    files exist but neither can be read
static func read(path: String = "") -> Dictionary:
	if path == "":
		path = save_path()
	var bak := path + SUFFIX_BAK
	var main_exists := FileAccess.file_exists(path)
	var bak_exists := FileAccess.file_exists(bak)
	if not main_exists and not bak_exists:
		return {"state": "none"}
	var main := _parse_file(path)
	if not main.is_empty():
		return {"state": "ok", "data": main}
	var back := _parse_file(bak)
	if not back.is_empty():
		if main_exists:
			# keep the damaged file for inspection, then put the backup back in its place
			DirAccess.copy_absolute(path, path + SUFFIX_CORRUPT)
		DirAccess.copy_absolute(bak, path)
		return {"state": "restored", "data": back}
	return {"state": "unreadable"}

## Move any damaged files aside (so a new game can start without losing them).
static func set_aside_damaged(path: String = "") -> void:
	if path == "":
		path = save_path()
	for suffix in ["", SUFFIX_BAK, SUFFIX_TMP]:
		var p: String = path + suffix
		if FileAccess.file_exists(p):
			var target: String = path + SUFFIX_CORRUPT + suffix
			if FileAccess.file_exists(target):
				DirAccess.remove_absolute(target)   # an earlier .corrupt (e.g. from a restore) would block the rename
			DirAccess.rename_absolute(p, target)

## Remove the save and its backup (Reset Game): otherwise the .bak would bring the old game back.
static func delete_all(path: String = "") -> void:
	if path == "":
		path = save_path()
	for suffix in ["", SUFFIX_BAK, SUFFIX_TMP]:
		var p: String = path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

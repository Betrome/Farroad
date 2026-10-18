extends Node
## Test-build patch loader (autoload, first thing that runs).
##
## A "patch" is a Godot .pck that holds only the files changed since a base
## export (see tools/patch/README.md). In a TEST build only, this loads it at
## startup so a phone can try a code change without a full APK install. Test
## builds are exported from the "Android Test" preset, which carries the custom
## feature "patchable"; every other build (including every release) has no such
## feature and this script does nothing.
##
## Where the patch is read from:
##   user://patch/patch.pck                                  (desktop; also usable on Android)
##   /storage/emulated/0/Android/data/<package>/files/patch.pck   (Android; `adb push` writes here)
##
## Crash-loop guard: a marker file is written before the patch is loaded and
## removed by mark_boot_ok() once the game has run for a few seconds. If the
## marker is still there at the next start, the previous start never finished, so
## the patch is set aside (renamed .bad) and the game starts without it. That
## keeps a broken patch from locking the game out.
##
## Limits (a patch cannot change these; they need a new base APK): new
## class_name scripts (the class list is read before this runs), project
## settings and autoloads, native plugins, the engine.

const PATCH_DIR := "user://patch"
const MARKER := "user://patch/booting"
const ANDROID_FILES := "/storage/emulated/0/Android/data/com.farroad.game/files"

var status := "No patch."
var patch_path := ""     # the patch file that was loaded ("" if none)
var info: Dictionary = {}   # res://patch_info.json after loading

func _init() -> void:
	if not enabled():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PATCH_DIR))
	var found := _find_patch()
	if found == "":
		return
	if FileAccess.file_exists(MARKER):
		# the last start with a patch never reached mark_boot_ok()
		_set_aside(found)
		status = "A patch was set aside: the last start with it never finished."
		print("PatchLoader: ", status)
		return
	var f := FileAccess.open(MARKER, FileAccess.WRITE)
	if f != null:
		f.store_string(found)
		f.close()
	if ProjectSettings.load_resource_pack(found, true):
		patch_path = found
		info = _read_info()
		status = "Patch loaded: %s" % str(info.get("stamp", "unknown build"))
	else:
		_clear_marker()
		status = "The patch file could not be loaded."
	print("PatchLoader: ", status)

## Whether patches are used in this build.
static func enabled() -> bool:
	if OS.has_feature("patchable"):
		return true
	# desktop testing from the editor or a debug export
	return OS.is_debug_build() and OS.get_cmdline_user_args().has("--patchable")

## Called by GameController after the game has been running a few seconds.
func mark_boot_ok() -> void:
	_clear_marker()

## Deletes the patch file(s); the change takes effect at the next start.
func remove_patch() -> void:
	for p in _candidates():
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_clear_marker()
	status = "Patch removed. Restart the game."

func _candidates() -> Array:
	var out: Array = [ProjectSettings.globalize_path(PATCH_DIR) + "/patch.pck"]
	if OS.has_feature("android"):
		out.append(ANDROID_FILES + "/patch.pck")
	return out

func _find_patch() -> String:
	for p in _candidates():
		if FileAccess.file_exists(p):
			return p
	return ""

func _set_aside(path: String) -> void:
	_clear_marker()
	DirAccess.rename_absolute(path, path + ".bad")

func _clear_marker() -> void:
	if FileAccess.file_exists(MARKER):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MARKER))

func _read_info() -> Dictionary:
	if not FileAccess.file_exists("res://patch_info.json"):
		return {}
	var f := FileAccess.open("res://patch_info.json", FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}

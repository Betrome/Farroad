class_name Updates
extends RefCounted
## Patch notes and the "is there a newer version?" check (Settings).
##
## The notes for each version are bundled in data/patch_notes.json (newest
## first), so they work offline and can be read before a release goes out.
## The check asks GitHub which release is the latest; it only reads, and sends
## nothing about the player.

const RELEASE_URL := "https://api.github.com/repos/Betrome/Farroad/releases/latest"

static func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))

## "2.36" / "v2.37" -> [2, 36] / [2, 37].
static func parse(v: String) -> Array:
	var out: Array = []
	for part in v.trim_prefix("v").split("."):
		out.append(int(part) if part.is_valid_int() else 0)
	return out

## True when version `a` is newer than `b`.
static func is_newer(a: String, b: String) -> bool:
	var pa := parse(a)
	var pb := parse(b)
	for i in maxi(pa.size(), pb.size()):
		var x: int = pa[i] if i < pa.size() else 0
		var y: int = pb[i] if i < pb.size() else 0
		if x != y:
			return x > y
	return false

## Settings: whether the game looks for a new version when it starts.
static func check_enabled() -> bool:
	return bool(Analytics.state.get("updateCheck", true)) if not Analytics.state.is_empty() else true

static func set_check_enabled(on: bool) -> void:
	Analytics.enabled()
	Analytics.state["updateCheck"] = on
	Analytics._dirty = true
	Analytics.save()

static func load_notes() -> Array:
	var f := FileAccess.open("res://data/patch_notes.json", FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Array else []

static func has_notes_for(version: String) -> bool:
	for e in load_notes():
		if str(e.get("version", "")) == version:
			return true
	return false

## The notes as text for a RichTextLabel: one entry (`only`) or every version,
## newest first, with versions newer than the one running marked "coming next".
static func notes_bbcode(only: String = "") -> String:
	var cur := current_version()
	var out := ""
	for e in load_notes():
		var ver := str(e.get("version", ""))
		if only != "" and ver != only:
			continue
		var tag := "  (coming next)" if is_newer(ver, cur) else ("  (you're on this)" if ver == cur else "")
		out += "[b][font_size=20]Version %s[/font_size][/b]%s\n" % [ver, tag]
		if str(e.get("title", "")) != "":
			out += "[i]%s[/i]\n" % _plain(str(e["title"]))
		for line in e.get("notes", []):
			out += "• %s\n" % _inline(str(line))
		out += "\n"
	return out.strip_edges() if out != "" else "No patch notes yet."

## Text from outside (a GitHub release) shown safely: no way to inject BBCode.
static func _plain(s: String) -> String:
	return s.replace("[", "[lb]")

## **bold** -> bold, on already-escaped text.
static func _inline(s: String) -> String:
	var re := RegEx.new()
	re.compile("\\*\\*(.+?)\\*\\*")
	return re.sub(_plain(s), "[b]$1[/b]", true)

## A GitHub release body (markdown) as plain, safe BBCode.
static func release_bbcode(body: String) -> String:
	var out := ""
	for raw in body.replace("\r", "").split("\n"):
		var line := raw.strip_edges(false, true)
		if line.begins_with("#"):
			out += "[b]%s[/b]\n" % _plain(line.lstrip("#").strip_edges())
		elif line.begins_with("- ") or line.begins_with("* "):
			out += "• %s\n" % _inline(line.substr(2))
		elif line == "":
			out += "\n"
		else:
			out += _inline(line) + "\n"
	return out.strip_edges()

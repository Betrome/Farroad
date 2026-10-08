class_name UnitSets
extends RefCounted
## The saved-sets section shared by the Gambits and Equipment screens
## (Ian: "5 per unit gambit and gear sets in their tabs that can be saved and
## loaded similar to parties"). Name it, save the unit's current gambits or
## gear, load or delete it later; up to FarroadProgression.UNIT_SET_CAP each.

## kind is "gambit" or "gear". `on_change` runs after a load/save/delete so
## the screen can rebuild. Returns a VBoxContainer to add to the screen.
## A message from the last load (what couldn't be filled), shown once on the
## rebuilt screen.
static var last_note: String = ""

static func build(g: Dictionary, uid: String, kind: String, on_change: Callable) -> VBoxContainer:
	var gambit: bool = kind == "gambit"
	var sets: Array = FarroadProgression.loadout_sets(g, uid) if gambit else FarroadProgression.gear_sets(g, uid)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var header := Label.new()
	header.text = "%s SETS (%d/%d)" % ["GAMBIT" if gambit else "GEAR", sets.size(), FarroadProgression.UNIT_SET_CAP]
	header.modulate = Palette.PARTY_BLUE
	box.add_child(header)

	var save_row := HBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Set name"
	name_edit.max_length = 24
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(name_edit)
	var save_btn := Button.new()
	save_btn.text = "Save current"
	var full: bool = sets.size() >= FarroadProgression.UNIT_SET_CAP
	save_btn.disabled = full
	if full:
		save_btn.tooltip_text = "Up to %d sets per unit -- delete one to save another." % FarroadProgression.UNIT_SET_CAP
	var note := Label.new()
	note.modulate = Palette.TEXT_DIM
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if last_note != "":
		note.text = last_note
		note.visible = true
		last_note = ""
	else:
		note.visible = false
	save_btn.pressed.connect(func():
		var nm: String = name_edit.text.strip_edges()
		if nm == "":
			nm = "Set %d" % (sets.size() + 1)
		var ok: bool = FarroadProgression.save_loadout_set(g, uid, nm) if gambit else FarroadProgression.save_gear_set(g, uid, nm)
		if ok:
			on_change.call())
	save_row.add_child(save_btn)
	box.add_child(save_row)

	for i in range(sets.size()):
		var s: Dictionary = sets[i]
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = "%s -- %s" % [s["name"], _summary(s, gambit)]
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		var load_btn := Button.new()
		load_btn.text = "Load"
		load_btn.pressed.connect(func():
			var n: int = FarroadProgression.load_loadout_set(g, uid, i) if gambit else FarroadProgression.load_gear_set(g, uid, i)
			if n > 0:
				last_note = ("%d slot%s could not be filled (action or gambit missing, or in use by another unit) and were left on the default."
					if gambit else "%d piece%s could not be equipped (not owned, or all copies are in use).") % [n, "" if n == 1 else "s"]
			on_change.call())
		row.add_child(load_btn)
		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.pressed.connect(func():
			var _ok: bool = FarroadProgression.delete_loadout_set(g, uid, i) if gambit else FarroadProgression.delete_gear_set(g, uid, i)
			on_change.call())
		row.add_child(del_btn)
		box.add_child(row)
	box.add_child(note)
	return box

static func _summary(s: Dictionary, gambit: bool) -> String:
	if gambit:
		var names: Array = []
		for sl in s["slots"]:
			var a = FarroadCore.ACTIONS.get(sl["action"])
			names.append(str(a["name"]) if a else str(sl["action"]))
		return ", ".join(names)
	var bits: Array = []
	for slot in FarroadCore.EQUIPMENT_SLOTS:
		var id = (s["items"] as Dictionary).get(slot)
		if id != null:
			var item = FarroadCore.EQUIPMENT.get(id)
			bits.append(str(item["name"]) if item else str(id))
	return ", ".join(bits) if not bits.is_empty() else "nothing equipped"

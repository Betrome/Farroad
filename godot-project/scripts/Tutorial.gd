class_name Tutorial
extends Node
## Ian's guided onboarding: menus unlock at fixed waves, each with a
## hands-on tutorial. Everything outside the control the player needs is
## darkened, the Road pauses, and the tutorial only finishes once the real
## action is done. Each tutorial pays 1 Crystal (Marks pays 10, spent in the
## Shop tutorial right after). The caption's Skip ends just that tutorial
## (its menu unlocks and it still pays); Menu > Skip all tutorials ends
## them all -- skipped ones still hand out their rewards when their wave
## comes, and every menu unlocks at once.
##
## State lives in g["tutorials"] (id -> true when done) and g["tutorialSkip"].
## Steps poll real game state (a menu is open, a level went up, a gambit is
## set...), so a step can't be "faked" past and survives the player
## wandering off: if the control a step points at disappears, the step falls
## back to its `back` step (e.g. "open Units" again).

## In order. `wave`: the wave whose clear starts it. `unlocks`: the tab (or
## Units sub-tab) it opens.
const TUTS := [
	{"id": "road", "wave": 0, "unlocks": ""},   # right after character creation
	{"id": "units", "wave": 1, "unlocks": "units"},
	{"id": "gambits", "wave": 3, "unlocks": "gambits"},
	{"id": "quests", "wave": 5, "unlocks": "quests"},
	{"id": "lore", "wave": 7, "unlocks": "lore"},
	{"id": "marks", "wave": 8, "unlocks": "marks"},
	{"id": "shop", "wave": 8, "unlocks": "shop"},
	{"id": "party", "wave": 10, "unlocks": "party"},
	{"id": "gear", "wave": 20, "unlocks": "equipment"},
	{"id": "expedition", "wave": 30, "unlocks": "expedition"},
]
const ALWAYS_OPEN := ["settings", "summary", "aether", "catalogue"]

var gc: Node          # GameController
var g: Dictionary
var active := ""      # tutorial id in progress
var steps: Array = []
var step := 0
var _missing := 0.0
var _poll := 0.0
var _start_level := 0

# overlay pieces (re-hosted on whichever window holds the target)
var _layer: CanvasLayer
var _root: Control
var _shades: Array = []
var _ring: Panel
var _caption: PanelContainer
var _caption_lbl: Label
var _next_btn: Button
var _skip_btn: Button
var _blocker: Control
var _outer: ColorRect   # the screen around a menu the spotlight is in

func setup(controller: Node) -> void:
	gc = controller
	g = gc.g
	migrate(g)
	_layer = CanvasLayer.new()
	_layer.layer = 20
	add_child(_layer)
	_build_overlay()

## A save from before the tutorials: anything already passed counts as done.
static func migrate(gd: Dictionary) -> void:
	if gd.get("tutorials") is Dictionary:
		return
	gd["tutorials"] = {}
	for t in TUTS:
		if int(gd.get("farthest", 1)) > int(t["wave"]) + 1:
			gd["tutorials"][t["id"]] = true

static func is_done(gd: Dictionary, id: String) -> bool:
	return bool((gd.get("tutorials", {}) as Dictionary).get(id, false))

## Whether a tab ("units", "party"...) or Units sub-tab ("gambits"...) is open.
static func unlocked(gd: Dictionary, key: String, active_id: String = "") -> bool:
	if key in ALWAYS_OPEN or gd.get("tutorialSkip", false):
		return true
	for t in TUTS:
		if t["unlocks"] == key:
			return is_done(gd, t["id"]) or active_id == t["id"]
	return true

# ================================================================ driving
func _process(delta: float) -> void:
	if g.is_empty():
		return
	_apply_locks()
	if active == "":
		_poll -= delta
		if _poll <= 0.0:
			_poll = 0.5
			_try_start()
		return
	# the Road stays paused for the whole tutorial, including a wave that
	# started after it began (each wave gets a fresh presenter)
	if gc.current_presenter != null and not gc.current_presenter.loop_paused:
		gc.current_presenter.call("set_loop_paused", true)
	_hold_popups()
	_run_step(delta)

func _due() -> Dictionary:
	for t in TUTS:
		if not is_done(g, t["id"]) and int(g.get("farthest", 1)) > int(t["wave"]):
			return t
	return {}

func _try_start() -> void:
	var t := _due()
	if t.is_empty():
		return
	if g.get("tutorialSkip", false):
		_grant(t["id"], true)
		show_toast("Tutorial reward: " + reward_text(t["id"], true).replace("\n", ", "), gc.currency_row)
		return
	# wait for a quiet moment: no side battle, no menu, no pop-up
	if g.get("sideBattle") != null or gc.current_presenter == null:
		return
	if gc.open_panel != null and is_instance_valid(gc.open_panel) and gc.open_panel.popup.visible:
		return
	if gc._full_layer != null and is_instance_valid(gc._full_layer) and gc._full_layer.get_child_count() > 0:
		return
	# the Road tour waits for the first couple of turns, so the field, turn
	# order and log have something in them
	if t["id"] == "road" and int(gc.current_presenter.battle.get("beat", 0)) < 2:
		return
	_begin(t["id"])

func _begin(id: String) -> void:
	active = id
	steps = _steps_for(id)
	step = 0
	_missing = 0.0
	gc.current_presenter.call("set_loop_paused", true)
	_enter_step()

func _enter_step() -> void:
	_missing = 0.0
	_root.visible = false   # one frame for the caption to lay out
	if step >= steps.size():
		_finish()
		return
	var s: Dictionary = steps[step]
	if s.has("enter"):
		s["enter"].call()
	_caption_lbl.text = s["text"]
	_next_btn.visible = s.get("done") == null
	_apply_locks()

func _run_step(delta: float) -> void:
	var s: Dictionary = steps[step]
	var done = s.get("done")
	if done != null and done.call():
		step += 1
		_enter_step()
		return
	if s.has("rect"):
		_show_spot(null, false, s["rect"].call())
		return
	var target: Control = s["target"].call() if s.has("target") else null
	if s.has("target") and (target == null or not target.is_visible_in_tree()):
		_missing += delta
		if _missing > 1.2 and s.has("back"):
			step = int(s["back"])
			_enter_step()
			return
		_show_spot(null, s.get("quiet", false))
		return
	_missing = 0.0
	# a target scrolled out of view gets scrolled to
	var p: Node = target.get_parent() if target != null else null
	while p != null and not (p is ScrollContainer):
		p = p.get_parent()
	if p is ScrollContainer and not p.get_global_rect().encloses(target.get_global_rect()):
		(p as ScrollContainer).ensure_control_visible(target)
	_show_spot(target, s.get("quiet", false))

func _on_next() -> void:
	if active == "":
		return
	if step < steps.size() and steps[step].get("done") == null:
		step += 1
		_enter_step()

func _finish() -> void:
	var id := active
	_end(false)
	gc._show_tab_tutorial_popup("Tutorial complete!", "%s\n%s" % [DONE_TEXT.get(id, ""), reward_text(id, false)])

## Closes the running tutorial (done or skipped): rewards, overlay, any
## menu or Status/Log box it opened, and the Road starts again.
func _end(skipped: bool) -> void:
	var id := active
	_grant(id, skipped)
	active = ""
	steps = []
	_hide_overlay()
	_release_popups()
	_hide_popup()
	_close_battle_boxes()
	if gc.current_presenter != null:
		gc.current_presenter.call("set_loop_paused", false)
	gc._refresh_hud()
	gc._save_game()
	_apply_locks()

## The caption's Skip: just this tutorial.
func skip_current() -> void:
	if active != "":
		var id := active
		_end(true)
		gc._show_tab_tutorial_popup("Tutorial skipped", reward_text(id, true))

## The tutorial's rewards (also what a skipped tutorial grants on its wave).
func _grant(id: String, skipped: bool) -> void:
	if is_done(g, id):
		return
	g["tutorials"][id] = true
	g["crystal"] = int(g.get("crystal", 0)) + (10 if id == "marks" else 1)
	if skipped:
		# Ian: a skipped tutorial still gives what playing it would have
		match id:
			"lore":
				if not bool(g.get("tutorialLoreGift", false)):
					_gift_lore("sear")
			"marks":
				if not g["actions"].has("mend"):
					g["actions"].append("mend")
				if g.get("forcedPull") == "mend":
					g["forcedPull"] = null
			"shop":   # the gambit the Shop tutorial has you buy
				if not g["conditions"].has("self_hp_lte_50"):
					g["conditions"].append("self_hp_lte_50")
	g.erase("tutorialLoreGift")
	gc._save_game()

## What a tutorial pays, for the "complete" / "skipped" pop-ups.
func reward_text(id: String, skipped: bool) -> String:
	var parts: Array = ["+10 Crystal -- spend it in the Shop!" if id == "marks" else "+1 Crystal"]
	if skipped:
		match id:
			"lore": parts.append("+1 Lore for Sear")
			"marks": parts.append("Mend joined your actions")
			"shop": parts.append("Gambit: %s" % FarroadCore.cond_label("self_hp_lte_50"))
	return "\n".join(parts)

func skip_all() -> void:
	g["tutorialSkip"] = true
	if active != "":
		_end(true)
	gc._refresh_hud()
	gc._save_game()
	_apply_locks()

# ================================================================ locks
func _apply_locks() -> void:
	var cur: Control = _current_target()
	var tabs := {"units": gc.units_panel, "party": gc.party_panel, "quests": gc.quests_panel,
		"marks": gc.marks_panel, "shop": gc.shop_panel, "expedition": gc.expedition_panel,
		"settings": gc.settings_panel}
	for key in tabs:
		var p = tabs[key]
		if p == null or not is_instance_valid(p) or p.get("toggle_button") == null:
			continue
		var b: Button = p.toggle_button
		if not is_instance_valid(b):
			continue
		var open := unlocked(g, key, active)
		# during a tutorial only the button the current step points at
		# can be tapped (Ian: tapping another menu mid-step broke it)
		if active != "" and open:
			open = cur == b
		# Ian: locked icons are darkened (not greyed out) and a tap on one
		# says when it opens -- a clear button over the icon takes the tap
		b.disabled = false
		var catcher: Button = b.get_node_or_null("LockCatch")
		if open and catcher != null:
			catcher.queue_free()
		elif not open and catcher == null:
			catcher = Button.new()
			catcher.name = "LockCatch"
			catcher.flat = true
			catcher.focus_mode = Control.FOCUS_NONE
			catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
			for st in ["normal", "hover", "pressed", "focus"]:
				catcher.add_theme_stylebox_override(st, StyleBoxEmpty.new())
			catcher.pressed.connect(locked_tap.bind(key, b))
			b.add_child(catcher)
		b.modulate = Color(1, 1, 1, 1) if open else LOCKED_TINT
	for b in [gc.road_button, gc.speed_toggle_btn]:
		if b != null and is_instance_valid(b):
			b.disabled = active != ""

const LOCKED_TINT := Color(0.35, 0.35, 0.38, 1)

func _current_target() -> Control:
	if active == "" or step >= steps.size() or not steps[step].has("target"):
		return null
	var t = steps[step]["target"].call()
	return t if t is Control and is_instance_valid(t) else null

## Menus and the Status/Log boxes don't close on a tap outside them while a
## tutorial runs (a stray tap used to close a menu mid-step).
var _held: Array = []

func _hold_popups() -> void:
	var list: Array = []
	for p in [gc.units_panel, gc.party_panel, gc.quests_panel, gc.marks_panel, gc.shop_panel,
			gc.expedition_panel, gc.settings_panel]:
		if p != null and is_instance_valid(p) and p.get("popup") != null:
			list.append(p.popup)
	var pr = gc.current_presenter
	if pr != null and is_instance_valid(pr):
		list.append(pr.status_popup)
		list.append(pr.log_popup)
	for w in list:
		if w != null and is_instance_valid(w) and w.visible and w.popup_window:
			w.popup_window = false
			_held.append(w)

func _release_popups() -> void:
	for w in _held:
		if is_instance_valid(w):
			w.popup_window = true
	_held.clear()

## The wave whose clear opens a menu or Units sub-tab (-1: always open).
static func unlock_wave(key: String) -> int:
	for t in TUTS:
		if t["unlocks"] == key:
			return int(t["wave"])
	return -1

## A tap on a locked menu or sub-tab: say when it opens.
func locked_tap(key: String, near: Control) -> void:
	var w := unlock_wave(key)
	if active != "" and (w < 0 or unlocked(g, key, active)):
		show_toast("Finish this tutorial first.", near)
	else:
		show_toast("Unlocks after wave %d." % w, near)

var _toast: PanelContainer

## A short note beside `near`, fading after a couple of seconds.
func show_toast(text: String, near: Control) -> void:
	if _toast != null and is_instance_valid(_toast):
		_toast.queue_free()
	_toast = PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Palette.BG_PARCHMENT
	st.border_color = Palette.PARTY_BLUE
	st.set_border_width_all(2)
	st.set_corner_radius_all(6)
	st.set_content_margin_all(8)
	_toast.add_theme_stylebox_override("panel", st)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := Label.new()
	lbl.text = text
	_toast.add_child(lbl)
	var win: Window = near.get_window() if near != null else null
	var host: Node = win if win != null and win != get_tree().root else _layer
	host.add_child(_toast)
	_toast.top_level = host != _layer
	var host_size: Vector2 = Vector2(win.size) if host != _layer else gc._vp
	var sz := _toast.get_combined_minimum_size()
	var r: Rect2 = near.get_global_rect() if near != null else Rect2(host_size / 2.0, Vector2.ZERO)
	var y: float = r.position.y - sz.y - 6.0 if r.get_center().y > host_size.y * 0.5 else r.end.y + 6.0
	var x: float = clampf(r.get_center().x - sz.x / 2.0, 6.0, host_size.x - sz.x - 6.0)
	_toast.position = Vector2(x, y)
	var t := _toast
	var tw := t.create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(t, "modulate:a", 0.0, 0.4)
	tw.tween_callback(t.queue_free)

func _needs(id: String) -> Array:
	match id:
		"units", "gambits", "lore", "gear": return ["units"]
		"quests": return ["quests"]
		"marks": return ["marks"]
		"shop": return ["shop", "units"]
		"party": return ["party"]
		"expedition": return ["party", "expedition"]
	return []

# ================================================================ finders
func _popup_open(panel) -> bool:
	return panel != null and is_instance_valid(panel) and panel.popup.visible

func _buttons(root: Node) -> Array:
	if root == null or not is_instance_valid(root):
		return []
	return root.find_children("*", "Button", true, false).filter(func(b): return b.is_visible_in_tree())

func _btn_text(root: Node, prefix: String, last := false) -> Button:
	var hits: Array = _buttons(root).filter(func(b): return b.text.begins_with(prefix))
	if hits.is_empty():
		return null
	return hits[-1] if last else hits[0]

func _units_tab(key: String) -> Control:
	if not _popup_open(gc.units_panel):
		return null
	return gc.units_panel.sub_tab_buttons.get(key)

func _slot(i: int) -> Dictionary:
	var sl: Array = g["loadout"].get("kesh", [])
	return sl[i] if i < sl.size() else {}

## Slot i's IF (cond) or THEN (action) button in the Gambits tab: each slot
## card is "IF" label, condition button, "THEN" label, then a row whose
## first child is the action button -- walked in order, so identical
## buttons on different slots can't be confused.
func _slot_button(i: int, which: String) -> Control:
	if not _popup_open(gc.units_panel) or gc.units_panel.current_sub_tab != "gambits":
		return null
	var marks: Array = gc.units_panel.content_container.find_children("*", "Label", true, false).filter(
		func(l): return l.text == ("IF" if which == "if" else "THEN") and l.is_visible_in_tree())
	if i >= marks.size():
		return null
	var lbl: Label = marks[i]
	var parent := lbl.get_parent()
	var nxt: Node = parent.get_child(lbl.get_index() + 1) if lbl.get_index() + 1 < parent.get_child_count() else null
	if nxt is Button:
		return nxt
	if nxt != null and nxt.get_child_count() > 0 and nxt.get_child(0) is Button:
		return nxt.get_child(0)
	return null

## A row in an open picker list (overlay inside the Units pop-up).
func _picker_row(text_prefix: String) -> Control:
	if not _popup_open(gc.units_panel):
		return null
	for c in gc.units_panel.popup.get_children():
		if c is ColorRect:   # picker overlays sit on a backdrop
			var b := _btn_text(c, text_prefix)
			if b != null:
				return b
	return null

func _party_row_button(uid: String, prefix: String) -> Control:
	if not _popup_open(gc.party_panel):
		return null
	var name: String = FarroadCore.roster_by_id(uid)["name"]
	for row in gc.party_panel.popup.find_children("*", "HBoxContainer", true, false):
		if row.get_child_count() > 0 and row.get_child(0) is Label and row.get_child(0).text == name:
			for b in row.get_children():
				if b is Button and b.text.begins_with(prefix) and b.is_visible_in_tree():
					return b
	return null

func _hide_popup() -> void:
	if gc.open_panel != null and is_instance_valid(gc.open_panel):
		gc.open_panel.popup.hide()

## The Road's Status and Log boxes (opened by the Road tour).
func _close_battle_boxes() -> void:
	var p = gc.current_presenter
	if p == null or not is_instance_valid(p):
		return
	for box in [p.status_popup, p.log_popup]:
		if box != null and box.visible:
			box.hide()

## Screen rect around every living unit on one side of the field.
func _side_rect(party: bool) -> Rect2:
	var p = gc.current_presenter
	var r := Rect2()
	if p == null:
		return r
	for v in p.unit_views_by_id.values():
		if not is_instance_valid(v) or not v.visible or bool(v.unit.get("isParty", false)) != party:
			continue
		var sz: float = v.size
		var vr := Rect2(v.global_position + Vector2(-sz * 0.75, -sz * 0.9), Vector2(sz * 1.5, sz * 2.0))
		r = vr if r.size == Vector2.ZERO else r.merge(vr)
	return r

## Screen rect around a few Controls.
func _controls_rect(list: Array) -> Rect2:
	var r := Rect2()
	for c in list:
		if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
			continue
		var cr: Rect2 = c.get_global_rect()
		r = cr if r.size == Vector2.ZERO else r.merge(cr)
	return r

# ================================================================ steps
## Each step: text, optional target (Callable -> Control), done (Callable ->
## bool; none = a "Next" step), back (step to return to if the target is
## gone), enter (Callable run on entry), quiet (no dimming: e.g. a fight).
const DONE_TEXT := {
	"road": "That's the Road. New menus open as you travel further.",
	"units": "You levelled up your first unit. Units is where you'll manage everyone.",
	"gambits": "Your first gambit is set: Sear only fires when a foe isn't already burning.",
	"quests": "Quest stage cleared. Every companion has a 5-stage quest line.",
	"lore": "Lore makes an action stronger. Every action has its own Lore.",
	"marks": "Mend joined your actions.",
	"shop": "Mend now heals you whenever you drop to half health.",
	"party": "You can now arrange your party.",
	"gear": "Gear stays on a unit until you change it.",
	"expedition": "Your expedition will fight on its own, even while you're away.",
}

func _steps_for(id: String) -> Array:
	var units_icon := func(): return gc.units_panel.toggle_button
	var units_open := func(): return _popup_open(gc.units_panel)
	match id:
		"road":
			var p = gc.current_presenter
			return [
				{"text": "Welcome to the Road! Your party travels it and fights on its own, wave after wave."},
				{"text": "Your units stand on the left. Tap any unit to see its stats.", "rect": func(): return _side_rect(true)},
				{"text": "Enemies line up on the right. Defeat them all to clear the wave.", "rect": func(): return _side_rect(false)},
				{"text": "This bar tracks the waves to the next boss. Beat the boss to move on; if your party falls, you go back a few waves.",
					"rect": func(): return _controls_rect([p.wave_progress_label] + p.wave_progress_circles.map(func(c): return c["panel"]))},
				{"text": "Turn order: who acts next, and what they'll do.", "target": func(): return p.turn_order_frame},
				{"text": "Your currencies: Aether levels up units, Marks pay for pulls, and Crystal buys from the Shop.", "target": func(): return gc.currency_row},
				{"text": "Idle rewards: what you earn every 5 minutes, even while the game is closed. Power sums up how strong you are.", "target": func(): return gc.idle_row},
				{"text": "Status shows every unit in the fight.", "target": func(): return p.status_icon_btn,
					"enter": func(): _close_battle_boxes()},
				{"text": "HP, charge, stats, and any buffs or debuffs, updated live.",
					"enter": func(): p._on_status_pressed(),
					"target": func(): return p.status_popup.get_child(0) if p.status_popup.visible else null},
				{"text": "The Log records every action.", "target": func(): return p.log_icon_btn,
					"enter": func(): _close_battle_boxes()},
				{"text": "Each entry shows who did what, to whom, and for how much. Tap an entry to see the damage math.",
					"enter": func(): p._on_log_pressed(),
					"target": func(): return p.log_popup.get_child(0) if p.log_popup.visible else null},
			]
		"units":
			return [
				{"text": "A new menu is open: Units. Tap it.", "target": units_icon, "done": units_open,
					"enter": func(): _prepare_level_up()},
				{"text": "Pick which unit to manage here.", "target": func(): return gc.units_panel.dropdown if _popup_open(gc.units_panel) else null, "back": 0},
				{"text": "Each unit has Summary, Gambits, Aether, Lore and Gear. Most unlock as you go.", "target": func(): return gc.units_panel.sub_tab_buttons.get("summary") if _popup_open(gc.units_panel) else null, "back": 0},
				{"text": "Tap Aether.", "target": func(): return _units_tab("aether"), "back": 0,
					"done": func(): return _popup_open(gc.units_panel) and gc.units_panel.current_sub_tab == "aether"},
				{"text": "HP: how much damage a unit can take before falling.", "target": func(): return gc.units_panel.content_container, "back": 0},
				{"text": "ATK powers physical actions; MAG powers magic and healing.", "target": func(): return gc.units_panel.content_container, "back": 0},
				{"text": "DEF reduces physical damage taken; RES reduces magic damage.", "target": func(): return gc.units_panel.content_container, "back": 0},
				{"text": "SPD: faster units take more turns.", "target": func(): return gc.units_panel.content_container, "back": 0},
				{"text": "Crit lands bonus damage, Evade dodges hits, and Affinity makes elements hit harder or softer.", "target": func(): return gc.units_panel.content_container, "back": 0},
				{"text": "Spend Aether to level up. Tap the level-up button.", "back": 0,
					"enter": func(): _prepare_level_up(),
					"target": func(): return _btn_text(gc.units_panel.content_container, "→ LV") if _popup_open(gc.units_panel) else null,
					"done": func(): return FarroadProgression.level_of(g, "kesh") > _start_level},
			]
		"gambits":
			return [
				{"text": "Gambits are open. Tap Units.", "target": units_icon, "done": units_open,
					"enter": func(): _reset_top_slot()},
				{"text": "Tap Gambits.", "target": func(): return _units_tab("gambits"), "back": 0,
					"done": func(): return _popup_open(gc.units_panel) and gc.units_panel.current_sub_tab == "gambits"},
				{"text": "Each slot is IF (a condition) THEN (an action). The top slot is checked first; if its IF isn't true, the next one is.", "target": func(): return gc.units_panel.content_container if _popup_open(gc.units_panel) else null, "back": 0},
				{"text": "Set the top slot's THEN to Sear: tap it and pick Sear.", "back": 0,
					"target": func():
						var r = _picker_row("Sear")
						return r if r != null else _slot_button(0, "then"),
					"done": func(): return _slot(0).get("action") == "sear"},
				{"text": "Now its IF: tap it and pick \"Foe: lacks a debuff\", so Sear never burns a foe that's already burning.", "back": 0,
					"target": func():
						var r = _picker_row(FarroadCore.cond_label("foe_lacks_debuff"))
						return r if r != null else _slot_button(0, "if"),
					"done": func(): return _slot(0).get("cond") == "foe_lacks_debuff"},
			]
		"quests":
			return [
				{"text": "Quests are open. Tap Quests.", "target": func(): return gc.quests_panel.toggle_button,
					"done": func(): return _popup_open(gc.quests_panel)},
				{"text": "This is your own quest line. Tap Attempt to fight its first stage.", "back": 0,
					"target": func(): return _btn_text(gc.quests_panel.popup, "Attempt") if _popup_open(gc.quests_panel) else null,
					"done": func(): return g.get("sideBattle") != null},
				{"text": "Win the fight!", "quiet": true,
					"enter": func(): gc.current_presenter.call("set_loop_paused", true),
					"done": func():
						if int(g["quests"].get("kesh", {}).get("stage", 0)) >= 1:
							return true
						if g.get("sideBattle") == null:   # lost or gave up: try again
							step = 0
						return false},
			]
		"lore":
			return [
				{"text": "Lore is open, and here's a Lore point for Sear. Tap Units.", "target": units_icon, "done": units_open,
					"enter": func(): _gift_lore("sear")},
				{"text": "Tap Lore.", "target": func(): return _units_tab("lore"), "back": 0,
					"done": func(): return _popup_open(gc.units_panel) and gc.units_panel.current_sub_tab == "lore"},
				{"text": "Select Sear.", "back": 0,
					"target": func():
						var r = _picker_row("Sear")
						if r != null:
							return r
						return _btn_text(gc.units_panel.content_container, "Sear") if _popup_open(gc.units_panel) else null,
					"done": func(): return gc.lore_panel.selected_action_id == "sear"},
				{"text": "Buy an upgrade with your Lore: tap a + button.", "back": 0,
					"target": func():
						if not _popup_open(gc.units_panel):
							return null
						for b in _buttons(gc.units_panel.content_container):
							if b.text.begins_with("+ ") and not b.disabled:
								return b
						return null,
					"done": func(): return FarroadCore.bonus_spend({"sear": g["bonuses"].get("sear", {})}) > 0},
			]
		"marks":
			return [
				{"text": "Marks are open, and you have enough for a pull. Tap Marks.", "target": func(): return gc.marks_panel.toggle_button,
					"enter": func():
						g["marks"] = maxf(float(g.get("marks", 0.0)), 100.0)
						g["forcedPull"] = "mend"
						gc._refresh_hud(),
					"done": func(): return _popup_open(gc.marks_panel)},
				{"text": "Tap Pull.", "back": 0,
					"target": func(): return _btn_text(gc.marks_panel.popup, "PULL —") if _popup_open(gc.marks_panel) else null,
					"done": func(): return g["actions"].has("mend")},
				{"text": "You pulled Mend, a heal! Pulls can give units, actions, gambits or gear.",
					"target": func(): return gc.marks_panel.popup.get_child(0) if _popup_open(gc.marks_panel) else null},
			]
		"shop":
			return [
				{"text": "The Shop is open. Crystal buys exactly what you want. Tap Shop.", "target": func(): return gc.shop_panel.toggle_button,
					"enter": func(): _hide_popup(),
					"done": func(): return _popup_open(gc.shop_panel)},
				{"text": "Tap Gambits.", "back": 0,
					"target": func(): return gc.shop_panel.tab_buttons.get("gambits") if _popup_open(gc.shop_panel) else null,
					"done": func(): return _popup_open(gc.shop_panel) and gc.shop_panel.current_tab == "gambits"},
				{"text": "Buy \"%s\": it lets Mend heal you only when you need it." % FarroadCore.cond_label("self_hp_lte_50"), "back": 0,
					"target": func(): return _shop_row_buy(FarroadCore.cond_label("self_hp_lte_50")),
					"done": func(): return g["conditions"].has("self_hp_lte_50")},
				{"text": "Now put it to use. Tap Units.", "target": units_icon, "done": units_open,
					"enter": func(): _hide_popup()},
				{"text": "Tap Gambits.", "target": func(): return _units_tab("gambits"), "back": 3,
					"done": func(): return _popup_open(gc.units_panel) and gc.units_panel.current_sub_tab == "gambits"},
				{"text": "Set the second slot's THEN to Mend.", "back": 3,
					"target": func():
						var r = _picker_row("Mend")
						return r if r != null else _slot_button(1, "then"),
					"done": func(): return _slot(1).get("action") == "mend" or _slot(0).get("action") == "mend"},
				{"text": "Set its IF to \"%s\"." % FarroadCore.cond_label("self_hp_lte_50"), "back": 3,
					"target": func():
						var r = _picker_row(FarroadCore.cond_label("self_hp_lte_50"))
						return r if r != null else _slot_button(1, "if"),
					"done": func(): return _has_slot("mend", "self_hp_lte_50")},
				{"text": "Healing comes first: tap ▲ to move it to the top.", "back": 3,
					"target": func(): return _move_up_button(),
					"done": func(): return _slot(0).get("action") == "mend"},
			]
		"party":
			return [
				{"text": "Ansa joined you, and Party is open. Tap Party.", "target": func(): return gc.party_panel.toggle_button,
					"done": func(): return _popup_open(gc.party_panel)},
				{"text": "Front row hits harder but takes more physical damage; the back row is safer. Tap Ansa's row button.", "back": 0,
					"enter": func(): _row_start = FarroadCore.roster_by_id("ansa").get("row", "back"),
					"target": func(): return _party_row_button("ansa", FarroadCore.roster_by_id("ansa").get("row", "back").capitalize()),
					"done": func(): return FarroadCore.roster_by_id("ansa").get("row") != _row_start},
				{"text": "Tap Bench to take Ansa out of the party.", "back": 0,
					"target": func(): return _party_row_button("ansa", "Bench"),
					"done": func(): return not (g["party"] as Array).has("ansa")},
				{"text": "Tap Field to bring her back.", "back": 0,
					"target": func(): return _party_row_button("ansa", "Field"),
					"done": func(): return (g["party"] as Array).has("ansa")},
			]
		"gear":
			return [
				{"text": "Gear is open. Tap Units.", "target": units_icon, "done": units_open},
				{"text": "Tap Gear.", "target": func(): return _units_tab("equipment"), "back": 0,
					"done": func(): return _popup_open(gc.units_panel) and gc.units_panel.current_sub_tab == "equipment"},
				{"text": "Tap a slot and equip your new piece of gear.", "back": 0,
					"target": func():
						if not _popup_open(gc.units_panel):
							return null
						for o in gc.units_panel.content_container.find_children("*", "OptionButton", true, false):
							if o.is_visible_in_tree() and o.item_count > 1:
								return o
						return null,
					"done": func(): return _any_gear_equipped()},
			]
		"expedition":
			return [
				{"text": "Dorrek joined you, and Expeditions are open. Benched units can explore on their own. First, tap Party.", "target": func(): return gc.party_panel.toggle_button,
					"done": func(): return _popup_open(gc.party_panel) or not FarroadProgression.available_for_party(g).is_empty()},
				{"text": "Bench one unit to send it out.", "back": 0,
					"target": func():
						for uid in g["party"]:
							if uid != "kesh":
								var b = _party_row_button(uid, "Bench")
								if b != null:
									return b
						return null,
					"done": func(): return not FarroadProgression.available_for_party(g).is_empty()},
				{"text": "Tap Exped.", "target": func(): return gc.expedition_panel.toggle_button,
					"enter": func(): _hide_popup(),
					"done": func(): return _popup_open(gc.expedition_panel)},
				{"text": "Pick the benched unit.", "back": 2,
					"target": func():
						var av: Array = FarroadProgression.available_for_party(g)
						if av.is_empty() or not _popup_open(gc.expedition_panel):
							return null
						return _btn_text(gc.expedition_panel.popup, FarroadCore.roster_by_id(av[0])["name"]),
					"done": func(): return not gc.expedition_panel.selected_uids.is_empty()},
				{"text": "Send them West: tap W on the map.", "back": 2,
					"target": func():
						if not _popup_open(gc.expedition_panel):
							return null
						for m in gc.expedition_panel.popup.find_children("*", "ExpeditionMap", true, false):
							return m._direction_buttons.get("west")
						return null,
					"done": func(): return gc.expedition_panel.selected_direction == "west"},
				{"text": "Tap Send.", "back": 2,
					"target": func(): return _btn_text(gc.expedition_panel.popup, "Send expedition") if _popup_open(gc.expedition_panel) else null,
					"done": func(): return (g["expeditions"] as Array).any(func(e): return e["direction"] == "west")},
			]
	return []

var _row_start := ""

func _prepare_level_up() -> void:
	_start_level = FarroadProgression.level_of(g, "kesh")
	# make sure the first level-up is affordable
	var need: float = maxf(0.0, ceilf(FarroadProgression.cost_next(g, "kesh") - FarroadProgression.exp_of(g, "kesh")))
	if need > float(g.get("aether", 0.0)):
		g["aether"] = need
		gc._refresh_hud()
	# the Aether page was drawn before the top-up: redraw it so the
	# level-up button isn't left greyed out
	if _popup_open(gc.units_panel):
		gc.units_panel._refresh_content()

## The Gambits tutorial has the player set Sear up themselves: if the top
## slot already holds it (an auto-equip), start it back at plain Strike.
func _reset_top_slot() -> void:
	var sl: Array = g["loadout"].get("kesh", [])
	if not sl.is_empty() and (sl[0]["action"] == "sear" or sl[0]["cond"] == "foe_lacks_debuff"):
		sl[0] = {"cond": "none", "action": "strike"}
		FarroadProgression.sync_loadout(g, "kesh")

func _gift_lore(aid: String) -> void:
	g["tutorialLoreGift"] = true
	if not g["actions"].has(aid):
		aid = g["actions"][0]
	FarroadProgression._credit_lore(g, aid)

func _has_slot(action: String, cond: String) -> bool:
	for s in g["loadout"].get("kesh", []):
		if s["action"] == action and s["cond"] == cond:
			return true
	return false

func _move_up_button() -> Control:
	if not _popup_open(gc.units_panel) or gc.units_panel.current_sub_tab != "gambits":
		return null
	var ups: Array = _buttons(gc.units_panel.content_container).filter(func(b): return b.text == "▲" and not b.disabled)
	var sl: Array = g["loadout"].get("kesh", [])
	for i in sl.size():
		if sl[i]["action"] == "mend" and i > 0 and i - 1 < ups.size():
			return ups[i - 1]
	return ups[0] if not ups.is_empty() else null

func _shop_row_buy(label: String) -> Control:
	if not _popup_open(gc.shop_panel):
		return null
	for row in gc.shop_panel.popup.find_children("*", "HBoxContainer", true, false):
		if row.get_child_count() > 0 and row.get_child(0) is RichTextLabel and row.get_child(0).text == label:
			var last: Button = null
			for b in row.get_children():
				if b is Button:
					last = b
			return last
	return null

func _any_gear_equipped() -> bool:
	for uid in (g.get("equipped", {}) as Dictionary).keys():
		for slot in (g["equipped"][uid] as Dictionary).keys():
			if g["equipped"][uid][slot]:
				return true
	return false

# ================================================================ overlay
func _build_overlay() -> void:
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	for i in 4:
		var r := ColorRect.new()
		r.color = Color(0, 0, 0, 0.6)
		r.mouse_filter = Control.MOUSE_FILTER_STOP
		_root.add_child(r)
		_shades.append(r)
	# over the hole on "look" steps (a Next step), so the highlighted
	# part can't be tapped (e.g. buying an affinity mid-explanation)
	_blocker = Control.new()
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_blocker)
	_ring = Panel.new()
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color(0, 0, 0, 0)
	rs.border_color = Palette.GOLD_LIGHT
	rs.set_border_width_all(3)
	rs.set_corner_radius_all(8)
	_ring.add_theme_stylebox_override("panel", rs)
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_ring)
	_caption = PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = Palette.BG_PARCHMENT
	cs.border_color = Palette.PARTY_BLUE
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(6)
	cs.set_content_margin_all(10)
	_caption.add_theme_stylebox_override("panel", cs)
	_root.add_child(_caption)
	var v := VBoxContainer.new()
	_caption.add_child(v)
	_caption_lbl = Label.new()
	_caption_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_caption_lbl)
	var row := HBoxContainer.new()
	v.add_child(row)
	_skip_btn = Button.new()
	_skip_btn.text = "Skip tutorial"
	_skip_btn.flat = true
	_skip_btn.add_theme_font_size_override("font_size", 12)
	_skip_btn.pressed.connect(skip_current)
	row.add_child(_skip_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_next_btn = Button.new()
	_next_btn.text = "Next"
	_next_btn.pressed.connect(_on_next)
	row.add_child(_next_btn)
	_layer.add_child(_root)
	_outer = ColorRect.new()
	_outer.color = Color(0, 0, 0, 0.6)
	_outer.mouse_filter = Control.MOUSE_FILTER_STOP
	_outer.visible = false
	_layer.add_child(_outer)

func _hide_overlay() -> void:
	_outer.visible = false
	_root.visible = false
	if _root.get_parent() != _layer:
		_root.get_parent().remove_child(_root)
		_layer.add_child(_root)

## Dims everything but `target` (in whatever window holds it) and places the
## caption beside it. With no target the screen dims fully, caption centred.
func _show_spot(target: Control, quiet: bool, area := Rect2()) -> void:
	var host: Node = _layer
	var host_size: Vector2 = gc._vp
	var win: Window = target.get_window() if target != null else null
	if win != null and win != get_tree().root:
		host = win
		host_size = Vector2(win.size)
	if _root.get_parent() != host:
		_root.get_parent().remove_child(_root)
		host.add_child(_root)
		_root.top_level = host != _layer
	host.move_child(_root, host.get_child_count() - 1)
	_outer.visible = host != _layer
	_outer.position = Vector2.ZERO
	_outer.size = gc._vp
	_outer.color = Color(0, 0, 0, 0.0 if quiet else 0.6)
	var first_frame := not _root.visible
	_root.visible = true
	_root.position = Vector2.ZERO
	_root.size = host_size
	var hole := Rect2(Vector2.ZERO, Vector2.ZERO)
	if target != null:
		hole = target.get_global_rect().grow(4)
	elif area.size != Vector2.ZERO:
		hole = area.grow(4)
	var a := 0.0 if quiet else 0.6
	for r in _shades:
		r.color = Color(0, 0, 0, a)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE if quiet else Control.MOUSE_FILTER_STOP
	if hole.size == Vector2.ZERO:
		_shades[0].position = Vector2.ZERO
		_shades[0].size = host_size
		for i in range(1, 4):
			_shades[i].size = Vector2.ZERO
		_ring.visible = false
	else:
		_shades[0].position = Vector2.ZERO
		_shades[0].size = Vector2(host_size.x, hole.position.y)
		_shades[1].position = Vector2(0, hole.end.y)
		_shades[1].size = Vector2(host_size.x, maxf(0.0, host_size.y - hole.end.y))
		_shades[2].position = Vector2(0, hole.position.y)
		_shades[2].size = Vector2(hole.position.x, hole.size.y)
		_shades[3].position = Vector2(hole.end.x, hole.position.y)
		_shades[3].size = Vector2(maxf(0.0, host_size.x - hole.end.x), hole.size.y)
		_ring.visible = not quiet
		_ring.position = hole.position
		_ring.size = hole.size
		var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() / 200.0)
		_ring.modulate = Color(1, 1, 1, pulse)
	var look_only: bool = active != "" and step < steps.size() and steps[step].get("done") == null
	_blocker.visible = look_only and hole.size != Vector2.ZERO
	_blocker.position = hole.position
	_blocker.size = hole.size
	# caption above the hole if it's in the lower half, else below
	var cw: float = minf(host_size.x - 20.0, gc._vp.x * 0.86)
	_caption_lbl.custom_minimum_size = Vector2(cw - 24.0, 0)   # wrap width known up front
	_caption.custom_minimum_size = Vector2(cw, 0)
	_caption.size = Vector2(cw, 0)
	_caption.reset_size()
	var ch: float = _caption.get_combined_minimum_size().y
	var cy: float
	if hole.size == Vector2.ZERO:
		cy = (host_size.y - ch) / 2.0
	elif hole.size.y > host_size.y * 0.6:   # a whole box: along its bottom
		cy = host_size.y - ch - 12.0
	elif hole.get_center().y > host_size.y * 0.5:
		cy = maxf(8.0, hole.position.y - ch - 12.0)
	else:
		cy = minf(host_size.y - ch - 8.0, hole.end.y + 12.0)
	_caption.position = Vector2((host_size.x - cw) / 2.0, cy)
	_caption.modulate.a = 0.0 if first_frame else 1.0

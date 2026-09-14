extends Node2D
## Milestone 3, Step 3b: the real game loop. Owns the live game-state
## Dictionary `g` (mirrors newGame()'s real field list -- see
## FarroadProgression.gd) and drives BattlePresenter wave after wave using
## FarroadProgression's real build_party/build_enemies/grant_drops/
## after_wave_cleared/on_wipe -- the existing battle view (Milestone 2) is
## reused exactly as-is, only the "where does the battle come from" seam
## changed (BattlePresenter.start_battle(), not its own hardcoded demo
## scenario).
##
## No `mc` yet (character creation is Step 3j) -- a fresh game runs with
## `g["mc"] = null`, exactly like a fresh JS save before creation exists,
## which uses the hardcoded Kesh default. Step 3c added the GAMBITS tab
## (loadout editor + party bench/field, see GambitsPanel.gd); Step 3d
## added AETHER (leveling/Recovery/Evade-Crit/Affinity investment, see
## AetherPanel.gd); Step 3e added LORE (per-action bonus purchase/refund,
## see LorePanel.gd); Step 3f added EQUIPMENT (per-unit gear management,
## see EquipmentPanel.gd); Step 3g added MARKS (gacha pulls, see
## MarksPanel.gd); Step 3h added EXPEDITION (real-time idle sending +
## offline catch-up, see ExpeditionPanel.gd); Step 3i added QUESTS
## (companion quest lines + direction dungeons, a real interactive side
## battle -- see QuestsPanel.gd and _enter_side_battle() below). No
## character-creation screen yet (Step 3j, the last roadmap item).

const SAVE_PATH := "user://save.json"
## How often expeditions get a chance to resolve while the game is
## running (mirrors the real farroad-ui.js's own 15s setInterval poll --
## see _on_expedition_tick()). Offline catch-up (a much bigger, one-shot
## time gap) is handled separately, once, at boot -- see
## _load_or_new_game().
const EXPEDITION_POLL_SEC := 15.0

var g: Dictionary
var _vp: Vector2
var current_presenter: Node = null
var gambits_panel: Node
var party_panel: Node
var aether_panel: Node
var lore_panel: Node
var equipment_panel: Node
var marks_panel: Node
var expedition_panel: Node
var expedition_timer: Timer
var quests_panel: Node
## The side battle currently running (a quest attempt or a dungeon
## crawl), or null when none is active -- GameController's own equivalent
## of the real JS's reassignable G.battle pointer (see
## FarroadProgression.start_side_battle's own comment for why a SECOND,
## independent BattlePresenter instance is enough here, unlike the real
## JS's shared-tick-loop architecture).
var side_presenter: Node = null

var wave_label: Label
var currency_label: Label
var wave_popup: PanelContainer
var wave_popup_label: Label
var fade_overlay: ColorRect

func _ready() -> void:
	_vp = get_viewport_rect().size
	if not FarroadCore.load_real_content():
		push_error("GameController: failed to load res://data/content.json")
		return
	_build_hud()
	_load_or_new_game()
	_refresh_hud()
	gambits_panel = load("res://scripts/GambitsPanel.gd").new()
	add_child(gambits_panel)
	gambits_panel.setup(g, _vp, self)
	party_panel = load("res://scripts/PartyPanel.gd").new()
	add_child(party_panel)
	party_panel.setup(g, _vp, self)
	aether_panel = load("res://scripts/AetherPanel.gd").new()
	add_child(aether_panel)
	aether_panel.setup(g, _vp, self)
	lore_panel = load("res://scripts/LorePanel.gd").new()
	add_child(lore_panel)
	lore_panel.setup(g, _vp, self)
	equipment_panel = load("res://scripts/EquipmentPanel.gd").new()
	add_child(equipment_panel)
	equipment_panel.setup(g, _vp, self)
	marks_panel = load("res://scripts/MarksPanel.gd").new()
	add_child(marks_panel)
	marks_panel.setup(g, _vp, self)
	expedition_panel = load("res://scripts/ExpeditionPanel.gd").new()
	add_child(expedition_panel)
	expedition_panel.setup(g, _vp, self)
	quests_panel = load("res://scripts/QuestsPanel.gd").new()
	add_child(quests_panel)
	quests_panel.setup(g, _vp, self)
	expedition_timer = Timer.new()
	expedition_timer.wait_time = EXPEDITION_POLL_SEC
	expedition_timer.autostart = true
	expedition_timer.timeout.connect(_on_expedition_tick)
	add_child(expedition_timer)
	get_viewport().size_changed.connect(_on_viewport_resized)
	_begin_next_fight()

## The live equivalent of the offline catch-up below -- while the game
## keeps running, an active expedition still needs a chance to resolve
## progress without requiring a full app restart. Mirrors the real JS's
## own periodic poll (setInterval, farroad-ui.js:3249-3251); Godot's Timer
## node is the natural equivalent (nothing like this existed anywhere in
## this port before this step). Only refreshes expedition_panel's own
## popup if it's actually open -- no point rebuilding UI nobody can see.
func _on_expedition_tick() -> void:
	FarroadProgression.resolve_all_expeditions(g, Time.get_unix_time_from_system())
	if expedition_panel.popup.visible:
		expedition_panel.call("_refresh")
	# resolve_all_expeditions can unlock a new dungeon (Step 3i,
	# unlock_direction_dungeon called from inside resolve_expedition) --
	# refresh a currently-open QUESTS popup so a new dungeon card appears
	# without waiting for the player to close and reopen it.
	if quests_panel.popup.visible:
		quests_panel.call("_refresh")

## A window resize (or, on a real device, a size Godot didn't report until
## just now) changes what get_viewport_rect().size actually is -- everything
## in this project is laid out as a FRACTION of that, computed once at
## build time, so without this every fraction-based position would stay
## wrong (sized for the old viewport) for the rest of the session. Repositions
## this controller's own static HUD directly, and asks BattlePresenter/
## GambitsPanel/AetherPanel to do the same for their own chrome. Currently-
## live battle UNITS are deliberately left alone here -- see
## BattlePresenter.reflow()'s own comment for why that's safe, not an
## oversight.
func _on_viewport_resized() -> void:
	_vp = get_viewport_rect().size
	wave_label.position = Vector2(_vp.x * 0.02, _vp.y * 0.015)
	wave_label.add_theme_font_size_override("font_size", int(_vp.y * 0.035))
	currency_label.position = Vector2(_vp.x * 0.02, _vp.y * 0.055)
	currency_label.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	fade_overlay.size = _vp
	# wave_popup itself needs no repositioning here -- _show_wave_popup()
	# already computes its center fresh from _vp every time it's shown.
	if current_presenter != null:
		current_presenter.reflow(_vp)
	gambits_panel.reflow(_vp)
	party_panel.reflow(_vp)
	aether_panel.reflow(_vp)
	lore_panel.reflow(_vp)
	equipment_panel.reflow(_vp)
	marks_panel.reflow(_vp)
	expedition_panel.reflow(_vp)
	quests_panel.reflow(_vp)

## Resumes user://save.json if one exists and parses cleanly; otherwise
## starts a brand new run. Mirrors tryResumeSave()/boot() (farroad-ui.js) --
## startWave(...);simulateOfflineProgress(snap);resolveAllExpeditions();
## same exact call order. `saved_at` comes from the save envelope's own
## top-level "savedAt" field (sibling to the FIELDS-derived content
## deserialize() reads), not from anything inside `g` itself.
func _load_or_new_game() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f != null:
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed != null:
			g = FarroadSave.deserialize(parsed)
			var resume_wave: int = g["wave"] if g.get("wave") else 1
			# skip_drops=true: this wave was never cleared when saved, so
			# grant_drops(w) must not treat resuming it as a fresh visit --
			# same reasoning as the real tryResumeSave()'s own call.
			FarroadProgression.start_wave(g, resume_wave, true)
			var now := Time.get_unix_time_from_system()
			FarroadProgression.simulate_offline_progress(g, parsed.get("savedAt"), now)
			FarroadProgression.resolve_all_expeditions(g, now)
			return
	g = FarroadProgression.new_game(int(Time.get_unix_time_from_system()) % 100000, null)
	FarroadProgression.start_wave(g, 1)

func _save_game() -> void:
	var snap := FarroadSave.serialize(g, int(Time.get_unix_time_from_system()))
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("GameController: failed to open %s for writing" % SAVE_PATH)
		return
	f.store_string(JSON.stringify(snap))
	f.close()

## A minimal top strip (currency purse + wave number) above the existing
## battle view -- not a full tab bar yet, since there's only one screen to
## navigate to until Step 3c. Between waves, a centered "Wave N" popup
## (see _show_wave_popup) is the only new control surface this step needs --
## it announces the upcoming wave for a second, then the next fight starts
## on its own, no button to press.
func _build_hud() -> void:
	wave_label = Label.new()
	wave_label.position = Vector2(_vp.x * 0.02, _vp.y * 0.015)
	wave_label.add_theme_font_size_override("font_size", int(_vp.y * 0.035))
	add_child(wave_label)

	currency_label = Label.new()
	currency_label.position = Vector2(_vp.x * 0.02, _vp.y * 0.055)
	currency_label.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	add_child(currency_label)

	# A full-screen overlay for the wipe-transition fade (see
	# _fade_out()/_fade_in()) -- starts fully transparent and hidden;
	# mouse_filter=IGNORE so it never blocks input while invisible (during
	# the fade itself it's the only thing meant to be interactable-looking
	# anyway, and nothing needs to be clicked while the screen is black).
	fade_overlay = ColorRect.new()
	fade_overlay.color = Color(0, 0, 0, 0)
	fade_overlay.position = Vector2.ZERO
	fade_overlay.size = _vp
	fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_overlay.hide()
	add_child(fade_overlay)

	wave_popup = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.85, 0.7, 0.15, 1.0)
	style.set_border_width_all(3)
	style.set_content_margin_all(int(_vp.y * 0.03))
	wave_popup.add_theme_stylebox_override("panel", style)
	wave_popup.hide()
	add_child(wave_popup)

	wave_popup_label = Label.new()
	wave_popup_label.add_theme_font_size_override("font_size", int(_vp.y * 0.06))
	wave_popup.add_child(wave_popup_label)

func _refresh_hud() -> void:
	wave_label.text = "Wave %d" % g["wave"]
	currency_label.text = "Aether %d   Lore %d   Marks %d" % [
		roundi(g["aether"]), roundi(g["lore"]), roundi(g["marks"])]

## Called by GambitsPanel/AetherPanel (dynamic has_method()+call(), same
## pattern as _notify_currency_changed) when either popup opens/closes --
## see BattlePresenter.loop_paused's own comment for why this exists. Only
## one of these popups is ever open at a time in practice, so a single
## shared pause flag is enough -- no need to track which panel asked.
func _set_battle_paused(paused: bool) -> void:
	if current_presenter != null:
		current_presenter.call("set_loop_paused", paused)

## Called by PartyPanel (dynamic has_method()+call(), same pattern as
## _set_battle_paused) right after a bench/field edit -- pushes the roster
## change onto the live fight immediately (see
## FarroadProgression.refresh_live_party's own comment) rather than waiting
## for the next wave's build_party().
func _sync_party_change() -> void:
	if current_presenter == null:
		return
	var added: Array = FarroadProgression.refresh_live_party(g)
	current_presenter.call("sync_live_party", added)

func _begin_next_fight() -> void:
	var presenter = load("res://scripts/BattlePresenter.gd").new()
	presenter.battle_finished.connect(_on_battle_finished)
	add_child(presenter)
	await get_tree().process_frame
	presenter.start_battle(g["battle"], g["units"] + g["enemies"])
	current_presenter = presenter

## Mirrors the real doStep()'s post-battle branch (afterWaveCleared() on a
## win, onWipe() on a loss) -- on_wipe already rebuilds g["battle"] at the
## checkpoint wave internally (it calls start_wave itself), so only a WIN
## needs a separate start_wave(wave+1) call here.
func _on_battle_finished(outcome: String) -> void:
	if outcome == "party":
		FarroadProgression.after_wave_cleared(g)
		FarroadProgression.start_wave(g, g["wave"] + 1)
		_refresh_hud()
		_save_game()
		# The finished battlefield (units, HP bars, log/status buttons) stays
		# on screen behind the popup -- only freed once the NEXT fight is
		# actually being built, not the moment this one ends.
		await _show_wave_popup(g["wave"])
		if current_presenter != null:
			current_presenter.queue_free()
			current_presenter = null
		_begin_next_fight()
	else:
		FarroadProgression.on_wipe(g)
		_refresh_hud()
		_save_game()
		# A wipe hides the checkpoint jump behind a fade to black instead of
		# announcing it with text -- the field swap happens while the screen
		# is fully black, so the return to an earlier wave reads as a scene
		# transition rather than a called-out event.
		await _fade_out()
		if current_presenter != null:
			current_presenter.queue_free()
			current_presenter = null
		await _begin_next_fight()
		await _fade_in()

## Announces the upcoming wave for a second, then dismisses itself --
## replaces the earlier "Next Wave" button with a fully automatic
## transition, no click needed. Centered on the COMBAT field specifically
## (the same 0.11-0.58 viewport-height band BattlePresenter's own
## field_top/field_bottom lay units out in), not the full window -- that
## keeps it clear of the currency/wave strip above and the log/status
## buttons + turn-order strip below.
func _show_wave_popup(w: int) -> void:
	wave_popup_label.text = "Wave %d" % w
	# wave_popup is a plain PanelContainer (a CanvasItem sibling of
	# GameController's other children), not a real overlay window -- its
	# draw order follows its position in the children list. Each new
	# BattlePresenter (and its units) gets added AFTER wave_popup was first
	# built in _build_hud(), so without this it silently ends up drawn on
	# TOP of the popup from the second wave onward. Move it to the very end
	# of the children list -- drawn last, i.e. on top -- every time it's
	# about to show.
	move_child(wave_popup, get_child_count() - 1)
	wave_popup.show()
	await get_tree().process_frame   # let the container size itself to the new text
	var combat_center := Vector2(_vp.x / 2.0, _vp.y * (0.11 + 0.58) / 2.0)
	wave_popup.position = combat_center - wave_popup.size / 2.0
	await get_tree().create_timer(1.0).timeout
	wave_popup.hide()

const FADE_HALF_SEC := 0.5

## A ~1s fade to black and back, used on a wipe to hide the checkpoint jump
## (the actual battlefield swap happens while the screen is fully black,
## between _fade_out() finishing and _fade_in() starting).
func _fade_out() -> void:
	# Same z-order trick wave_popup uses -- new BattlePresenter children get
	# added after fade_overlay was built in _build_hud(), so without this it
	# would draw UNDER them instead of covering the whole screen.
	move_child(fade_overlay, get_child_count() - 1)
	fade_overlay.show()
	fade_overlay.color.a = 0.0
	var tw := create_tween()
	tw.tween_property(fade_overlay, "color:a", 1.0, FADE_HALF_SEC)
	await tw.finished

func _fade_in() -> void:
	var tw := create_tween()
	tw.tween_property(fade_overlay, "color:a", 0.0, FADE_HALF_SEC)
	await tw.finished
	fade_overlay.hide()

## ===== QUESTS side battles (Step 3i) =====
## Mirrors startSideBattle's presentation half (farroad-ui.js:1455-1466) --
## the state mutation itself is FarroadProgression.start_side_battle().
## No wasPlaying/play() dance is needed here: this port has no
## player-facing play/pause/speed control for the Road to preserve in the
## first place (the Road always auto-plays), unlike the real JS, which
## needed that dance specifically to avoid double-scheduling a second
## parallel setTimeout chain. Pausing+hiding current_presenter (the SAME
## set_loop_paused every sibling panel already uses, plus additionally
## hiding it since the side battle needs the same on-field real estate,
## not a small popup) is this port's whole equivalent.
func _enter_side_battle(enemies: Array, wave: int, meta: Dictionary) -> void:
	if not FarroadProgression.start_side_battle(g, enemies, wave, meta):
		return
	if current_presenter != null:
		current_presenter.call("set_loop_paused", true)
		current_presenter.hide()
		if current_presenter.log_popup.visible:
			current_presenter.log_popup.hide()
		if current_presenter.status_popup.visible:
			current_presenter.status_popup.hide()
	side_presenter = load("res://scripts/BattlePresenter.gd").new()
	side_presenter.battle_finished.connect(_on_side_battle_finished)
	add_child(side_presenter)
	await get_tree().process_frame
	side_presenter.start_battle(g["battle"], g["battle"]["units"])

## Called by QuestsPanel (dynamic has_method()+call(), same pattern as
## every other panel-to-controller call in this project).
func _attempt_quest(uid: String) -> void:
	var prep := FarroadProgression.prep_quest_attempt(g, uid)
	if prep.is_empty():
		return
	quests_panel.popup.hide()
	_enter_side_battle(prep["enemies"], prep["wave"], prep["meta"])

func _enter_dungeon(id: String) -> void:
	var prep := FarroadProgression.prep_dungeon_attempt(g, id)
	if prep.is_empty():
		return
	quests_panel.popup.hide()
	_enter_side_battle(prep["enemies"], prep["wave"], prep["meta"])

func _on_side_battle_finished(outcome: String) -> void:
	_resolve_side_battle(outcome, false)

## Give Up is quests-only (the real JS's own "Ian's ask" scope -- dungeons
## can't be abandoned mid-crawl, only quests). Instant: directly
## queue_free()s side_presenter rather than waiting for another beat --
## Godot's Tween/coroutine machinery already cleans up safely when the
## node it's bound to is freed mid-animation (the same unconditional
## queue_free() a Road wipe already relies on), so no BattlePresenter-side
## abort flag is needed.
func _give_up_quest() -> void:
	if g.get("sideBattle") == null or g["sideBattle"]["meta"]["kind"] != "quest":
		return
	side_presenter.battle_finished.disconnect(_on_side_battle_finished)
	side_presenter.queue_free()
	side_presenter = null
	_resolve_side_battle("enemy", true)

func _resolve_side_battle(result: String, gave_up: bool) -> void:
	var event := FarroadProgression.finish_side_battle(g, result, gave_up)
	if event["kind"] == "dungeon_wave_advance":
		# Same fresh-instance-per-wave convention _begin_next_fight already
		# uses for the Road -- BattlePresenter._layout_units() never frees
		# prior UnitViews, so reusing one instance across waves would leak
		# them; a new instance per wave is both simpler and consistent.
		side_presenter.queue_free()
		side_presenter = load("res://scripts/BattlePresenter.gd").new()
		side_presenter.battle_finished.connect(_on_side_battle_finished)
		add_child(side_presenter)
		await get_tree().process_frame
		side_presenter.start_battle(g["battle"], g["battle"]["units"])
		return
	if side_presenter != null:
		side_presenter.queue_free()
		side_presenter = null
	if current_presenter != null:
		current_presenter.show()
		current_presenter.call("set_loop_paused", false)
	quests_panel.call("_show_result", event)
	_refresh_hud()
	_save_game()

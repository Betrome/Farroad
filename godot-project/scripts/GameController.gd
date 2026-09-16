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
## Step 3c added the GAMBITS tab (loadout editor + party bench/field, see
## GambitsPanel.gd); Step 3d added AETHER (leveling/Recovery/Evade-Crit/
## Affinity investment, see AetherPanel.gd); Step 3e added LORE (per-action
## bonus purchase/refund, see LorePanel.gd); Step 3f added EQUIPMENT
## (per-unit gear management, see EquipmentPanel.gd); Step 3g added MARKS
## (gacha pulls, see MarksPanel.gd); Step 3h added EXPEDITION (real-time
## idle sending + offline catch-up, see ExpeditionPanel.gd); Step 3i added
## QUESTS (companion quest lines + direction dungeons, a real interactive
## side battle -- see QuestsPanel.gd and _enter_side_battle() below);
## Step 3j (the last roadmap item) added character creation (MC point-buy
## + charge-action picker, see McCreatePanel.gd) -- `_ready()` now gates
## the whole HUD/panels/first-fight sequence (moved into `_start_game()`)
## behind EITHER a resumed save (`_try_resume_save()`) OR a confirmed new
## character (`_on_mc_confirmed()`), matching the real `tryResumeSave()`/
## `showMcCreate()`/`boot()` boot gate exactly -- there is no more
## "fresh game, no mc" fallback, since the real JS has no such path either
## (character creation is unconditional whenever no save exists).

const SAVE_PATH := "user://save.json"
## How often expeditions get a chance to resolve while the game is
## running (mirrors the real farroad-ui.js's own 15s setInterval poll --
## see _on_expedition_tick()). Offline catch-up (a much bigger, one-shot
## time gap) is handled separately, once, at boot -- see
## _try_resume_save().
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
var mc_panel: Node
## Tracks whichever panel's own popup is currently open -- see
## _panel_opening()'s own comment for why this exists.
var open_panel: Node = null
## The side battle currently running (a quest attempt or a dungeon
## crawl), or null when none is active -- GameController's own equivalent
## of the real JS's reassignable G.battle pointer (see
## FarroadProgression.start_side_battle's own comment for why a SECOND,
## independent BattlePresenter instance is enough here, unlike the real
## JS's shared-tick-loop architecture).
var side_presenter: Node = null

var wave_label: Label
var currency_label: Label
var idle_rate_label: Label
var wave_popup: PanelContainer
var wave_popup_label: Label
var fade_overlay: ColorRect
## Captured by _try_resume_save() (empty {} when no save existed, or the
## real 5s no-op floor wasn't met) -- consumed once by _start_game() to
## show the welcome-back popup (Group J, post-Milestone-3 batch).
var _offline_summary: Dictionary = {}

func _ready() -> void:
	_vp = get_viewport_rect().size
	if not FarroadCore.load_real_content():
		push_error("GameController: failed to load res://data/content.json")
		return
	if _try_resume_save():
		_start_game()
	else:
		mc_panel = load("res://scripts/McCreatePanel.gd").new()
		add_child(mc_panel)
		mc_panel.setup(_vp, self, _on_mc_confirmed)

## Everything that used to run unconditionally right after
## _load_or_new_game() -- now shared by both boot paths (a resumed save,
## or a freshly confirmed character), run only once `g` is guaranteed
## fully built either way.
func _start_game() -> void:
	_build_hud()
	_refresh_hud()
	if not _offline_summary.is_empty():
		_show_welcome_back_popup()
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
	idle_rate_label.position = Vector2(_vp.x * 0.02, _vp.y * 0.083)
	idle_rate_label.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
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

## Resumes user://save.json if one exists and parses cleanly. Mirrors
## tryResumeSave() (farroad-ui.js) -- applyCustomMC();startWave(...);
## simulateOfflineProgress(snap);resolveAllExpeditions(); same exact call
## order, including calling apply_custom_mc unconditionally (a no-op when
## g["mc"] is null, e.g. a legacy pre-MC save -- matches the real
## tryResumeSave()'s own applyCustomMC() call). `saved_at` comes from the
## save envelope's own top-level "savedAt" field (sibling to the
## FIELDS-derived content deserialize() reads), not from anything inside
## `g` itself. Returns false (doing nothing else) when no save exists or
## it fails to parse -- the caller then shows character creation instead
## of silently falling back to a fresh mc=null game, matching how the real
## JS has no "fresh game, no mc" path at all (showMcCreate() is
## unconditional whenever no save exists).
func _try_resume_save() -> bool:
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null:
		return false
	g = FarroadSave.deserialize(parsed)
	FarroadProgression.apply_custom_mc(g)
	var resume_wave: int = g["wave"] if g.get("wave") else 1
	# skip_drops=true: this wave was never cleared when saved, so
	# grant_drops(w) must not treat resuming it as a fresh visit --
	# same reasoning as the real tryResumeSave()'s own call.
	FarroadProgression.start_wave(g, resume_wave, true)
	var now := Time.get_unix_time_from_system()
	_offline_summary = FarroadProgression.simulate_offline_progress(g, parsed.get("savedAt"), now)
	FarroadProgression.resolve_all_expeditions(g, now)
	return true

## Mirrors boot(7,mc) (farroad-ui.js:3234, the real btnMcConfirm handler --
## fresh games always seed 7 in the real game; there is no real-JS
## equivalent of a time-based seed, since a fresh mc=null game was never
## a real path there). Called by McCreatePanel once the player confirms.
func _on_mc_confirmed(mc: Dictionary) -> void:
	g = FarroadProgression.new_game(7, mc)
	FarroadProgression.apply_custom_mc(g)
	FarroadProgression.start_wave(g, 1)
	_save_game()   # mirrors doSave() immediately after boot(7,mc)
	_start_game()

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

	# Idle reward rate (Group I, post-Milestone-3 batch) -- a small line
	# under the currency purse showing the ambient trickle rate feeding it
	# (idle_per_sec already runs regardless of whether the player is
	# actively fighting -- see simulate_offline_progress's own comment).
	idle_rate_label = Label.new()
	idle_rate_label.position = Vector2(_vp.x * 0.02, _vp.y * 0.083)
	idle_rate_label.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	idle_rate_label.modulate = Color(0.65, 0.65, 0.65)
	add_child(idle_rate_label)

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

## Group J (post-Milestone-3 batch): a one-time "welcome back" summary,
## shown right after the HUD is built whenever a resumed save had a real
## offline gap (_offline_summary is non-empty -- simulate_offline_progress's
## own 5s no-op floor already filters out a trivial gap, so no further
## threshold check is needed here). A genuine step back toward a real
## separate modal versus the real JS's current pushDrop()-banner approach --
## a deliberate, Ian-requested choice for this port specifically, not a
## "fix" to match current real-JS behavior (see this batch's own Group J
## plan). Same opaque-panel styling convention every sibling panel's own
## _style_popup already uses, just with its own border tint (blue, distinct
## from the wave popup's gold and every tab panel's grey) to read as its
## own kind of moment.
func _show_welcome_back_popup() -> void:
	var s := _offline_summary
	var elapsed_sec: float = s["elapsed_sec"]
	var away_txt: String
	if elapsed_sec >= 3600.0:
		away_txt = "%.1f hours" % (elapsed_sec / 3600.0)
	else:
		away_txt = "%d minutes" % maxi(1, roundi(elapsed_sec / 60.0))
	if elapsed_sec > FarroadProgression.OFFLINE_CAP_SEC:
		away_txt += " (capped at %dh)" % int(FarroadProgression.OFFLINE_CAP_SEC / 3600)

	var wave_delta: int = int(s["wave_after"]) - int(s["wave_before"])
	var progress_txt: String
	if wave_delta > 0:
		progress_txt = "Cleared %d wave%s, now at wave %d." % [wave_delta, ("" if wave_delta == 1 else "s"), int(s["wave_after"])]
	else:
		progress_txt = "Not enough time passed to clear another wave."

	var wipes_gained: int = int(s["wipes_gained"])
	var wipe_txt := ""
	if wipes_gained > 0:
		wipe_txt = "\nWiped %d time%s — back to checkpoint." % [wipes_gained, ("" if wipes_gained == 1 else "s")]

	var popup := PopupPanel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.35, 0.6, 0.85, 1.0)
	style.set_border_width_all(3)
	style.set_content_margin_all(int(_vp.y * 0.03))
	popup.add_theme_stylebox_override("panel", style)
	add_child(popup)
	# _show_welcome_back_popup() is called synchronously from _start_game(),
	# itself called synchronously from _ready() -- a freshly add_child()ed
	# Window-derived node (PopupPanel is one) hasn't finished its own
	# internal _ready() setup yet within that same frame, so calling
	# popup_centered() immediately after add_child() can silently fail to
	# actually show it. One frame is enough (same fix shape _show_wave_popup
	# already uses for its own post-add sizing).
	await get_tree().process_frame

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(_vp.x * 0.78, 0)
	vbox.add_theme_constant_override("separation", 10)
	popup.add_child(vbox)

	var title := Label.new()
	title.text = "Welcome back!"
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.04))
	vbox.add_child(title)

	var body := Label.new()
	body.text = "Away %s.\n%s%s" % [away_txt, progress_txt, wipe_txt]
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	var gained := Label.new()
	gained.text = "+%d Aether, +%d Marks" % [roundi(s["aether_gained"]), int(floor(s["marks_gained"]))]
	gained.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	gained.modulate = Color(0.85, 0.75, 0.4)
	vbox.add_child(gained)

	var got_it := Button.new()
	got_it.text = "Got it"
	got_it.pressed.connect(func():
		popup.hide()
		popup.queue_free())
	vbox.add_child(got_it)

	popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.6))

func _refresh_hud() -> void:
	wave_label.text = "Wave %d" % g["wave"]
	currency_label.text = "Aether %d   Lore %d   Marks %d" % [
		roundi(g["aether"]), roundi(g["lore"]), roundi(g["marks"])]
	var r := FarroadProgression.idle_per_sec(g.get("farthest", 1))
	var marks_rate: float = r["marks"] * FarroadProgression.marks_mul(g)
	idle_rate_label.text = "%.1f Aether/hr   %.1f Marks/hr" % [r["aether"] * 3600.0, marks_rate * 3600.0]

## Called by GambitsPanel/AetherPanel (dynamic has_method()+call(), same
## pattern as _notify_currency_changed) when either popup opens/closes --
## see BattlePresenter.loop_paused's own comment for why this exists. Only
## one of these popups is ever open at a time in practice, so a single
## shared pause flag is enough -- no need to track which panel asked.
func _set_battle_paused(paused: bool) -> void:
	if current_presenter != null:
		current_presenter.call("set_loop_paused", paused)

## Called by every panel (dynamic has_method()+call()) at the very start
## of its own _on_toggle_pressed, BEFORE opening its own popup -- closes
## whichever OTHER panel's popup is currently open first. Godot's own
## PopupPanel auto-dismisses on an outside click, but that SAME click
## does not also pass through to whatever is underneath it -- tapping a
## different tab's icon while another panel's popup is open would
## otherwise just dismiss the old one (consuming that tap) and require a
## second tap to actually open the new one, exactly the "switching tabs
## sometimes just closes the current one" bug. Explicitly closing the
## old popup here, from the NEW panel's own button-press handler (a
## normal click on an always-visible sibling Control, never eaten by the
## old popup's own dismiss handling), means the new popup still opens on
## the SAME tap that closed the old one.
func _panel_opening(panel: Node) -> void:
	if open_panel != null and open_panel != panel and is_instance_valid(open_panel):
		open_panel.popup.hide()
	open_panel = panel

## Called by PartyPanel (dynamic has_method()+call(), same pattern as
## _set_battle_paused) right after a bench/field edit -- pushes the roster
## change onto the live fight immediately (see
## FarroadProgression.refresh_live_party's own comment) rather than waiting
## for the next wave's build_party().
func _sync_party_change() -> void:
	if current_presenter == null:
		return
	var result: Dictionary = FarroadProgression.refresh_live_party(g)
	current_presenter.call("sync_live_party", result["added"], result["removed"])

## Guarded against a real race with side battles (Step 3i/3j fix): a Road
## win/wipe can already be mid-await (_show_wave_popup/_fade_out, both a
## full second or more) when the player attempts a quest/dungeon --
## start_side_battle() reassigns g["battle"] to the side fight's own
## battle out from under this function. Without the two checks below,
## the resumed _on_battle_finished call would build a SECOND, unpaused,
## visible presenter from that reassigned g["battle"]/stale g["units"]/
## g["enemies"], rendered alongside side_presenter -- exactly the
## visible "quests overlap with the road" bug this was written to fix.
## _resolve_side_battle's own restore path is what rebuilds the Road's
## presenter once it's actually safe again (see its own comment).
func _begin_next_fight() -> void:
	if g.get("sideBattle") != null:
		return
	var presenter = load("res://scripts/BattlePresenter.gd").new()
	presenter.battle_finished.connect(_on_battle_finished)
	add_child(presenter)
	await get_tree().process_frame
	if g.get("sideBattle") != null:
		presenter.queue_free()
		return
	presenter.start_battle(g["battle"], g["units"] + g["enemies"])
	current_presenter = presenter

## Mirrors the real doStep()'s post-battle branch (afterWaveCleared() on a
## win, onWipe() on a loss) -- on_wipe already rebuilds g["battle"] at the
## checkpoint wave internally (it calls start_wave itself), so only a WIN
## needs a separate start_wave(wave+1) call here.
func _on_battle_finished(outcome: String) -> void:
	if outcome == "party":
		var aether_before: float = g.get("aether", 0.0)
		var lore_before: float = g.get("lore", 0.0)
		var marks_before: float = g.get("marks", 0.0)
		var events: Array = FarroadProgression.after_wave_cleared(g)
		events += FarroadProgression.start_wave(g, g["wave"] + 1)
		_refresh_hud()
		_save_game()
		_spawn_reward_drops(events, aether_before, lore_before, marks_before)
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

## ===== Group H: wave-clear reward drop animation =====
## Icon x-fractions duplicated from the target panels' own _build_icon_tab
## calls (GambitsPanel.gd/PartyPanel.gd/EquipmentPanel.gd, all at
## icon_size=0.11*vp.x, y=0.93*vp.y) -- same per-file duplication
## convention this project already uses everywhere else, not a new pattern.
const ICON_SIZE_FRAC := 0.11
const ICON_Y_FRAC := 0.93
const GAMBITS_ICON_X_FRAC := 0.0133
const PARTY_ICON_X_FRAC := 0.1367
const EQUIPMENT_ICON_X_FRAC := 0.5067

const REWARD_FLYER_TIME := 0.7
const REWARD_FLYER_STAGGER := 0.12

func _icon_center(x_frac: float) -> Vector2:
	var icon_size: float = _vp.x * ICON_SIZE_FRAC
	return Vector2(_vp.x * x_frac + icon_size / 2.0, _vp.y * ICON_Y_FRAC + icon_size / 2.0)

## Snapshotted aether/lore/marks BEFORE after_wave_cleared/start_wave ran,
## diffed against the current (post-call) values -- covers every plain
## per-wave Aether/Marks gain and duplicate-drop Lore conversion, which
## have no dedicated event of their own, without adding new event kinds to
## the engine layer (see this batch's own Group H plan for why a diff is
## preferred over new events). Each captured typed event
## (action/cond -> Gambits, equip -> Equipment, boss_companion(_roll) ->
## Party) spawns its own flyer too. Fire-and-forget -- not awaited by the
## caller, matching the established "small reusable helper, no bespoke
## animation per reward kind" design.
func _spawn_reward_drops(events: Array, aether_before: float, lore_before: float, marks_before: float) -> void:
	var start := Vector2(_vp.x / 2.0, _vp.y * (0.11 + 0.58) / 2.0)
	var delay := 0.0
	var aether_delta: float = g.get("aether", 0.0) - aether_before
	if aether_delta >= 1.0:
		_spawn_reward_flyer(start, currency_label.position, "+%d Aether" % roundi(aether_delta), delay)
		delay += REWARD_FLYER_STAGGER
	var lore_delta: float = g.get("lore", 0.0) - lore_before
	if lore_delta >= 1.0:
		_spawn_reward_flyer(start, currency_label.position, "+%d Lore" % roundi(lore_delta), delay)
		delay += REWARD_FLYER_STAGGER
	var marks_delta: float = g.get("marks", 0.0) - marks_before
	if marks_delta >= 1.0:
		_spawn_reward_flyer(start, currency_label.position, "+%d Marks" % roundi(marks_delta), delay)
		delay += REWARD_FLYER_STAGGER
	for e in events:
		var target = _reward_icon_target(e)
		if target == null:
			continue
		_spawn_reward_flyer(start, target, _reward_event_text(e), delay)
		delay += REWARD_FLYER_STAGGER

func _reward_icon_target(e: Dictionary) -> Variant:
	match e.get("kind", ""):
		"action", "cond":
			return _icon_center(GAMBITS_ICON_X_FRAC)
		"equip":
			return _icon_center(EQUIPMENT_ICON_X_FRAC)
		"boss_companion", "boss_companion_roll":
			return _icon_center(PARTY_ICON_X_FRAC)
		_:
			return null

func _reward_event_text(e: Dictionary) -> String:
	match e.get("kind", ""):
		"action":
			return "Action (dup)" if e.get("duplicate", false) else "New action!"
		"cond":
			return "Gambit (dup)" if e.get("duplicate", false) else "New gambit!"
		"equip":
			return "New gear!"
		"boss_companion", "boss_companion_roll":
			return "New companion!"
		_:
			return ""

## A small Label tweening from `start` to `end` while fading out near the
## end, then freeing itself -- the reusable flyer every reward kind
## (currency deltas and typed events alike) spawns through.
func _spawn_reward_flyer(start: Vector2, end: Vector2, text: String, delay: float) -> void:
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.028))
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	lbl.position = start
	add_child(lbl)
	move_child(lbl, get_child_count() - 1)
	var tw := create_tween()
	tw.tween_property(lbl, "position", end, REWARD_FLYER_TIME)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, REWARD_FLYER_TIME).set_delay(REWARD_FLYER_TIME * 0.4)
	await tw.finished
	lbl.queue_free()

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
	wave_label.text = _side_battle_label_text(meta)

## Replaces the top strip's "Wave N" text with the quest/dungeon's own
## name while a side battle is active -- restored by the ordinary
## _refresh_hud() call once the side battle fully resolves.
func _side_battle_label_text(meta: Dictionary) -> String:
	if meta["kind"] == "quest":
		return "%s's Quest — Stage %d/5" % [meta["name"], int(meta["stage"]) + 1]
	return "%s — Wave %d/%d" % [meta["name"], int(meta["waveIndex"]) + 1, int(meta["totalWaves"])]

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
		wave_label.text = _side_battle_label_text(g["sideBattle"]["meta"])
		return
	if side_presenter != null:
		side_presenter.queue_free()
		side_presenter = null
	if current_presenter != null:
		current_presenter.show()
		current_presenter.call("set_loop_paused", false)
	else:
		# Recovery path for the race _begin_next_fight() guards against:
		# a Road win/wipe that was already mid-await when this side battle
		# started ran its own cleanup (current_presenter freed and nulled)
		# but skipped rebuilding a new one, deferring that to right here --
		# now that g["sideBattle"] is clear again, it's finally safe to.
		_begin_next_fight()
	quests_panel.call("_show_result", event)
	_refresh_hud()
	_save_game()

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
## see LorePanel.gd). No EQUIPMENT/MARKS/EXPEDITION/QUESTS tabs yet
## (Steps 3f-3j).

const SAVE_PATH := "user://save.json"

var g: Dictionary
var _vp: Vector2
var current_presenter: Node = null
var gambits_panel: Node
var aether_panel: Node
var lore_panel: Node

var wave_label: Label
var currency_label: Label
var outcome_label: Label
var wave_popup: PanelContainer
var wave_popup_label: Label

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
	aether_panel = load("res://scripts/AetherPanel.gd").new()
	add_child(aether_panel)
	aether_panel.setup(g, _vp, self)
	lore_panel = load("res://scripts/LorePanel.gd").new()
	add_child(lore_panel)
	lore_panel.setup(g, _vp, self)
	get_viewport().size_changed.connect(_on_viewport_resized)
	_begin_next_fight()

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
	outcome_label.position = Vector2(_vp.x * 0.30, _vp.y * 0.025)
	outcome_label.add_theme_font_size_override("font_size", int(_vp.y * 0.03))
	# wave_popup itself needs no repositioning here -- _show_wave_popup()
	# already computes its center fresh from _vp every time it's shown.
	if current_presenter != null:
		current_presenter.reflow(_vp)
	gambits_panel.reflow(_vp)
	aether_panel.reflow(_vp)
	lore_panel.reflow(_vp)

## Resumes user://save.json if one exists and parses cleanly; otherwise
## starts a brand new run. Mirrors tryResumeSave()/boot() (farroad-ui.js) --
## minus simulateOfflineProgress()/resolveAllExpeditions(), both out of
## scope (idle/expedition catch-up, Step 3h) -- a resumed game picks up
## exactly where it was left, with no time-away simulation yet.
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

	outcome_label = Label.new()
	outcome_label.position = Vector2(_vp.x * 0.30, _vp.y * 0.025)
	outcome_label.add_theme_font_size_override("font_size", int(_vp.y * 0.03))
	outcome_label.hide()
	add_child(outcome_label)

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

## Called by GambitsPanel (dynamic has_method()+call(), same pattern as
## AetherPanel's _notify_currency_changed) when its popup opens/closes --
## see BattlePresenter.loop_paused's own comment for why this exists.
func _set_gambits_paused(paused: bool) -> void:
	if current_presenter != null:
		current_presenter.call("set_loop_paused", paused)

func _begin_next_fight() -> void:
	outcome_label.hide()
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
		# Back to its normal top-strip spot -- a PRIOR wipe (see below) can
		# have left it centered over the combat field instead.
		outcome_label.custom_minimum_size = Vector2.ZERO
		outcome_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		outcome_label.position = Vector2(_vp.x * 0.30, _vp.y * 0.025)
		outcome_label.text = "Wave %d cleared!" % g["wave"]
		FarroadProgression.start_wave(g, g["wave"] + 1)
	else:
		var wave_lost: int = g["wave"]
		FarroadProgression.on_wipe(g)
		# Just above the "Wave N" popup that's about to show (_show_wave_popup,
		# same combat-field vertical band) -- centered the same way the popup
		# centers itself, so "here's why you're back here" and "here's what's
		# next" read as one grouped announcement instead of two unrelated texts
		# in different corners of the screen.
		var combat_center_y: float = _vp.y * (0.11 + 0.58) / 2.0
		outcome_label.custom_minimum_size = Vector2(_vp.x * 0.9, 0)
		outcome_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		outcome_label.position = Vector2(_vp.x * 0.05, combat_center_y - _vp.y * 0.12)
		outcome_label.text = "Wiped at wave %d — back to wave %d" % [wave_lost, g["wave"]]
	outcome_label.show()
	_refresh_hud()
	_save_game()
	# The finished battlefield (units, HP bars, log/status buttons) stays on
	# screen behind the popup -- only freed once the NEXT fight is actually
	# being built, not the moment this one ends.
	await _show_wave_popup(g["wave"])
	if current_presenter != null:
		current_presenter.queue_free()
		current_presenter = null
	_begin_next_fight()

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

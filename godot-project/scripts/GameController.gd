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
## which uses the hardcoded Kesh default. Step 3c adds the GAMBITS tab
## (loadout editor + party bench/field, see GambitsPanel.gd). No AETHER/
## LORE/EQUIPMENT/MARKS/EXPEDITION/QUESTS tabs yet (Steps 3d-3j).

const SAVE_PATH := "user://save.json"

var g: Dictionary
var _vp: Vector2
var current_presenter: Node = null
var gambits_panel: Node

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
	_begin_next_fight()

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
		outcome_label.text = "Wave %d cleared!" % g["wave"]
		FarroadProgression.start_wave(g, g["wave"] + 1)
	else:
		var wave_lost: int = g["wave"]
		FarroadProgression.on_wipe(g)
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
	wave_popup.show()
	await get_tree().process_frame   # let the container size itself to the new text
	var combat_center := Vector2(_vp.x / 2.0, _vp.y * (0.11 + 0.58) / 2.0)
	wave_popup.position = combat_center - wave_popup.size / 2.0
	await get_tree().create_timer(1.0).timeout
	wave_popup.hide()

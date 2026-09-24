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
var units_panel: Node
var catalogue_panel: Node
var settings_panel: Node
var party_panel: Node
var aether_panel: Node
var lore_panel: Node
var equipment_panel: Node
var marks_panel: Node
var expedition_panel: Node
var expedition_timer: Timer
var quests_panel: Node
var shop_panel: Node
var mc_panel: Node
var road_button: Button
## Tracks whichever panel's own popup is currently open -- see
## _panel_opening()'s own comment for why this exists.
var open_panel: Node = null
## Every currently-open self-hosted detail overlay (_build_detail_overlay's
## own backdrop, built when _overlay_host() resolves to `self` -- i.e. no
## tab panel is open to nest inside). A quest/dungeon result popup can stay
## open indefinitely while the Road keeps running behind it, and a wave
## clear/wipe during that window tears down and rebuilds current_presenter
## (_begin_next_fight -- a brand-new sibling Control/Node2D, added AFTER
## this backdrop was originally raised to the top), silently drawing the
## new battle's units back over the still-open popup. Tracked here so
## _raise_self_hosted_overlays() can re-raise them every time a new
## presenter is added, instead of a one-time raise at build time.
var _self_hosted_overlays: Array = []
## The side battle currently running (a quest attempt or a dungeon
## crawl), or null when none is active -- GameController's own equivalent
## of the real JS's reassignable G.battle pointer (see
## FarroadProgression.start_side_battle's own comment for why a SECOND,
## independent BattlePresenter instance is enough here, unlike the real
## JS's shared-tick-loop architecture).
var side_presenter: Node = null

var currency_row: HBoxContainer
var aether_cell: Label
var marks_cell: Label
var crystal_cell: Label
var idle_row: HBoxContainer
var power_level_cell: Label
var idle_rate_label: Label
var speed_toggle_btn: Button
var _speed_2x: bool = false
var fade_overlay: ColorRect
var background_layer: Node2D
## Captured by _try_resume_save() (empty {} when no save existed, or the
## real 5s no-op floor wasn't met) -- consumed once by _start_game() to
## show the welcome-back popup (Group J, post-Milestone-3 batch).
var _offline_summary: Dictionary = {}

func _ready() -> void:
	# Ian: "can we add a 2x speed button?" Engine.time_scale is a global
	# engine property, NOT reset by a scene reload alone (e.g. Settings'
	# own "Reset Game" button) -- defensively reset here so every fresh
	# boot of this scene always starts at normal speed regardless of
	# whatever a previous session left it at.
	Engine.time_scale = 1.0
	_speed_2x = false
	# 24-item batch, Group F: touch-drag scrolling that works no matter what
	# the first touch lands on -- see TouchScroll.gd's own header comment.
	# Hooked on node_added (every ScrollContainer/OptionButton anywhere in
	# the game, including ones built later inside popups/overlays), plus one
	# pass over whatever already exists.
	get_tree().node_added.connect(_on_node_added)
	for n in get_tree().root.find_children("*", "", true, false):
		_on_node_added(n)
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

## Group F: a ScrollContainer gets a TouchScroll helper child (drag scrolls
## even when the press started on a button/card/text), and a dropdown opens
## on RELEASE instead of on press -- OptionButton defaults to press, which
## would open it the instant a scroll gesture's first touch landed on it.
func _on_node_added(n: Node) -> void:
	if n is ScrollContainer:
		# Deferred: node_added fires mid-add_child, when the container can
		# still refuse a child of its own.
		_attach_touch_scroll.call_deferred(n)
	elif n is OptionButton:
		(n as OptionButton).action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE

## INTERNAL_MODE_BACK keeps the helper out of get_children(), so nothing
## that walks a container's own children ever sees it.
func _attach_touch_scroll(sc: ScrollContainer) -> void:
	if not is_instance_valid(sc) or not sc.is_inside_tree():
		return
	for c in sc.get_children(true):
		if c is TouchScroll:
			return
	sc.add_child(TouchScroll.new(), false, Node.INTERNAL_MODE_BACK)

## Everything that used to run unconditionally right after
## _load_or_new_game() -- now shared by both boot paths (a resumed save,
## or a freshly confirmed character), run only once `g` is guaranteed
## fully built either way.
func _start_game() -> void:
	_build_background_layer()
	_build_hud()
	_refresh_hud()
	if not _offline_summary.is_empty():
		_show_welcome_back_popup()
	gambits_panel = load("res://scripts/GambitsPanel.gd").new()
	add_child(gambits_panel)
	gambits_panel.setup(g, _vp, self)
	units_panel = load("res://scripts/UnitsPanel.gd").new()
	add_child(units_panel)
	units_panel.setup(g, _vp, self)
	catalogue_panel = load("res://scripts/CataloguePanel.gd").new()
	add_child(catalogue_panel)
	catalogue_panel.setup(g, _vp, self)
	settings_panel = load("res://scripts/SettingsPanel.gd").new()
	add_child(settings_panel)
	settings_panel.setup(g, _vp, self)
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
	shop_panel = load("res://scripts/ShopPanel.gd").new()
	add_child(shop_panel)
	shop_panel.setup(g, _vp, self)
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
	# 24-item batch, Group D3: shifted down 5% from the old 0.015/0.043 --
	# see _build_hud's own comment for the full history.
	currency_row.position = Vector2(_vp.x * 0.02, _vp.y * 0.065)
	currency_row.add_theme_constant_override("separation", int(_vp.x * 0.03))
	aether_cell.add_theme_font_size_override("font_size", int(_vp.y * 0.0175))
	marks_cell.add_theme_font_size_override("font_size", int(_vp.y * 0.0175))
	crystal_cell.add_theme_font_size_override("font_size", int(_vp.y * 0.0175))
	idle_row.position = Vector2(_vp.x * 0.02, _vp.y * 0.093)
	idle_row.add_theme_constant_override("separation", int(_vp.x * 0.03))
	idle_rate_label.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	power_level_cell.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	speed_toggle_btn.position = Vector2(_vp.x * 0.86, _vp.y * 0.015)
	speed_toggle_btn.custom_minimum_size = Vector2(_vp.x * 0.12, _vp.y * 0.035)
	fade_overlay.size = _vp
	if background_layer != null:
		background_layer.position.x = 0.0
		_rebuild_background_marks()
	if current_presenter != null:
		current_presenter.reflow(_vp)
	gambits_panel.reflow(_vp)
	units_panel.reflow(_vp)
	catalogue_panel.reflow(_vp)
	settings_panel.reflow(_vp)
	party_panel.reflow(_vp)
	aether_panel.reflow(_vp)
	lore_panel.reflow(_vp)
	equipment_panel.reflow(_vp)
	marks_panel.reflow(_vp)
	expedition_panel.reflow(_vp)
	quests_panel.reflow(_vp)
	shop_panel.reflow(_vp)
	_reflow_road_button()

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

## Ian (batch): "I want to eventually replace the blank background with
## illustrations and locales along the road... what do we need to do now
## to prepare for that?" -- this IS that preparation: a dedicated Node2D
## layer, added first (drawn behind the battle field/HUD), spanning a
## band 3x screen width so a wave-transition scroll never reveals a bare
## edge. Placeholder content only (simple ground marks, no art yet) --
## real illustration/locale sprites drop in as children of this SAME node
## later with no other code changes needed. Also what
## _animate_wave_transition scrolls during the post-wave-clear "run".
func _build_background_layer() -> void:
	background_layer = Node2D.new()
	add_child(background_layer)
	move_child(background_layer, 0)
	_rebuild_background_marks()

## Ian: "do a procedural polish pass" -- a soft vertical gradient (a warm
## "sky" tone fading into the existing parchment tone) generated once and
## shared by every rebuild, standing in for real illustrated background
## art (same "still just a texture swap later" placeholder discipline
## UnitView's own procedural shapes follow).
const _SKY_GRADIENT_TEX_H := 64
static var _sky_gradient_texture: Texture2D

static func _get_sky_gradient_texture() -> Texture2D:
	if _sky_gradient_texture == null:
		var img := Image.create(1, _SKY_GRADIENT_TEX_H, false, Image.FORMAT_RGBA8)
		var top := Color(0.97, 0.92, 0.80, 1.0)
		var bottom: Color = Palette.BG_PARCHMENT_DEEP
		for y in range(_SKY_GRADIENT_TEX_H):
			img.set_pixel(0, y, top.lerp(bottom, float(y) / float(_SKY_GRADIENT_TEX_H - 1)))
		_sky_gradient_texture = ImageTexture.create_from_image(img)
	return _sky_gradient_texture

## Ian: "do a procedural polish pass." Was a single flat-colored row of
## identical rects -- now a soft sky gradient behind everything, a "road"
## band along the bottom, and per-mark size/tone/spacing jitter (a FIXED
## seed, not real randomness, so a rebuild -- e.g. on resize -- reproduces
## the exact same layout rather than reshuffling every time) so the row
## reads as varied ground clutter instead of one shape stamped on repeat.
func _rebuild_background_marks() -> void:
	for c in background_layer.get_children():
		c.queue_free()
	var band_bottom: float = _vp.y * 0.58
	var span: float = _vp.x * 3.0

	var sky := Sprite2D.new()
	sky.texture = _get_sky_gradient_texture()
	sky.centered = false
	sky.position = Vector2(-span / 2.0, 0.0)
	sky.scale = Vector2(span, band_bottom) / Vector2(1.0, float(_SKY_GRADIENT_TEX_H))
	background_layer.add_child(sky)

	var road_h: float = _vp.y * 0.02
	var road := ColorRect.new()
	road.color = Palette.BORDER_LEATHER.lerp(Palette.BG_PARCHMENT_DEEP, 0.55)
	road.size = Vector2(span, road_h)
	road.position = Vector2(-span / 2.0, band_bottom - road_h)
	background_layer.add_child(road)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260101   # fixed -- see comment above for why
	var mark_w: float = _vp.x * 0.03
	var mark_h: float = _vp.y * 0.012
	var gap: float = _vp.x * 0.09
	var x: float = -span / 2.0
	while x < span / 2.0:
		var j: float = rng.randf_range(-0.5, 0.5)
		var mark := ColorRect.new()
		mark.color = Palette.BG_PARCHMENT_DEEP.lerp(Palette.BORDER_LEATHER, 0.15 + 0.15 * absf(j))
		mark.size = Vector2(mark_w * (0.75 + 0.5 * (j + 0.5)), mark_h)
		mark.position = Vector2(x, band_bottom - road_h - mark_h * (1.0 + 0.5 * j))
		background_layer.add_child(mark)
		x += gap * (0.8 + 0.4 * (j + 0.5))

## A minimal top strip (currency purse) above the existing battle view --
## not a full tab bar yet, since there's only one screen to navigate to
## until Step 3c. Between waves, the field itself now carries the wave
## transition (party runs right, next wave's enemies run in -- see
## _animate_wave_transition/BattlePresenter.run_enemies_entering),
## no popup needed.
##
## Ian: "remove the Wave x from the top... move the total Aether and mark
## text up to where the Wave x text was." wave_label is gone entirely --
## BattlePresenter's own wave-progress row (just above its enrage bar)
## now carries the current-wave text instead. currency_row moved up to
## the old wave_label position (0.015, was 0.055); idle_row shifted up by
## the same 0.04 that freed (0.083 -> 0.043) -- both then shifted back
## DOWN by 0.05 per the 24-item batch's Group D3 ("move top aether and
## marks down 5% to avoid running into the camera"), landing at 0.065/0.093.
func _build_hud() -> void:
	# Ian: "I want to replace some of the text like Aether and Marks with
	# icons -- what do we need to do now to prepare for that?" Split what
	# used to be one combined "Aether N   Marks N" Label into two separate
	# cells in a row -- an icon can be inserted in front of just ONE
	# currency's text later by changing only _build_currency_label (or
	# just one cell's own build site) instead of hunting down a combined
	# string. Each cell also gets its own real screen position, so a
	# reward flyer can fly to the EXACT currency it's for (see
	# _spawn_reward_drops) instead of a single shared combined-label spot.
	currency_row = HBoxContainer.new()
	currency_row.position = Vector2(_vp.x * 0.02, _vp.y * 0.065)
	currency_row.add_theme_constant_override("separation", int(_vp.x * 0.03))
	add_child(currency_row)
	aether_cell = _build_currency_label(currency_row)
	marks_cell = _build_currency_label(currency_row)
	# 24-item batch, Group C4: "Crystal needs listed at the top" -- third
	# cell in the same row as Aether/Marks.
	crystal_cell = _build_currency_label(currency_row)

	# 24-item batch, Group C4: "move total power down a row, next to idle
	# income" -- Power moves OUT of currency_row (where it used to sit as
	# a third cell alongside Aether/Marks, before Crystal took that slot)
	# into its own row alongside the idle-rate line below.
	idle_row = HBoxContainer.new()
	idle_row.position = Vector2(_vp.x * 0.02, _vp.y * 0.093)
	idle_row.add_theme_constant_override("separation", int(_vp.x * 0.03))
	add_child(idle_row)
	# Idle reward rate (Group I, post-Milestone-3 batch) -- shows the
	# ambient trickle rate feeding Aether/Marks (idle_per_sec already runs
	# regardless of whether the player is actively fighting -- see
	# simulate_offline_progress's own comment).
	idle_rate_label = Label.new()
	idle_rate_label.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	idle_rate_label.modulate = Color(0.65, 0.65, 0.65)
	idle_row.add_child(idle_rate_label)
	power_level_cell = Label.new()
	power_level_cell.add_theme_font_size_override("font_size", int(_vp.y * 0.018))
	power_level_cell.modulate = Color(0.65, 0.65, 0.65)
	idle_row.add_child(power_level_cell)

	# Ian: "can we add a 2x speed button?" Top-right corner, mirroring
	# currency_row's own top-left placement. Toggles Engine.time_scale
	# globally -- the simplest way to uniformly speed up every tween/timer
	# already scattered across this codebase (hops, projectiles, beat
	# pauses, wave-transition waits, UI fades) without touching any of
	# their individual duration constants.
	speed_toggle_btn = Button.new()
	speed_toggle_btn.position = Vector2(_vp.x * 0.86, _vp.y * 0.015)
	speed_toggle_btn.custom_minimum_size = Vector2(_vp.x * 0.12, _vp.y * 0.035)
	speed_toggle_btn.pressed.connect(_on_speed_toggle_pressed)
	add_child(speed_toggle_btn)
	_refresh_speed_toggle()

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

	_build_road_button()

func _on_speed_toggle_pressed() -> void:
	_speed_2x = not _speed_2x
	Engine.time_scale = 2.0 if _speed_2x else 1.0
	_refresh_speed_toggle()

func _refresh_speed_toggle() -> void:
	speed_toggle_btn.text = "2x ⏩" if _speed_2x else "1x ⏩"
	speed_toggle_btn.modulate = Palette.GOLD_LIGHT if _speed_2x else Color(1, 1, 1)

func _build_currency_label(parent: Container) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.0175))
	parent.add_child(lbl)
	return lbl

## Called by SettingsPanel (dynamic has_method()+call()) after the player
## confirms the "Reset Game" prompt -- deletes the save file (first use of
## file-deletion anywhere in this codebase, a standard, low-risk Godot API)
## and reloads the scene, cleanly re-entering _ready()'s own existing boot
## gate (no save found -> character creation) rather than hand-rolling a
## manual in-place teardown/rebuild of every panel and timer.
func _reset_game() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)
	get_tree().reload_current_scene()

## Post-Milestone-3 APK feedback (Group B4) -- center of the bottom icon
## row (same 0.11*vp.x icon size/0.93*vp.y row every tab panel's own icon
## uses), styled distinctly (a gold fill, not the flat grey every tab icon
## uses) so it reads as a different KIND of control, not just another tab.
## Recomputed by the 24-item batch's own Group C6 (Shop added, now an
## 8-icon row) -- moved next to Expedition to stay close to true center
## (0.5067 vs the ideal 0.5) -- see MarksPanel.gd's own comment for the
## full 8-slot layout.
func _build_road_button() -> void:
	var icon_size: float = _vp.x * 0.11
	road_button = Button.new()
	road_button.text = "Road"
	road_button.position = Vector2(_vp.x * 0.5067, _vp.y * 0.93)
	road_button.custom_minimum_size = Vector2(icon_size, icon_size)
	road_button.clip_text = true
	road_button.add_theme_font_size_override("font_size", maxi(9, int(icon_size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Palette.GOLD
	normal_style.set_corner_radius_all(int(icon_size / 2.0))
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Palette.GOLD_LIGHT
	hover_style.set_corner_radius_all(int(icon_size / 2.0))
	road_button.add_theme_stylebox_override("normal", normal_style)
	road_button.add_theme_stylebox_override("hover", hover_style)
	road_button.add_theme_stylebox_override("pressed", hover_style)
	road_button.pressed.connect(_on_road_pressed)
	add_child(road_button)

func _reflow_road_button() -> void:
	var icon_size: float = _vp.x * 0.11
	road_button.position = Vector2(_vp.x * 0.5067, _vp.y * 0.93)
	road_button.custom_minimum_size = Vector2(icon_size, icon_size)

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

	# Post-24-item-batch (Group A2): migrated off a raw PopupPanel onto
	# _build_detail_overlay -- fixes the same width-overflow class of bug
	# this popup used to have its own bespoke fix for (that fix is now
	# subsumed: _build_detail_overlay's scroll container has an explicit,
	# content-independent minimum size, so nothing here needs its own
	# margin arithmetic anymore) and, per Ian's own "reduce the height of
	# informational pop-ups by 50% and center them" ask, replaces the old
	# fixed _vp.y*0.65 height with content-driven sizing (capped at
	# _vp.y*0.6, usually far less) -- already correctly centered by
	# _finish_detail_overlay. This popup isn't triggered from inside an
	# already-open tab popup (fires once at boot/resume), so it never had
	# Group A1's sibling-Window bug, but gets the same overlay treatment
	# for consistency and the height/centering win.
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Welcome back!"
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = "Away %s.\n%s%s" % [away_txt, progress_txt, wipe_txt]
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	var gained := Label.new()
	gained.text = "+%d Aether, +%d Marks from wave clears" % [roundi(s["aether_gained"]), int(floor(s["marks_gained"]))]
	gained.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	gained.modulate = Palette.GOLD_PRESSED
	gained.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(gained)

	# Ian: "don't add rewards from... idle until collected. Add a collect
	# button." Idle's own flat trickle is banked into pendingIdleAether/
	# pendingIdleMarks (simulate_offline_progress), distinct from the
	# wave-clear gains above (which stay auto-applied, never gated).
	var idle_aether: float = s.get("idle_aether_pending", 0.0)
	var idle_marks: float = s.get("idle_marks_pending", 0.0)
	if idle_aether > 0.0 or idle_marks > 0.0:
		var idle_lbl := Label.new()
		idle_lbl.text = "+%d Aether, +%d Marks of idle income, pending" % [roundi(idle_aether), floori(idle_marks)]
		idle_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
		idle_lbl.modulate = Palette.PARTY_BLUE
		idle_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(idle_lbl)

		var collect_btn := Button.new()
		collect_btn.text = "Collect idle income"
		collect_btn.pressed.connect(func():
			FarroadProgression.collect_idle_reward(g)
			_refresh_hud()
			idle_lbl.text = "Collected."
			collect_btn.disabled = true)
		vbox.add_child(collect_btn)

	await _finish_detail_overlay(o)

## Ian: a one-time popup shown exactly when enrage first turns on (clearing
## the wave-20 boss -- see the "tutorial_complete" event, FarroadProgression.
## after_wave_cleared) -- congratulates the player on finishing the
## tutorial, warns the Road only gets harder from here, and explains the
## enrage mechanic + points at its own bar/label so it isn't a total
## surprise the first time it fires for real. Same raw-PopupPanel
## construction as _show_welcome_back_popup (a big milestone announcement,
## not a small in-flow result like _show_quest_result_popup below) --
## AWAITABLE, unlike that one, since the caller (_on_battle_finished) needs
## to hold the wave-transition animation until the player has actually read
## and dismissed it.
func _show_tutorial_complete_popup() -> void:
	# Post-24-item-batch (Group A1/A2): migrated off a raw PopupPanel onto
	# _build_detail_overlay/_finish_detail_overlay -- this used to
	# add_child() a SECOND top-level Window while a tab popup could
	# already be open (see the big comment on _build_detail_overlay's own
	# declaration for the full root-cause writeup), silently closing it
	# the instant this popup appeared. Nesting inside whichever popup is
	# already open (or GameController itself when none is) fixes that,
	# and its content-driven sizing also satisfies "reduce the height of
	# informational pop-ups by 50% and center them" for free. Still
	# genuinely blocks the caller until dismissed (backdrop.tree_exiting
	# fires from either the Close button or a backdrop tap) -- the win
	# branch that calls this needs to hold the wave-transition animation
	# until the player has actually read and dismissed it.
	var o := _build_detail_overlay(Palette.GOLD_PRESSED)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Tutorial complete!"
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = "You've beaten the Roadwarden. From here, the Road only gets harder."
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	# Post-24-item-batch balance pass: enrage now starts at wave 31, so this
	# popup only foreshadows it -- the full explanation is its own popup
	# (_show_enrage_intro_popup) right before the first fight it applies to.
	var heads_up := Label.new()
	heads_up.text = "Use the next stretch of the Road to level up and build your party -- something more dangerous is waiting past wave 30."
	heads_up.add_theme_font_size_override("font_size", int(_vp.y * 0.022))
	heads_up.modulate = Palette.TEXT_DIM
	heads_up.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(heads_up)

	await _finish_detail_overlay(o)
	await o["backdrop"].tree_exiting

## Post-24-item-batch balance pass: the enrage explanation that used to be
## part of the tutorial-complete popup, now shown on its own on the first
## clear of wave ENRAGE_FROM_WAVE-1 -- right before the first fight that can
## actually enrage (the "enrage_intro" event, FarroadProgression.
## after_wave_cleared). Same awaited overlay shape as the popup above.
func _show_enrage_intro_popup() -> void:
	var o := _build_detail_overlay(Palette.BAD_RED)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Enemies can now become ENRAGED"
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.035))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var enrage_body := Label.new()
	enrage_body.text = "Enemies that fight for a long time will grow ENRAGED -- hitting harder and moving faster the longer a battle drags on. Keep your fights short."
	enrage_body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	enrage_body.modulate = Palette.BAD_RED
	enrage_body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(enrage_body)

	var enrage_pointer := Label.new()
	enrage_pointer.text = "Watch the red bar above the turn order -- once it fills, its label shows exactly how much stronger enemies have gotten."
	enrage_pointer.add_theme_font_size_override("font_size", int(_vp.y * 0.022))
	enrage_pointer.modulate = Palette.TEXT_DIM
	enrage_pointer.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(enrage_pointer)

	await _finish_detail_overlay(o)
	await o["backdrop"].tree_exiting

## Ian: "add a pop-up when she joins... you save her from the enemies and
## she chooses to join you" -- fires whenever a milestone companion
## actually joins (the "boss_companion" event, see after_wave_cleared's own
## comment -- despite the name, no longer boss-exclusive). Same raw-
## PopupPanel/awaited-"Got it" shape as _show_tutorial_complete_popup
## above; generic enough in its wording to read naturally for any of the
## 4 roster companions this can fire for (ansa/dorrek/vey/mirel), not just
## Ansa's own wave-10 case.
func _show_companion_joined_popup(uid: String) -> void:
	var def = FarroadCore.roster_by_id(uid)
	var name: String = def["name"] if def != null else uid

	# Post-24-item-batch (Group A1/A2): same overlay migration as
	# _show_tutorial_complete_popup above -- see its comment.
	var o := _build_detail_overlay(Palette.GOOD_GREEN)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "%s joins you!" % name
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = "You cut down the last of the danger just in time -- %s was caught in the middle of it. Grateful, and impressed, they choose to join you on the Road." % name
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	await _finish_detail_overlay(o)
	await o["backdrop"].tree_exiting

## Ian: "after wave 20, instead of a new unit, get a piece of equipment
## and show a pop-up about equipment and where it can be equipped" --
## fires on the "tutorial_equip" event (after_wave_cleared, wave 20
## specifically). A simple, standalone item description (name/rarity/
## slot/flat stat bonuses) rather than EquipmentPanel's own
## _describe_equipment -- that one needs a specific unit to compute
## per-unit affinity deltas against, which this generic introductory
## popup has no natural "selected unit" for.
func _show_tutorial_equip_popup(item_id: String) -> void:
	var item: Dictionary = FarroadCore.EQUIPMENT.get(item_id, {})
	var item_name: String = item.get("name", item_id)
	var rarity: String = item.get("rarity", "common")
	var slot: String = String(item.get("slot", "")).capitalize()
	var bits: Array = []
	for k in ["atk", "mag", "def", "res", "spd"]:
		if item.get(k):
			bits.append("%s +%d" % [k.to_upper(), int(item[k])])
	if item.get("evade"):
		bits.append("Evade +%d%%" % roundi(float(item["evade"]) * 100.0))
	var stat_line: String = " · ".join(bits) if not bits.is_empty() else "no flat stat bonus (affinity only)"

	# Post-24-item-batch (Group A1/A2): same overlay migration as
	# _show_tutorial_complete_popup above -- see its comment.
	var o := _build_detail_overlay(Palette.GOLD_PRESSED)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "New gear: %s!" % item_name
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	# Duplicated small lookup, matching EquipmentPanel.gd's own RARITY_COLOR
	# -- no class_name on that script to reference directly, same small-
	# duplication convention this project already uses for shared-but-not-
	# globally-registered constants.
	var rarity_color: Dictionary = {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
	var rarity_lbl := Label.new()
	rarity_lbl.text = "%s %s -- %s" % [rarity.capitalize(), slot, stat_line]
	rarity_lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.022))
	rarity_lbl.modulate = rarity_color.get(rarity, Palette.TEXT_DIM)
	rarity_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(rarity_lbl)

	var body := Label.new()
	body.text = "Equipment gives a unit permanent stat bonuses for as long as it's worn -- head, body, legs, and two hand slots, each unit gearing up independently. Open the Equipment tab to equip this on whoever needs it most."
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	await _finish_detail_overlay(o)
	await o["backdrop"].tree_exiting

## Ian: "add tutorial pop-ups the first time each page/tab is opened to
## provide information and context for players." One shared, reusable
## popup + a single content lookup table, rather than a bespoke builder
## duplicated into all 7 panels -- each panel's own _on_toggle_pressed
## just calls `await _parent.call("_maybe_show_tab_tutorial", "<id>")`
## once it's actually open (same dynamic-dispatch convention this project
## already uses for _panel_opening/_set_battle_paused), and this file
## owns both the "have we shown this before" state (persisted via
## g["seenTabTutorial"], Godot-only -- see new_game()'s own comment) and
## the actual content. Scoped to the 7 icon-row tabs (Units/Party/Marks/
## Expedition/Quests/Catalogue/Settings) -- Road isn't a content tab (it
## just closes whatever's open), and the 4 panels folded under Units
## (Gambits/Aether/Lore/Equipment) render their content INTO Units' own
## popup via build_into() rather than owning a popup/toggle of their own,
## so "the Units tab" is the natural single unit here; those 4 could get
## their own first-open tutorials as a follow-up if wanted.
const TAB_TUTORIALS: Dictionary = {
	"units": {"title": "Units", "body": "Pick any owned unit here to manage them: set their Gambits (the AI rules deciding what they do in a fight), spend Aether to level them up, buy Lore upgrades for their actions, and equip gear -- all from one screen, one unit at a time."},
	"party": {"title": "Party", "body": "Choose who's actually fighting. Field or bench units (up to 5 fielded at once), and set each unit's row -- front row deals and takes more physical damage, back row is safer but hits softer."},
	"marks": {"title": "Marks", "body": "Spend Marks here to pull for a random unit, action, gambit condition, or piece of equipment. A duplicate pull still pays off: units convert to Aether, actions and conditions convert to Lore, equipment just stacks. Pulls unlock once you're far enough down the Road."},
	"expedition": {"title": "Expedition", "body": "Send benched units out on an expedition down one of 8 directions. They fight on their own and keep progressing even while you're away -- recall them anytime, or leave them to push further out for a bigger haul."},
	"quests": {"title": "Quests", "body": "Two things live here: each companion's own 5-stage quest line, and direction dungeons that unlock as your expeditions explore further. Both are fought live, right on this screen, same as any Road battle."},
	"catalogue": {"title": "Catalogue", "body": "A running record of everything you've found -- units, actions, gambit conditions, equipment, and enemies. Anything you haven't encountered yet shows up as a mystery entry until you do."},
	"settings": {"title": "Settings", "body": "Game-wide settings live here, including a full Reset Game option if you ever want to start completely fresh."},
	"shop": {"title": "Shop", "body": "Spend Crystal (earned from dungeons and companion quests) on a specific gambit condition, action, unit, or piece of equipment of your choosing -- a guaranteed pick, priced by rarity, instead of Marks' random pulls."}
}

func _maybe_show_tab_tutorial(tab_id: String) -> void:
	if g["seenTabTutorial"].get(tab_id, false):
		return
	g["seenTabTutorial"][tab_id] = true
	_save_game()
	var info: Dictionary = TAB_TUTORIALS.get(tab_id, {})
	if info.is_empty():
		return
	await _show_tab_tutorial_popup(info["title"], info["body"])

func _show_tab_tutorial_popup(title_text: String, body_text: String) -> void:
	# Post-24-item-batch (Group A1/A2): same overlay migration as
	# _show_tutorial_complete_popup above -- this one's the exact bug Ian
	# actually reported ("clicking 'Got it' on the tutorial pop-ups closes
	# the menu behind it"), since this is the one that fires WHILE a tab
	# popup (e.g. Settings') is already open -- see _build_detail_overlay's
	# own comment for the full root-cause writeup.
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.035))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = body_text
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.024))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	await _finish_detail_overlay(o)
	await o["backdrop"].tree_exiting

## Post-Milestone-3 APK feedback (Group A3): "there should be a pop-up
## after completing or failing a quest that does the rewards you got,
## similar to the welcome back pop-up" -- same PopupPanel/StyleBoxFlat
## construction and post-add-one-frame-before-popup_centered fix as
## _show_welcome_back_popup above, just keyed off a
## FarroadProgression.finish_side_battle event instead of an offline
## summary. QuestsPanel's own "_show_result" card (still called right
## after this from _resolve_side_battle) is UNCHANGED -- this popup is in
## addition to it, not a replacement.
func _show_quest_result_popup(event: Dictionary) -> void:
	var kind: String = event["kind"]
	var title_text: String
	var border_color: Color
	match kind:
		"quest_cleared":
			title_text = "Quest complete!" if event["questComplete"] else "Quest cleared!"
			border_color = Palette.GOOD_GREEN
		"quest_failed":
			title_text = "Quest failed"
			border_color = Palette.BAD_RED
		"quest_abandoned":
			title_text = "Quest abandoned"
			border_color = Color(0.55, 0.46, 0.16, 1.0)
		"dungeon_cleared":
			title_text = "Dungeon cleared!"
			border_color = Palette.GOOD_GREEN
		"dungeon_failed":
			title_text = "Dungeon failed"
			border_color = Palette.BAD_RED
		_:
			return

	var body_text: String
	match kind:
		"quest_cleared":
			body_text = "%s -- stage %d of 5 cleared." % [event["name"], int(event["stageNum"])]
		"quest_failed":
			body_text = "%s -- stage %d of 5 was not cleared." % [event["name"], int(event["stageNum"])]
		"quest_abandoned":
			body_text = "%s -- stage %d attempt abandoned." % [event["name"], int(event["stageNum"])]
		_:
			body_text = "%s" % event["name"]

	# Post-Milestone-3 APK feedback (round 6): a real, reported bug -- this
	# popup used to build its own unbounded backdrop+box+vbox directly
	# (predating _build_detail_overlay, from when it still needed the
	# "nest inside whatever's already open" fix on its own). An
	# auto-sizing vbox with no explicit size budget, combined with a large
	# (_vp.y*0.04) title font, could apparently take more than the one
	# awaited frame to fully converge on its real layout size -- box.size
	# was then read for centering BEFORE it reflected the title's true
	# rendered height, positioning the box as if it were smaller than it
	# actually rendered, so content visibly overflowed past the box's own
	# drawn border (reported live: "Quest cleared!" text spilling out
	# above the green-bordered box, "+100 Aether" spilling out below it).
	# _build_detail_overlay's own scroll container has an EXPLICIT,
	# content-independent minimum size instead -- deterministic from the
	# moment it's created, not something that can lag behind children
	# still settling -- exactly the fix every OTHER detail overlay
	# (action/equipment/enemy) already gets for free. Reusing it here
	# closes that gap and keeps the "nest inside whatever's open, or
	# fall back to full-screen" behavior unchanged (still via
	# _overlay_host() internally).
	var o := _build_detail_overlay(border_color)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", int(_vp.y * 0.04))
	vbox.add_child(title)

	var body := Label.new()
	body.text = body_text
	body.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	# Quests and dungeons pay Crystal only now (no Aether/Marks).
	var crystal_gained: int = int(event.get("crystal", 0))
	if crystal_gained > 0:
		var gained := Label.new()
		gained.text = "+%d Crystal" % crystal_gained
		gained.add_theme_font_size_override("font_size", int(_vp.y * 0.025))
		gained.modulate = Palette.GOLD_PRESSED
		vbox.add_child(gained)

	await _finish_detail_overlay(o)

func _refresh_hud() -> void:
	aether_cell.text = "Aether %d" % roundi(g["aether"])
	marks_cell.text = "Marks %d" % roundi(g["marks"])
	crystal_cell.text = "Crystal %d" % int(g.get("crystal", 0))
	power_level_cell.text = "Power %d" % FarroadProgression.power_level(g)
	var r := FarroadProgression.idle_per_sec(g.get("farthest", 1))
	var marks_rate: float = r["marks"] * FarroadProgression.marks_mul(g)
	# Ian: "idle rewards: show per 5 minutes, not per hour" -- matches the
	# real JS reference's own already-established convention exactly
	# (farroad-ui.js's renderIdleRate: x300/.toFixed(2), chosen there
	# specifically because a per-hour/per-minute figure rounds to a
	# misleading "0" at real depth long before the trickle actually stops).
	idle_rate_label.text = "%.2f Aether/5min   %.2f Marks/5min" % [r["aether"] * 300.0, marks_rate * 300.0]

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

## Group H (20-item batch): Catalogue folded out of the bottom icon row --
## reached via a "Catalogue" button inside SettingsPanel's own popup
## instead (dynamic dispatch, matching every other cross-panel trigger in
## this project, e.g. _reset_game()). Just re-triggers Catalogue's own
## existing open logic (_panel_opening + refresh + popup + battle-pause),
## which already correctly closes Settings' own popup via _panel_opening.
func _open_catalogue() -> void:
	catalogue_panel.call("_on_toggle_pressed")

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}

## Post-Milestone-3 APK feedback: "closing the details of an action closes
## all popups." Root cause: _show_action_detail_popup used to add_child() a
## brand new top-level PopupPanel directly onto GameController -- a SIBLING
## Window to whatever tab popup was already open (e.g. UnitsPanel's).
## Godot's embedded-window system only tracks ONE exclusive top-level popup
## layer at a time, so opening that second, independent Window silently
## closed the first the instant it appeared; closing the info popup then
## left nothing visibly open, reading as "closing it closed everything."
## A Control (not Window) added as a CHILD of the popup that's already
## open does not have this problem -- it just nests inside that SAME
## window, the same way the existing ScrollContainer/VBoxContainer content
## already does. _overlay_host() below resolves where to nest into.
## Re-raises every still-open self-hosted overlay (see _self_hosted_overlays'
## own comment) to the end of the child list -- called right after any new
## BattlePresenter/side-battle presenter is added as a sibling, so a
## still-open quest/dungeon result popup keeps drawing on top of it instead
## of falling behind. Order among multiple stacked overlays is preserved
## (each moved to the end in turn).
func _raise_self_hosted_overlays() -> void:
	for ov in _self_hosted_overlays:
		if is_instance_valid(ov):
			move_child(ov, get_child_count() - 1)

func _overlay_host() -> Array:
	if open_panel != null and is_instance_valid(open_panel) and open_panel.popup.visible:
		return [open_panel.popup, Vector2(open_panel.popup.size)]
	return [self, _vp]

## Shared construction for every "on top of the current view" detail
## overlay (action/equipment/enemy) -- builds the dim backdrop + bordered,
## internally-scrollable box, nested inside whichever popup is currently
## open (see _overlay_host's own comment for why this, not a second
## top-level Window). Returns a Dictionary the caller appends its own
## content into (o["vbox"]) and later finishes via _finish_detail_overlay
## (adds the Close button, centers the box once its real size is known).
## Tapping the dim backdrop also dismisses it, same as an explicit Close.
func _build_detail_overlay(border_color: Color = Palette.BORDER_LEATHER) -> Dictionary:
	var hs := _overlay_host()
	var host: Node = hs[0]
	var host_size: Vector2 = hs[1]

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.55)
	backdrop.size = host_size
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(backdrop)
	# Same z-order trick fade_overlay already uses -- draws on top of
	# whatever content this window already had, since later-added
	# siblings draw last. Also correctly layers a SECOND overlay (e.g. an
	# enemy's own action info, opened from inside its own detail overlay)
	# on top of the first, since both nest as siblings under the same host
	# rather than inside one another.
	host.move_child(backdrop, host.get_child_count() - 1)
	# A self-hosted overlay (host==self -- no tab panel open to nest inside,
	# the quest/dungeon-result popup's own case) can outlive the moment it
	# was raised -- see _self_hosted_overlays' own comment.
	if host == self:
		_self_hosted_overlays.append(backdrop)
		backdrop.tree_exiting.connect(func(): _self_hosted_overlays.erase(backdrop))

	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = border_color
	style.set_border_width_all(2)
	style.set_content_margin_all(int(_vp.y * 0.025))
	box.add_theme_stylebox_override("panel", style)
	backdrop.add_child(box)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(host_size.x * 0.8, minf(host_size.y * 0.75, _vp.y * 0.6))
	box.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(host_size.x * 0.76, 0)
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# Tapping the dim area outside the box also dismisses it -- standard
	# modal-overlay convention. box itself stops the click from reaching
	# backdrop's own handler when the tap actually landed inside it.
	# Ian: "scrolling all the way down on a pop-up box closes it" -- root
	# cause: a mouse-wheel scroll is ALSO delivered as an InputEventMouseButton
	# with pressed==true (wheel-up/down are just button indices), so once
	# the inner ScrollContainer reached the bottom of its range and stopped
	# consuming further wheel events, the same "click" check here matched
	# the wheel event too and dismissed the popup. Restricted to real
	# mouse buttons (left/right/middle) so a wheel scroll can never match.
	const _DISMISS_BUTTONS := [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]
	backdrop.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index in _DISMISS_BUTTONS:
			backdrop.queue_free())
	box.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index in _DISMISS_BUTTONS:
			get_viewport().set_input_as_handled())

	return {"vbox": vbox, "backdrop": backdrop, "box": box, "host_size": host_size}

func _finish_detail_overlay(o: Dictionary) -> void:
	var backdrop: ColorRect = o["backdrop"]
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): backdrop.queue_free())
	o["vbox"].add_child(close_btn)
	await get_tree().process_frame
	var box: PanelContainer = o["box"]
	# Ian: "in general, pop-ups aren't centered." Root cause, confirmed by
	# direct measurement: when `host` is a STYLED PopupPanel (any tab
	# popup already open -- the common case, since every info icon lives
	# INSIDE one), Godot automatically insets a plain child Control added
	# directly to it by the panel's own StyleBoxFlat content margin
	# (_style_popup's 10px) -- so `backdrop`'s REAL rendered size ends up
	# smaller than the `host_size` it was originally told to be (measured
	# directly: 375x794 actual vs. 395x814 intended, exactly a 2×10px
	# shrink). Centering `box` against the ORIGINAL, now-wrong `host_size`
	# put it off by that same 10px on both axes -- reading as "not
	# centered" since it's consistently offset toward the bottom-right.
	# Using `backdrop`'s own ACTUAL post-layout size instead is correct
	# either way: identical to host_size when host has no such inset
	# (GameController itself, confirmed unaffected by direct measurement
	# too), and self-correcting when it does.
	box.position = (backdrop.size - box.size) / 2.0

## Post-Milestone-3 APK feedback (round 5): "I want to have the filters be
## in the actual drop downs when selecting the actions, not above them...
## I just want a header at the top of the list you scroll through to pare
## it down some." A native OptionButton can't embed a custom filter
## control inside its own popup, so wherever a filter narrows a list of
## selectable actions/conditions, that OptionButton is replaced with a
## plain trigger Button that opens THIS overlay instead -- same backdrop+
## box+scroll construction _build_detail_overlay already uses (so it
## nests correctly inside whichever popup is open, not a second top-level
## Window), with a scrollable `list_container` whose own FIRST children
## are the filter row, followed by the actual selectable rows -- one
## single list you scroll through together, exactly as asked, not a fixed
## toolbar above a separately-scrolling area.
##
## `populate(list_container, backdrop)` is called once up front and is
## expected to clear+rebuild `list_container` itself (filter row first,
## then rows) -- the CALLER owns its own filter state and re-invokes its
## own `populate` closure recursively from each filter dropdown's
## on_change handler to refresh the list in place without closing the
## overlay; each selectable row's own press handler calls
## `backdrop.queue_free()` after applying the pick, closing the overlay
## the same way _finish_detail_overlay's own Close button does.
func _show_picker_overlay(title: String, populate: Callable) -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title_lbl)

	var list_container := VBoxContainer.new()
	list_container.add_theme_constant_override("separation", 6)
	vbox.add_child(list_container)
	populate.call(list_container, o["backdrop"])

	await _finish_detail_overlay(o)

## Ian: "give each expedition you send out its own button to pop up a log
## showing battle, events, and dungeons they encounter." exp["log"]
## (push_expedition_log, newest-first, 40-entry cap) already records every
## one of those -- sent/heading-home/arrived, bonus-fight wins/losses
## ("battle"), and now dungeon-unlock notices too (FarroadProgression.gd's
## resolve_expedition) -- ExpeditionPanel's own card only ever showed the
## single most recent entry inline; this shows the FULL history. Central,
## GameController-owned overlay, same precedent every other detail popup
## here already set, rather than a second top-level Window nested inside
## ExpeditionPanel's own already-open popup (which Godot would silently
## close -- see _overlay_host's own comment).
func _show_expedition_log_popup(exp: Dictionary) -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var names := ""
	for uid in exp["partyIds"]:
		var def = FarroadCore.roster_by_id(uid)
		names += ("" if names == "" else ", ") + (def["name"] if def else uid)
	var title_lbl := Label.new()
	title_lbl.text = "%s — %s" % [names, FarroadProgression.direction_label(exp["direction"])]
	title_lbl.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title_lbl)

	var log: Array = exp.get("log", [])
	if log.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "Nothing logged yet."
		none_lbl.modulate = Palette.TEXT_DIM
		vbox.add_child(none_lbl)
	for entry in log:
		var dt := Time.get_datetime_dict_from_unix_time(int(entry.get("at", 0)))
		var clock: String = "%02d:%02d" % [int(dt["hour"]), int(dt["minute"])]
		var entry_lbl := Label.new()
		entry_lbl.text = "[%s] %s" % [clock, String(entry.get("text", ""))]
		entry_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		entry_lbl.modulate = Palette.TEXT_DIM
		vbox.add_child(entry_lbl)

	await _finish_detail_overlay(o)

## A small "detailed stats" overlay for any action id -- shared by
## GambitsPanel's slot-editor info icon, LorePanel's unequipped-action
## dropdown, and CataloguePanel's Actions tab (a central, GameController-
## owned builder, same precedent _show_quest_result_popup/
## _show_welcome_back_popup already set, rather than duplicating this
## construction into every panel that needs it).
func _show_action_detail_popup(action_id: String) -> void:
	var act = FarroadCore.ACTIONS.get(action_id)
	if act == null:
		return
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var color: Color = RARITY_COLOR.get(act.get("rarity", "common"), Color(1, 1, 1))
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b][color=#%s]%s[/color][/b]" % [color.to_html(false), act["name"]]
	vbox.add_child(title)

	var camp_txt: String = "Magic" if act.get("camp") == "mag" else "Physical"
	var target_txt: String = str(act.get("tk", "foe"))
	# Ian: "actions say rank x0.87, not the stat(s) they scale with and the
	# multiplier." Same "scales with X · power ×N" phrasing LorePanel's own
	# action-detail card already uses, so both surfaces read consistently.
	var scale_txt: String = "MAG" if act.get("camp") == "mag" else "ATK"
	var power_lbl := Label.new()
	power_lbl.text = "%s -- target: %s -- scales with %s" % [camp_txt, target_txt, scale_txt]
	if act.get("power"):
		power_lbl.text += "  ·  power ×%.2f" % float(act["power"])
	power_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	power_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(power_lbl)

	var cost_lbl := Label.new()
	if act.get("isCharge", false):
		cost_lbl.text = "Charge action -- fills at %d per use of a non-charge action" % int(FarroadCore.cost_of_charge(act))
	else:
		# Ian: "shorten the charge bit to just Charge +x, where x is the
		# current amount."
		cost_lbl.text = "Charge +%d" % int(act.get("charge", 0))
	cost_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	cost_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(cost_lbl)

	if act.get("heal", false):
		var heal_lbl := Label.new()
		heal_lbl.text = "Heals its target(s) instead of dealing damage."
		heal_lbl.modulate = Palette.GOOD_GREEN
		heal_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		heal_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(heal_lbl)

	if act.get("element"):
		var elem_lbl := Label.new()
		elem_lbl.text = "Element: %s" % str(act["element"]).capitalize()
		vbox.add_child(elem_lbl)

	# Ian: "on action inspection, say exactly what buffs and debuffs do" --
	# a real, numeric effect line (derived from FarroadCore's own
	# STATUS_BASE_MAG where the status is magnitude-based, so this can
	# never silently drift out of sync with the actual engine math),
	# not just the bare status name.
	if act.get("applies"):
		var status_id: String = str(act["applies"])
		var applies_lbl := Label.new()
		var turns_txt: String = " for %d turns" % int(act["turns"]) if act.get("turns") else ""
		applies_lbl.text = "Applies %s%s: %s" % [status_id.capitalize(), turns_txt, _status_description(status_id)]
		applies_lbl.modulate = Palette.PARTY_BLUE if FarroadCore.is_buff_status(status_id) else Palette.NOTE_PURPLE
		applies_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		applies_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(applies_lbl)

	if act.get("note"):
		var note_lbl := Label.new()
		note_lbl.text = str(act["note"])
		note_lbl.modulate = Palette.TEXT_DIM
		note_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		note_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(note_lbl)

	# 24-item batch, Group D1: "move the (Used by x) text on actions into
	# the detailed inspection of them... keep them unselectable." A plain
	# Label (never selectable) listing every owned unit holding it, fielded
	# or benched -- starter actions (strike/ember) are freely shareable, so
	# they're labelled as such rather than listing everyone.
	var used_lbl := Label.new()
	if FarroadProgression.STARTER_ACTIONS.has(action_id):
		used_lbl.text = "Starter action -- any number of units can use it at once."
	else:
		var holders: Array = FarroadProgression.action_holders(g, action_id)["active"]
		used_lbl.text = ("Used by %s" % ", ".join(holders)) if not holders.is_empty() else "Not currently used by anyone."
	used_lbl.modulate = Palette.TEXT_DIM
	used_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	used_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(used_lbl)

	await _finish_detail_overlay(o)

## 24-item batch: "add a Stats button in the menu that shows furthest
## wave, number of wipes, enemies defeated, bosses defeated, dungeons
## found, quests completed (%), and Power Level, among any other stats you
## think worth tracking." Everything is derived live from existing save
## state except enemies defeated (g["enemiesDefeated"], a real counter
## bumped by every win path -- Road, quests, dungeons, expeditions).
func _show_stats_popup() -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "Stats"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var quest_total := 0
	var quest_done := 0
	var lines_total := 0
	var lines_done := 0
	for uid in FarroadCore.QUEST_LINES.keys():
		var stages: int = (FarroadCore.QUEST_LINES[uid] as Array).size()
		quest_total += stages
		lines_total += 1
		var st: int = mini(stages, int(g.get("quests", {}).get(uid, {}).get("stage", 0)))
		quest_done += st
		if st >= stages:
			lines_done += 1
	var quest_pct: float = 100.0 * float(quest_done) / float(maxi(quest_total, 1))

	var dungeon_clears := 0
	for d in g.get("dungeons", []):
		dungeon_clears += int(d.get("clears", 0))
	var top_level := 1
	for uid in g.get("owned", {}).keys():
		top_level = maxi(top_level, int(g["lvl"].get(uid, 1)))
	var equip_pieces := 0
	for iid in g.get("equipInv", {}).keys():
		equip_pieces += int(g["equipInv"][iid])
	var mc_charges: int = (g["mc"].get("acquiredCharges", []) as Array).size() if g.get("mc") != null else 0

	var rows: Array = [
		["Power level", str(FarroadProgression.power_level(g))],
		["Furthest wave", str(int(g.get("farthest", 1)))],
		["Current wave", str(int(g.get("wave", 1)))],
		["Bosses defeated", str(int(g.get("bossesCleared", 0)))],
		["Enemies defeated", str(int(g.get("enemiesDefeated", 0)))],
		["Wipes", str(int(g.get("wipes", 0)))],
		["Dungeons found", str((g.get("dungeons", []) as Array).size())],
		["Dungeon clears", str(dungeon_clears)],
		["Quests completed", "%d%% (%d/%d stages, %d/%d lines)" % [roundi(quest_pct), quest_done, quest_total, lines_done, lines_total]],
		["Units owned", "%d / %d" % [(g.get("owned", {}) as Dictionary).size(), FarroadCore.ROSTER.size()]],
		["Highest unit level", str(top_level)],
		["Actions unlocked", "%d (+%d charge)" % [(g.get("actions", []) as Array).size(), mc_charges]],
		["Gambits unlocked", "%d / %d" % [maxi(0, (g.get("conditions", []) as Array).size() - 1), FarroadCore.ALL_CONDITION_IDS.size() - 1]],
		["Equipment pieces", str(equip_pieces)],
	]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	for r in rows:
		var k := Label.new()
		k.text = r[0]
		k.modulate = Palette.TEXT_DIM
		grid.add_child(k)
		var v := Label.new()
		v.text = r[1]
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(v)
	vbox.add_child(grid)
	await _finish_detail_overlay(o)

## Ian: "change the inventory section in the settings to be a button."
## Same shared small-overlay shape every other detail popup already uses
## (nests inside Settings' own already-open popup via _overlay_host).
func _show_inventory_popup() -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "Inventory"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	var body := Label.new()
	body.text = "Aether: %d\nMarks: %d\nLore (total): %d" % [
		roundi(g.get("aether", 0.0)), roundi(g.get("marks", 0.0)), roundi(FarroadProgression.total_lore(g))]
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(body)
	await _finish_detail_overlay(o)

## Ian: "add a button to change our main character's name." A LineEdit +
## Save button inside the same shared overlay shape. FarroadProgression.
## set_mc_name already patches g["mc"]/the roster template/any matching
## live g["units"] entry -- this also pushes the rename onto whichever
## BattlePresenter(s) are actually on screen right now (Road and/or a
## side battle), so it's visible immediately, not just next wave.
func _show_change_name_popup() -> void:
	if g.get("mc") == null:
		return
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Change name"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var name_edit := LineEdit.new()
	name_edit.max_length = 20
	name_edit.text = str(g["mc"].get("name", ""))
	vbox.add_child(name_edit)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(func():
		var sanitized := _sanitize_mc_name(name_edit.text)
		if sanitized != "":
			var old_name: String = str(g["mc"].get("name", ""))
			FarroadProgression.set_mc_name(g, sanitized)
			if current_presenter != null:
				current_presenter.call("sync_mc_name", old_name, sanitized)
			if side_presenter != null:
				side_presenter.call("sync_mc_name", old_name, sanitized)
			_save_game()
		o["backdrop"].queue_free())
	vbox.add_child(save_btn)

	await _finish_detail_overlay(o)

## Same sanitize rule McCreatePanel._sanitize_name uses -- small per-file
## duplication (this project's own established convention) rather than a
## shared base class for a 3-line regex.
func _sanitize_mc_name(raw: String) -> String:
	var re := RegEx.new()
	re.compile("[<>&\"']")
	return re.sub(raw, "", true).strip_edges().substr(0, 20)

## Ian: "say exactly what buffs and debuffs do." Every magnitude-based
## status reads its real number straight from FarroadCore.STATUS_BASE_MAG
## (the same table apply_status/eff_atk/eff_def/etc. actually use), so
## this can never quietly drift out of sync with the real combat math.
## "taunted" and "blinded" have no single named magnitude constant to
## read (taunted is a pure behavioral flag; blinded's +30% evade-chance
## bonus is a literal inline constant in resolve_hit, matching how the
## engine itself defines it) -- their text is hand-written to match.
func _status_description(status_id: String) -> String:
	var mag: float = FarroadCore.STATUS_BASE_MAG.get(status_id, 0.0)
	match status_id:
		"enfeebled": return "ATK %+.0f%%" % (mag * 100.0)
		"dulled": return "MAG %+.0f%%" % (mag * 100.0)
		"bracing": return "DEF %+.0f%%" % (mag * 100.0)
		"sundered": return "DEF %+.0f%%" % (mag * 100.0)
		"frail": return "RES %+.0f%%" % (mag * 100.0)
		"blurred": return "Evade %+.0f%%" % (mag * 100.0)
		"warded": return "Incoming damage %+.0f%%" % (mag * 100.0)
		"slowed": return "Turns take %.0f%% longer" % (mag * 100.0)
		"hasted": return "Turns take %.0f%% less time" % (-mag * 100.0)
		"surging": return "Charge rate %+.0f%%" % (mag * 100.0)
		"burning": return "Loses %.0f%% max HP per turn" % (mag * 100.0)
		"regen": return "Heals %.0f%% max HP per turn" % (mag * 100.0)
		"taunted": return "Forces enemies to target this unit"
		"blinded": return "Attacks are 30% more likely to be evaded"
		_: return "%+.0f%%" % (mag * 100.0) if mag != 0.0 else ""

## Post-Milestone-3 APK feedback (round 3): "change enemies and equipment
## to have similar popups" -- shared by EquipmentPanel's per-slot info icon
## and CataloguePanel's Equipment tab. `uid` is optional (empty when opened
## from a unit-agnostic context like Catalogue) -- see
## EquipmentPanel._describe_equipment's own comment for why a marginal %
## affinity contribution needs a REAL unit's baseline to be well-defined;
## with no uid, this falls back to the item's raw affinity values instead
## of a computed %.
func _show_equipment_detail_popup(item_id: String, uid: String = "") -> void:
	var item = FarroadCore.EQUIPMENT.get(item_id)
	if item == null:
		return
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var color: Color = RARITY_COLOR.get(item.get("rarity", "common"), Color(1, 1, 1))
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b][color=#%s]%s[/color][/b]" % [color.to_html(false), item["name"]]
	vbox.add_child(title)

	var slot_lbl := Label.new()
	slot_lbl.text = "Slot: %s" % str(item.get("slot", "")).capitalize()
	slot_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	slot_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(slot_lbl)

	var stat_bits: Array = []
	for k in ["atk", "mag", "def", "res", "spd"]:
		if item.get(k):
			stat_bits.append("%s +%d" % [k.to_upper(), item[k]])
	if item.get("evade"):
		stat_bits.append("Evade +%d%%" % roundi(item["evade"] * 100.0))
	if not stat_bits.is_empty():
		var stat_lbl := Label.new()
		stat_lbl.text = ", ".join(stat_bits)
		# A real, reported overflow bug: this Label (like several others
		# across this popup and the welcome-back/enemy-detail popups) was
		# missing the same autowrap+expand-fill every SIBLING label here
		# already had (aff_lbl, just below) -- its fixed-pixel-font text
		# doesn't shrink with a narrower _vp.x the way this container's own
		# fraction-based width does, so at the real portrait aspect ratio
		# it was wider than its own available space, forcing an unwanted
		# reflow that pushed the whole popup's content taller than it
		# needed to be.
		stat_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		stat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(stat_lbl)

	var affinity: Dictionary = item.get("affinity", {})
	var nonzero_axes: Array = affinity.keys().filter(func(ax): return affinity[ax] != 0.0)
	if not nonzero_axes.is_empty():
		var aff_lbl := Label.new()
		aff_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		if uid != "" and g.get("owned", {}).has(uid):
			var base := FarroadProgression.affinity_baseline(uid)
			var purchased := FarroadProgression.affinity_purchased(g, uid)
			var bits: Array = []
			for ax in nonzero_axes:
				var without: float = base.get(ax, 0.0) + purchased.get(ax, 0.0)
				var with_item: float = without + affinity[ax]
				var delta_pct: float = (FarroadCore.affinity_mul(with_item) - FarroadCore.affinity_mul(without)) * 100.0
				bits.append("%s %+.0f%%" % [str(ax).capitalize(), delta_pct])
			var unit_def = FarroadCore.roster_by_id(uid)
			aff_lbl.text = "Affinity on %s: %s" % [(unit_def["name"] if unit_def else uid), ", ".join(bits)]
		else:
			var bits: Array = []
			for ax in nonzero_axes:
				bits.append("%s +%s" % [str(ax).capitalize(), str(affinity[ax])])
			aff_lbl.text = "Affinity (raw): %s" % ", ".join(bits)
		vbox.add_child(aff_lbl)

	if item.get("note"):
		var note_lbl := Label.new()
		note_lbl.text = str(item["note"])
		note_lbl.modulate = Palette.TEXT_DIM
		note_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(note_lbl)

	await _finish_detail_overlay(o)

## Post-Milestone-3 APK feedback (round 3): "for enemies, include their
## actions" -- CataloguePanel's Enemies tab info icon. Enemy archetypes
## carry their own gambit `slots` (an Array of {cond,action} pairs, same
## shape a unit's own loadout uses) -- resolved here into readable
## condition/action names via the same FarroadCore.cond_label/ACTIONS
## lookups every other panel already uses. Each listed action gets its own
## info icon too, opening _show_action_detail_popup as a second overlay --
## nests correctly on top of this one since both are siblings under the
## same host popup, not nested inside each other (see
## _build_detail_overlay's own comment).
func _show_enemy_detail_popup(arch_key: String) -> void:
	var a = FarroadCore.ARCH.get(arch_key)
	if a == null:
		return
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var color: Color = RARITY_COLOR.get(a.get("rarity", "common"), Color(1, 1, 1))
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b][color=#%s]%s[/color][/b]" % [color.to_html(false), a["name"]]
	vbox.add_child(title)

	var stat_lbl := Label.new()
	stat_lbl.text = "ATK %s   MAG %s   DEF %s   RES %s   SPD %s" % [
		str(a.get("atk", 0)), str(a.get("mag", 0)), str(a.get("def", 0)), str(a.get("res", 0)), str(a.get("spd", 0))]
	# A real, reported overflow bug: this line's fixed-pixel-font text
	# doesn't shrink with a narrower _vp.x the way this overlay's own
	# fraction-based width does (see _show_equipment_detail_popup's own
	# stat_lbl fix for the full reasoning) -- measured directly at the
	# real 412-wide portrait viewport: ~366px of unwrapped text against a
	# ~313-330px available width, a genuine overflow this autowrap fixes.
	stat_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	stat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(stat_lbl)

	# Ian: "show enemy growths" -- this archetype's own relative scaling
	# multipliers (everything beyond the flat ATK/MAG/DEF/RES/SPD above):
	# HP multiplier and effective tankiness (FarroadCore.dmg_taken_mul,
	# the SAME real formula build_enemies itself uses -- how much more/
	# less damage this archetype actually takes than the wolf baseline),
	# crit rates, evade, and field size (only when notably non-default,
	# matching content-pipeline.js's own "omit when default" convention
	# for the `size` CSV field).
	var growth_bits: Array = []
	growth_bits.append("HP ×%.2f" % float(a.get("hpMul", 1.0)))
	growth_bits.append("Takes %.0f%% dmg" % (FarroadCore.dmg_taken_mul(a) * 100.0))
	growth_bits.append("ATK crit %.0f%%" % (float(a.get("atkCrit", 0.0)) * 100.0))
	growth_bits.append("MAG crit %.0f%%" % (float(a.get("magCrit", 0.0)) * 100.0))
	growth_bits.append("Evade %.0f%%" % (float(a.get("evade", 0.0)) * 100.0))
	if a.get("size") and float(a["size"]) != 1.0:
		growth_bits.append("Size ×%.2f" % float(a["size"]))
	var growth_lbl := Label.new()
	growth_lbl.text = "Growth: %s" % ", ".join(growth_bits)
	growth_lbl.modulate = Palette.TEXT_DIM
	growth_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	growth_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(growth_lbl)

	var affinity: Dictionary = a.get("affinity", {})
	var aff_bits: Array = []
	for ax in affinity.keys():
		if affinity[ax] != 0.0:
			aff_bits.append("%s %+d" % [str(ax).capitalize(), int(affinity[ax])])
	if not aff_bits.is_empty():
		var aff_lbl := Label.new()
		aff_lbl.text = "Affinity: %s" % ", ".join(aff_bits)
		aff_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		vbox.add_child(aff_lbl)

	if a.get("chargeAction"):
		var cact = FarroadCore.ACTIONS.get(a["chargeAction"])
		var charge_row := HBoxContainer.new()
		var charge_lbl := Label.new()
		charge_lbl.text = "⚡ Charge action: %s" % (cact["name"] if cact else a["chargeAction"])
		charge_lbl.modulate = Palette.GOLD_PRESSED
		charge_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		charge_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		charge_row.add_child(charge_lbl)
		# Ian: "charge actions (both ally and enemy) need inspect icons
		# next to them." Opens as a second, sibling overlay on top of this
		# one (see this function's own header comment).
		var charge_action_id: String = a["chargeAction"]
		var charge_info_btn := Button.new()
		charge_info_btn.text = "ⓘ"
		charge_info_btn.custom_minimum_size = Vector2(36, 0)
		charge_info_btn.pressed.connect(_show_action_detail_popup.bind(charge_action_id))
		charge_row.add_child(charge_info_btn)
		vbox.add_child(charge_row)

	var slots: Array = a.get("slots", [])
	if not slots.is_empty():
		var slots_header := Label.new()
		slots_header.text = "Gambits:"
		slots_header.modulate = Palette.PARTY_BLUE
		vbox.add_child(slots_header)
		for s in slots:
			var cond_id: String = s.get("cond", "none")
			var action_id: String = s.get("action", "strike")
			var act = FarroadCore.ACTIONS.get(action_id)
			var row := HBoxContainer.new()
			var lbl := Label.new()
			lbl.text = "IF %s THEN %s" % [FarroadCore.cond_label(cond_id), (act["name"] if act else action_id)]
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var info_btn := Button.new()
			info_btn.text = "ⓘ"
			info_btn.custom_minimum_size = Vector2(36, 0)
			info_btn.pressed.connect(_show_action_detail_popup.bind(action_id))
			row.add_child(info_btn)
			vbox.add_child(row)

	await _finish_detail_overlay(o)

## Called by UnitsPanel (dynamic has_method()+call()) whenever its
## Gambits/Aether/Lore/Equipment sub-tab needs to (re)build its content --
## on first selecting that sub-tab, and again on every unit swap while it
## stays the active sub-tab. Dispatches to whichever panel's own
## build_into(container, uid, host_popup) -- these 4 panels no longer own
## any popup of their own (see GambitsPanel.gd's header comment for why:
## a nested-popup-closes-everything bug, plus Ian's explicit "show up
## beneath them, not as new windows" request) -- `host_popup` is passed
## through only so a panel with its OWN transient dialog (LorePanel's
## refund confirm) can nest it inside the SAME window this content lives
## in, rather than risking the identical sibling-Window bug.
func _build_unit_subpanel_content(panel_key: String, container: Container, uid: String, host_popup: Window) -> void:
	match panel_key:
		"gambits": gambits_panel.call("build_into", container, uid, host_popup)
		"aether": aether_panel.call("build_into", container, uid, host_popup)
		"lore": lore_panel.call("build_into", container, uid, host_popup)
		"equipment": equipment_panel.call("build_into", container, uid, host_popup)

## Post-Milestone-3 APK feedback (Group B4): full-screen popups (B2) would
## otherwise make the Road/combat view unreachable-looking while a tab is
## open -- the Road view is already always rendered behind every popup, so
## "returning to it" is just closing whatever's currently open.
func _on_road_pressed() -> void:
	if open_panel != null and is_instance_valid(open_panel):
		open_panel.popup.hide()
		open_panel = null

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

## Called by PartyPanel (dynamic has_method()+call()) right after a
## front/back row toggle (post-Milestone-3 APK feedback, Group A1) --
## pushes the row change onto the live fight's on-field sprite immediately,
## animated, rather than waiting for the next wave's build_party().
func _sync_row_change(uid: String) -> void:
	if current_presenter == null:
		return
	current_presenter.call("hop_to_new_row", uid)

## Guarded against a real race with side battles (Step 3i/3j fix): a Road
## win/wipe can already be mid-await (_animate_wave_transition's own
## WAVE_RUN_TIME wait/_fade_out, both a full second or more) when the
## player attempts a quest/dungeon --
## start_side_battle() reassigns g["battle"] to the side fight's own
## battle out from under this function. Without the two checks below,
## the resumed _on_battle_finished call would build a SECOND, unpaused,
## visible presenter from that reassigned g["battle"]/stale g["units"]/
## g["enemies"], rendered alongside side_presenter -- exactly the
## visible "quests overlap with the road" bug this was written to fix.
## _resolve_side_battle's own restore path is what rebuilds the Road's
## presenter once it's actually safe again (see its own comment).
func _begin_next_fight(stage_enemies_offscreen: bool = false, hide_party_until_revealed: bool = false, auto_start_loop: bool = true) -> void:
	if g.get("sideBattle") != null:
		return
	var presenter = load("res://scripts/BattlePresenter.gd").new()
	presenter.battle_finished.connect(_on_battle_finished)
	add_child(presenter)
	_raise_self_hosted_overlays()
	await get_tree().process_frame
	if g.get("sideBattle") != null:
		presenter.queue_free()
		return
	presenter.start_battle(g["battle"], g["units"] + g["enemies"], stage_enemies_offscreen, g.get("clearedWaves", {}), hide_party_until_revealed, auto_start_loop)
	current_presenter = presenter

const WAVE_RUN_TIME := 1.0
## Piece G: "have them move back over .25 seconds" -- the party's own
## "stop and settle" beat (see _on_battle_finished's own sequencing
## comment for the full narrative this and ENEMY_RUN_IN_TIME together
## build).
const WAVE_RETREAT_TIME := 0.25
## Piece G: "move the background more as well" -- was 1.5x run_dx.
const BG_RUN_MUL := 3.0
## Piece G: "fade in over .5 seconds when they stop moving."
const CHROME_FADE_TIME := 0.5
## Duplicated from BattlePresenter.ENEMY_RUN_IN_TIME (that script has no
## class_name, so it's not reachable as a qualified constant from here --
## same small-duplication convention this project already uses for icon
## x-fractions etc.) -- how long GameController waits after triggering
## run_enemies_entering() before treating everyone as "assembled." Ian:
## "slow down the enemy movement into their positions" -- was 1.0.
const ENEMY_RUN_IN_TIME := 1.6

## Ian: "after clearing a wave, have units run towards the right...
## maintain framing but have the background move behind them." Party
## units shift right by a modest amount ("framing maintained" -- they stay
## within their own band, not actually leaving the field). background_layer
## itself does NOT move during this leg -- see _animate_wave_retreat's own
## comment for why all of its motion happens there instead. A dead party
## member (dimmed, not removed) is skipped -- nothing to "run" for a unit
## that's down.
##
## Piece G additions: a defensive sweep force-hides any already-dead enemy
## before the run starts ("make sure they disappear before the party runs
## forward" -- update_hp() already hides a dead enemy the instant it dies,
## well before this ever runs, but this costs nothing and removes any
## doubt), and each moving party view's HP/charge/name chrome hides before
## it starts moving (fading back in only happens once the WHOLE run+retreat
## sequence stops -- see reveal_party(), called by _on_battle_finished once
## the retreat below actually finishes).
func _animate_wave_transition(old_presenter: Node) -> void:
	if old_presenter == null:
		return
	for view in old_presenter.unit_views_by_id.values():
		if not view.unit["isParty"] and view.unit["hp"] <= 0:
			view.visible = false
	var run_dx: float = _vp.x * 0.1
	for view in old_presenter.unit_views_by_id.values():
		if view.unit["isParty"] and view.unit["hp"] > 0:
			view.hide_chrome()
			var tw := create_tween()
			tw.tween_property(view, "position:x", view.position.x + run_dx, WAVE_RUN_TIME)

## Ian follow-up: "the Background moves backwards with units when they
## stop. It should move forward still, and stop when the units are at
## their starting positions. It shouldn't start moving until the units
## are at their 'running' positions as well. Enemies shouldn't run in
## until the background stops."
## The background used to scroll DURING the run-right leg, then reverse
## (scroll back the other way) during this retreat leg to literally undo
## itself -- visually that read as the party moonwalking while the world
## also lurched into reverse. Now the background stays completely still
## during the run-right leg (_animate_wave_transition no longer touches it
## at all) and does ALL of its scrolling here instead, continuing in the
## SAME forward direction every time (never reversing, so distance keeps
## accumulating wave over wave, exactly like genuine continuous travel) --
## starting the instant the party begins its own retreat (i.e. only once
## they've reached their "running" position) and stopping exactly when the
## party finishes settling back at its starting position. _on_battle_finished
## awaits this SAME WAVE_RETREAT_TIME duration before ever calling
## run_enemies_entering(), so enemies are guaranteed not to start arriving
## until this motion has actually stopped. The party's own "shift right
## then return to center" is just a framing trick; the background is what
## actually sells continuous forward travel down the road, so it should
## only ever move the one way.
func _animate_wave_retreat(old_presenter: Node) -> void:
	if old_presenter == null:
		return
	for view in old_presenter.unit_views_by_id.values():
		if view.unit["isParty"] and view.unit["hp"] > 0:
			var tw := create_tween()
			tw.tween_property(view, "position", view.rest_position, WAVE_RETREAT_TIME)
	if background_layer != null:
		var run_dx: float = _vp.x * 0.1
		var bg_tw := create_tween()
		bg_tw.tween_property(background_layer, "position:x", background_layer.position.x - run_dx * BG_RUN_MUL, WAVE_RETREAT_TIME)

## Mirrors the real doStep()'s post-battle branch (afterWaveCleared() on a
## win, onWipe() on a loss) -- on_wipe already rebuilds g["battle"] at the
## checkpoint wave internally (it calls start_wave itself), so only a WIN
## needs a separate start_wave(wave+1) call here.
func _on_battle_finished(outcome: String) -> void:
	if outcome == "party":
		# Captured BEFORE after_wave_cleared/start_wave advance g["wave"] --
		# this is the wave that just got cleared, not the upcoming one, so
		# light_up_wave below lights the correct circle.
		var cleared_wave: int = g["wave"]
		var aether_before: float = g.get("aether", 0.0)
		var lore_before: float = FarroadProgression.total_lore(g)
		var marks_before: float = g.get("marks", 0.0)
		var events: Array = FarroadProgression.after_wave_cleared(g)
		events += FarroadProgression.start_wave(g, g["wave"] + 1)
		_refresh_hud()
		_save_game()
		_spawn_reward_drops(events, aether_before, lore_before, marks_before)
		# Ian: a one-time popup congratulating the player on finishing the
		# tutorial and explaining enrage, shown exactly when the mechanic
		# itself first turns on. Awaited BEFORE the wave-transition animation
		# below so the player actually reads it (the just-finished boss
		# encounter stays on screen behind it, same as the welcome-back
		# popup showing over the live game rather than a blank screen).
		for e in events:
			if e.get("kind") == "tutorial_complete":
				await _show_tutorial_complete_popup()
				break
		for e in events:
			if e.get("kind") == "enrage_intro":
				await _show_enrage_intro_popup()
				break
		# Ian: "add a pop-up when she joins... you save her from the enemies
		# and she chooses to join you" -- the milestone-companion event
		# (still named "boss_companion" even though it can now fire on a
		# non-boss wave -- see after_wave_cleared's own comment) gets the
		# same awaited-popup treatment as tutorial_complete above.
		for e in events:
			if e.get("kind") == "boss_companion":
				await _show_companion_joined_popup(e["id"])
				break
		# Ian: "after wave 20, instead of a new unit, get a piece of
		# equipment and show a pop-up about equipment and where it can be
		# equipped" -- same awaited-popup shape as the two above.
		for e in events:
			if e.get("kind") == "tutorial_equip":
				await _show_tutorial_equip_popup(e["id"])
				break
		# Ian: "get rid of the wave pop-up." The finished battlefield (units,
		# HP bars, log/status buttons) stays on screen through the run
		# animation -- only freed once its own retreat finishes, not the
		# moment the fight ends. light_up_wave runs on this SAME
		# (about-to-be-freed) presenter, so the circle glows during the
		# run, matching "lights up... AS the party runs to the next
		# encounter" -- the NEW presenter then opens already showing it lit,
		# via the cleared_waves passed into its own start_battle call.
		#
		# Piece G follow-up: full sequence is now strictly ordered, not
		# concurrent -- "the party stops because they see enemies coming,
		# assuming battle stances, and THEN we see enemies coming in from
		# off-screen. After everyone's assembled in their spot, then combat
		# begins." (1) run right, (2) retreat/settle (background_layer's own
		# retreat tween is started in the SAME call, same WAVE_RETREAT_TIME
		# duration, so it always stops at exactly the same moment the party
		# does -- see _animate_wave_retreat), (3) enemies run in IMMEDIATELY
		# once the party's stopped (Ian: "immediately followed by enemies
		# entering" -- no held pause), (4) only once they've actually
		# arrived does the battle loop start.
		var old_presenter = current_presenter
		_animate_wave_transition(old_presenter)
		if old_presenter != null:
			old_presenter.call("light_up_wave", cleared_wave)
		await get_tree().create_timer(WAVE_RUN_TIME).timeout

		_animate_wave_retreat(old_presenter)
		await get_tree().create_timer(WAVE_RETREAT_TIME).timeout
		if old_presenter != null:
			old_presenter.queue_free()
		current_presenter = null
		# stage_enemies_offscreen=true (built hidden, not yet running in),
		# hide_party_until_revealed=true (old presenter is already gone by
		# now, so this is purely for the chrome fade-in polish, not to dodge
		# an overlap), auto_start_loop=false (combat waits for step 5 below).
		await _begin_next_fight(true, true, false)
		if current_presenter != null:
			current_presenter.call("reveal_party", CHROME_FADE_TIME)
			current_presenter.call("run_enemies_entering")
		await get_tree().create_timer(ENEMY_RUN_IN_TIME).timeout
		if current_presenter != null:
			current_presenter.call("begin_combat")
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

const FADE_HALF_SEC := 0.5

## A ~1s fade to black and back, used on a wipe to hide the checkpoint jump
## (the actual battlefield swap happens while the screen is fully black,
## between _fade_out() finishing and _fade_in() starting).
func _fade_out() -> void:
	# New BattlePresenter children get added after fade_overlay was built in
	# _build_hud(), so without this it would draw UNDER them instead of
	# covering the whole screen.
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
## calls, all at icon_size=0.11*vp.x, y=0.93*vp.y -- same per-file
## duplication convention this project already uses everywhere else, not
## a new pattern. Recomputed for the 8-icon row (24-item batch's own Group
## C6: Shop added) -- UnitsPanel 0.0133, PartyPanel 0.1367, ExpeditionPanel
## 0.3833, confirmed by reading each panel's own current _build_ui.
const ICON_SIZE_FRAC := 0.11
const ICON_Y_FRAC := 0.93
const UNITS_ICON_X_FRAC := 0.0133
const PARTY_ICON_X_FRAC := 0.1367
const EXPEDITION_ICON_X_FRAC := 0.3833

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
		# Flies to aether_cell's own real position now (a real HBox cell of
		# its own, not a single combined Aether+Marks Label) -- lands on
		# the exact currency it's for.
		_spawn_reward_flyer(start, aether_cell.global_position, "+%d Aether" % roundi(aether_delta), delay)
		delay += REWARD_FLYER_STAGGER
	var lore_delta: float = FarroadProgression.total_lore(g) - lore_before
	if lore_delta >= 1.0:
		# Lore's own HUD figure was removed (Ian: "remove lore total") --
		# Lore is per-action now and lives under Units -> Lore, so the
		# flyer's destination moves there instead of a currency cell.
		_spawn_reward_flyer(start, _icon_center(UNITS_ICON_X_FRAC), "+%d Lore" % roundi(lore_delta), delay)
		delay += REWARD_FLYER_STAGGER
	var marks_delta: float = g.get("marks", 0.0) - marks_before
	if marks_delta >= 1.0:
		_spawn_reward_flyer(start, marks_cell.global_position, "+%d Marks" % roundi(marks_delta), delay)
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
			return _icon_center(UNITS_ICON_X_FRAC)
		"equip":
			return _icon_center(EXPEDITION_ICON_X_FRAC)
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
	lbl.add_theme_font_size_override("font_size", int(_vp.y * 0.0196))
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
	_raise_self_hosted_overlays()
	await get_tree().process_frame
	side_presenter.start_battle(g["battle"], g["battle"]["units"])
	side_presenter.call("set_status_override", _side_battle_label_text(meta))

## Replaces the side presenter's own "Wave N" text (BattlePresenter.
## set_status_override) with the quest/dungeon's own name while a side
## battle is active -- the Road's own presenter/label are never touched,
## so nothing needs restoring once the side battle resolves.
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
	var prep := FarroadProgression.prep_dungeon_attempt(g, id, Time.get_unix_time_from_system())
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
	var event := FarroadProgression.finish_side_battle(g, result, gave_up, Time.get_unix_time_from_system())
	if event["kind"] == "dungeon_wave_advance":
		# Same fresh-instance-per-wave convention _begin_next_fight already
		# uses for the Road -- BattlePresenter._layout_units() never frees
		# prior UnitViews, so reusing one instance across waves would leak
		# them; a new instance per wave is both simpler and consistent.
		side_presenter.queue_free()
		side_presenter = load("res://scripts/BattlePresenter.gd").new()
		side_presenter.battle_finished.connect(_on_side_battle_finished)
		add_child(side_presenter)
		_raise_self_hosted_overlays()
		await get_tree().process_frame
		side_presenter.start_battle(g["battle"], g["battle"]["units"])
		side_presenter.call("set_status_override", _side_battle_label_text(g["sideBattle"]["meta"]))
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
	_show_quest_result_popup(event)
	_refresh_hud()
	_save_game()

class_name GameController
extends Node2D
## The game controller. It owns the live game-state Dictionary `g` (the field
## list is in FarroadProgression.new_game) and drives BattlePresenter wave
## after wave using FarroadProgression's build_party / build_enemies /
## grant_drops / after_wave_cleared / on_wipe. The tab panels are
## GambitsPanel, AetherPanel, LorePanel, EquipmentPanel (all shown inside
## UnitsPanel), PartyPanel, MarksPanel (shown in the Shop), ExpeditionPanel,
## QuestsPanel (side battles, see _enter_side_battle() below) and the
## character-creation screen McCreatePanel.
##
## _ready() gates the whole HUD / panels / first-fight sequence (_start_game())
## behind either a resumed save (_try_resume_save()) or a confirmed new
## character (_on_mc_confirmed()). Character creation is unconditional
## whenever no save exists; there is no "fresh game, no main character" path.

const SaveStore := preload("res://scripts/SaveStore.gd")
## How often expeditions get a chance to resolve while the game is running
## (see _on_expedition_tick()). Offline catch-up (a much bigger, one-shot time
## gap) is handled separately, once, at boot; see _try_resume_save().
const EXPEDITION_POLL_SEC := 15.0

var g: Dictionary
var vp: Vector2
## Wide windows (see WideShell.gd): the ribbon on top, the battle column on the
## left, the dock on the right. vp stays the whole viewport; _bpos/bvp are the
## battle column (the whole viewport in a portrait layout).
var wide := false
var shell: Node
var _bpos := Vector2.ZERO
var bvp := Vector2.ZERO
var current_presenter: BattlePresenter = null
var gambits_panel: GambitsPanel
var units_panel: UnitsPanel
var catalogue_panel: CataloguePanel
var settings_panel: SettingsPanel
var party_panel: PartyPanel
var aether_panel: AetherPanel
var lore_panel: LorePanel
var equipment_panel: EquipmentPanel
var marks_panel: MarksPanel
var expedition_panel: ExpeditionPanel
var expedition_timer: Timer
var quests_panel: QuestsPanel
var shop_panel: ShopPanel
var mc_panel: Node
var road_button: Button
var tutorial: Tutorial = null
## Tracks whichever panel's own popup is currently open -- see
## panel_opening()'s own comment for why this exists.
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
## The side battle currently running (a quest attempt or a dungeon crawl), or
## null when none is active. It is a second, independent BattlePresenter
## instance (see FarroadProgression.start_side_battle); the Road's presenter
## is parked and hidden meanwhile.
var side_presenter: BattlePresenter = null

var currency_row: HBoxContainer
var aether_cell: Label
var marks_cell: Label
var crystal_cell: Label
var power_level_cell: Label
var speed_toggle_btn: Button
var _speed_2x: bool = false
var fade_overlay: ColorRect
var background_layer: Node2D
## Captured by _try_resume_save() (empty {} when no save existed, or the 5 s
## no-op floor wasn't met); consumed once by _start_game() to show the
## welcome-back popup.
var _offline_summary: Dictionary = {}

## Symbols and emoji (✕ ⏩ ⓘ ⚡ 🔥 ...) come from bundled Noto fonts (SIL
## OFL, fonts/OFL.txt) as fallbacks to the default font: a browser has no
## system fonts to borrow them from, and this keeps them the same on every
## device.
const SYMBOL_FONTS := ["res://fonts/NotoSansSymbols2-Regular.ttf", "res://fonts/NotoSansSymbols.ttf", "res://fonts/NotoEmoji.ttf"]

static func _add_symbol_fonts() -> void:
	var base: Font = ThemeDB.fallback_font
	# the theme's own font (Selawik) lacks a few characters (the true minus,
	# >= and <=): it falls back to the engine font, which has them
	var pt: Theme = ThemeDB.get_project_theme()
	if pt != null and base != null:
		var tf: Font = pt.default_font
		if tf is FontFile and not tf.fallbacks.has(base):
			tf.fallbacks = [base]
		if pt.has_font("bold_font", "RichTextLabel"):
			var bf: Font = pt.get_font("bold_font", "RichTextLabel")
			if bf is FontFile and not bf.fallbacks.has(base):
				bf.fallbacks = [base]
	if base == null or not base.fallbacks.is_empty():
		return
	var list: Array[Font] = []
	for path in SYMBOL_FONTS:
		var f = load(path)
		if f is FontFile:
			# Labels space lines by the tallest font in the fallback list:
			# give the symbol fonts the main font's height at every size so
			# plain text isn't spread out
			for size in range(6, 97):
				f.set_cache_ascent(0, size, base.get_ascent(size))
				f.set_cache_descent(0, size, base.get_descent(size))
			list.append(f)
	base.fallbacks = list

## On a PC the window opens phone-shaped (the game's 412:915 proportions) at
## 90% of the screen's usable height, centred. It is sized to the actual
## screen, so it reads the same on 1080p, 1440p or a scaled display. Once per
## run (not again on a scene reload).
static var _window_sized := false

static func _size_desktop_window() -> void:
	if _window_sized or OS.has_feature("web") or not OS.has_feature("pc") or DisplayServer.get_name() == "headless":
		return
	_window_sized = true
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var usable: Rect2i = DisplayServer.screen_get_usable_rect()
	var base := Vector2(float(ProjectSettings.get_setting("display/window/size/viewport_width", 412)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 915)))
	var h := int(usable.size.y * 0.9)
	var size := Vector2i(int(h * base.x / base.y), h)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)

func _ready() -> void:
	# the frame-rate cap (and the debug fps readout) applies from the very first screen
	var frame_rate := FrameRate.new()
	frame_rate.name = "FrameRate"
	add_child(frame_rate)
	UiKit.auto_top_light(get_tree())
	_apply_desktop_scaling()
	get_window().size_changed.connect(_apply_desktop_scaling)
	# The PvP server is this same game started with "-- --server" (or a
	# dedicated-server export): it swaps straight to the server scene.
	# a look at the proposed UI kit: run the game with --ui-preview
	if OS.get_cmdline_user_args().has("--ui-preview"):
		get_tree().change_scene_to_file.call_deferred("res://scenes/UiKitMockup.tscn")
		return
	if OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server"):
		get_tree().change_scene_to_file.call_deferred("res://scenes/Server.tscn")
		return
	_add_symbol_fonts()
	_size_desktop_window()
	# Engine.time_scale is a global engine property, not reset by a scene reload
	# alone (e.g. Settings' "Reset Game"), so it is reset here: every fresh
	# boot of this scene starts at normal speed whatever a previous session
	# left it at.
	Engine.time_scale = 1.0
	_speed_2x = false
	# Touch-drag scrolling that works no matter what the first touch lands on
	# (see TouchScroll.gd). Hooked on node_added (every ScrollContainer /
	# OptionButton anywhere in the game, including ones built later inside
	# popups and overlays), plus one pass over whatever already exists.
	get_tree().node_added.connect(_on_node_added)
	for n in get_tree().root.find_children("*", "", true, false):
		_on_node_added(n)
	vp = get_viewport_rect().size
	_compute_regions()
	if not FarroadCore.load_real_content():
		push_error("GameController: failed to load res://data/content.json")
		return
	# Playing means agreeing to the terms (they cover the gameplay data
	# Analytics.gd sends): asked before anything else, every launch until
	# agreed, and again when the terms change.
	if Analytics.terms_accepted():
		_boot_after_terms()
	else:
		var terms = load("res://scripts/TermsPanel.gd").new()
		add_child(terms)
		terms.setup(vp, self, _boot_after_terms)

func _boot_after_terms() -> void:
	if _try_resume_save():
		await _run_offline_replay()
		_finish_resume()
		_start_game()
	elif _save_unreadable:
		_show_save_recovery()
	else:
		mc_panel = load("res://scripts/McCreatePanel.gd").new()
		add_child(mc_panel)
		mc_panel.setup(vp, self, _on_mc_confirmed)

## A ScrollContainer gets a TouchScroll helper child (drag scrolls even when
## the press started on a button, card or text), and a dropdown opens on
## release instead of on press (OptionButton defaults to press, which would
## open it the instant a scroll gesture's first touch landed on it).
func _on_node_added(n: Node) -> void:
	if n is ScrollContainer:
		# Deferred: node_added fires mid-add_child, when the container can
		# still refuse a child of its own.
		_attach_touch_scroll.call_deferred(n)
	elif n is OptionButton:
		(n as OptionButton).action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE

## INTERNAL_MODE_BACK keeps the helper out of get_children(), so nothing
## that walks a container's own children ever sees it.
func _attach_touch_scroll(node) -> void:   # untyped: it may be freed by the time this runs
	if not is_instance_valid(node) or not (node is ScrollContainer) or not node.is_inside_tree():
		return
	var sc: ScrollContainer = node
	for c in sc.get_children(true):
		if c is TouchScroll:
			return
	sc.add_child(TouchScroll.new(), false, Node.INTERNAL_MODE_BACK)

## Everything that used to run unconditionally right after
## _load_or_new_game() -- now shared by both boot paths (a resumed save,
## or a freshly confirmed character), run only once `g` is guaranteed
## fully built either way.
const DEBUG_CRYSTAL := 5000

func _start_game() -> void:
	# Debug builds only: plenty of Crystal to test the Shop with (a release
	# build never does this).
	if OS.is_debug_build() and int(g.get("crystal", 0)) < DEBUG_CRYSTAL:
		g["crystal"] = DEBUG_CRYSTAL
	_start_cloud.call_deferred()
	_build_background_layer()
	_compute_regions()
	shell = load("res://scripts/WideShell.gd").new()
	add_child(shell)
	shell.build(self)
	_build_hud()
	_layer_hud_above_trees()
	refresh_hud()
	if not _offline_summary.is_empty():
		_show_welcome_back_popup()
	gambits_panel = GambitsPanel.new()
	add_child(gambits_panel)
	gambits_panel.setup(g, _units_content_vp(), self)
	units_panel = UnitsPanel.new()
	add_child(units_panel)
	units_panel.setup(g, _menu_vp(), self)
	catalogue_panel = CataloguePanel.new()
	add_child(catalogue_panel)
	catalogue_panel.setup(g, _menu_vp(), self)
	settings_panel = SettingsPanel.new()
	add_child(settings_panel)
	settings_panel.setup(g, _menu_vp(), self)
	party_panel = PartyPanel.new()
	add_child(party_panel)
	party_panel.setup(g, _menu_vp(), self)
	aether_panel = AetherPanel.new()
	add_child(aether_panel)
	aether_panel.setup(g, _units_content_vp(), self)
	lore_panel = LorePanel.new()
	add_child(lore_panel)
	lore_panel.setup(g, _units_content_vp(), self)
	equipment_panel = EquipmentPanel.new()
	add_child(equipment_panel)
	equipment_panel.setup(g, _units_content_vp(), self)
	marks_panel = MarksPanel.new()
	add_child(marks_panel)
	marks_panel.setup(g, _menu_vp(), self)
	expedition_panel = ExpeditionPanel.new()
	add_child(expedition_panel)
	expedition_panel.setup(g, _menu_vp(), self)
	quests_panel = QuestsPanel.new()
	add_child(quests_panel)
	quests_panel.setup(g, _menu_vp(), self)
	shop_panel = ShopPanel.new()
	add_child(shop_panel)
	shop_panel.setup(g, _menu_vp(), self)
	_build_arena_button()
	_start_analytics()
	var wd := Timer.new()
	wd.wait_time = ROAD_WATCHDOG_SEC
	wd.autostart = true
	wd.timeout.connect(_road_watchdog)
	add_child(wd)
	notifier = Notifier.new()
	add_child(notifier)
	notifier.setup(g)
	expedition_timer = Timer.new()
	expedition_timer.wait_time = EXPEDITION_POLL_SEC
	expedition_timer.autostart = true
	expedition_timer.timeout.connect(_on_expedition_tick)
	add_child(expedition_timer)
	get_viewport().size_changed.connect(_on_viewport_resized)
	# guided onboarding (Tutorial.gd): unlocks menus at fixed waves
	tutorial = Tutorial.new()
	add_child(tutorial)
	tutorial.setup(self)
	# The panels in lists like this one are called by duck typing (open_menu, can_go_back, go_back, close_popups)
	# because they have no shared base class.
	for p in [units_panel, party_panel, quests_panel, shop_panel, expedition_panel,
			settings_panel, catalogue_panel]:
		# before _reset_menu, so it sees the level the menu was on
		p.popup.popup_hide.connect(_on_tab_hidden.bind(p))
		p.popup.popup_hide.connect(_reset_menu.bind(p))
		p.popup.window_input.connect(_on_shortcut_event)
	_layout_wide()
	_begin_next_fight()
	_resume_path_fight.call_deferred()
	_whats_new_if_updated()
	if Updates.check_enabled() and not OS.has_feature("web"):
		get_tree().create_timer(6.0).timeout.connect(func(): check_updates(false))

## A closed menu resets to its default: it drops any info / picker box left
## open inside it and goes back to its first tab with no filters or selections,
## so it always reopens the same way (a leftover info box hid the Lore
## tutorial's target).
const _MENU_DEFAULTS := {"current_tab": "", "current_sub_tab": "summary", "selected_action_id": "", "selected_uids": [],
	"selected_direction": "", "action_filter_target": "any", "action_filter_camp": "any",
	"action_filter_effect": "any", "cond_filter_group": "any", "gambit_filter_group": "any"}
const _FIRST_TAB := {"shop": "marks", "catalogue": "units"}

func _reset_menu(panel: Node) -> void:
	UiKit.set_icon_active(panel.get("toggle_button"), false)
	for c in panel.popup.get_children():
		if c.has_meta("menu_overlay"):
			c.queue_free()
	var subs: Array = [panel]
	if panel == units_panel:
		subs += [gambits_panel, aether_panel, lore_panel, equipment_panel]
	for p in subs:
		if p == null or not is_instance_valid(p):
			continue
		for key in _MENU_DEFAULTS:
			if p.get(key) == null:
				continue
			var v = _MENU_DEFAULTS[key]
			if key == "current_tab":
				v = _FIRST_TAB.get("shop" if p == shop_panel else "catalogue" if p == catalogue_panel else "", "")
				if v == "":
					continue
			p.set(key, v.duplicate() if v is Array else v)

## Whether a tab or Units sub-tab is unlocked yet (Tutorial.unlocked).
func tab_unlocked(key: String) -> bool:
	return tutorial == null or Tutorial.unlocked(g, key, tutorial.active)

func skip_tutorials() -> void:
	if tutorial != null:
		tutorial.skip_all()

## The live equivalent of the offline catch-up below: while the game keeps
## running, an active expedition still gets a chance to resolve progress
## without a full app restart. It runs on a Timer. It only refreshes
## expedition_panel's popup if that is open, since there is no point
## rebuilding UI nobody can see.
var notifier: Notifier = null

## True while some expedition still has a long stretch to catch up (a long absence, or a Recall waiting for it).
## _process then works on it a few milliseconds a frame, so the game never stalls for it.
var _exp_backlog := false
const EXP_SLICE_MS := 6
var _exp_refresh_at := 0.0

func _slice_expeditions() -> void:
	if not _exp_backlog or g.is_empty():
		return
	var out_ids: Array = _out_expedition_ids()
	var done: bool = FarroadProgression.resolve_all_expeditions(g, Time.get_unix_time_from_system(), EXP_SLICE_MS)
	_expedition_progress_done(out_ids)
	if done:
		_exp_backlog = false
		save_game()
	var t := Time.get_ticks_msec()
	if t >= _exp_refresh_at or done:
		_exp_refresh_at = t + 1000
		if expedition_panel.popup.visible:
			expedition_panel.refresh()

func _out_expedition_ids() -> Array:
	var out_ids: Array = []
	for e in g.get("expeditions", []):
		if e.get("arrivedAt") == null:
			out_ids.append(e["id"])
	return out_ids

func _expedition_progress_done(out_ids: Array) -> void:
	if notifier != null:
		for e in g.get("expeditions", []):
			if e.get("arrivedAt") != null and out_ids.has(e["id"]):
				notifier.on_expedition_arrived(e)   # Windows, when not focused

## Works out whether any expedition has a stretch to catch up that is worth doing in slices.
func note_expedition_backlog() -> void:
	var now := Time.get_unix_time_from_system()
	for e in g.get("expeditions", []):
		if e.get("homeAt") == null and (now - float(e["lastResolvedAt"]) >= 90.0 or e.get("recallPending", false)):
			_exp_backlog = true
			return

func _on_expedition_tick() -> void:
	var out_ids: Array = _out_expedition_ids()
	FarroadProgression.resolve_all_expeditions(g, Time.get_unix_time_from_system(), EXP_SLICE_MS)
	note_expedition_backlog()
	if notifier != null:
		for e in g.get("expeditions", []):
			if e.get("arrivedAt") != null and out_ids.has(e["id"]):
				notifier.on_expedition_arrived(e)   # Windows, when not focused
	if expedition_panel.popup.visible:
		expedition_panel.refresh()
	# resolve_all_expeditions can unlock a new dungeon (unlock_direction_dungeon,
	# called from inside resolve_expedition), so refresh a currently open QUESTS
	# popup: a new dungeon card appears without the player closing and
	# reopening it.
	if quests_panel.popup.visible:
		quests_panel.refresh()

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
	vp = get_viewport_rect().size
	_compute_regions()
	# positioned 5% lower than the original 0.015 / 0.043 (see _build_hud)
	currency_row.position = Vector2(vp.x * 0.02, vp.y * 0.065)
	_place_hud_plate()
	currency_row.add_theme_constant_override("separation", int(vp.x * 0.022))
	aether_cell.add_theme_font_size_override("font_size", int(vp.y * 0.0175))
	marks_cell.add_theme_font_size_override("font_size", int(vp.y * 0.0175))
	crystal_cell.add_theme_font_size_override("font_size", int(vp.y * 0.0175))
	power_level_cell.add_theme_font_size_override("font_size", int(vp.y * 0.0175))
	speed_toggle_btn.position = Vector2(vp.x * 0.86, vp.y * 0.015)
	speed_toggle_btn.custom_minimum_size = Vector2(vp.x * 0.12, vp.y * 0.035)
	fade_overlay.size = vp
	if background_layer != null:
		background_layer.position = Vector2(0.0, _bpos.y)
		if foreground_layer != null:
			foreground_layer.position = Vector2(0.0, _bpos.y)
			foreground_layer.size = bvp
		_rebuild_background_marks()
	for pr in [current_presenter, side_presenter]:
		if pr != null and is_instance_valid(pr):
			_fit_presenter(pr)
			pr.reflow(bvp)
			_dock_presenter(pr)
	gambits_panel.reflow(_units_content_vp())
	units_panel.reflow(_menu_vp())
	catalogue_panel.reflow(_menu_vp())
	settings_panel.reflow(_menu_vp())
	party_panel.reflow(_menu_vp())
	aether_panel.reflow(_units_content_vp())
	lore_panel.reflow(_units_content_vp())
	equipment_panel.reflow(_units_content_vp())
	marks_panel.reflow(_menu_vp())
	_build_arena_button()
	expedition_panel.reflow(_menu_vp())
	quests_panel.reflow(_menu_vp())
	shop_panel.reflow(_menu_vp())
	_reflow_road_button()
	_layout_wide()

## Resumes user://save.json if one exists and parses cleanly: apply_custom_mc,
## start_wave, simulate_offline_progress, resolve_all_expeditions, in that
## order. apply_custom_mc is called unconditionally (a no-op when g["mc"] is
## null, e.g. a legacy save from before character creation). `saved_at` comes
## from the save envelope's own top-level "savedAt" field (a sibling of the
## FIELDS-derived content deserialize() reads), not from anything inside `g`.
## Returns false (doing nothing else) when no save exists or it fails to
## parse; the caller then shows character creation instead of silently falling
## back to a fresh game without a main character.
var _save_too_new := false        # the save was written by a newer build of the game than this one
var _save_unreadable := false     # files exist but neither the save nor its backup can be read
var _offline_state: Dictionary = {}
var _resume_now: float = 0.0

func _try_resume_save() -> bool:
	CatchupRef.apply_cached()   # before the offline catch-up works out its rewards
	var rd: Dictionary = SaveStore.read()
	if rd["state"] == "none":
		return false
	if rd["state"] == "unreadable":
		# never start a new game silently over files that may still be recoverable
		_save_unreadable = true
		return false
	if rd["state"] == "restored":
		Analytics.add("features", "saveRestoredFromBackup")
	var parsed: Dictionary = rd["data"]
	if FarroadSave.is_from_newer_build(parsed):
		# loading it would drop what this build doesn't know and save that over it
		_save_unreadable = true
		_save_too_new = true
		Analytics.add("features", "saveFromNewerBuild")
		return false
	g = FarroadSave.deserialize(parsed)
	_local_saved_at = int(parsed.get("savedAt", 0))
	FarroadProgression.apply_custom_mc(g)
	FarroadProgression.apply_rows(g)
	UnitView.mc_body = str(g["mc"].get("body", "male")) if g.get("mc") != null else "male"
	UnitView.game_state = g
	var resume_wave: int = g["wave"] if g.get("wave") else 1
	# skip_drops=true: this wave was never cleared when saved, so
	# grant_drops(w) must not treat resuming it as a fresh visit.
	FarroadProgression.start_wave(g, resume_wave, true)
	_resume_now = Time.get_unix_time_from_system()
	# the replay of the time away runs in slices (_run_offline_replay), then _finish_resume
	_offline_state = FarroadProgression.offline_begin(g, parsed.get("savedAt"), _resume_now)
	return true

## Replays the time away a little each frame behind a progress screen, so a long absence
## never freezes the app.
func _run_offline_replay() -> void:
	if _offline_state.is_empty():
		return
	# A title screen with a loading bar at the bottom while the time away is replayed.
	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.05, 0.08, 1.0)
	bg.size = vp
	layer.add_child(bg)
	var title := Label.new()
	title.text = "FARROAD"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.085))
	title.add_theme_color_override("font_color", UiKit.BAND)
	title.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.03))
	title.add_theme_constant_override("outline_size", 8)
	title.size = Vector2(vp.x, vp.y * 0.12)
	title.position = Vector2(0.0, vp.y * 0.34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(title)
	var rule := ColorRect.new()
	rule.color = UiKit.SILVER_DIM
	rule.size = Vector2(vp.x * 0.5, 2.0)
	rule.position = Vector2(vp.x * 0.25, vp.y * 0.34 + vp.y * 0.125)
	layer.add_child(rule)
	var bar_w: float = vp.x * 0.72
	var bar_h: float = vp.y * 0.012
	var bar_x: float = (vp.x - bar_w) / 2.0
	var bar_y: float = vp.y * 0.9
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", int(vp.y * 0.02))
	lbl.add_theme_color_override("font_color", Palette.TEXT_DIM)
	lbl.size = Vector2(vp.x, vp.y * 0.03)
	lbl.position = Vector2(0.0, bar_y - vp.y * 0.04)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(lbl)
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.16, 0.14, 0.18)
	bar_bg.size = Vector2(bar_w, bar_h)
	bar_bg.position = Vector2(bar_x, bar_y)
	layer.add_child(bar_bg)
	var bar_fg := ColorRect.new()
	bar_fg.color = UiKit.BAND
	bar_fg.size = Vector2(0.0, bar_h)
	bar_fg.position = bar_bg.position
	layer.add_child(bar_fg)
	while true:
		var frac: float = FarroadProgression.offline_progress(_offline_state)
		lbl.text = "Catching up on your time away... %d%%" % roundi(frac * 100.0)
		bar_fg.size.x = bar_w * clampf(frac, 0.0, 1.0)
		if FarroadProgression.offline_step(g, _offline_state, 8):
			break
		await get_tree().process_frame
	layer.queue_free()

## Everything that used to follow the synchronous replay.
func _finish_resume() -> void:
	_offline_summary = FarroadProgression.offline_summary(g, _offline_state) if not _offline_state.is_empty() else {}
	if not _offline_summary.is_empty():
		Analytics.add("offline", "seconds", float(_offline_summary.get("elapsed_sec", 0.0)))
		Analytics.add("offline", "returns")
		Analytics.add("offline", "waveGain", float(int(_offline_summary.get("wave_after", 0)) - int(_offline_summary.get("wave_before", 0))))
		# wipes (and clears) fought while the game was closed count in the wave stats too
		Analytics.waves_offline(_offline_summary.get("wave_results", {}))
	FarroadProgression.resolve_all_expeditions(g, _resume_now, EXP_SLICE_MS)   # the rest is caught up a few ms a frame (_process)
	note_expedition_backlog()
	# the time away must be accurate next launch even after a very short
	# session, so the save is stamped now that this gap has been counted
	save_game()

## Shown when a save exists but neither it nor its backup can be read.
func _show_save_recovery() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.05, 0.08, 1.0)
	bg.size = vp
	layer.add_child(bg)
	var vb := VBoxContainer.new()
	vb.position = Vector2(vp.x * 0.08, vp.y * 0.2)
	vb.custom_minimum_size = Vector2(vp.x * 0.84, 0)
	vb.add_theme_constant_override("separation", int(vp.y * 0.02))
	layer.add_child(vb)
	var title := Label.new()
	title.text = "This save is from a newer version" if _save_too_new else "Your save could not be read"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.035))
	vb.add_child(title)
	var body := Label.new()
	body.text = ("This save was made by a newer version of Farroad. Update the game to keep playing it; nothing has been changed or deleted.

Starting a new game keeps the save next to it, renamed .corrupt." if _save_too_new else "The save file and its backup are both damaged. Nothing has been changed or deleted.\n\nYou can try again (for example after restoring the files), or start a new game. A new game keeps the damaged files next to the save, renamed .corrupt.")
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	body.custom_minimum_size = Vector2(vp.x * 0.84, 0)
	vb.add_child(body)
	var retry := Button.new()
	retry.text = "Try again"
	retry.pressed.connect(func(): get_tree().reload_current_scene())
	vb.add_child(retry)
	if OS.has_feature("pc"):
		var folder := Button.new()
		folder.text = "Show the save folder"
		folder.pressed.connect(func(): OS.shell_show_in_file_manager(ProjectSettings.globalize_path("user://")))
		vb.add_child(folder)
	var fresh := Button.new()
	fresh.text = "Start a new game"
	var armed := [false]
	fresh.pressed.connect(func():
		if not armed[0]:
			armed[0] = true
			fresh.text = "Tap again to start a new game"
			return
		SaveStore.set_aside_damaged()
		_save_unreadable = false
		_save_too_new = false
		layer.queue_free()
		mc_panel = load("res://scripts/McCreatePanel.gd").new()
		add_child(mc_panel)
		mc_panel.setup(vp, self, _on_mc_confirmed))
	vb.add_child(fresh)

## Starts a new game from the confirmed main character. A fresh game always
## uses seed 7. Called by McCreatePanel once the player confirms.
func _on_mc_confirmed(mc: Dictionary) -> void:
	g = FarroadProgression.new_game(7, mc)
	FarroadProgression.apply_custom_mc(g)
	UnitView.mc_body = str(g["mc"].get("body", "male")) if g.get("mc") != null else "male"
	UnitView.game_state = g
	FarroadProgression.start_wave(g, 1)
	save_game()   # mirrors doSave() immediately after boot(7,mc)
	_start_game()

## ===== Shifted Reflection =====
## After a player hits wave 100, an item lets them redo their Main
## Character's stats. One is given the first time they reach it (a save that
## is already past 100 gets it the next time a fight starts).
const RESPEC_WAVE := 100

func _check_respec_item() -> void:
	if g.get("mc") == null or bool(g.get("mcRespecGranted", false)) or int(g.get("farthest", 1)) < RESPEC_WAVE:
		return
	g["mcRespecGranted"] = true
	g["mcRespecs"] = int(g.get("mcRespecs", 0)) + 1
	save_game()
	show_tab_tutorial_popup("Shifted Reflection",
		"You found a Shifted Reflection. Use it from Units, on your Main Character, to spread your stat points again. Your name, look and charge action stay as they are.")

func start_mc_respec() -> void:
	if g.get("mc") == null or int(g.get("mcRespecs", 0)) <= 0 or g.get("sideBattle") != null:
		return
	_close_all_popups()
	var panel = load("res://scripts/McCreatePanel.gd").new()
	add_child(panel)
	panel.setup_respec(vp, self, g["mc"], _on_mc_respec, func(): pass)

func _on_mc_respec(points: Dictionary) -> void:
	if g.get("mc") == null or int(g.get("mcRespecs", 0)) <= 0:
		return
	var built: Dictionary = FarroadProgression.mc_build_stats(points)
	g["mc"]["stats"] = built["stats"]
	g["mc"]["hp"] = built["hp"]
	g["mc"]["growth"] = built["growth"]
	g["mc"]["points"] = points
	g["mc"].erase("legacy")
	g["mcRespecs"] = int(g["mcRespecs"]) - 1
	FarroadProgression.apply_custom_mc(g)   # onto the roster entry and its growth
	FarroadProgression.refresh_live_stats(g)
	Analytics.add("features", "mcRespec")
	refresh_hud()
	save_game()

## Save whenever the app is closed or sent to the background; coming back
## after a real break reloads the game so the welcome-back catch-up runs fresh
## from that save, so the time away is accurate (a side battle in progress is
## simply abandoned, same as closing the app).
const RESUME_RELOAD_SEC := 60.0
var _backgrounded_at: float = -1.0

func _notification(what: int) -> void:
	if g.is_empty() or g.get("mc") == null:
		return
	# Only a real mobile pause/resume counts as a break -- a desktop window
	# losing focus (alt-tab) just saves, it never reloads the game.
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
				_hold_popups_open()
				if notifier != null and Notifier.platform() == "web":
					notifier.schedule_away()   # browser timers while the tab stays open in the background
			save_game()
			if what == NOTIFICATION_WM_CLOSE_REQUEST and notifier != null:
				notifier.schedule_away()
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_release_popups()
			if notifier != null and Notifier.platform() == "web":
				notifier.cancel_scheduled()
		NOTIFICATION_APPLICATION_PAUSED:
			save_game()
			if cloud != null:
				cloud.upload()
			_backgrounded_at = Time.get_unix_time_from_system()
			if notifier != null:
				notifier.schedule_away()   # Android: idle-full / party-home alerts
		NOTIFICATION_APPLICATION_RESUMED:
			if notifier != null:
				notifier.cancel_scheduled()
			if _backgrounded_at > 0.0 and Time.get_unix_time_from_system() - _backgrounded_at >= RESUME_RELOAD_SEC:
				_backgrounded_at = -1.0
				get_tree().reload_current_scene()
			else:
				_backgrounded_at = -1.0

## Godot closes every popup window when the app loses focus. This node hears
## that first (it is their parent), so it turns the popup behaviour off for the
## ones showing and puts it back when focus returns. If a menu closed anyway,
## it is reopened.
var _held_popups: Array = []
var _focus_panel: Node = null

func _hold_popups_open() -> void:
	_focus_panel = open_panel if (open_panel != null and is_instance_valid(open_panel) and open_panel.popup.visible) else null
	_held_popups.clear()
	for p in get_tree().root.find_children("*", "Popup", true, false):
		if p.visible and p.get_flag(Window.FLAG_POPUP):
			p.set_flag(Window.FLAG_POPUP, false)
			_held_popups.append(p)

func _release_popups() -> void:
	for p in _held_popups:
		if is_instance_valid(p):
			p.set_flag(Window.FLAG_POPUP, true)
	_held_popups.clear()
	var panel := _focus_panel
	_focus_panel = null
	if panel != null and is_instance_valid(panel) and open_panel == panel and not panel.popup.visible:
		panel.call_deferred("open_menu")

## ===== Gameplay stats (Analytics.gd) =====
## Counted locally while playing and sent about once a day; see Analytics.gd.
const ANALYTICS_TICK_SEC := 60.0
var _road_wave_started_ms: int = 0
var _side_started_ms: int = 0
var _analytics_ticks: int = 0

func _start_analytics() -> void:
	Analytics.add("session", "starts")
	var t := Timer.new()
	t.wait_time = ANALYTICS_TICK_SEC
	t.ignore_time_scale = true   # real minutes played, at 1x or 2x
	t.autostart = true
	t.timeout.connect(_on_analytics_tick)
	add_child(t)
	# A report that's due goes out a little after launch, not mid-boot.
	get_tree().create_timer(20.0).timeout.connect(func(): Analytics.maybe_send(g, self))

func _on_analytics_tick() -> void:
	Analytics.add("session", "minutes")
	if Engine.time_scale > 1.0:
		Analytics.add("session", "minutesFast")
	_analytics_ticks += 1
	if _analytics_ticks % 10 == 0:
		Analytics.save()
		Analytics.maybe_send(g, self)

## Time on a Road wave, from its fight being built to its end (quest,
## dungeon and Arena fights in between don't count), plus who fought it.
func _record_road_wave(cleared: bool) -> void:
	if _road_wave_started_ms <= 0:
		return
	var secs := (Time.get_ticks_msec() - _road_wave_started_ms) / 1000.0
	_road_wave_started_ms = 0
	Analytics.wave(int(g.get("wave", 1)), secs, cleared)
	if cleared:
		for uid in g.get("party", []):
			Analytics.add("partyWaves", uid)

func _record_side_battle(meta: Dictionary, kind: String) -> void:
	var secs := (Time.get_ticks_msec() - _side_started_ms) / 1000.0
	if _road_wave_started_ms > 0:
		_road_wave_started_ms += int(secs * 1000.0)   # the Road was paused meanwhile
	var key := kind
	match str(meta.get("kind", "")):
		"quest": key += ":%s#%d" % [meta.get("uid", "?"), int(meta.get("stage", 0)) + 1]
		"dungeon": key += ":%s#t%d" % [meta.get("direction", "?"), int(meta.get("tier", 0))]
		"pvp": key += ":" + (str(meta.get("rival", "")) if str(meta.get("rival", "")) != "" else "code")
	Analytics.add("sideBattles", key)
	Analytics.add("sideBattleSeconds", str(meta.get("kind", "?")), secs)

## The terms, to read again from Settings.
func show_terms_popup() -> void:
	var o := _build_detail_overlay(Palette.BORDER_LEATHER, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.scroll_active = false
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_color_override("default_color", Palette.TEXT_INK)
	text.text = Analytics.terms_bbcode().replace("By tapping Agree and continue, you agree to these terms.", "You agreed to these terms when you started playing.")
	vbox.add_child(text)
	await _finish_detail_overlay(o)

## ===== Patch notes and updates (Updates.gd) =====
## Patch notes in the game, and a way to see that a newer version is out.
## The notes ship inside the game; the check asks GitHub for the latest release.

## The notes: one version (the "what's new" after an update) or all of them.
func show_patch_notes_popup(only_version: String = "") -> void:
	var o := _build_detail_overlay(Palette.BORDER_LEATHER, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = ("What's new in version %s" % only_version) if only_version != "" else "Patch notes"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Palette.TEXT_INK)
	vbox.add_child(title)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.scroll_active = false
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_color_override("default_color", Palette.TEXT_INK)
	text.text = Updates.notes_bbcode(only_version)
	vbox.add_child(text)
	if only_version != "":
		var all_btn := Button.new()
		all_btn.text = "All patch notes"
		all_btn.pressed.connect(func():
			o["backdrop"].queue_free()
			show_patch_notes_popup())
		vbox.add_child(all_btn)
	await _finish_detail_overlay(o)

## Once after the game has been updated: show what changed in this version.
## A brand-new player (no progress yet) isn't shown it.
func _whats_new_if_updated() -> void:
	var cur := Updates.current_version()
	var last := str(Analytics.state.get("lastSeenVersion", ""))
	if last == cur:
		return
	Analytics.state["lastSeenVersion"] = cur
	Analytics._dirty = true
	Analytics.save()
	if last == "" and int(g.get("farthest", 1)) <= 3:
		return
	if Updates.has_notes_for(cur):
		await get_tree().create_timer(2.5).timeout
		show_patch_notes_popup(cur)

## Asks GitHub for the latest release. `manual` (the Settings button) always
## answers and always shows the window when there is a newer version; the
## automatic check at launch stays quiet unless there is one, and only
## mentions each version once. `on_done` gets a one-line result.
## The newest released version ("" when it can't be found, and on the web,
## which is always the latest).
func _latest_release_version() -> String:
	if OS.has_feature("web"):
		return ""
	var req := HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	if req.request(Updates.RELEASE_URL, PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: Farroad"])) != OK:
		req.queue_free()
		return ""
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return ""
	var rel = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return str(rel.get("tag_name", "")).trim_prefix("v") if rel is Dictionary else ""

func check_updates(manual: bool, on_done: Callable = Callable()) -> void:
	if OS.has_feature("web"):
		if on_done.is_valid():
			on_done.call("The browser version is always the latest one.")
		return
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _headers, body: PackedByteArray):
		req.queue_free()
		var rel = JSON.parse_string(body.get_string_from_utf8()) if (result == HTTPRequest.RESULT_SUCCESS and code == 200) else null
		if not (rel is Dictionary) or str(rel.get("tag_name", "")) == "":
			if on_done.is_valid():
				on_done.call("Couldn't check for updates right now.")
			return
		var latest := str(rel["tag_name"]).trim_prefix("v")
		var cur := Updates.current_version()
		if not Updates.is_newer(latest, cur):
			if on_done.is_valid():
				on_done.call("You're up to date (version %s)." % cur)
			return
		if on_done.is_valid():
			on_done.call("Version %s is available." % latest)
		if manual or str(Analytics.state.get("updateShown", "")) != latest:
			Analytics.state["updateShown"] = latest
			Analytics._dirty = true
			Analytics.save()
			_show_update_popup(rel))
	if req.request(Updates.RELEASE_URL, PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: Farroad"])) != OK:
		req.queue_free()
		if on_done.is_valid():
			on_done.call("Couldn't check for updates right now.")

func _show_update_popup(rel: Dictionary) -> void:
	var latest := str(rel.get("tag_name", "")).trim_prefix("v")
	var o := _build_detail_overlay(Palette.BORDER_LEATHER, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "Version %s is available" % latest
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Palette.TEXT_INK)
	vbox.add_child(title)
	var sub := Label.new()
	sub.text = "You have version %s." % Updates.current_version()
	sub.add_theme_color_override("font_color", Palette.TEXT_INK)
	vbox.add_child(sub)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.scroll_active = false
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_color_override("default_color", Palette.TEXT_INK)
	text.text = Updates.release_bbcode(str(rel.get("body", "")))
	vbox.add_child(text)
	var url := str(rel.get("html_url", ""))
	if url.begins_with("https://github.com/"):
		var go := Button.new()
		go.text = "Download the update"
		go.pressed.connect(func(): OS.shell_open(url))
		vbox.add_child(go)
	await _finish_detail_overlay(o)

func save_game() -> void:
	var snap := FarroadSave.serialize(g, int(Time.get_unix_time_from_system()))
	if not SaveStore.write(snap):
		return   # the existing save is untouched; try again at the next save
	Analytics.save()
	if cloud != null:
		cloud.mark_dirty()

## The scrolling backdrop: a dedicated Node2D layer, added first (drawn behind
## the battle field and HUD), spanning a band 3x the screen width so a
## wave-transition scroll never reveals a bare edge. It is also what
## _animate_wave_transition scrolls during the post-wave-clear "run".
func _build_background_layer() -> void:
	background_layer = Node2D.new()
	add_child(background_layer)
	move_child(background_layer, 0)
	background_layer.position = Vector2(0.0, _bpos.y)
	# The front trees live in a layer of their own, drawn above the units (z_index 1) but
	# below the HUD (2), clipped to the battle area so trees queued off to the side never
	# show over the dock.
	foreground_layer = Control.new()
	foreground_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foreground_layer.clip_contents = true
	foreground_layer.z_index = 1
	add_child(foreground_layer)
	foreground_layer.position = Vector2(0.0, _bpos.y)
	foreground_layer.size = bvp
	bg_set = _desired_bg_set() if _bg_set_complete(_desired_bg_set()) else BG_SET_DEFAULT
	lighting = Lighting.new()
	add_child(lighting)
	lighting.setup(self)
	_rebuild_background_marks()

## A soft vertical gradient (a warm "sky" tone fading into the existing
## parchment tone), generated once and shared by every rebuild.
const _SKY_GRADIENT_TEX_H := 64
static var _sky_gradient_texture: Texture2D

static func _get_sky_gradient_texture() -> Texture2D:
	if _sky_gradient_texture == null:
		var img := Image.create(1, _SKY_GRADIENT_TEX_H, false, Image.FORMAT_RGBA8)
		var top: Color = Palette.SKY_TOP
		var bottom: Color = Palette.SKY_BOTTOM
		for y in range(_SKY_GRADIENT_TEX_H):
			img.set_pixel(0, y, top.lerp(bottom, float(y) / float(_SKY_GRADIENT_TEX_H - 1)))
		_sky_gradient_texture = ImageTexture.create_from_image(img)
	return _sky_gradient_texture

## The background art: a soft sky gradient behind everything, a "road" band
## along the bottom, and per-mark size / tone / spacing jitter (from a fixed
## seed, not real randomness, so a rebuild, e.g. on resize, reproduces the
## same layout) so the row reads as varied ground clutter instead of one shape
## stamped on repeat. The forest path is three tileable layers
## (art_src/forest_path): deep forest far back, trunk bases in the middle, and
## the tall dirt path the units stand on. Each scrolls at its own fraction of
## the travel distance (parallax); the far and middle strips only fill the top
## of the band, the near layer is the whole band.
const BG_DIR := "res://sprites/background/"
const BG_ART_H := 544.0   # the near layer's height in art pixels = the whole battle area (the units stand in its top two thirds)
## Which environment set is showing. Files are <set>_far/_mid/_near/_tree_l/_tree_r.png in BG_DIR
## (cave also has cave_overhang.png, drawn in the foreground). A set missing its core files falls
## back to the forest. "colosseum" is a static set: no front tree, nothing to scroll past.
const BG_SETS := ["forest", "prairie", "mountains", "cave", "colosseum"]
const BG_STATIC_SETS := ["colosseum"]
const BG_SET_DEFAULT := "forest"
## speed = share of the scroll distance each layer moves (far, mid, near)
const BG_LAYER_SPEEDS := [0.25, 0.84, 1.0]
const BG_LAYER_SUFFIX := ["_far.png", "_mid.png", "_near.png"]
var bg_set := BG_SET_DEFAULT

## The Road climbs: every ENV_WAVES waves the environment changes (ROAD_SETS in order; the last one
## repeats until more are made). Dungeons are the cave, the Arena (PvP) is the colosseum.
const ENV_WAVES := 100
const ROAD_SETS := ["prairie", "forest", "mountains"]
const SIDE_SETS := {"dungeon": "cave", "pvp": "colosseum", "raid": "colosseum", "path": "forest"}

func _road_set_for_wave(w: int) -> String:
	var tier: int = clampi((maxi(1, w) - 1) / ENV_WAVES, 0, ROAD_SETS.size() - 1)
	return ROAD_SETS[tier]

## The set the screen should show right now: the side battle's, else the Road's for the current wave.
func _desired_bg_set() -> String:
	var sb = g.get("sideBattle") if not g.is_empty() else null
	if sb != null:
		var k: String = str((sb as Dictionary).get("meta", {}).get("kind", ""))
		if SIDE_SETS.has(k):
			return SIDE_SETS[k]
	return _road_set_for_wave(int(g.get("wave", 1)))

## The battle area (position and size) in this node's coordinates.
func battle_rect() -> Rect2:
	return Rect2(_bpos, bvp)

## Settings > Dynamic lighting was switched: rebuild the art so the cave's crystal lights come or go.
func apply_lighting_setting() -> void:
	if background_layer != null:
		_rebuild_background_marks()

func _refresh_background() -> void:
	set_background(_desired_bg_set())

func _bg_set_complete(set_name: String) -> bool:
	for suf in BG_LAYER_SUFFIX:
		if not ResourceLoader.exists(BG_DIR + set_name + suf):
			return false
	return true

## Switch the background set (e.g. by context: arena -> "colosseum"). Rebuilds the layers.
func set_background(set_name: String) -> void:
	if not BG_SETS.has(set_name) or not _bg_set_complete(set_name):
		set_name = BG_SET_DEFAULT
	if set_name == bg_set and not _bg_nodes.is_empty():
		return
	bg_set = set_name
	if background_layer != null:
		_rebuild_background_marks()

var bg_scroll := 0.0                  # total distance travelled; layers wrap by their own tile width
var _bg_nodes: Array = []             # [{node, speed, tile_w}]

func _set_bg_scroll(v: float) -> void:
	bg_scroll = v
	for e in _bg_nodes:
		if is_instance_valid(e["node"]):
			e["node"].position.x = -fposmod(bg_scroll * float(e["speed"]), float(e["tile_w"]))

func _rebuild_background_marks() -> void:
	for c in background_layer.get_children():
		c.queue_free()
	_bg_nodes.clear()
	var band_bottom: float = bvp.y * (0.60 if wide else 0.58)
	var span: float = bvp.x * 3.0
	var textures: Array = []
	if not _bg_set_complete(bg_set):
		bg_set = BG_SET_DEFAULT
	for suf in BG_LAYER_SUFFIX:
		var t = load(BG_DIR + bg_set + suf)
		if not (t is Texture2D):
			textures.clear()
			break
		textures.append(t)
	if textures.is_empty():
		_rebuild_background_fallback(band_bottom, span)
		return
	var s: float = bvp.y / BG_ART_H   # the forest fills the whole battle area, behind the chrome too
	for i in BG_LAYER_SPEEDS.size():
		var tex: Texture2D = textures[i]
		# whole-pixel tile width, so neighbouring tiles never leave a seam
		var tile_w: int = maxi(1, roundi(float(tex.get_width()) * s))
		var layer := Node2D.new()
		background_layer.add_child(layer)
		if BG_STATIC_SETS.has(bg_set):
			# one picture, never scrolled or tiled; stretched sideways only if the screen is wider than it
			var sx: float = maxf(s, bvp.x / float(tex.get_width()))
			var one := Sprite2D.new()
			one.texture = tex
			one.centered = false
			one.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if s >= 1.0 else CanvasItem.TEXTURE_FILTER_LINEAR
			one.scale = Vector2(sx, s)
			one.position = Vector2((bvp.x - float(tex.get_width()) * sx) / 2.0, 0.0)
			layer.add_child(one)
			_bg_nodes.append({"node": layer, "speed": 0.0, "tile_w": tile_w})
			continue
		var n: int = ceili(span / float(tile_w)) + 3
		for k in n:
			var sp := Sprite2D.new()
			sp.texture = tex
			sp.centered = false
			sp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if s >= 1.0 else CanvasItem.TEXTURE_FILTER_LINEAR
			sp.scale = Vector2(float(tile_w) / float(tex.get_width()), s)
			sp.position = Vector2(-span / 2.0 - tile_w + k * tile_w, 0.0)
			layer.add_child(sp)
		_bg_nodes.append({"node": layer, "speed": float(BG_LAYER_SPEEDS[i]), "tile_w": tile_w})
	_set_bg_scroll(bg_scroll)
	_rebuild_foreground(s)
	if lighting != null:
		lighting.on_background_rebuilt()

## The front trees: a tree at each screen edge when the party is standing, and a queue of
## the next pair waiting off to the right. While the party travels they all slide left
## (BG_FG_SPEED times as fast as the ground, so they parallax past the party): the right
## tree crosses the screen in front of the party and leaves on the left, and the next pair
## arrives and stops at the edges. One transition moves them exactly `_fg_travel`, which
## puts the next pair where the first pair began, so the loop is seamless.
const BG_FG_SPEED := 1.0   # Ian: the front trees move at the same rate as the road (they are so close together)
## How many whole front trees cross the screen in one wave transition.
const BG_FG_TREES := 1
## The front trees are moved down a little so they aren't so close to the
## path: the tree is stretched this many art pixels taller from the top (so
## the canopy stays put and the base drops).
const BG_TREE_STRETCH := 24.0
const BG_FG_GAP := 0.0    # trees are exactly one screen apart; a tree's two halves touch
var foreground_layer: Control
var lighting: Lighting = null   # sun tint, normal-map shading, blob shadows, cave crystal lights (Settings > Dynamic lighting)
var _fg_nodes: Array = []             # [{node, base_x}]
var _fg_travel := 0.0                 # how far the front trees move in one wave transition
var _fg_p := 0.0                      # 0 = standing, 1 = one full transition done

func _rebuild_foreground(s: float) -> void:
	_fg_nodes.clear()
	if foreground_layer == null:
		return
	for c in foreground_layer.get_children():
		c.queue_free()
	_add_overhang(s)
	if BG_STATIC_SETS.has(bg_set):
		_fg_travel = 0.0
		return
	var tex_l = load(BG_DIR + bg_set + "_tree_l.png") if ResourceLoader.exists(BG_DIR + bg_set + "_tree_l.png") else null
	var tex_r = load(BG_DIR + bg_set + "_tree_r.png") if ResourceLoader.exists(BG_DIR + bg_set + "_tree_r.png") else null
	if not (tex_l is Texture2D and tex_r is Texture2D):
		_fg_travel = bvp.x
		return
	# one whole-pixel width for both halves, so a tree's two halves always meet with no gap
	var w: float = float(roundi(float(tex_l.get_width()) * s))
	_fg_travel = bvp.x * (1.0 + BG_FG_GAP) * float(BG_FG_TREES)   # N tree-spacings per transition
	var right_rest: float = bvp.x - w
	# At rest: the right half of one tree at the left edge, the left half of the next at the right
	# edge. Queued behind them are the rest of the trees that will cross during a transition: each
	# tree is a left half and a right half exactly one tree-spacing from the next tree's.
	var spacing: float = bvp.x * (1.0 + BG_FG_GAP)
	var specs: Array = []
	for j in BG_FG_TREES + 1:
		specs.append([tex_r, float(j) * spacing])                       # right half of tree j (its centre at j * spacing)
		specs.append([tex_l, float(j + 1) * spacing - w])               # left half of tree j + 1
	for spec in specs:
		var e := Sprite2D.new()
		e.texture = spec[0]
		e.centered = false
		e.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if s >= 1.0 else CanvasItem.TEXTURE_FILTER_LINEAR
		e.scale = Vector2(w / float(tex_l.get_width()), s * (1.0 + BG_TREE_STRETCH / BG_ART_H))
		foreground_layer.add_child(e)
		_fg_nodes.append({"node": e, "base_x": float(spec[1])})
	_set_fg_progress(_fg_p)

## Cave only: a stalactite overhang across the top of the screen (kept out of the units' band by the art).
func _add_overhang(s: float) -> void:
	var path: String = BG_DIR + bg_set + "_overhang.png"
	if not ResourceLoader.exists(path):
		return
	var tex = load(path)
	if not (tex is Texture2D):
		return
	var e := Sprite2D.new()
	e.texture = tex
	e.centered = false
	e.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if s >= 1.0 else CanvasItem.TEXTURE_FILTER_LINEAR
	e.scale = Vector2(bvp.x / float(tex.get_width()), s)
	foreground_layer.add_child(e)

func _set_fg_progress(p: float) -> void:
	_fg_p = p
	for e in _fg_nodes:
		if is_instance_valid(e["node"]):
			e["node"].position.x = float(e["base_x"]) - p * _fg_travel

func _travel_step(p: float, from_scroll: float, ground_dist: float) -> void:
	_set_bg_scroll(from_scroll + ground_dist * p)
	_set_fg_progress(p)

## Scrolls the whole forest one transition's worth over `duration`, at a steady speed.
func _start_travel(duration: float) -> void:
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_LINEAR)   # Ian: no ease in or out -- the forest moves at one steady speed
	tw.tween_method(_travel_step.bind(bg_scroll, _fg_travel / BG_FG_SPEED), 0.0, 1.0, duration)
	tw.tween_callback(_set_fg_progress.bind(0.0))   # the next pair is now standing exactly where the first began

## The old plain background (gradient sky, a road band, ground marks), used
## only if the forest textures aren't available.
func _rebuild_background_fallback(band_bottom: float, span: float) -> void:
	var sky := Sprite2D.new()
	sky.texture = _get_sky_gradient_texture()
	sky.centered = false
	sky.position = Vector2(-span / 2.0, 0.0)
	sky.scale = Vector2(span, band_bottom) / Vector2(1.0, float(_SKY_GRADIENT_TEX_H))
	background_layer.add_child(sky)

	var road_h: float = bvp.y * 0.02
	var road := ColorRect.new()
	road.color = Palette.BORDER_LEATHER.lerp(Palette.BG_PARCHMENT_DEEP, 0.55)
	road.size = Vector2(span, road_h)
	road.position = Vector2(-span / 2.0, band_bottom - road_h)
	background_layer.add_child(road)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260101   # fixed -- see comment above for why
	var mark_w: float = bvp.x * 0.03
	var mark_h: float = bvp.y * 0.012
	var gap: float = bvp.x * 0.09
	var x: float = -span / 2.0
	while x < span / 2.0:
		var j: float = rng.randf_range(-0.5, 0.5)
		var mark := ColorRect.new()
		mark.color = Palette.BG_PARCHMENT_DEEP.lerp(Palette.BORDER_LEATHER, 0.15 + 0.15 * absf(j))
		mark.size = Vector2(mark_w * (0.75 + 0.5 * (j + 0.5)), mark_h)
		mark.position = Vector2(x, band_bottom - road_h - mark_h * (1.0 + 0.5 * j))
		background_layer.add_child(mark)
		x += gap * (0.8 + 0.4 * (j + 0.5))

## The top strip (currencies and Power) above the battle view. Between waves
## the field itself carries the wave transition (party runs right, next wave's
## enemies run in; see _animate_wave_transition / BattlePresenter.
## run_enemies_entering), so no popup is needed.
##
## There is no wave label here: BattlePresenter's wave-progress row (just above
## its enrage bar) carries the current-wave text. currency_row sits at the top
## (y 0.065), lowered a little so it doesn't run into a phone camera cutout.
## The front trees sit above the units (z_index 1); the HUD text, the wipe fade
## and the reward flyers must stay above the trees.
func _layer_hud_above_trees() -> void:
	# UI elements above all of the art layers: every Control that is a direct
	# child of the game (the HUD, the menu buttons, the Road button...) except
	# the front trees' own layer.
	for n in get_children():
		if n is Control and n != foreground_layer:
			(n as Control).z_index = 2
	# the wide dock sits above the battle's chrome (its turn-order strip runs off the battle column)
	if shell != null and shell.dock_bg != null:
		shell.dock_bg.z_index = 3
	if fade_overlay != null:
		fade_overlay.z_index = 10

func _build_hud() -> void:
	# The currencies are separate cells in a row (not one combined "Aether N
	# Marks N" Label), so an icon can later be put in front of just one
	# currency's text by changing only _build_currency_label (or one cell's
	# build site). Each cell also has its own real screen position, so a reward
	# flyer can fly to the exact currency it is for (see _spawn_reward_drops).
	# Every word sits on a plate (the UI kit): the currency and idle lines get
	# one, since the road behind them is the pale sky.
	hud_plate = Panel.new()
	var plate_style := StyleBoxFlat.new()
	plate_style.bg_color = Color(UiKit.PLATE, 0.93)
	plate_style.set_corner_radius_all(UiKit.RADIUS)
	plate_style.set_border_width_all(1)
	plate_style.border_color = UiKit.SILVER_DIM
	hud_plate.add_theme_stylebox_override("panel", plate_style)
	hud_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_plate)
	_place_hud_plate()
	currency_row = HBoxContainer.new()
	currency_row.position = Vector2(vp.x * 0.02, vp.y * 0.065)
	currency_row.add_theme_constant_override("separation", int(vp.x * 0.022))
	add_child(currency_row)
	aether_cell = _build_currency_label(currency_row)
	marks_cell = _build_currency_label(currency_row)
	# Crystal is the third cell in the same row as Aether / Marks.
	crystal_cell = _build_currency_label(currency_row)

	# Power sits in the same row as the currencies.
	power_level_cell = _build_currency_label(currency_row)

	# The speed toggle, top-right, mirroring currency_row's top-left placement.
	# It toggles Engine.time_scale globally, the simplest way to uniformly speed
	# up every tween and timer already scattered across this codebase (hops,
	# projectiles, beat pauses, wave-transition waits, UI fades) without
	# touching any of their individual duration constants.
	speed_toggle_btn = Button.new()
	speed_toggle_btn.position = Vector2(vp.x * 0.86, vp.y * 0.015)
	speed_toggle_btn.custom_minimum_size = Vector2(vp.x * 0.12, vp.y * 0.035)
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
	fade_overlay.size = vp
	fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_overlay.hide()
	add_child(fade_overlay)

	_build_road_button()

var hud_plate: Panel

func _place_hud_plate() -> void:
	if hud_plate == null:
		return
	hud_plate.position = Vector2(vp.x * 0.01, vp.y * 0.059)
	hud_plate.size = Vector2(vp.x * 0.98, vp.y * 0.036)

func _on_speed_toggle_pressed() -> void:
	_speed_2x = not _speed_2x
	Engine.time_scale = 2.0 if _speed_2x else 1.0
	_refresh_speed_toggle()

func _refresh_speed_toggle() -> void:
	speed_toggle_btn.text = "2x ⏩" if _speed_2x else "1x ⏩"
	speed_toggle_btn.modulate = Palette.GOLD_LIGHT if _speed_2x else Color(1, 1, 1)

func _build_currency_label(parent: Container) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", int(vp.y * 0.0175))
	parent.add_child(lbl)
	return lbl

## Called by SettingsPanel after the player
## confirms the "Reset Game" prompt -- deletes the save file (first use of
## file-deletion anywhere in this codebase, a standard, low-risk Godot API)
## and reloads the scene, cleanly re-entering _ready()'s own existing boot
## gate (no save found -> character creation) rather than hand-rolling a
## manual in-place teardown/rebuild of every panel and timer.
func reset_game() -> void:
	SaveStore.delete_all()   # the backup too, or it would bring the old game back
	get_tree().reload_current_scene()

## The Road button: a screen-wide rectangular button just above the other menu
## buttons, styled distinctly (a gold fill, not the flat grey every tab icon
## uses) so it reads as a different kind of control, not just another tab.
const ROAD_BAR_Y := 0.893   # just below the turn-order frame (ends 0.89)
const ROAD_BAR_H := 0.034   # ends above the tab icons (0.93)

func _build_road_button() -> void:
	road_button = Button.new()
	road_button.text = "Road"
	road_button.position = Vector2(vp.x * 0.02, vp.y * ROAD_BAR_Y)
	road_button.custom_minimum_size = Vector2(vp.x * 0.96, vp.y * ROAD_BAR_H)
	road_button.clip_text = true
	road_button.add_theme_font_size_override("font_size", maxi(10, int(vp.y * ROAD_BAR_H * 0.5)))
	# the kit's primary capsule (bronze), no vertical padding so the bar keeps
	# its slot and doesn't push down over the tab icons
	var bar_h: float = vp.y * ROAD_BAR_H
	var states := {"normal": UiKit.PRIMARY, "hover": UiKit.PRIMARY.lightened(0.05),
		"pressed": UiKit.PRIMARY.darkened(0.25), "disabled": Color(UiKit.PRIMARY, 0.45)}
	for st in states:
		var sb := UiKit.capsule_style(states[st], UiKit.SILVER if st == "hover" else UiKit.SILVER_DIM, bar_h)
		sb.content_margin_top = 0.0
		sb.content_margin_bottom = 0.0
		sb.content_margin_left = 4.0
		sb.content_margin_right = 4.0
		road_button.add_theme_stylebox_override(st, sb)
	road_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for fc in ["font_color", "font_hover_color", "font_pressed_color"]:
		road_button.add_theme_color_override(fc, UiKit.TEXT)
	road_button.add_theme_color_override("font_disabled_color", UiKit.DISABLED_TEXT)
	road_button.pressed.connect(_on_road_pressed)
	add_child(road_button)

func _reflow_road_button() -> void:
	road_button.position = Vector2(vp.x * 0.02, vp.y * ROAD_BAR_Y)
	road_button.custom_minimum_size = Vector2(vp.x * 0.96, vp.y * ROAD_BAR_H)

## A one-time "welcome back" summary, shown right after the HUD is built
## whenever a resumed save had a real offline gap (_offline_summary is
## non-empty; simulate_offline_progress's own 5 s no-op floor already filters
## out a trivial gap, so no further threshold check is needed here). It is a
## separate modal rather than a banner. It uses the same opaque-panel styling
## as every tab panel's _style_popup, with its own border tint (blue, distinct
## from the wave popup's gold and every tab panel's grey) to read as its own
## kind of moment.
func _show_welcome_back_popup() -> void:
	# at start-up the window may still be settling into its final shape
	await get_tree().process_frame
	await get_tree().process_frame
	vp = get_viewport_rect().size
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
		progress_txt = "No checkpoint reached."

	var wipes_gained: int = int(s["wipes_gained"])
	var wipe_txt := ""
	if wipes_gained > 0:
		wipe_txt = "\nWiped %d time%s — back to checkpoint." % [wipes_gained, ("" if wipes_gained == 1 else "s")]

	# Built on _build_detail_overlay: its scroll container has an explicit,
	# content-independent minimum size, so nothing here needs its own margin
	# arithmetic, and sizing is content-driven (capped at vp.y * 0.6, usually far
	# less) and centered by _finish_detail_overlay. This popup fires once at
	# boot / resume, not from inside an already-open tab popup.
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Welcome back!"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = "Away %s.\n%s%s" % [away_txt, progress_txt, wipe_txt]
	body.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	var gained := Label.new()
	gained.text = "+%d Aether, +%d Marks from wave clears" % [roundi(s["aether_gained"]), int(floor(s["marks_gained"]))]
	gained.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	gained.modulate = Palette.GOLD_TEXT
	gained.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(gained)

	await _finish_detail_overlay(o)

## Feedback from the menu: suggestions and bug reports, submitted straight to a
## Google Form (no email app, no keys in the game). The entry ids are the
## form's own question ids.
const FEEDBACK_FORM := "https://docs.google.com/forms/d/e/1FAIpQLSeAe9dcoP59Nfq_dUxY70iEHJ9NUfmjOUg9oeOX5QyoOAtfdA/formResponse"
const FEEDBACK_FIELDS := {"type": "entry.1138442964", "text": "entry.1220989861", "wave": "entry.16782905",
	"power": "entry.1284231246", "party": "entry.804742323", "device": "entry.145143319"}

## The form's fields for a report: the player's text plus the game details.
func _feedback_fields(kind: String, body: String) -> Dictionary:
	var party_names: Array = (g["party"] as Array).map(func(u):
		var d = FarroadCore.roster_by_id(u)
		return d["name"] if d else u)
	return {"type": kind, "text": body,
		"wave": "%d (furthest %d)" % [int(g.get("wave", 1)), int(g.get("farthest", 1))],
		"power": str(FarroadProgression.power_level(g)),
		"party": ", ".join(party_names),
		"device": _device_details()}

## Device type (phone / tablet / desktop), OS and version, model, game version.
func _device_details() -> String:
	var kind := "Desktop"
	if OS.has_feature("mobile"):
		var dpi: float = maxf(1.0, float(DisplayServer.screen_get_dpi()))
		var inches: float = Vector2(DisplayServer.screen_get_size()).length() / dpi
		kind = "Tablet" if inches >= 7.0 else "Phone"
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	return "%s - %s %s - %s - game %s - ID %s" % [kind, OS.get_name(), OS.get_version(), OS.get_model_name(),
		ver if ver != "" else "dev", Analytics.display_id()]

## Posts a report to the form; calls done(ok) when Google answers.
func _submit_feedback(fields: Dictionary, done: Callable) -> void:
	var parts: Array = []
	for k in FEEDBACK_FIELDS:
		parts.append("%s=%s" % [FEEDBACK_FIELDS[k], str(fields.get(k, "")).uri_encode()])
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h, _b):
		http.queue_free()
		done.call(result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 400))
	var err := http.request(FEEDBACK_FORM, ["Content-Type: application/x-www-form-urlencoded"],
		HTTPClient.METHOD_POST, "&".join(parts))
	if err != OK:
		http.queue_free()
		done.call(false)

func show_feedback_popup() -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "Send Feedback"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	var kind := OptionButton.new()
	for k in ["Suggestion", "Bug Report"]:   # the form's own choices
		kind.add_item(k)
	vbox.add_child(kind)
	var text := TextEdit.new()
	text.placeholder_text = "What would you like to tell us? For bugs, what happened and what you expected."
	text.custom_minimum_size = Vector2(0, vp.y * 0.22)
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(text)
	var note := Label.new()
	note.text = "Sent with some game details (wave, power, party, device and your player ID) to help with bugs."
	note.modulate = Palette.TEXT_DIM
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(note)
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(func():
		var body: String = text.text.strip_edges()
		if body == "":
			note.text = "Write something first."
			return
		send.disabled = true
		send.text = "Sending..."
		_submit_feedback(_feedback_fields(kind.get_item_text(kind.selected), body), func(ok: bool):
			if not is_instance_valid(send):
				return
			if ok:
				text.text = ""
				note.text = "Thanks! Your feedback was sent."
				send.text = "Sent"
			else:
				note.text = "Couldn't send -- check your connection and try again."
				send.text = "Send"
				send.disabled = false))
	vbox.add_child(send)
	await _finish_detail_overlay(o)

## A one-time popup shown when the tutorial ends (clearing the wave-20 boss;
## see the "tutorial_complete" event, FarroadProgression.after_wave_cleared). It
## congratulates the player on finishing the tutorial and warns the Road only
## gets harder from here. It is a big milestone announcement, not a small
## in-flow result like _show_quest_result_popup below. It is awaitable, because
## the caller (_on_battle_finished) holds the wave-transition animation until
## the player has read and dismissed it.
func _show_tutorial_complete_popup() -> void:
	# Built on _build_detail_overlay / _finish_detail_overlay. A second top-level
	# Window opened while a tab popup was already open would silently close it
	# the instant it appeared (see the comment on _build_detail_overlay);
	# nesting inside whichever popup is open (or GameController itself when none
	# is) avoids that, and content-driven sizing keeps it compact. It still
	# blocks the caller until dismissed (backdrop.tree_exiting fires from the
	# Close button or a backdrop tap): the win branch that calls this holds the
	# wave-transition animation until the player has read and dismissed it.
	var o := _build_detail_overlay(Palette.GOLD_PRESSED, false, true)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Tutorial complete!"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = "You've beaten the first boss. From here, the Road only gets harder."
	body.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	# Enrage starts at wave 31, so this popup only foreshadows it; the full
	# explanation is its own popup (_show_enrage_intro_popup) right before the
	# first fight it applies to.
	var heads_up := Label.new()
	heads_up.text = "Use the next stretch of the Road to level up and build your party -- something more dangerous is waiting past wave 30."
	heads_up.add_theme_font_size_override("font_size", int(vp.y * 0.022))
	heads_up.modulate = Palette.TEXT_DIM
	heads_up.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(heads_up)

	await _finish_detail_overlay(o)
	if is_instance_valid(o["backdrop"]) and o["backdrop"].is_inside_tree():
		await o["backdrop"].tree_exiting
	# resume a frame later: mid-removal, the next pop-up in a row (Wave 20
	# has several) couldn't be added and the Road waited on it forever
	await get_tree().process_frame

## The enrage explanation, shown on the first clear of wave ENRAGE_FROM_WAVE-1,
## right before the first fight that can actually enrage (the "enrage_intro"
## event, FarroadProgression.after_wave_cleared). It explains the mechanic and
## points at its own bar and label. Same awaited overlay shape as the popup
## above.
func _show_enrage_intro_popup() -> void:
	var o := _build_detail_overlay(Palette.BAD_RED, false, true)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "Enemies can now become ENRAGED"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.035))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var enrage_body := Label.new()
	enrage_body.text = "Enemies that fight for a long time will grow ENRAGED -- hitting harder and moving faster the longer a battle drags on. Keep your fights short."
	enrage_body.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	enrage_body.modulate = Palette.BAD_RED
	enrage_body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(enrage_body)

	var enrage_pointer := Label.new()
	enrage_pointer.text = "Watch the red bar above the turn order -- once it fills, its label shows exactly how much stronger enemies have gotten."
	enrage_pointer.add_theme_font_size_override("font_size", int(vp.y * 0.022))
	enrage_pointer.modulate = Palette.TEXT_DIM
	enrage_pointer.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(enrage_pointer)

	await _finish_detail_overlay(o)
	if is_instance_valid(o["backdrop"]) and o["backdrop"].is_inside_tree():
		await o["backdrop"].tree_exiting
	# resume a frame later: mid-removal, the next pop-up in a row (Wave 20
	# has several) couldn't be added and the Road waited on it forever
	await get_tree().process_frame

## Fires whenever a milestone companion joins (the "boss_companion" event, see
## after_wave_cleared; despite the name it is no longer boss-exclusive): you
## save her from the enemies and she chooses to join you. Same
## awaited-"Got it" shape as _show_tutorial_complete_popup above, with wording
## generic enough for any of the roster companions this can fire for
## (ansa / dorrek / vey / mirel), not just Ansa's wave-10 case.
func _show_companion_joined_popup(uid: String) -> void:
	var def = FarroadCore.roster_by_id(uid)
	var name: String = def["name"] if def != null else uid

	# Built on _build_detail_overlay, like _show_tutorial_complete_popup above.
	var o := _build_detail_overlay(Palette.GOOD_GREEN, false, true)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "%s joins you!" % name
	title.add_theme_font_size_override("font_size", int(vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = "You cut down the last of the danger just in time -- %s was caught in the middle of it. Grateful, and impressed, they choose to join you on the Road." % name
	body.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	await _finish_detail_overlay(o)
	if is_instance_valid(o["backdrop"]) and o["backdrop"].is_inside_tree():
		await o["backdrop"].tree_exiting
	# resume a frame later: mid-removal, the next pop-up in a row (Wave 20
	# has several) couldn't be added and the Road waited on it forever
	await get_tree().process_frame

## Fires on the "tutorial_equip" event (after_wave_cleared, wave 20): the
## player gets a piece of equipment and a popup about equipment and where it
## can be equipped. It is a simple, standalone item description (name, rarity,
## slot, flat stat bonuses) rather than EquipmentPanel's _describe_equipment,
## which needs a specific unit to compute per-unit affinity deltas against;
## this introductory popup has no natural "selected unit".
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

	# Built on _build_detail_overlay, like _show_tutorial_complete_popup above.
	var o := _build_detail_overlay(Palette.GOLD_PRESSED, false, true)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = "New gear: %s!" % item_name
	title.add_theme_font_size_override("font_size", int(vp.y * 0.04))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	# Duplicated small lookup, matching EquipmentPanel.gd's own RARITY_COLOR
	# -- no class_name on that script to reference directly, same small-
	# duplication convention this project already uses for shared-but-not-
	# globally-registered constants.
	var rarity_color: Dictionary = {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}
	var rarity_lbl := Label.new()
	rarity_lbl.text = "%s %s -- %s" % [rarity.capitalize(), slot, stat_line]
	rarity_lbl.add_theme_font_size_override("font_size", int(vp.y * 0.022))
	rarity_lbl.modulate = rarity_color.get(rarity, Palette.TEXT_DIM)
	rarity_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(rarity_lbl)

	var body := Label.new()
	body.text = "Gear gives a unit permanent stat bonuses for as long as it's worn -- head, body, legs, and two hand slots, each unit gearing up independently. Open Units > Gear to equip this on whoever needs it most."
	body.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	await _finish_detail_overlay(o)
	if is_instance_valid(o["backdrop"]) and o["backdrop"].is_inside_tree():
		await o["backdrop"].tree_exiting
	# resume a frame later: mid-removal, the next pop-up in a row (Wave 20
	# has several) couldn't be added and the Road waited on it forever
	await get_tree().process_frame

func show_tab_tutorial_popup(title_text: String, body_text: String) -> void:
	# Built on _build_detail_overlay, like _show_tutorial_complete_popup above.
	# This one matters most: it fires while a tab popup (e.g. Settings') is
	# already open, and a second top-level Window would have closed that popup
	# behind it (see _build_detail_overlay's comment).
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", int(vp.y * 0.035))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)

	var body := Label.new()
	body.text = body_text
	body.add_theme_font_size_override("font_size", int(vp.y * 0.024))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	await _finish_detail_overlay(o)
	if is_instance_valid(o["backdrop"]) and o["backdrop"].is_inside_tree():
		await o["backdrop"].tree_exiting
	# resume a frame later: mid-removal, the next pop-up in a row (Wave 20
	# has several) couldn't be added and the Road waited on it forever
	await get_tree().process_frame

## A popup after completing or failing a quest or dungeon, showing the rewards
## got, similar to the welcome-back popup. It is keyed off a
## FarroadProgression.finish_side_battle event. QuestsPanel's own "show_result"
## card (still called right after this from _resolve_side_battle) is in
## addition to it, not replaced by it.
## What each pull gave, in a box: cards revealed one by one, duplicates
## converting into Lore or Aether in front of you (see PullResults.gd).
func show_pull_results(results: Array) -> void:
	if results.is_empty():
		return
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	vbox_title(o["vbox"], "Pull result" if results.size() == 1 else "%d pulls" % results.size())
	PullResults.build(o["vbox"], results, vp)
	await _finish_detail_overlay(o)

## What an expedition (or all of them, for Collect All) paid: Aether, Marks, and
## every find as a card (duplicates of one item share a card).
func show_expedition_collected(summary: Dictionary) -> void:
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var n: int = int(summary.get("count", 1))
	vbox_title(o["vbox"], "Expedition collected" if n == 1 else "%d expeditions collected" % n)
	var gains: Array = []
	if float(summary.get("aether", 0.0)) > 0.0:
		gains.append("+%d Aether" % roundi(float(summary["aether"])))
	if float(summary.get("marks", 0.0)) > 0.0:
		gains.append("+%d Marks" % roundi(float(summary["marks"])))
	var gain_lbl := Label.new()
	gain_lbl.text = "  ·  ".join(gains) if not gains.is_empty() else "No Aether or Marks this time."
	gain_lbl.add_theme_font_size_override("font_size", 18)
	gain_lbl.add_theme_color_override("font_color", PullResults.AETHER_COL)
	gain_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	o["vbox"].add_child(gain_lbl)
	var finds: Array = summary.get("finds", [])
	if not finds.is_empty():
		PullResults.build(o["vbox"], finds, vp)
	await _finish_detail_overlay(o)

## A sparkly flourish when a unit levels up (called by the Aether screen).
func level_up_fx(uid: String, new_level: int) -> void:
	var def = FarroadCore.roster_by_id(uid)
	var nm: String = def["name"] if def else uid
	LevelUpFx.play(self, vp, Vector2(vp.x * 0.5, vp.y * 0.24), nm, new_level)

func _show_raid_result_popup(event: Dictionary) -> void:
	var o := _build_detail_overlay(Palette.GOLD_PRESSED, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "%s defeated!" % event["name"] if event["defeated"] else "Raid attempt over"
	title.add_theme_font_size_override("font_size", int(vp.y * 0.034))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(title)
	vbox.add_child(_wrap_label("You took %.1f%% of %s's HP this attempt, %.1f%% of the week's total so far." % [float(event["attemptPct"]) * 100.0, event["name"], minf(1.0, float(event["pct"])) * 100.0]))
	var tier: Dictionary = Raids.tier_by_id(str(event["tier"])) if str(event["tier"]) != "" else {}
	vbox.add_child(_wrap_label(("Tier so far: %s." % tier["name"]) if not tier.is_empty() else "Reach 10% of its HP this week for the first reward tier.", true))
	vbox.add_child(_wrap_label("Attempts left today: %d." % int(event["left"]), true))
	await _finish_detail_overlay(o)

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

	# Built on _build_detail_overlay. An auto-sizing vbox with no explicit size
	# budget, combined with a large (vp.y * 0.04) title font, can take more than
	# the one awaited frame to converge on its real layout size; box.size was
	# then read for centering before it reflected the title's true height, so
	# content overflowed past the box's drawn border. _build_detail_overlay's
	# scroll container has an explicit, content-independent minimum size, so it
	# is deterministic from the moment it is created. It still nests inside
	# whatever is open, or falls back to full-screen (via _overlay_host()).
	var o := _build_detail_overlay(border_color)
	var vbox: VBoxContainer = o["vbox"]

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", int(vp.y * 0.04))
	vbox.add_child(title)

	var body := Label.new()
	body.text = body_text
	body.add_theme_font_size_override("font_size", int(vp.y * 0.025))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(body)

	# Quests and dungeons pay Crystal only now (no Aether/Marks).
	var crystal_gained: int = int(event.get("crystal", 0))
	if crystal_gained > 0:
		var gained := Label.new()
		gained.text = "+%d Crystal" % crystal_gained
		gained.add_theme_font_size_override("font_size", int(vp.y * 0.025))
		gained.modulate = Palette.GOLD_TEXT
		vbox.add_child(gained)
	var gear_id: String = str(event.get("gear", ""))
	if gear_id != "" and FarroadCore.EQUIPMENT.has(gear_id):
		var gear := Label.new()
		var item: Dictionary = FarroadCore.EQUIPMENT[gear_id]
		gear.text = "Found gear: %s" % str(item.get("name", gear_id))
		gear.add_theme_font_size_override("font_size", int(vp.y * 0.025))
		gear.add_theme_color_override("font_color", RARITY_COLOR.get(str(item.get("rarity", "common")), UiKit.TEXT))
		vbox.add_child(gear)

	await _finish_detail_overlay(o)

## The Goals window (daily / weekly goals), opened from the Goals button above the Log button.
func open_goals_window() -> void:
	GoalsWindow.open(self)

## Overlay helpers for GoalsWindow (a small centred card on the game's own layer).
func build_overlay_window(on_game: bool = true, full: bool = false) -> Dictionary:
	return _build_detail_overlay(Palette.GOLD_PRESSED, full, on_game)

func finish_overlay_window(o: Dictionary) -> void:
	await _finish_detail_overlay(o)

## A goal's Crystal was claimed: show the new total and save.
func goal_claimed() -> void:
	refresh_hud()
	save_game()

## Updates the dot on the Goals button of whichever battle views exist.
func refresh_goals_badges() -> void:
	for p in [current_presenter, side_presenter]:
		if p != null and is_instance_valid(p):
			p.refresh_goals_badge()

func refresh_hud() -> void:
	aether_cell.text = "Aether %d" % roundi(g["aether"])
	marks_cell.text = "Marks %d" % roundi(g["marks"])
	crystal_cell.text = "Crystal %d" % int(g.get("crystal", 0))
	# the HUD's Power is the fielded party's, on the same scale the quest /
	# dungeon / Arena recommendations use
	power_level_cell.text = "Power %d" % FarroadProgression.party_power(g)
	_live_refresh_menu()

## Gaining Aether (or a level) while a menu is open must update what the menu
## shows (what you can afford, the levels in the unit list) without closing
## and reopening it. Runs whenever the HUD refreshes; only acts when the wallet
## or a level actually changed.
var _wallet_key := ""
var _last_input_ms := 0

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		_last_input_ms = Time.get_ticks_msec()

## Taps inside a menu window never reach _input here, so watch the pointer
## itself: while it is down, the player is interacting.
var _last_win_size := Vector2i.ZERO

func _process(_delta: float) -> void:
	_slice_expeditions()
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_last_input_ms = Time.get_ticks_msec()
	# maximizing or snapping the window changes its size without always raising
	# the signal in time: look every frame and re-apply the scaling when it moved
	var ws: Vector2i = get_window().size
	if ws != _last_win_size:
		_last_win_size = ws
		_apply_desktop_scaling()

## ---- desktop and web windows ----
## On a computer the window can be any shape. Up to a slightly wider portrait
## (DESKTOP_MAX_ASPECT) the layout simply gets the extra width; wider than that
## it stays that shape, centred, with bars at the sides. Phones are untouched.
const DESKTOP_MAX_ASPECT := 0.7

func _apply_desktop_scaling() -> void:
	if OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return
	var win := get_window()
	var aspect: float = float(win.size.x) / maxf(1.0, float(win.size.y))
	var want_aspect: Window.ContentScaleAspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	var want_size := Vector2i(412, 915)
	if aspect >= WIDE_MIN_ASPECT:
		# a landscape window: 1280x720 and as much extra as the window has
		want_size = Vector2i(1280, 720)
		if aspect > 2.2:
			want_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	elif aspect > DESKTOP_MAX_ASPECT:
		want_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
		want_size = Vector2i(roundi(915.0 * DESKTOP_MAX_ASPECT), 915)
	if win.content_scale_aspect != want_aspect:
		win.content_scale_aspect = want_aspect
	if win.content_scale_size != want_size:
		win.content_scale_size = want_size

## ---- wide layout ----
const WIDE_MIN_ASPECT := 1.3

func _is_wide_window() -> bool:
	if OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return false
	var win := get_window()
	return float(win.size.x) / maxf(1.0, float(win.size.y)) >= WIDE_MIN_ASPECT

func _compute_regions() -> void:
	wide = _is_wide_window() and vp.x > vp.y
	if wide:
		var r: Rect2 = load("res://scripts/WideShell.gd").battle_rect(vp)
		_bpos = r.position
		bvp = r.size
	else:
		_bpos = Vector2.ZERO
		bvp = vp

## What the legacy tab panels are told the screen is: in a wide window, a virtual
## screen sized so their usual 0.96 x 0.76 popup comes out as the menu rect.
func _menu_vp() -> Vector2:
	if not wide:
		return vp
	var r: Rect2i = menu_popup_rect()
	return Vector2(r.size.x / 0.96, r.size.y / 0.76)

## Where a tab's menu window opens (the panels call this): the usual spot in
## portrait; in a wide window, centred in the battle column below the ribbon so
## the dock stays visible beside it.
func menu_popup_rect() -> Rect2i:
	if not wide:
		return Rect2i(Vector2i(vp.x * 0.02, vp.y * 0.125), Vector2i(vp.x * 0.96, vp.y * 0.76))
	var w: float = minf(640.0, bvp.x - 24.0)
	var h: float = vp.y - _bpos.y - 24.0
	return Rect2i(Vector2i(int((bvp.x - w) / 2.0), int(_bpos.y + 8.0)), Vector2i(int(w), int(h)))

## Full-screen menus (Units...): everything under the ribbon, dock included.
func full_menu_rect() -> Rect2i:
	var top: float = _bpos.y if wide else vp.y * 0.125
	return Rect2i(Vector2i(0, int(top)), Vector2i(int(vp.x), int(vp.y - top)))

## What the Units sub-pages (Gambits, Aether, Lore, Gear) are told the screen is:
## their usual 0.96-of-width popup should come out as the page area beside the list.
func _units_content_vp() -> Vector2:
	if not wide:
		return vp
	var r: Rect2i = full_menu_rect()
	var w: float = r.size.x - 250.0 - 24.0 - 16.0 - 40.0
	return Vector2(w / 0.96, r.size.y / 0.76)

## Puts the presenter in the battle column (before it is added to the tree).
func _fit_presenter(pr: BattlePresenter) -> void:
	pr.position = _bpos
	pr.region_vp = bvp
	pr.set_wide(wide, 1.45 if wide else 1.0)

func _dock_presenter(pr) -> void:
	if pr == null or not is_instance_valid(pr) or not pr.is_inside_tree():
		return
	if not wide or shell == null:
		pr.undock()
		return
	for other in [current_presenter, side_presenter]:
		if other != null and other != pr and is_instance_valid(other) and other.docked:
			other.undock()
	pr.dock_into(shell.status_host, shell.log_host)

## A panel that sends you into another fight (Quests...) opens in the dock in a
## wide window: its popup's scroll is moved into the dock's page host.
var docked_panel: Node
var _docked_scroll: Control

func dock_open(panel: Node) -> bool:
	if not wide or shell == null or panel.get("popup") == null:
		return false
	dock_close()
	var scroll: Control = null
	for c in panel.popup.get_children():
		if c is ScrollContainer:
			scroll = c
			break
	if scroll == null:
		return false
	docked_panel = panel
	_docked_scroll = scroll
	scroll.set_meta("dock_min", scroll.custom_minimum_size)
	var inner: Control = scroll.get_child(0)
	inner.set_meta("dock_min", inner.custom_minimum_size)
	scroll.reparent(shell.page_host)
	scroll.custom_minimum_size = Vector2.ZERO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(scroll as ScrollContainer).horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner.custom_minimum_size = Vector2.ZERO
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title: String = str(panel.get_script().resource_path.get_file()).replace("Panel.gd", "")
	shell.show_page(title, true)
	if not shell.page_back.pressed.is_connected(_on_road_pressed):
		shell.page_back.pressed.connect(_on_road_pressed)
	return true

func dock_close() -> void:
	if docked_panel == null:
		return
	var panel := docked_panel
	docked_panel = null
	if is_instance_valid(_docked_scroll) and is_instance_valid(panel):
		var inner: Control = _docked_scroll.get_child(0)
		_docked_scroll.reparent(panel.popup)
		panel.popup.move_child(_docked_scroll, 0)
		_docked_scroll.custom_minimum_size = _docked_scroll.get_meta("dock_min")
		inner.custom_minimum_size = inner.get_meta("dock_min")
		(_docked_scroll as ScrollContainer).horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_docked_scroll = null
	if shell != null:
		shell.show_page("", false)
	if is_instance_valid(panel):
		UiKit.set_icon_active(panel.get("toggle_button"), false)

const RIBBON_ICON := 50.0

func _ribbon_buttons() -> Array:
	var out: Array = []
	for pn in [units_panel, party_panel, expedition_panel, quests_panel]:
		out.append(pn.toggle_button)
	out.append(arena_button)
	out.append(shop_panel.toggle_button)
	out.append(settings_panel.toggle_button)
	return out

## Used by the reward flyers, which fly toward a tab's icon.
func _ribbon_icon_for_frac(x_frac: float):
	var b: Array = _ribbon_buttons()
	if x_frac <= UNITS_ICON_X_FRAC + 0.01:
		return b[0]
	if x_frac <= PARTY_ICON_X_FRAC + 0.01:
		return b[1]
	return b[2]

func _layout_wide() -> void:
	if shell == null:
		return
	shell.set_shown(wide)
	if not wide:
		dock_close()
		return
	shell.layout(vp)
	var rh: float = shell.RIBBON_H
	var x := 14.0
	road_button.position = Vector2(x, (rh - 40.0) / 2.0)
	road_button.custom_minimum_size = Vector2(92.0, 40.0)
	road_button.size = Vector2(92.0, 40.0)
	road_button.add_theme_font_size_override("font_size", 17)
	x += 92.0 + 18.0
	for btn in _ribbon_buttons():
		if btn == null or not is_instance_valid(btn):
			continue
		btn.position = Vector2(x, (rh - RIBBON_ICON) / 2.0)
		btn.custom_minimum_size = Vector2(RIBBON_ICON, RIBBON_ICON)
		btn.size = Vector2(RIBBON_ICON, RIBBON_ICON)
		btn.add_theme_font_size_override("font_size", 12)
		x += RIBBON_ICON + 8.0
	x += 16.0
	var plate_w: float = clampf(vp.x - x - 100.0, 200.0, 500.0)
	hud_plate.position = Vector2(x, 6.0)
	hud_plate.size = Vector2(plate_w, rh - 12.0)
	currency_row.position = Vector2(x + 10.0, (rh - 22.0) / 2.0)
	currency_row.add_theme_constant_override("separation", 14)
	for c in [aether_cell, marks_cell, crystal_cell, power_level_cell]:
		c.add_theme_font_size_override("font_size", 14)
	speed_toggle_btn.custom_minimum_size = Vector2(70.0, 34.0)
	speed_toggle_btn.size = Vector2(70.0, 34.0)
	speed_toggle_btn.position = Vector2(vp.x - 84.0, (rh - 34.0) / 2.0)

## ---- keyboard shortcuts (computers) ----
## Esc goes back one level (and out of a menu); Q and E move to the previous and
## next menu. Polled here because a menu is its own window and does not pass
## its key presses up to this node. Never while a tutorial runs, or while a text
## box has the keyboard.
## Key presses arrive from the main window (_unhandled_key_input) and from each
## menu's own window (window_input, hooked up in _start_game).
func _on_shortcut_event(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if OS.has_feature("android") or OS.has_feature("ios") or shell == null:
		return
	var k: int = (event as InputEventKey).keycode
	if k == KEY_ESCAPE or k == KEY_Q or k == KEY_E:
		_shortcut(k)

func _typing() -> bool:
	var wins: Array = [get_viewport()]
	if open_panel != null and is_instance_valid(open_panel) and open_panel.get("popup") != null:
		wins.append(open_panel.popup)
	for w in wins:
		var f = w.gui_get_focus_owner()
		if f is LineEdit or f is TextEdit:
			return true
	return false

func _shortcut(k: int) -> void:
	if tutorial != null and tutorial.active != "":
		return
	var cur: Node = open_panel if open_panel != null and is_instance_valid(open_panel) else docked_panel
	var menu_open: bool = cur != null and (cur.get("popup") != null and (cur.popup.visible or cur == docked_panel))
	var arena_open: bool = shell != null and shell.page_box.visible and cur == null
	if k == KEY_ESCAPE:
		if menu_open and cur != docked_panel:
			_tab_close_or_back(cur)
		elif menu_open or arena_open:
			_on_road_pressed()
		return
	if _typing():
		return
	var btns: Array = _ribbon_buttons()
	var idx := -1
	if arena_open:
		idx = btns.find(arena_button)
	elif menu_open:
		for i in range(btns.size()):
			if btns[i] != null and is_instance_valid(btns[i]) and btns[i].has_meta("ui_active"):
				idx = i
	var n: int = btns.size()
	var step_dir: int = 1 if k == KEY_E else -1
	var nxt: int = (idx + step_dir + n) % n if idx >= 0 else (0 if k == KEY_E else n - 1)
	var target: Button = btns[nxt]
	if target != null and is_instance_valid(target):
		target.pressed.emit()

## F11 or Alt+Enter: full screen on and off (on the web it needs a key press,
## which this is).
func _unhandled_key_input(event: InputEvent) -> void:
	_on_shortcut_event(event)
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k: InputEventKey = event
	if k.keycode == KEY_F11 or (k.keycode == KEY_ENTER and k.alt_pressed):
		var full: bool = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
		get_viewport().set_input_as_handled()

func _wallet_signature() -> String:
	var lv := 0
	for v in (g.get("lvl", {}) as Dictionary).values():
		lv += int(v)
	var lore := 0.0
	for v in (g.get("loreByAction", {}) as Dictionary).values():
		lore += float(v)
	return "%d|%d|%d|%d|%d" % [roundi(g.get("aether", 0.0)), roundi(g.get("marks", 0.0)), int(g.get("crystal", 0)), roundi(lore), lv]

func _live_refresh_menu() -> void:
	var key := _wallet_signature()
	if key == _wallet_key:
		return
	_wallet_key = key
	if open_panel == null or not is_instance_valid(open_panel) or not open_panel.popup.visible:
		return
	_apply_live_refresh.call_deferred(open_panel)

func _apply_live_refresh(panel: Node) -> void:
	if not is_instance_valid(panel) or panel != open_panel or not panel.popup.visible:
		return
	var pop: Window = panel.popup
	if panel == shop_panel and bool(shop_panel.get("_anim_busy")):
		return                                    # a purchase animation is playing
	if panel == units_panel:
		units_panel.refresh_dropdown()     # levels in the list
	# the player's own tap already refreshed what they pressed; only rebuild a
	# menu that changed underneath them (Aether from a wave clear, say), and
	# never while a dropdown is open or a field is being typed in
	if Time.get_ticks_msec() - _last_input_ms < 700:
		return
	for pm in pop.find_children("*", "PopupMenu", true, false):
		if (pm as PopupMenu).visible:
			return
	if pop.gui_get_focus_owner() is LineEdit:
		return
	var scrolls: Array = pop.find_children("*", "ScrollContainer", true, false)
	var saved: Array = scrolls.map(func(sc): return (sc as ScrollContainer).scroll_vertical)
	if panel == units_panel:
		if units_panel.current_sub_tab == "gambits":
			return
		units_panel.refresh_content()
	elif panel == shop_panel:
		shop_panel.refresh()
	else:
		return
	await get_tree().process_frame
	await get_tree().process_frame
	for i in mini(scrolls.size(), saved.size()):
		if is_instance_valid(scrolls[i]):
			(scrolls[i] as ScrollContainer).scroll_vertical = saved[i]

## Selecting a button at the bottom closes all pop-ups and opens the selected
## one (including the road). This is the one place that dismisses everything
## closable: the open tab menu, the Arena, and the battle's Status / Log.
func _close_all_popups() -> void:
	dock_close()
	_close_arena()
	if open_panel != null and is_instance_valid(open_panel):
		_hide_open_panel()
	for p in [current_presenter, side_presenter]:
		if p != null and is_instance_valid(p) and p.has_method("close_popups"):
			p.call("close_popups")

## Hide the open tab menu for good: it must not "go up a level" and reopen
## (e.g. Units' Gambits -> Summary on top of the screen that replaced it,
## like the training setup opened from the Gambits editor's Test button).
func _hide_open_panel() -> void:
	dock_close()
	if open_panel == null or not is_instance_valid(open_panel):
		return
	if open_panel == units_panel:
		units_panel.current_sub_tab = "summary"
	elif open_panel == catalogue_panel:
		catalogue_panel.set_meta("fromMenu", false)
	open_panel.popup.hide()

## Called by every panel at the very start
## of its own open_menu, BEFORE opening its own popup -- closes
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
func panel_opening(panel: Node) -> void:
	# Switching from one menu window straight to another: the old one stays up until
	# the new one has shown, so the Road never flashes between them.
	var old = open_panel
	if wide and old != null and is_instance_valid(old) and old != panel and old.get("popup") != null 			and old.popup.visible and panel.get("popup") != null:
		dock_close()
		_close_arena()
		for p in [current_presenter, side_presenter]:
			if p != null and is_instance_valid(p) and p.has_method("close_popups"):
				p.call("close_popups")
		_hide_replaced_menu.call_deferred(old, panel)
	else:
		_close_all_popups()
	open_panel = panel
	UiKit.set_icon_active(panel.get("toggle_button"), true)
	# A menu screen that is exited and returned to resets to the top. This runs
	# after the panel has rebuilt and shown its content.
	_reset_scrolls.call_deferred(panel)
	_ensure_tab_close_x.call_deferred(panel)

func _hide_replaced_menu(old: Node, new_panel: Node) -> void:
	if not is_instance_valid(old) or old == new_panel:
		return
	if old == units_panel:
		units_panel.current_sub_tab = "summary"
	elif old == catalogue_panel:
		catalogue_panel.set_meta("fromMenu", false)
	old.popup.hide()

## Every tab menu gets the same always-visible top-right ✕ (top_level, so
## the PopupPanel doesn't stretch it and its own scrolling can't move it).
func _ensure_tab_close_x(panel: Node) -> void:
	if not is_instance_valid(panel) or panel.get("popup") == null:
		return
	var pop: PopupPanel = panel.popup
	var x: Button = pop.get_node_or_null("CloseX")
	if x == null:
		x = _make_close_x(func(): _tab_close_or_back(panel))
		x.name = "CloseX"
		x.top_level = true
		pop.add_child(x)
	x.position = Vector2(pop.size.x - x.size.x - 10.0, 10.0)

func _reset_scrolls(panel: Node) -> void:
	if not is_instance_valid(panel) or panel.get("popup") == null:
		return
	await get_tree().process_frame
	for sc in panel.popup.find_children("*", "ScrollContainer", true, false):
		sc.scroll_vertical = 0
		sc.scroll_horizontal = 0

## The Catalogue has no bottom-row icon; it is reached from a "Catalogue"
## button inside SettingsPanel's popup. This re-triggers the Catalogue's own
## open logic (panel_opening + refresh + popup), which already closes
## Settings' own popup via panel_opening.
func open_catalogue() -> void:
	catalogue_panel.set_meta("fromMenu", true)
	catalogue_panel.open_menu()

## Clicking the X or the outside of a page takes you up one level. A menu with
## a level above it (Units on Gambits / Aether / Lore / Gear -> Summary;
## Catalogue opened from the Menu -> the Menu) goes there instead of closing;
## at the top level it closes. Pop-ups inside a menu already close one at a
## time.
func _tab_can_go_back(panel: Node) -> bool:
	if panel == catalogue_panel:
		return catalogue_panel.get_meta("fromMenu", false)
	return panel.has_method("can_go_back") and panel.call("can_go_back")

func _tab_go_back(panel: Node) -> void:
	if panel == catalogue_panel:
		catalogue_panel.set_meta("fromMenu", false)
		if catalogue_panel.popup.visible:
			catalogue_panel.popup.hide()
		settings_panel.open_menu()
	elif panel.has_method("go_back"):
		panel.call("go_back")

## The tab menu's X.
func _tab_close_or_back(panel: Node) -> void:
	# The Units page's X closes the whole page (unlike the other pages, where it
	# goes up a level). It goes back to the summary first, so closing it doesn't
	# make _on_tab_hidden reopen one level up.
	if panel == units_panel:
		units_panel.current_sub_tab = "summary"
		panel.popup.hide()
		return
	if _tab_can_go_back(panel):
		_tab_go_back(panel)
	else:
		if panel == catalogue_panel:
			catalogue_panel.set_meta("fromMenu", false)
		panel.popup.hide()

## A tap outside a menu hides it; if the menu had a level above, reopen
## there instead (unless something else was opened in its place).
func _on_tab_hidden(panel: Node) -> void:
	var back := _tab_can_go_back(panel)
	if back:
		_reopen_one_level_up.call_deferred(panel)

func _reopen_one_level_up(panel: Node) -> void:
	if open_panel != panel or panel.popup.visible:
		return   # another menu took its place, or it's already showing
	if panel == catalogue_panel:
		_tab_go_back(panel)
	else:
		panel.call("open_menu")   # reopens at its top level

const RARITY_COLOR := {"common": Palette.RARITY_COMMON, "rare": Palette.RARITY_RARE, "legendary": Palette.RARITY_LEGENDARY}

## Detail popups are Controls nested inside the popup that is already open,
## not separate Windows. A brand new top-level PopupPanel added to
## GameController would be a sibling Window of whatever tab popup is open
## (e.g. UnitsPanel's), and Godot's embedded-window system only tracks one
## exclusive top-level popup layer at a time: opening the second closes the
## first the instant it appears, which reads as "closing the details closes
## everything". A Control added as a child of the open popup just nests inside
## that same window. _overlay_host() below resolves where to nest into.
## This re-raises every still-open self-hosted overlay (see
## _self_hosted_overlays) to the end of the child list. It is called right
## after any new BattlePresenter / side-battle presenter is added as a
## sibling, so a still-open quest / dungeon result popup keeps drawing on top
## of it instead of falling behind. The order among stacked overlays is
## preserved (each is moved to the end in turn).
func _raise_self_hosted_overlays() -> void:
	for ov in _self_hosted_overlays:
		if is_instance_valid(ov) and ov.get_parent() != null:
			ov.get_parent().move_child(ov, ov.get_parent().get_child_count() - 1)

## A pop-up window that isn't a tab menu (e.g. the battle Log) can host
## detail overlays while it's open.
var overlay_host_override: Window = null

func _overlay_host() -> Array:
	if overlay_host_override != null and is_instance_valid(overlay_host_override) and overlay_host_override.visible:
		return [overlay_host_override, Vector2(overlay_host_override.size)]
	if open_panel != null and is_instance_valid(open_panel) and open_panel.popup.visible:
		return [open_panel.popup, Vector2(open_panel.popup.size)]
	return [self, vp]

## Shared construction for every "on top of the current view" detail
## overlay (action/equipment/enemy) -- builds the dim backdrop + bordered,
## internally-scrollable box, nested inside whichever popup is currently
## open (see _overlay_host's own comment for why this, not a second
## top-level Window). Returns a Dictionary the caller appends its own
## content into (o["vbox"]) and later finishes via _finish_detail_overlay
## (adds the Close button, centers the box once its real size is known).
## Tapping the dim backdrop also dismisses it, same as an explicit Close.
var full_layer: CanvasLayer = null
## `on_game`: shown on the game itself, closing any open menu first -- for
## the between-wave milestone pop-ups the next wave waits on (nested in a
## menu, closing the menu hid them unanswered and the Road never moved on).
func _build_detail_overlay(border_color: Color = Palette.BORDER_LEATHER, full: bool = false, on_game: bool = false) -> Dictionary:
	var hs := _overlay_host()
	var host: Node = hs[0]
	var host_size: Vector2 = hs[1]
	if (full or on_game) and open_panel != null and is_instance_valid(open_panel) and open_panel.popup.visible:
		# a full-size screen takes over the whole view: the menu it was
		# opened from closes, and it hosts on the game itself
		_hide_open_panel()
	if full or on_game or host == self:
		# Anything hosted on the game itself (welcome back, quest results,
		# full-size screens) goes on its own canvas layer: battle effects
		# (trails, halos, lights) are top-level nodes that would otherwise
		# draw over it, and combat keeps running behind pop-ups now.
		if full_layer == null or not is_instance_valid(full_layer):
			full_layer = CanvasLayer.new()
			full_layer.layer = 5
			add_child(full_layer)
		host = full_layer
		host_size = vp

	var backdrop := ColorRect.new()
	backdrop.set_meta("menu_overlay", true)   # cleared when its menu closes
	backdrop.color = Color(0, 0, 0, 0.55)
	backdrop.size = host_size
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(backdrop)
	if host is CanvasLayer:
		backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)   # always the whole screen, whatever its size
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
	if host == full_layer:
		_self_hosted_overlays.append(backdrop)
		backdrop.tree_exiting.connect(func(): _self_hosted_overlays.erase(backdrop))

	var box := UiPanel.new(true)
	(box.get_theme_stylebox("panel") as StyleBoxFlat).set_content_margin_all(int(vp.y * 0.025))
	(box.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = Color(UiKit.PLATE, 1.0)
	backdrop.add_child(box)

	var scroll := ScrollContainer.new()
	# a full-size screen gets a fixed header above its scrolling list
	# (o["header"]) for things that should always stay visible
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	if full:
		var outer := VBoxContainer.new()
		outer.add_theme_constant_override("separation", 8)
		box.add_child(outer)
		outer.add_child(header)
		outer.add_child(scroll)
	# `full`: the box fills nearly the whole host instead of a small card (used
	# for the customization and stats windows).
	var pad: float = vp.y * 0.05
	scroll.custom_minimum_size = (Vector2(host_size.x - pad * 1.2, host_size.y - pad * 2.6) if full
		else Vector2(host_size.x * 0.8, minf(host_size.y * 0.75, vp.y * 0.6)))
	if not full:
		box.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(scroll.custom_minimum_size.x - (16.0 if full else host_size.x * 0.04), 0)
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# Tapping the dim area outside the box also dismisses it (standard
	# modal-overlay convention). box itself stops the click from reaching
	# backdrop's own handler when the tap actually landed inside it.
	# A mouse-wheel scroll is also delivered as an InputEventMouseButton with
	# pressed == true (wheel up / down are just button indices), so once the
	# inner ScrollContainer reached the bottom of its range and stopped
	# consuming wheel events, the same "click" check here matched the wheel
	# event and dismissed the popup. The check is restricted to real mouse
	# buttons (left / right / middle) so a wheel scroll can never match.
	const _DISMISS_BUTTONS := [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]
	backdrop.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index in _DISMISS_BUTTONS:
			backdrop.queue_free())
	box.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index in _DISMISS_BUTTONS:
			get_viewport().set_input_as_handled())

	return {"vbox": vbox, "backdrop": backdrop, "box": box, "host_size": host_size, "header": header, "scroll": scroll}

## A round "✕" close button (shared by every overlay and tab pop-up).
func _make_close_x(on_close: Callable) -> Button:
	var b := Button.new()
	# No text: the ✕ is drawn, so a font's own glyph width or height can never
	# stretch the button into an oval -- it is always exactly d x d.
	b.text = ""
	var d: float = maxf(34.0, _menu_vp().x * 0.085)
	b.custom_minimum_size = Vector2(d, d)
	b.size = b.custom_minimum_size
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.clip_contents = true
	UiKit.round_style(b, d)
	b.draw.connect(func():
		var c := b.size / 2.0
		var r: float = minf(b.size.x, b.size.y) * 0.2
		var col: Color = UiKit.TEXT
		b.draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, 2.5, true)
		b.draw_line(c + Vector2(-r, r), c + Vector2(r, -r), col, 2.5, true))
	b.pressed.connect(on_close)
	return b

func _finish_detail_overlay(o: Dictionary) -> void:
	var backdrop: ColorRect = o["backdrop"]
	# An always-visible X button in the top right. It sits on the backdrop at the
	# box's corner, so scrolling the box's content never moves it.
	var close_btn := _make_close_x(func(): backdrop.queue_free())
	backdrop.add_child(close_btn)
	await get_tree().process_frame
	if not is_instance_valid(backdrop) or not is_instance_valid(o["box"]):
		return   # closed before it was laid out
	var box: PanelContainer = o["box"]
	# Centering uses `backdrop`'s own actual post-layout size, not the `host_size`
	# it was built with. When `host` is a styled PopupPanel (any tab popup already
	# open, the common case since every info icon lives inside one), Godot
	# insets a plain child Control by the panel's StyleBoxFlat content margin
	# (_style_popup's 10 px), so backdrop's real size is smaller than host_size
	# (measured 375x794 actual vs 395x814 intended); centering against host_size
	# put the box 10 px off toward the bottom-right. The actual size is identical
	# to host_size when host has no such inset (GameController itself) and
	# self-correcting when it does.
	# The box is anchored to the centre and grows both ways, so it stays centred
	# whatever size it ends up (on web it could still report size 0 a frame after
	# being built); the close button follows it.
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	var place := func():
		if not is_instance_valid(box) or not is_instance_valid(close_btn):
			return
		box.position = (backdrop.size - box.size) / 2.0
		close_btn.position = box.position + Vector2(box.size.x - close_btn.size.x - 6.0, 6.0)
	place.call()
	box.resized.connect(place)
	backdrop.resized.connect(place)

## A picker overlay with a filter header. A native OptionButton can't embed a
## custom filter control in its own popup, so wherever a filter narrows a list
## of selectable actions / conditions, that OptionButton is replaced with a
## plain trigger Button that opens this overlay. It uses the same backdrop +
## box + scroll construction as _build_detail_overlay (so it nests inside
## whichever popup is open instead of being a second top-level Window), with a
## scrollable `list_container` whose first children are the filter row,
## followed by the selectable rows: one list scrolled together, not a fixed
## toolbar above a separately scrolling area.
##
## `populate(list_container, backdrop)` is called once up front and is expected
## to clear and rebuild `list_container` itself (filter row first, then rows).
## The caller owns its filter state and calls its own `populate` again from
## each filter dropdown's on_change handler to refresh the list in place
## without closing the overlay. Each selectable row's press handler calls
## `backdrop.queue_free()` after applying the pick, closing the overlay the
## same way _finish_detail_overlay's own Close button does.
func show_picker_overlay(title: String, populate: Callable) -> void:
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

## An expedition's full log history in an overlay: sent / heading home /
## arrived, bonus-fight wins and losses ("battle"), and dungeon-unlock notices
## (exp["log"], push_expedition_log, newest first, 40-entry cap). The
## expedition card only shows the single most recent entry inline. It is a
## GameController-owned overlay like the other detail popups, not a second
## top-level Window inside ExpeditionPanel's already-open popup (which Godot
## would silently close; see _overlay_host's comment).
func show_expedition_log_popup(exp: Dictionary) -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var names: String = FarroadProgression.expedition_label(exp)
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
func show_action_detail_popup(action_id: String) -> void:
	if FarroadCore.ACTIONS.get(action_id) == null:
		return
	var o := _build_detail_overlay()
	_fill_action_detail(o["vbox"], action_id)
	await _finish_detail_overlay(o)

## Everything the action-detail card shows, built into any container. The
## popup uses it, and so does the Lore page (which shows the details of the
## selected action).
func _fill_action_detail(vbox: Container, action_id: String) -> void:
	var act = FarroadCore.ACTIONS.get(action_id)
	if act == null:
		return

	var color: Color = RARITY_COLOR.get(act.get("rarity", "common"), Color(1, 1, 1))
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b][color=#%s]%s[/color][/b]" % [color.to_html(false), act["name"]]
	vbox.add_child(title)

	var camp_txt: String = "Magic" if act.get("camp") == "mag" else "Physical"
	var target_txt: String = ActionFilter.target_label(act)
	# "scales with X - power xN" (not the raw rank), the same phrasing
	# LorePanel's action-detail card uses, so both surfaces read consistently.
	var power_lbl := Label.new()
	power_lbl.text = "%s -- target: %s -- %s" % [camp_txt, target_txt, ActionFilter.scales_text(act)]
	power_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	power_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(power_lbl)

	var cost_lbl := Label.new()
	# the action's cost (rank x100, the same "cost" Lore shows): how long until
	# the user's next turn, 100 being a normal action
	var time_txt := "Cost %d%s" % [roundi(float(act["rank"]) * 100.0),
		" (the lowest a cost can go)" if float(act["rank"]) <= FarroadCore.RANK_FLOOR + 0.001 else ""]
	if act.get("isCharge", false):
		cost_lbl.text = "%s  ·  Charge action: uses %d charge" % [time_txt, int(FarroadCore.cost_of_charge(act))]
	else:
		# the charge bit is just "Charge +x", where x is the current amount
		cost_lbl.text = "%s  ·  Charge +%d" % [time_txt, int(act.get("charge", 0))]
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

	# say exactly what buffs and debuffs do: a real, numeric effect line (derived
	# from FarroadCore's own STATUS_BASE_MAG where the status is
	# magnitude-based, so it can never drift out of sync with the engine math),
	# not just the bare status name
	if act.get("applies"):
		var status_id: String = str(act["applies"])
		var applies_lbl := Label.new()
		var turns_txt: String = " for %d turns" % int(act["turns"]) if act.get("turns") else ""
		# the status as this action applies it (rarity and Deepening included)
		applies_lbl.text = "Applies %s%s: %s" % [status_id.capitalize(), turns_txt, _status_description(status_id, FarroadCore.status_potency(act))]
		applies_lbl.modulate = Palette.PARTY_BLUE if FarroadCore.is_buff_status(status_id) else Palette.NOTE_PURPLE
		applies_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		applies_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(applies_lbl)

	for line in ActionFilter.effect_lines(act):
		var fx_lbl := Label.new()
		fx_lbl.text = line
		fx_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		fx_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(fx_lbl)

	# "Used by": a plain Label (never selectable) listing every owned unit
	# holding the action, fielded or benched. Starter actions (strike / ember)
	# are freely shareable, so they are labelled as such rather than listing
	# everyone.
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

	# every Lore upgrade bought on it, not just the ones that change a number
	var stacks: String = FarroadProgression.lore_stacks_text(g, action_id)
	if stacks != "":
		var lore_lbl := Label.new()
		lore_lbl.text = "Lore upgrades: " + stacks
		lore_lbl.modulate = Palette.NOTE_PURPLE
		lore_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		lore_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(lore_lbl)

## The Stats popup (Menu > Stats): furthest wave, wipes, enemies defeated,
## bosses defeated, dungeons found, quests completed (%) and Power Level.
## Everything is derived live from existing save state except enemies defeated
## (g["enemiesDefeated"], a counter bumped by every win path: Road, quests,
## dungeons, expeditions).
## The Arena: fights against server opponents (players and ready-made rivals
## in one list), with a W/L record and rating.
## Weekly Arena season (only shown when the server reports one): the countdown, your fights and tier
## so far, and any finished season's reward waiting to be claimed.
func _add_season_section(box: VBoxContainer, season: Dictionary, rating: int) -> void:
	box.add_child(_section_label("Season %d" % int(season.get("number", 1))))
	var left: float = float(int(season["endsAt"]) - int(Time.get_unix_time_from_system()))
	var fights: int = int(season.get("fights", 0))
	var need: int = int(season.get("minFights", Seasons.MIN_FIGHTS))
	var tier := Seasons.tier_for(rating, 99)
	var line := "Ends in %s. Fights this season: %d of %d to qualify." % [GoalsWindow.eta_text(left), fights, need]
	box.add_child(_wrap_label(line))
	box.add_child(_wrap_label("Tier at this rating: %s (the top %d players finish as Champion). Rewards: Crystals, Marks and Distilled Aether." % [tier["name"], Seasons.TOP_N], true))
	for entry in season.get("pending", []):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var t := Seasons.tier_by_id(str(entry["tier"]))
		var lbl := _wrap_label("Season %d finished: %s (rank %d of %d)" % [int(entry.get("number", 1)), t["name"], int(entry["rank"]), int(entry["of"])])
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		var claim := Button.new()
		claim.text = "Claim"
		UiKit.primary(claim)
		claim.pressed.connect(func():
			claim.disabled = true
			var res := await _ranked().call_api("/season/claim", {"season": int(entry["season"])})
			if res.has("error"):
				claim.disabled = false
				return
			var paid := Seasons.pay(g, str((res["claimed"] as Dictionary)["tier"]))
			save_game()
			refresh_hud()
			claim.text = "+%d Crystal, +%d Marks, +%d Distilled" % [paid["crystal"], paid["marks"], paid["distilled"]])
		row.add_child(claim)
		box.add_child(row)

## The Arena screen's two tabs: Arena (rated fights against other players) and Raids (the weekly boss).
func _arena_tabs(vbox: VBoxContainer, backdrop: Node) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", 6)
	var buttons := {}
	var ctx := {}
	ctx["show"] = func(tab: String):
		for k in buttons.keys():
			(buttons[k] as Button).set_pressed_no_signal(k == tab)
		for c in holder.get_children():
			c.queue_free()
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 6)
		holder.add_child(box)
		if tab == "arena":
			_fill_ranked.call_deferred(box, backdrop)
		else:
			RaidsWindow.build(self, box)
	for entry in [["arena", "Arena"], ["raids", "Raids"]]:
		var tb := Button.new()
		tb.text = entry[1]
		tb.toggle_mode = true
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.pressed.connect(func(): ctx["show"].call(entry[0]))
		row.add_child(tb)
		buttons[entry[0]] = tb
	vbox.add_child(row)
	vbox.add_child(holder)
	# ctx holds a lambda that captures it: break the cycle when the window goes
	backdrop.tree_exited.connect(func(): ctx.clear())
	ctx["show"].call("arena")

func _show_pvp_popup() -> void:
	_close_arena()
	if wide and shell != null:
		_show_arena_in_dock()
		return
	var o := _build_detail_overlay(Palette.PARTY_BLUE, true)
	o["backdrop"].set_meta("arena", true)
	var vbox: VBoxContainer = o["vbox"]
	# the same size as the tab menus (96% x 76%) instead of filling the whole
	# screen
	var arena_m: float = vp.y * 0.025
	var arena_scroll: ScrollContainer = o["scroll"]
	arena_scroll.custom_minimum_size = Vector2(vp.x * 0.96 - arena_m * 2.0, vp.y * 0.76 - arena_m * 2.0 - 8.0)
	arena_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.custom_minimum_size = Vector2(arena_scroll.custom_minimum_size.x - 16.0, 0)
	var title := Label.new()
	title.text = "Arena"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	# Every fight is decided on the PvP server; the ready-made rivals are server
	# opponents in the same list as players.
	_arena_tabs(vbox, o["backdrop"])
	await _finish_detail_overlay(o)

## ===== cloud saves (Ian) =====
var cloud: CloudSave = null
## When the save this session started from was written (0 for a new game).
var _local_saved_at := 0
## A cloud save the player hasn't decided about yet ({remote, further}); empty once they have.
var _cloud_pending: Dictionary = {}

func _start_cloud() -> void:
	if not RankedClient.online():
		return
	cloud = CloudSave.new()
	add_child(cloud)
	cloud.setup(_ranked(), func(): return FarroadSave.serialize(g, int(Time.get_unix_time_from_system())))
	cloud.held = true   # nothing goes up until this device has been compared with the cloud copy
	var catchup_ref := CatchupRef.new()
	add_child(catchup_ref)
	catchup_ref.setup(_ranked())
	# a newer save from another device is offered before this one overwrites it
	var remote: Dictionary = await cloud.fetch()
	while cloud.fetch_failed:
		# can't tell what the cloud holds right now: keep the hold and look again shortly
		await get_tree().create_timer(30.0).timeout
		if not is_instance_valid(cloud):
			return
		remote = await cloud.fetch()
	if not remote.is_empty():
		if int(remote.get("savedAt", 0)) > _local_saved_at + 60:
			_show_cloud_choice(remote)
			return
		if int(remote.get("farthest", 1)) > int(g.get("farthest", 1)):
			# this device is behind the cloud copy (a new or restored game): ask before replacing it
			_show_cloud_choice(remote, true)
			return
	cloud.held = false
	cloud.upload()

func _cloud_line(snap: Dictionary) -> String:
	var when := Time.get_datetime_string_from_unix_time(int(snap.get("savedAt", 0)), true)
	return "Furthest wave %d, %d Aether (saved %s UTC)" % [int(snap.get("farthest", 1)), roundi(float(snap.get("aether", 0))), when]

## Another device saved more recently: use that save, or keep this one (which
## then becomes the cloud copy).
func _show_cloud_choice(remote: Dictionary, further: bool = false) -> void:
	# cloud.held is already on: no upload happens until the player chooses (closing this box doesn't count)
	var o := _build_detail_overlay(Palette.PARTY_BLUE, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var chosen := [false]
	vbox_title(vbox, "Newer save found")
	vbox.add_child(_wrap_label("Your cloud save is further along than the one on this device." if further else "Your cloud save is newer than the one on this device."))
	vbox.add_child(_wrap_label("Cloud: " + _cloud_line(remote)))
	vbox.add_child(_wrap_label("This device: " + _cloud_line(FarroadSave.serialize(g, _local_saved_at)), true))
	var too_new := FarroadSave.is_from_newer_build(remote)
	var use_btn := Button.new()
	if too_new:
		# this build can't read it, and writing it here would replace the local save with something unplayable
		use_btn.text = "Update the game to use this save"
		use_btn.disabled = true
	else:
		use_btn.text = "Use the cloud save"
	use_btn.pressed.connect(func():
		chosen[0] = true
		_load_snapshot(remote))
	vbox.add_child(use_btn)
	var keep_btn := Button.new()
	keep_btn.text = "Keep this device's save"
	var keep_armed := [false]
	keep_btn.pressed.connect(func():
		if too_new and not keep_armed[0]:
			keep_armed[0] = true
			keep_btn.text = "Tap again: replace the newer-version cloud save"
			return
		chosen[0] = true
		cloud.held = false   # the only thing that lifts the hold
		o["backdrop"].queue_free()
		cloud.upload())
	vbox.add_child(keep_btn)
	# closed without choosing (the X, Esc, ...): decide later. The hold stays on for this run (nothing
	# uploads), the choice stays available under Settings > Cloud save, and the next launch asks again.
	_cloud_pending = {"remote": remote, "further": further}
	o["backdrop"].tree_exited.connect(func():
		if chosen[0]:
			_cloud_pending = {})
	await _finish_detail_overlay(o)

## Replaces the save on this device with `snap` and restarts from it.
## Refuses (returns false, writes nothing) a save from a newer build of the game than this one.
func _load_snapshot(snap: Dictionary) -> bool:
	if FarroadSave.is_from_newer_build(snap) or not SaveStore.write(snap):
		return false
	get_tree().reload_current_scene()
	return true

## The recovery code (to carry this game to another device) and the box to
## enter one from another device.
func show_account_popup() -> void:
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var vbox: VBoxContainer = o["vbox"]
	vbox_title(vbox, "Cloud save")
	if not _cloud_pending.is_empty() and cloud != null and is_instance_valid(cloud) and cloud.held:
		vbox.add_child(_wrap_label("Cloud sync is paused: a different save was found in the cloud and nothing has been uploaded. Choose which one to keep, or leave it and you will be asked again next launch."))
		var choose_btn := Button.new()
		choose_btn.text = "Choose which save to keep"
		choose_btn.pressed.connect(func():
			o["backdrop"].queue_free()
			_show_cloud_choice.call_deferred(_cloud_pending["remote"], _cloud_pending["further"]))
		vbox.add_child(choose_btn)
	if not RankedClient.online():
		vbox.add_child(_wrap_label("Cloud saves aren't online yet.", true))
		await _finish_detail_overlay(o)
		return
	if g.get("mc") != null:
		vbox.add_child(_wrap_label("Your game is saved to the cloud automatically. To play it on another device, enter this recovery code there. Keep it private: it's the key to your game."))
		var code := CloudSave.recovery_code()
		var code_box := TextEdit.new()
		code_box.text = code
		code_box.editable = false
		code_box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		code_box.custom_minimum_size = Vector2(0, vp.y * 0.07)
		vbox.add_child(code_box)
		var copy_btn := Button.new()
		copy_btn.text = "Copy recovery code"
		copy_btn.pressed.connect(func():
			copy_text(code)
			copy_btn.text = "Copied!")
		vbox.add_child(copy_btn)
	vbox.add_child(_section_label("Continue a game from another device"))
	vbox.add_child(_wrap_label("Enter that device's recovery code. This replaces the game on this device.", true))
	var entry := LineEdit.new()
	entry.placeholder_text = "Recovery code"
	vbox.add_child(entry)
	var row := HBoxContainer.new()
	var paste_btn := Button.new()
	paste_btn.text = "Paste"
	paste_btn.pressed.connect(func():
		var t := paste_text("Paste your recovery code:")
		if t != "":
			entry.text = t)
	row.add_child(paste_btn)
	var go := Button.new()
	go.text = "Load that game"
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(go)
	vbox.add_child(row)
	var note := _wrap_label("", true)
	vbox.add_child(note)
	go.pressed.connect(func():
		var why := CloudSave.use_recovery_code(entry.text)
		if why != "":
			note.text = why
			return
		go.disabled = true
		note.text = "Loading..."
		var res := await _ranked().call_api("/save/get")
		if res.has("error") or not (res.get("save") is Dictionary):
			var err := str(res.get("error", "offline"))
			note.text = "No cloud save was found for that code." if err in ["no_save", "bad_key"] else RankedClient.explain(err)
			go.disabled = false
			return
		if not _load_snapshot(res["save"]):
			note.text = "That game is from a newer version of Farroad. Update this device first."
			go.disabled = false)
	await _finish_detail_overlay(o)

## ===== ranked PvP (the server decides; the game replays) =====
var ranked_client: RankedClient = null

func _ranked() -> RankedClient:
	if ranked_client == null or not is_instance_valid(ranked_client):
		ranked_client = RankedClient.new()
		add_child(ranked_client)
	return ranked_client

## The Ranked part of the Arena: uploads the fielded party, then shows your
## rating, opponents near it and the leaderboard.
## Arena lists size their columns from this: the dock's width in a wide window.
func _arena_vx() -> float:
	return (360.0 / 0.96) if wide else vp.x

func _fill_ranked(box: VBoxContainer, backdrop: Node) -> void:
	if not RankedClient.online():
		box.add_child(_wrap_label("The Arena isn't online yet.", true))
		return
	var status := _wrap_label("Connecting to the Arena...", true)
	box.add_child(status)
	# the Arena needs the latest released version. The server also turns away any
	# other build, but this says so up front instead of at the first fight
	var newest := await _latest_release_version()
	if not is_instance_valid(box):
		return
	if newest != "" and Updates.is_newer(newest, Updates.current_version()):
		status.text = "Version %s is out. Update the game to use the Arena (you have %s)." % [newest, Updates.current_version()]
		var upd := Button.new()
		upd.text = "See the update"
		UiKit.primary(upd)
		upd.pressed.connect(func(): check_updates(true))
		box.add_child(upd)
		return
	var me_name: String = str(g["mc"].get("name", "Traveler")) if g.get("mc") != null else "Traveler"
	var hello := await _ranked().call_api("/hello", {"name": me_name})
	if not is_instance_valid(box):
		return
	if hello.has("error"):
		status.text = RankedClient.explain(str(hello["error"]))
		return
	# the Arena team comes from the cloud save, so every time the Arena opens the
	# save goes up first (starting cloud saves if they weren't yet)
	if cloud == null:
		cloud = CloudSave.new()
		add_child(cloud)
		cloud.setup(_ranked(), func(): return FarroadSave.serialize(g, int(Time.get_unix_time_from_system())))
	await cloud.upload()
	var up := await _ranked().call_api("/team", {"team": Ranked.team_from_game(g)})
	if not is_instance_valid(box):
		return
	if up.has("error"):
		status.text = RankedClient.explain(str(up["error"]))
		return
	var me: Dictionary = up["me"]
	status.text = "Rating %d  ·  %d won, %d lost" % [int(me["rating"]), int(me["wins"]), int(me["losses"])]
	status.modulate = Color(1, 1, 1)
	box.add_child(_wrap_label("Your team: Power %d" % int(me["power"])))
	box.add_child(_wrap_label("Your fielded party is your Arena team; others fight it while you're away.", true))
	if hello.get("season") is Dictionary:
		_add_season_section(box, hello["season"] as Dictionary, int(me["rating"]))
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var lb_btn := Button.new()
	lb_btn.text = "Leaderboard"
	lb_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb_btn.pressed.connect(_show_leaderboard)
	btn_row.add_child(lb_btn)
	# your last 50 fights, the ones you started and the ones you defended
	var rec_btn := Button.new()
	rec_btn.text = "Records"
	rec_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rec_btn.pressed.connect(_show_records)
	btn_row.add_child(rec_btn)
	box.add_child(btn_row)
	var opp := await _ranked().call_api("/opponents")
	if not is_instance_valid(box):
		return
	box.add_child(_section_label("Opponents"))
	var opp_box := VBoxContainer.new()
	var list: Array = opp.get("opponents", [])
	if list.is_empty():
		box.add_child(_wrap_label(RankedClient.explain(str(opp["error"])) if opp.has("error") else "No opponents yet. Check back soon.", true))
	else:
		box.add_child(ActionFilter.dropdown(OPPONENT_SORTS, _opponent_sort, func(v):
			_opponent_sort = v
			_fill_opponents(opp_box, list, status, backdrop)))
	box.add_child(opp_box)
	_fill_opponents(opp_box, list, status, backdrop)
	var hist: Array = hello.get("history", [])
	if not hist.is_empty():
		box.add_child(_section_label("Recent fights"))
		for h in hist.slice(0, 10):
			var how: String = ("Beat" if h.get("won") else "Lost to") if h.get("attack") else ("Held off" if h.get("won") else "Beaten by")
			box.add_child(_wrap_label("%s %s  (%+d)" % [how, str(h.get("vs", "?")), int(h.get("delta", 0))], true))

## Sort the opponent list.
const OPPONENT_SORTS := [["power_desc", "Highest power"], ["power_asc", "Lowest power"],
	["rating_desc", "Highest rating"], ["rating_asc", "Lowest rating"], ["name_asc", "Name A-Z"], ["name_desc", "Name Z-A"]]
static var _opponent_sort: String = "rating_desc"

func _fill_opponents(opp_box: VBoxContainer, list: Array, status: Label, backdrop: Node) -> void:
	for c in opp_box.get_children():
		c.queue_free()
	var sorted: Array = list.duplicate()
	sorted.sort_custom(func(a, b):
		match _opponent_sort:
			"power_desc": return int(a["power"]) > int(b["power"])
			"power_asc": return int(a["power"]) < int(b["power"])
			"rating_asc": return int(a["rating"]) < int(b["rating"])
			"name_asc": return str(a["name"]).to_lower() < str(b["name"]).to_lower()
			"name_desc": return str(a["name"]).to_lower() > str(b["name"]).to_lower()
		return int(a["rating"]) > int(b["rating"]))
	for i in sorted.size():
		var p: Dictionary = sorted[i]
		# a line between teams; the name with its Fight button, and Rating and
		# Power in columns on the line below
		if i > 0:
			opp_box.add_child(HSeparator.new())
		var row := HBoxContainer.new()
		var lbl := _wrap_label(str(p["name"]))
		row.add_child(lbl)
		var go := Button.new()
		go.text = "Fight"
		go.disabled = g.get("sideBattle") != null
		go.pressed.connect(func():
			go.disabled = true
			go.text = "..."
			var res := await _ranked().call_api("/fight", {"opponent": str(p["id"])})
			if res.has("error"):
				go.text = "Fight"
				go.disabled = false
				status.text = RankedClient.explain(str(res["error"]))
				return
			if is_instance_valid(backdrop):
				backdrop.queue_free()
			_start_ranked(res))
		row.add_child(go)
		opp_box.add_child(row)
		var stats := GridContainer.new()
		stats.columns = 2
		stats.add_theme_constant_override("h_separation", int(_arena_vx() * 0.06))
		for txt in ["Rating %d" % int(p["rating"]), "Power %d" % int(p["power"])]:
			var c := Label.new()
			c.text = txt
			c.modulate = Palette.TEXT_DIM
			c.custom_minimum_size = Vector2(_arena_vx() * 0.3, 0)
			stats.add_child(c)
		opp_box.add_child(stats)

## Your 50 most recent Arena fights, newest first: when, who, whether you
## attacked or defended, the result and the rating change.
func _show_records() -> void:
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	vbox_title(o["vbox"], "Records")
	var wait := _wrap_label("Loading...", true)
	o["vbox"].add_child(wait)
	_finish_detail_overlay(o)
	var me_name: String = str(g["mc"].get("name", "Traveler")) if g.get("mc") != null else "Traveler"
	var res := await _ranked().call_api("/hello", {"name": me_name})
	if not is_instance_valid(wait):
		return
	if res.has("error"):
		wait.text = RankedClient.explain(str(res["error"]))
		return
	var hist: Array = res.get("history", [])
	if hist.is_empty():
		wait.text = "No Arena fights yet."
		return
	wait.queue_free()
	var att := hist.filter(func(h): return h.get("attack"))
	var dfn := hist.filter(func(h): return not h.get("attack"))
	o["vbox"].add_child(_wrap_label("Offense: %d won, %d lost" % [
		att.filter(func(h): return h.get("won")).size(), att.filter(func(h): return not h.get("won")).size()], true))
	o["vbox"].add_child(_wrap_label("Defense: %d won, %d lost" % [
		dfn.filter(func(h): return h.get("won")).size(), dfn.filter(func(h): return not h.get("won")).size()], true))
	# Each fight is on two lines, in three columns: the opponent with Won/Lost
	# (green/red) under it; their Power with your rating change under it;
	# Offense/Defense with how long ago under it. A line between fights.
	# No sideways scrolling: the three columns share the window's own width (less
	# the gaps between them), and the window never scrolls sideways.
	var rec_scroll: ScrollContainer = o["scroll"]
	rec_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var avail: float = float(o["vbox"].custom_minimum_size.x) - _arena_vx() * 0.03 * 2.0 - 4.0
	var col_w: Array = [avail * 0.42, avail * 0.29, avail * 0.29]
	var cell := func(grid: GridContainer, text: String, col: int, dim: bool, color = null) -> void:
		var l := Label.new()
		l.text = text
		l.clip_text = true
		l.custom_minimum_size = Vector2(col_w[col], 0)
		if dim:
			l.modulate = Palette.TEXT_DIM
		if color != null:
			l.add_theme_color_override("font_color", color)
		grid.add_child(l)
	var list := hist.slice(0, 50)
	for i in list.size():
		var h: Dictionary = list[i]
		if i > 0:
			o["vbox"].add_child(HSeparator.new())
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", int(_arena_vx() * 0.03))
		grid.add_theme_constant_override("v_separation", 2)
		var won: bool = bool(h.get("won"))
		# line 1: opponent, their Power, when; line 2: Won/Lost with Offense/Defense
		# beside it, then the rating change
		cell.call(grid, str(h.get("vs", "?")), 0, false)
		cell.call(grid, ("Power %d" % int(h["power"])) if h.get("power") != null else "Power —", 1, false)
		cell.call(grid, _ago(int(h.get("at", 0))), 2, true)
		cell.call(grid, "Won" if won else "Lost", 0, false, Palette.GOOD_GREEN if won else Palette.BAD_RED)
		cell.call(grid, "Offense" if h.get("attack") else "Defense", 1, false)
		cell.call(grid, "Rating %+d" % int(h.get("delta", 0)), 2, true)
		o["vbox"].add_child(grid)

func _show_leaderboard() -> void:
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	vbox_title(o["vbox"], "Leaderboard")
	var wait := _wrap_label("Loading...", true)
	o["vbox"].add_child(wait)
	_finish_detail_overlay(o)
	var res := await _ranked().call_api("/leaderboard")
	if not is_instance_valid(wait):
		return
	if res.has("error"):
		wait.text = RankedClient.explain(str(res["error"]))
		return
	wait.queue_free()
	var top: Array = res.get("top", [])
	(o["scroll"] as ScrollContainer).horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# the rank number sits left of the name, the rating to the right of it (wins
	# and losses between them, small), so a row reads left to right
	var me_name: String = str(g["mc"].get("name", "")) if g.get("mc") != null else ""
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", int(_arena_vx() * 0.025))
	grid.add_theme_constant_override("v_separation", 6)
	var rank_colors := [Color("f2c94c"), Color("cfd6dc"), Color("d08a52")]
	var cell := func(text: String, align: int, expand: bool, color: Color, min_w: float) -> void:
		var l := Label.new()
		l.text = text
		l.clip_text = true
		l.horizontal_alignment = align
		if expand:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if min_w > 0.0:
			l.custom_minimum_size.x = min_w
		l.add_theme_color_override("font_color", color)
		grid.add_child(l)
	var dim: Color = UiKit.TEXT_DIM
	cell.call("#", HORIZONTAL_ALIGNMENT_LEFT, false, dim, _arena_vx() * 0.07)
	cell.call("Name", HORIZONTAL_ALIGNMENT_LEFT, true, dim, 0.0)
	cell.call("W–L", HORIZONTAL_ALIGNMENT_RIGHT, false, dim, _arena_vx() * 0.16)
	cell.call("Rating", HORIZONTAL_ALIGNMENT_RIGHT, false, dim, _arena_vx() * 0.14)
	for i in top.size():
		var p: Dictionary = top[i]
		var mine: bool = me_name != "" and str(p["name"]) == me_name
		var name_col: Color = UiKit.BAND.lightened(0.25) if mine else UiKit.TEXT
		var rank_col: Color = rank_colors[i] if i < 3 else UiKit.TEXT_DIM
		cell.call(str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, false, rank_col, _arena_vx() * 0.07)
		cell.call(str(p["name"]), HORIZONTAL_ALIGNMENT_LEFT, true, name_col, 0.0)
		cell.call("%d–%d" % [int(p["wins"]), int(p["losses"])], HORIZONTAL_ALIGNMENT_RIGHT, false, dim, _arena_vx() * 0.16)
		cell.call(str(int(p["rating"])), HORIZONTAL_ALIGNMENT_RIGHT, false, name_col, _arena_vx() * 0.14)
	o["vbox"].add_child(grid)

## Plays back a fight the server just decided: the same two teams and seed
## through the same engine, so it ends the way the server said.
func _start_ranked(res: Dictionary) -> void:
	if g.get("sideBattle") != null:
		return
	_hide_open_panel()
	Goals.record(g, "arena_fight")
	if bool(res["won"]):
		Goals.record(g, "arena_win")
	var battle := Ranked.build_battle(res["me"], res["them"], int(res["seed"]))
	var them_name: String = str(res.get("themName", "Rival"))
	_enter_side_battle([], Ranked.fight_wave(res["me"], res["them"]), {"kind": "pvp", "ranked": true, "owner": them_name,
		"power": Ranked.power_of(res["them"]), "team": them_name + "'s team", "rival": "",
		"serverWon": bool(res["won"]), "serverTurns": int(res.get("turns", 0)),
		"rating": int(res.get("rating", 0)), "delta": int(res.get("delta", 0))}, battle)

## The Arena has its own bottom-row button.
var arena_button: Button

func _build_arena_button() -> void:
	if arena_button != null and is_instance_valid(arena_button):
		arena_button.queue_free()
	var mv: Vector2 = _menu_vp()
	arena_button = UiKit.icon_tab(self, Vector2(mv.x * 0.5838, mv.y * 0.93), mv.x * 0.11, "Arena", _show_pvp_popup)

## Wide window: the Arena's opponent list sits in the dock beside the fight.
func _show_arena_in_dock() -> void:
	_close_all_popups()
	open_panel = null
	var scroll := ScrollContainer.new()
	scroll.set_meta("arena", true)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)
	_arena_tabs(vbox, scroll)
	shell.page_host.add_child(scroll)
	shell.show_page("Arena", true)
	if not shell.page_back.pressed.is_connected(_on_road_pressed):
		shell.page_back.pressed.connect(_on_road_pressed)
	scroll.tree_exited.connect(_arena_page_gone)

func _arena_page_gone() -> void:
	if shell == null or docked_panel != null:
		return
	for c in shell.page_host.get_children():
		if c.has_meta("arena") and not c.is_queued_for_deletion():
			return
	shell.show_page("", false)

## Closes the Arena screen (another menu or the Road was tapped).
func _close_arena() -> void:
	if shell != null:
		for c in shell.page_host.get_children():
			if c.has_meta("arena"):
				c.queue_free()
	if full_layer == null or not is_instance_valid(full_layer):
		return
	for c in full_layer.get_children():
		if c.has_meta("arena"):
			c.queue_free()

func _wrap_label(text: String, dim: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if dim:
		l.modulate = Palette.TEXT_DIM
	return l

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	return l

## Menu > Tutorials lists each tutorial: done, waiting to start, or the wave
## that opens it.
const TUTORIAL_NAMES := {"road": "The Road", "units": "Units", "gambits": "Gambits", "quests": "Quests",
	"lore": "Lore", "marks": "Marks", "shop": "Shop", "party": "Party", "gear": "Gear", "expedition": "Expedition"}

func show_tutorials_popup() -> void:
	var o := _build_detail_overlay(Palette.PARTY_BLUE)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "Tutorials"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	var due: Dictionary = tutorial.due() if tutorial != null else {}
	for t in Tutorial.TUTS:
		var id: String = t["id"]
		var status: String
		if Tutorial.is_done(g, id):
			status = "Done"
		elif tutorial != null and tutorial.active == id:
			status = "In progress"
		elif not due.is_empty() and due["id"] == id:
			status = "Ready -- starts when you close the menus"
		elif int(g.get("farthest", 1)) > int(t["wave"]):
			status = "Ready -- up next"
		else:
			status = "After wave %d" % int(t["wave"]) if int(t["wave"]) > 0 else "At the start"
		var row := HBoxContainer.new()
		row.add_child(_wrap_label("%s: %s" % [TUTORIAL_NAMES.get(id, id), status], Tutorial.is_done(g, id)))
		if Tutorial.is_done(g, id):   # Ian: repeatable from here, no rewards
			var again := Button.new()
			again.text = "Replay"
			again.pressed.connect(func():
				o["backdrop"].queue_free()
				_hide_open_panel()
				await get_tree().process_frame
				if not tutorial.start_replay(id):
					tutorial.show_toast("Can't replay during a fight.", road_button))
			row.add_child(again)
		vbox.add_child(row)
	if g.get("tutorialSkip", false):
		vbox.add_child(_wrap_label("Tutorials are skipped; their rewards arrive at their waves.", true))
	await _finish_detail_overlay(o)

## Whether a PvP fight is on (menus that change units are locked meanwhile).
func pvp_running() -> bool:
	var sb = g.get("sideBattle")
	return sb != null and str((sb as Dictionary).get("meta", {}).get("kind", "")) == "pvp"

## Starts a PvP fight: the player's fielded party at full HP against the
## rival team, run like a quest fight (Road paused and hidden meanwhile).
func _start_pvp(team: Dictionary) -> void:
	if g.get("sideBattle") != null:
		return
	_hide_open_panel()
	var enemies := PvP.build_opponent(g, team)
	_enter_side_battle(enemies, int(g.get("wave", 1)), {"kind": "pvp", "owner": str(team.get("owner", "?")),
		"power": int(team.get("power", 0)), "team": str(team.get("team", "")), "rival": str(team.get("rival", ""))})
	if pvp_skip_btn != null and is_instance_valid(pvp_skip_btn):
		pvp_skip_btn.queue_free()
	pvp_skip_btn = Button.new()
	pvp_skip_btn.text = "Skip fight ⏭"
	pvp_skip_btn.position = Vector2(vp.x * 0.56, vp.y * 0.015)
	pvp_skip_btn.custom_minimum_size = Vector2(vp.x * 0.28, vp.y * 0.035)
	pvp_skip_btn.pressed.connect(_skip_pvp)
	add_child(pvp_skip_btn)

## PvP fights can be skipped: the rest of the fight is worked out at once (same
## engine, same rules) and the result shown.
var pvp_skip_btn: Button

func _skip_pvp() -> void:
	if not pvp_running():
		return
	Analytics.add("features", "pvpSkip")
	if side_presenter != null and is_instance_valid(side_presenter):
		side_presenter.battle_finished.disconnect(_on_side_battle_finished)
		side_presenter.queue_free()
		side_presenter = null
	var b: Dictionary = g["battle"]
	var n := 0
	while b["over"] == null and n < 20000:
		if FarroadCore.step(b) == null:
			break
		n += 1
	_resolve_side_battle("party" if b["over"] == "party" else "enemy", false)

## The result, with a brag to copy that carries the player's own code so the
## rival can fight back.
func _show_pvp_result_popup(event: Dictionary) -> void:
	var won: bool = event["kind"] == "pvp_won"
	var o := _build_detail_overlay(Palette.GOOD_GREEN if won else Palette.BAD_RED, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.text = "Victory!" if won else "Defeat"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)
	var verb := "beat" if won else "lost to"
	var foe_name: String = event["team"] if str(event.get("team", "")) != "" else event["owner"] + "'s team"
	vbox.add_child(_wrap_label("You %s %s (Power %d) in %d turns." % [verb, foe_name, int(event["power"]), int(event["turns"])]))
	if event.get("ranked", false):
		vbox.add_child(_wrap_label("Rating %d (%+d)" % [int(event["rating"]), int(event["delta"])]))
		if event.get("replayDiffered", false):
			vbox.add_child(_wrap_label("(The replay on this device ended differently; the server's result counts.)", true))
		await _finish_detail_overlay(o)
		return
	var rec: Dictionary = g.get("pvp", {})
	vbox.add_child(_wrap_label("Record: %d won, %d lost" % [int(rec.get("wins", 0)), int(rec.get("losses", 0))], true))
	var me = FarroadCore.roster_by_id("kesh")
	var brag := "%s %s %s (Power %d) with a Power %d team in %d turns in Farroad! Think you can beat mine? %s" % [
		me["name"] if me else "I", "beat" if won else "lost to", foe_name, int(event["power"]),
		FarroadProgression.party_power(g), int(event["turns"]), PvP.export_code(g)]
	var copy_btn := Button.new()
	copy_btn.text = "Copy result to share" if won else "Copy result and my team code"
	copy_btn.pressed.connect(func():
		copy_text(brag)
		copy_btn.text = "Copied!")
	vbox.add_child(copy_btn)
	await _finish_detail_overlay(o)

## Copy / paste in the browser: the game can't read the system clipboard there.
## On web, copying uses the browser's clipboard (falling back to a box with the
## text selected), and pasting opens the browser's own prompt to paste into.
static func copy_text(text: String) -> void:
	DisplayServer.clipboard_set(text)
	if OS.has_feature("web"):
		var js := "(function(t){ var fb = function(){ window.prompt('Copy this (Ctrl+C, or long-press then Copy):', t); };" \
			+ " if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(t).catch(fb); } else { fb(); } })(%s);"
		JavaScriptBridge.eval(js % JSON.stringify(text), true)

## The pasted text, or "" if cancelled.
static func paste_text(prompt: String) -> String:
	if OS.has_feature("web"):
		var r = JavaScriptBridge.eval("window.prompt(%s, '') || ''" % JSON.stringify(prompt), true)
		return str(r) if r != null else ""
	return DisplayServer.clipboard_get()

## ===== Wipes (Ian) =====
## The last WIPE_LOG_MAX waves that wiped the party, newest first: the wave,
## when, the party, and the enemies as they were when the fight began.
const WIPE_LOG_MAX := 10

func _record_wipe() -> void:
	var enemies: Array = []
	if current_presenter != null and is_instance_valid(current_presenter) and current_presenter.has_meta("enemySnap"):
		enemies = current_presenter.get_meta("enemySnap")
	var party: Array = []
	for uid in g.get("party", []):
		var d = FarroadCore.roster_by_id(uid)
		party.append({"id": uid, "name": d["name"] if d else uid, "lvl": FarroadProgression.level_of(g, uid)})
	var log: Array = g.get("wipeLog", [])
	log.push_front({"wave": int(g.get("wave", 1)), "at": int(Time.get_unix_time_from_system()), "party": party, "enemies": enemies})
	g["wipeLog"] = log.slice(0, WIPE_LOG_MAX)

func _ago(ts: int) -> String:
	var s: int = maxi(0, int(Time.get_unix_time_from_system()) - ts)
	if s < 60: return "just now"
	if s < 3600: return "%dm ago" % (s / 60)
	if s < 86400: return "%dh ago" % (s / 3600)
	return "%dd ago" % (s / 86400)

## Level 1: the list of wipes. Each opens level 2 on top; tapping outside
## or the X on any level closes just that level.
func show_wipes_popup(host: Window = null) -> void:
	overlay_host_override = host
	var o := _build_detail_overlay()
	vbox_title(o["vbox"], "Recent wipes")
	var log: Array = g.get("wipeLog", [])
	if log.is_empty():
		o["vbox"].add_child(_wrap_label("No wipes yet.", true))
	for w in log:
		var b := Button.new()
		var names: Array = (w.get("party", []) as Array).map(func(p): return "%s %d" % [p["name"], int(p["lvl"])])
		b.text = "Wave %d  ·  %s  ·  %d foes" % [int(w["wave"]), _ago(int(w["at"])), (w.get("enemies", []) as Array).size()]
		b.tooltip_text = "Party: " + ", ".join(names)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(_show_wipe_wave.bind(w))
		o["vbox"].add_child(b)
	await _finish_detail_overlay(o)

func vbox_title(vbox: VBoxContainer, text: String) -> void:
	var t := Label.new()
	t.text = text
	t.add_theme_font_size_override("font_size", 18)
	vbox.add_child(t)

## Level 2: the enemies in that wave.
func _show_wipe_wave(w: Dictionary) -> void:
	var o := _build_detail_overlay()
	vbox_title(o["vbox"], "Wave %d" % int(w["wave"]))
	var names: Array = (w.get("party", []) as Array).map(func(p): return "%s (Lv %d)" % [p["name"], int(p["lvl"])])
	o["vbox"].add_child(_wrap_label("Your party: " + ", ".join(names), true))
	for e in w.get("enemies", []):
		var b := Button.new()
		var st: Dictionary = e["stats"]
		var elv: int = roundi(FarroadCore.level_curve(float(w["wave"])))
		b.text = "%s%s  ·  Lv %d" % [e["name"], "  (boss)" if e.get("isBoss", false) else "", elv]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(_show_wipe_enemy.bind(e, int(w["wave"])))
		o["vbox"].add_child(b)
	await _finish_detail_overlay(o)

## Level 3: one enemy's stats, as it was when the fight began.
func _show_wipe_enemy(e: Dictionary, wave: int) -> void:
	var o := _build_detail_overlay(Palette.ENEMY_RED)
	var vbox: VBoxContainer = o["vbox"]
	vbox_title(vbox, "%s%s" % [e["name"], " (boss)" if e.get("isBoss", false) else ""])
	var st: Dictionary = e["stats"]
	vbox.add_child(_wrap_label("Wave %d  ·  %s row" % [wave, str(e.get("row", "front"))], true))
	vbox.add_child(_wrap_label("HP %d   ATK %d   MAG %d" % [int(st["hp"]), int(st["atk"]), int(st["mag"])]))
	vbox.add_child(_wrap_label("DEF %d   RES %d   SPD %d" % [int(st["def"]), int(st["res"]), int(st["spd"])]))
	vbox.add_child(_wrap_label("Crit %d%% / %d%% magic   Evade %d%%" % [roundi(float(st["atkCrit"]) * 100.0),
		roundi(float(st["magCrit"]) * 100.0), roundi(float(st["evade"]) * 100.0)]))
	var aff: Array = []
	for ax in (e.get("affinity", {}) as Dictionary).keys():
		var v := float(e["affinity"][ax])
		if v != 0.0:
			aff.append("%s %+d%%" % [str(ax).capitalize(), roundi(FarroadCore.affinity_mul(v) * 100.0)])
	vbox.add_child(_wrap_label("Affinities: " + (", ".join(aff) if not aff.is_empty() else "none"), true))
	# the enemy's actions can be inspected from here
	vbox.add_child(_wrap_label("Actions (tap to inspect):", true))
	var act_row := HFlowContainer.new()
	act_row.add_theme_constant_override("h_separation", 6)
	act_row.add_theme_constant_override("v_separation", 4)
	var seen_ids: Array = []
	for s in e.get("slots", []):
		var aid_s: String = str(s["action"])
		if FarroadCore.ACTIONS.has(aid_s) and not seen_ids.has(aid_s):
			seen_ids.append(aid_s)
	if e.get("chargeAction") and FarroadCore.ACTIONS.has(e["chargeAction"]) and not seen_ids.has(e["chargeAction"]):
		seen_ids.append(e["chargeAction"])
	for aid_s in seen_ids:
		var ab := Button.new()
		ab.text = ("⚡ " if FarroadCore.ACTIONS[aid_s].get("isCharge", false) else "") + str(FarroadCore.ACTIONS[aid_s]["name"])
		ab.pressed.connect(show_action_detail_popup.bind(aid_s))
		act_row.add_child(ab)
	vbox.add_child(act_row)
	if float(e.get("thorns", 0.0)) > 0.0:
		vbox.add_child(_wrap_label("Thorns: reflects %d%% of max HP when hit" % roundi(float(e["thorns"]) * 100.0), true))
	await _finish_detail_overlay(o)

func show_stats_popup() -> void:
	var o := _build_detail_overlay(Palette.BORDER_LEATHER, true)
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
		["Gear pieces", str(equip_pieces)],
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

## The Inventory popup (a button in Settings): the same small overlay every
## other detail popup uses (it nests inside Settings' already-open popup via
## _overlay_host).
func show_inventory_popup() -> void:
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

## A LineEdit + Save button inside the shared overlay, for renaming the main
## character. FarroadProgression.set_mc_name already patches g["mc"], the
## roster template and any matching live g["units"] entry; this also pushes the
## rename onto whichever BattlePresenter(s) are on screen right now (the Road
## and/or a side battle), so it shows immediately, not just next wave.
func show_change_name_popup() -> void:
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
		if NameFilter.is_blocked(sanitized):
			name_edit.text = ""
			name_edit.placeholder_text = NameFilter.MESSAGE
			return
		if sanitized != "":
			var old_name: String = str(g["mc"].get("name", ""))
			FarroadProgression.set_mc_name(g, sanitized)
			if current_presenter != null:
				current_presenter.sync_mc_name(old_name, sanitized)
			if side_presenter != null:
				side_presenter.sync_mc_name(old_name, sanitized)
			save_game()
		o["backdrop"].queue_free())
	vbox.add_child(save_btn)

	await _finish_detail_overlay(o)

## Customization of the main character: male / female, plus colours for skin,
## hair, eyes, top, bottoms and shoes (presets and RGB sliders). It is the
## main character's one full-size customise screen (name, body, colours).
## Changes apply live, in battle too, and save straight away.
func show_change_body_popup() -> void:
	if g.get("mc") == null:
		return
	var o := _build_detail_overlay(Palette.BORDER_LEATHER, true)
	var vbox: VBoxContainer = o["vbox"]
	# the name and character sprite are always visible at the top: both live in
	# the fixed header; body and colours scroll below them
	var header: VBoxContainer = o["header"]
	var title := Label.new()
	title.text = "Customize"
	title.add_theme_font_size_override("font_size", 18)
	header.add_child(title)

	# ---- name
	var name_row := HBoxContainer.new()
	header.add_child(name_row)
	var name_edit := LineEdit.new()
	name_edit.max_length = 20
	name_edit.text = str(g["mc"].get("name", ""))
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	var save_name := Button.new()
	save_name.text = "Rename"
	save_name.pressed.connect(func():
		var sanitized := _sanitize_mc_name(name_edit.text)
		if NameFilter.is_blocked(sanitized):
			name_edit.text = ""
			name_edit.placeholder_text = NameFilter.MESSAGE
			return
		if sanitized == "":
			return
		var old_name: String = str(g["mc"].get("name", ""))
		FarroadProgression.set_mc_name(g, sanitized)
		name_edit.text = sanitized
		for p in [current_presenter, side_presenter]:
			if p != null:
				p.sync_mc_name(old_name, sanitized)
		save_game())
	name_row.add_child(save_name)

	var uid := "kesh"
	var body_box := VBoxContainer.new()
	body_box.add_theme_constant_override("separation", 6)
	vbox.add_child(body_box)
	# lambdas capture locals by value, so shared state lives in a dictionary
	var preview := TextureRect.new()
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.custom_minimum_size = Vector2(vp.x * 0.4, vp.x * 0.4)
	header.add_child(preview)
	var scroll_node: ScrollContainer = o["scroll"]
	scroll_node.custom_minimum_size.y -= header.get_combined_minimum_size().y + 8.0
	var state := {"preview": preview}
	var refresh_preview := func():
		var pv = state["preview"]
		if pv == null or not is_instance_valid(pv):
			return
		var frames = load("res://sprites/units/%s.tres" % Appearance.sprite_set(g, uid))
		if frames != null and frames.has_meta("part_ref"):
			pv.material = Appearance.material_for(g, uid, frames.get_meta("part_ref"))
	state["rebuild"] = func():
		for c in body_box.get_children():
			c.queue_free()
		var look := Appearance.look(g, uid)
		preview.texture = UnitView.body_preview(look["body"])
		refresh_preview.call()
		var brow := HBoxContainer.new()
		body_box.add_child(brow)
		for body in ["male", "female"]:
			var bb := Button.new()
			bb.text = body.capitalize()
			bb.disabled = body == look["body"]
			bb.pressed.connect(func():
				Appearance.set_body(g, uid, body)
				UnitView.mc_body = body
				_appearance_changed(uid)
				state["rebuild"].call())
			brow.add_child(bb)
		for part in Appearance.PARTS:
			var lbl := Label.new()
			lbl.text = Appearance.PART_LABEL[part]
			body_box.add_child(lbl)
			var row := HFlowContainer.new()
			body_box.add_child(row)
			var cur = (look["colors"] as Dictionary).get(part)
			var orig := Button.new()
			orig.text = "Original"
			orig.disabled = cur == null
			orig.pressed.connect(func():
				Appearance.set_part(g, uid, part, null)
				_appearance_changed(uid)
				state["rebuild"].call())
			row.add_child(orig)
			for hex in Appearance.PRESETS[part]:
				var sw := Button.new()
				sw.custom_minimum_size = Vector2(vp.x * 0.075, vp.x * 0.075)
				var st := StyleBoxFlat.new()
				st.bg_color = Color(hex)
				st.set_corner_radius_all(4)
				st.border_color = Palette.TEXT_INK if hex == cur else Color(0, 0, 0, 0.25)
				st.set_border_width_all(3 if hex == cur else 1)
				for k in ["normal", "hover", "pressed"]:
					sw.add_theme_stylebox_override(k, st)
				sw.pressed.connect(func():
					Appearance.set_part(g, uid, part, hex)
					_appearance_changed(uid)
					state["rebuild"].call())
				row.add_child(sw)
			# RGB color sliders start from the current colour (or the first preset,
			# close to the sprite's own, while the part is still Original);
			# dragging recolours the preview live, and the colour saves on
			# release.
			var start := Color(str(cur)) if cur != null else Color(str(Appearance.PRESETS[part][0]))
			var grid := GridContainer.new()
			grid.columns = 4
			body_box.add_child(grid)
			var chip := ColorRect.new()
			chip.color = start
			chip.custom_minimum_size = Vector2(vp.x * 0.06, vp.x * 0.06)
			var sliders := []
			for ch in 3:
				var cl := Label.new()
				cl.text = ["R", "G", "B"][ch]
				grid.add_child(cl)
				var sl := HSlider.new()
				sl.min_value = 0
				sl.max_value = 255
				sl.step = 1
				sl.value = roundi([start.r, start.g, start.b][ch] * 255.0)
				sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sl.custom_minimum_size = Vector2(0, vp.y * 0.03)
				grid.add_child(sl)
				var vl := Label.new()
				vl.text = str(int(sl.value))
				vl.custom_minimum_size = Vector2(vp.x * 0.09, 0)
				grid.add_child(vl)
				if ch == 0:
					grid.add_child(chip)
				else:
					grid.add_child(Control.new())
				sliders.append([sl, vl])
			var apply := func(save: bool):
				var c := Color8(int(sliders[0][0].value), int(sliders[1][0].value), int(sliders[2][0].value))
				for pair in sliders:
					pair[1].text = str(int(pair[0].value))
				chip.color = c
				Appearance.set_part(g, uid, part, "#" + c.to_html(false))
				refresh_preview.call()
				if save:
					_appearance_changed(uid)
			for pair in sliders:
				pair[0].value_changed.connect(func(_v): apply.call(false))
				pair[0].drag_ended.connect(func(_changed): apply.call(true))
	state["rebuild"].call()
	# a tap on a slider (no drag) still changes the colour -- make sure it
	# reaches the battle and the save when the screen closes
	o["backdrop"].tree_exiting.connect(func(): _appearance_changed(uid))
	await _finish_detail_overlay(o)

func _appearance_changed(uid: String) -> void:
	for p in [current_presenter, side_presenter]:
		if p != null:
			p.sync_appearance(uid)
	save_game()

## Same sanitize rule McCreatePanel._sanitize_name uses -- small per-file
## duplication (this project's own established convention) rather than a
## shared base class for a 3-line regex.
func _sanitize_mc_name(raw: String) -> String:
	var re := RegEx.new()
	re.compile("[<>&\"'\\[\\]]")
	return re.sub(raw, "", true).strip_edges().substr(0, 20)

## Says exactly what buffs and debuffs do. Every magnitude-based status reads
## its real number straight from FarroadCore.STATUS_BASE_MAG (the same table
## apply_status / eff_atk / eff_def / etc. use), so this can never drift out
## of sync with the combat math. "taunted" has no magnitude (it is a pure
## behavioral flag), so its text is hand-written.
func _status_description(status_id: String, potency: float = 1.0) -> String:
	var mag: float = FarroadCore.STATUS_BASE_MAG.get(status_id, 0.0) * potency
	if FarroadCore.STATUS_MAG_CAP.has(status_id):
		var cap: float = FarroadCore.STATUS_MAG_CAP[status_id]
		mag = maxf(mag, cap) if cap < 0.0 else minf(mag, cap)
	match status_id:
		"enfeebled", "empowered": return "ATK %+.0f%%" % (mag * 100.0)
		"inspired": return "MAG %+.0f%%" % (mag * 100.0)
		"resolute": return "RES %+.0f%%" % (mag * 100.0)
		"keen", "dazed": return "Crit chance %+.0f%%" % (mag * 100.0)
		"drained": return "Charge rate %+.0f%%" % (mag * 100.0)
		"vulnerable": return "Incoming damage %+.0f%%" % (mag * 100.0)
		"wounded": return "Healing received %+.0f%%" % (mag * 100.0)
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
		"blinded": return "Attacks are %.0f%% more likely to be evaded" % (mag * 100.0)
		"poisoned": return "Loses %.1f%% max HP every time any unit acts" % (mag * 100.0)
		"confused": return "%.0f%% chance its single-target actions land on a random unit" % (mag * 100.0)
		"exposed": return "Evade %+.0f%%" % (mag * 100.0)
		_:
			if status_id.begins_with("boon_") or status_id.begins_with("bane_"):
				return "%s affinity %+.0f" % [status_id.substr(5).capitalize(), mag]
			return "%+.0f%%" % (mag * 100.0) if mag != 0.0 else ""

## The equipment detail popup, shared by EquipmentPanel's per-slot info icon and
## CataloguePanel's Equipment tab. `uid` is optional (empty when opened from a
## unit-agnostic context like the Catalogue). A marginal % affinity
## contribution needs a real unit's baseline to be well defined (see
## EquipmentPanel._describe_equipment), so with no uid this falls back to the
## item's raw affinity values instead of a computed %.
func show_equipment_detail_popup(item_id: String, uid: String = "") -> void:
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
		# doesn't shrink with a narrower vp.x the way this container's own
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

	await _finish_detail_overlay(o)

## The enemy detail popup (CataloguePanel's Enemies tab info icon). Enemy
## archetypes carry their own gambit `slots` (an Array of {cond, action} pairs,
## the same shape as a unit's loadout), resolved here into readable condition /
## action names via FarroadCore.cond_label and ACTIONS. Each listed action gets
## its own info icon too, opening show_action_detail_popup as a second overlay;
## it nests correctly on top of this one since both are siblings under the same
## host popup (see _build_detail_overlay).
## The unit detail popup (the Shop's info icon) follows: a roster unit's base
## stats, growth, affinities and charge action.
func show_unit_detail_popup(uid: String) -> void:
	var d = FarroadCore.roster_by_id(uid)
	if d == null:
		return
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]
	var color: Color = RARITY_COLOR.get(d.get("rarity", "common"), Color(1, 1, 1))
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b][color=#%s]%s[/color][/b]  %s · %s row" % [color.to_html(false), d["name"],
		(FarroadProgression.unit_title(g, uid) if g["owned"].has(uid) else FarroadProgression.role_at_100(uid)),
		str(d.get("row", "front"))]
	vbox.add_child(title)
	var st: Dictionary = d.get("stats", {})
	var stat_lbl := Label.new()
	stat_lbl.text = "HP %d   ATK %s   MAG %s   DEF %s   RES %s   SPD %s" % [int(d.get("hp", 0)),
		str(st.get("atk", 0)), str(st.get("mag", 0)), str(st.get("def", 0)), str(st.get("res", 0)), str(st.get("spd", 0))]
	stat_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	stat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(stat_lbl)
	var gr = FarroadProgression.GROWTH.get(uid)
	if gr != null:
		var gbits: Array = []
		for k in gr.keys():
			gbits.append("%s +%s" % [str(k).to_upper(), str(snappedf(float(gr[k]), 0.01))])
		var gl := Label.new()
		gl.text = "Growth per level: %s" % ", ".join(gbits)
		gl.modulate = Palette.TEXT_DIM
		gl.autowrap_mode = TextServer.AUTOWRAP_WORD
		gl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(gl)
	var crit := Label.new()
	crit.text = "ATK crit %.0f%%   MAG crit %.0f%%   Evade %.0f%%" % [float(st.get("atkCrit", 0)) * 100.0,
		float(st.get("magCrit", 0)) * 100.0, float(st.get("evade", 0)) * 100.0]
	crit.autowrap_mode = TextServer.AUTOWRAP_WORD
	crit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(crit)
	var aff: Dictionary = d.get("affinity", {})
	var aff_bits: Array = []
	for ax in aff.keys():
		if float(aff[ax]) != 0.0:
			aff_bits.append("%s %+d" % [str(ax).capitalize(), int(aff[ax])])
	if not aff_bits.is_empty():
		var al := Label.new()
		al.text = "Affinity: %s" % ", ".join(aff_bits)
		al.autowrap_mode = TextServer.AUTOWRAP_WORD
		al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(al)
	if d.get("chargeAction"):
		var cid: String = d["chargeAction"]
		var cact = FarroadCore.ACTIONS.get(cid)
		var row := HBoxContainer.new()
		var cl := Label.new()
		cl.text = "⚡ Charge action: %s" % (cact["name"] if cact else cid)
		cl.modulate = Palette.GOLD_TEXT
		cl.autowrap_mode = TextServer.AUTOWRAP_WORD
		cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(cl)
		var ib := Button.new()
		ib.text = "ⓘ"
		ib.custom_minimum_size = Vector2(36, 0)
		ib.pressed.connect(show_action_detail_popup.bind(cid))
		row.add_child(ib)
		vbox.add_child(row)
	_finish_detail_overlay(o)

## A gambit condition's full wording and which side it reads.
func show_gambit_detail_popup(cond_id: String) -> void:
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b]%s[/b]" % FarroadCore.cond_label(cond_id)
	vbox.add_child(title)
	var side := "a foe" if cond_id.begins_with("foe_") else ("an ally" if cond_id.begins_with("ally_") else "the unit itself")
	var lbl := Label.new()
	lbl.text = "Checks %s. When true, the gambit slot's action fires (on the matching target); otherwise the unit tries its next slot." % side
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(lbl)
	_finish_detail_overlay(o)

func show_enemy_detail_popup(arch_key: String, display_name: String = "", boss_variant: bool = false) -> void:
	var a = FarroadCore.ARCH.get(arch_key)
	if a == null:
		return
	var o := _build_detail_overlay()
	var vbox: VBoxContainer = o["vbox"]

	var color: Color = RARITY_COLOR.get(a.get("rarity", "common"), Color(1, 1, 1))
	var title := RichTextLabel.new()
	title.bbcode_enabled = true
	title.fit_content = true
	title.text = "[b][color=#%s]%s[/color][/b]" % [color.to_html(false), display_name if display_name != "" else a["name"]]
	vbox.add_child(title)
	if boss_variant:
		var bl := Label.new()
		bl.text = "Warden: a title bestowed on enemies on The Road with great potential. A Warden %s has HP ×%.1f, ATK/MAG ×%.1f, extra Spirit (resists debuffs), and is drawn larger." % [
			a["name"], FarroadProgression.BOSS_LEN, 1.1 * FarroadProgression.BOSS_HARD_EXTRA]
		bl.modulate = Palette.GOLD_TEXT
		bl.autowrap_mode = TextServer.AUTOWRAP_WORD
		bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(bl)

	# the same lines a unit's detail shows: base stats, growth, crit / evade,
	# affinity (as %); enemy stats grow with the wave instead of a level
	var lines: Array = [
		"HP ×%.2f   ATK %s   MAG %s   DEF %s   RES %s   SPD %s" % [float(a.get("hpMul", 1.0)),
			str(a.get("atk", 0)), str(a.get("mag", 8)), str(a.get("def", 0)), str(a.get("res", 0)), str(a.get("spd", 0))],
		"Growth: HP, ATK, MAG, DEF and RES grow with the wave (stats above are at wave 1)",
		"ATK crit %.0f%%   MAG crit %.0f%%   Evade %.0f%%" % [float(a.get("atkCrit", 0.0)) * 100.0,
			float(a.get("magCrit", 0.04)) * 100.0, float(a.get("evade", 0.0)) * 100.0],
		"Takes %.0f%% damage%s" % [FarroadCore.dmg_taken_mul(a) * 100.0,
			("   ·   Size ×%.2f" % float(a["size"])) if a.get("size") and float(a["size"]) != 1.0 else ""]]
	for i in lines.size():
		var ll := Label.new()
		ll.text = lines[i]
		if i == 1:
			ll.modulate = Palette.TEXT_DIM
		ll.autowrap_mode = TextServer.AUTOWRAP_WORD
		ll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(ll)

	var affinity: Dictionary = a.get("affinity", {})
	var aff_bits: Array = []
	# affinities as the % they change damage by, like units
	for ax in affinity.keys():
		if affinity[ax] != 0.0:
			aff_bits.append("%s %+.0f%%" % [str(ax).capitalize(), FarroadCore.affinity_mul(float(affinity[ax])) * 100.0])
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
		charge_lbl.modulate = Palette.GOLD_TEXT
		charge_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		charge_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		charge_row.add_child(charge_lbl)
		# charge actions (ally and enemy) get inspect icons, which open as a
		# second, sibling overlay on top of this one (see this function's header
		# comment)
		var charge_action_id: String = a["chargeAction"]
		var charge_info_btn := Button.new()
		charge_info_btn.text = "ⓘ"
		charge_info_btn.custom_minimum_size = Vector2(36, 0)
		charge_info_btn.pressed.connect(show_action_detail_popup.bind(charge_action_id))
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
			info_btn.pressed.connect(show_action_detail_popup.bind(action_id))
			row.add_child(info_btn)
			vbox.add_child(row)

	await _finish_detail_overlay(o)

## Called by UnitsPanel whenever its Gambits / Aether / Lore / Equipment sub-tab
## needs to (re)build its content: on first selecting that sub-tab, and again
## on every unit swap while it stays the active sub-tab. Dispatches to
## whichever panel's build_into(container, uid, host_popup). Those panels own
## no popup of their own (a second popup opened from inside UnitsPanel's closed
## everything); `host_popup` is passed through so a panel with its own
## transient dialog can nest it inside the same window this content lives in.
func build_unit_subpanel_content(panel_key: String, container: Container, uid: String, host_popup: Window) -> void:
	match panel_key:
		"gambits": gambits_panel.build_into(container, uid, host_popup)
		"aether": aether_panel.build_into(container, uid, host_popup)
		"lore": lore_panel.build_into(container, uid, host_popup)
		"equipment": equipment_panel.build_into(container, uid, host_popup)

## Full-screen popups would otherwise make the Road / combat view look
## unreachable while a tab is open. The Road view is always rendered behind
## every popup, so returning to it is just closing whatever is currently open.
func _on_road_pressed() -> void:
	_close_all_popups()
	open_panel = null

## Called by PartyPanel right after a bench/field edit -- pushes the roster
## change onto the live fight immediately (see
## FarroadProgression.refresh_live_party's own comment) rather than waiting
## for the next wave's build_party().
func sync_party_change() -> void:
	refresh_hud()   # the HUD's Power is the fielded party's
	if current_presenter == null:
		return
	var result: Dictionary = FarroadProgression.refresh_live_party(g)
	current_presenter.sync_live_party(result["added"], result["removed"])

## Called by PartyPanel right after a front/back row toggle: pushes the row
## change onto the live fight's on-field sprite immediately, animated, rather
## than waiting for the next wave's build_party().
func sync_row_change(uid: String) -> void:
	if current_presenter == null:
		return
	current_presenter.hop_to_new_row(uid)

## Guarded against a race with side battles: a Road win / wipe can already be
## mid-await (_animate_wave_transition's WAVE_RUN_TIME wait or _fade_out, each a
## second or more) when the player attempts a quest or dungeon.
## start_side_battle() reassigns g["battle"] to the side fight's own battle out
## from under this function. Without the two checks below, the resumed
## _on_battle_finished call would build a second, unpaused, visible presenter
## from that reassigned g["battle"] and the stale g["units"] / g["enemies"],
## rendered alongside side_presenter (quests overlapping the road).
## _resolve_side_battle's restore path rebuilds the Road's presenter once it is
## safe again (see its comment).
func _begin_next_fight(stage_enemies_offscreen: bool = false, hide_party_until_revealed: bool = false, auto_start_loop: bool = true, defer_dock: bool = false) -> void:
	_crumb("beginNextFight")
	if g.get("sideBattle") != null:
		return
	_check_respec_item()
	_layer_hud_above_trees()   # catches any control built since the last wave
	var presenter := BattlePresenter.new()
	presenter.crumb_sink = _crumb
	presenter.wipes_lookup = show_wipes_popup
	presenter.goals_open = open_goals_window
	presenter.goals_count = func() -> int: return Goals.claimable_count(g)
	presenter.battle_finished.connect(_on_battle_finished.bind(presenter))
	presenter.recovery_lookup = func(uid): return FarroadProgression.recovery_of(g, str(uid))
	presenter.catchup_lookup = func(): return FarroadProgression.catchup_mul(g)
	presenter.title_lookup = func(uid): return FarroadProgression.unit_title(g, str(uid))
	presenter.action_info = func(aid, host):
		overlay_host_override = host
		show_action_detail_popup(str(aid))
	_fit_presenter(presenter)
	add_child(presenter)
	if not defer_dock:   # built early (while the old fight is still on screen): the dock switches at the swap
		_dock_presenter(presenter)
	_raise_self_hosted_overlays()
	await get_tree().process_frame
	if g.get("sideBattle") != null:
		presenter.queue_free()
		return
	if tutorial != null and tutorial.holds_road():
		presenter.set_loop_paused(true, "tutorialDue")   # the Road waits out a running (or due) tutorial
	# the wave's enemies as they were at the start (enrage changes them)
	presenter.set_meta("enemySnap", (g.get("enemies", []) as Array).map(FarroadProgression.bake_enemy_snapshot))
	presenter.analytics_key = str(int(g.get("wave", 1)))
	presenter.analytics_boss = FarroadProgression.is_boss_wave(int(g.get("wave", 1)))
	presenter.start_battle(g["battle"], g["units"] + g["enemies"], stage_enemies_offscreen, g.get("clearedWaves", {}), hide_party_until_revealed, auto_start_loop)
	current_presenter = presenter
	_road_wave_started_ms = Time.get_ticks_msec()

const WAVE_RUN_TIME := 1.0
## How far the party runs to the right, as a share of the screen width.
const WAVE_RUN_DIST_FRAC := 0.12
## Piece G: "have them move back over .25 seconds" -- the party's own
## "stop and settle" beat (see _on_battle_finished's own sequencing
## comment for the full narrative this and ENEMY_RUN_IN_TIME together
## build).
const WAVE_RETREAT_TIME := 0.25
## Units heal before they run, and the party runs past the front tree, so the
## forest scrolls for a good while (the tree has to cross the whole screen)
## with the party running in place; the party settles back to its stance in the
## last WAVE_RETREAT_TIME of it.
const WAVE_HEAL_TIME := 0.7
const WAVE_SCROLL_TIME := 1.8
## The parallax starts as soon as the units start running and stops as soon as
## the first unit is back at its stopping point. This is that whole span,
## counted from the start of the run.
const WAVE_TRAVEL_TIME := 2.4
## A full second of difference in how long the fastest and the slowest unit take
## to get to their marks. The fastest unit's forward run takes WAVE_RUN_MIN; the
## slowest's takes WAVE_RUN_MIN + the variance.
const WAVE_RUN_MIN := 0.4
## The first enemy gets to its place just after the first ally gets to theirs;
## it runs in for this long (the slowest enemy takes WAVE_RUN_VARIANCE
## longer).
const ENEMY_AFTER_ALLY := 0.15
const ENEMY_FAST_RUN_TIME := 1.0
const WAVE_RUN_VARIANCE := 1.0
## How far (as a share of the screen width) the slowest unit falls behind its place while the forest scrolls.
const WAVE_FALL_BEHIND_FRAC := 0.12   # about 50 px on the phone layout (412 wide)
## Piece G: "move the background more as well" -- was 1.5x run_dx.
const BG_RUN_MUL := 3.0
## Piece G: "fade in over .5 seconds when they stop moving."
const CHROME_FADE_TIME := 0.5
## Duplicated from BattlePresenter.ENEMY_RUN_IN_TIME: how long GameController
## waits after triggering run_enemies_entering() before treating everyone as
## assembled.
const ENEMY_RUN_IN_TIME := 1.6

## After clearing a wave the party units shift right by a modest amount
## (framing is maintained: they stay within their own band, not actually
## leaving the field). background_layer itself does not move during this leg;
## all of its motion happens in _animate_wave_retreat. A dead party member
## (dimmed, not removed) is skipped, since there is nothing to run for a unit
## that is down.
##
## Also: a defensive sweep force-hides any already-dead enemy before the run
## starts (update_hp() already hides a dead enemy the instant it dies, so this
## is cheap insurance that they disappear before the party runs forward), and
## each moving party view's HP / charge / name chrome hides before it starts
## moving (it only fades back in once the whole run + retreat sequence stops;
## see reveal_party(), called by _on_battle_finished once the retreat below
## finishes).
func _animate_wave_transition(old_presenter: Node) -> void:
	if old_presenter == null:
		return
	for view in old_presenter.unit_views_by_id.values():
		if not view.unit["isParty"] and view.unit["hp"] <= 0:
			view.visible = false
	var run_dx: float = vp.x * WAVE_RUN_DIST_FRAC   # Ian: 20% further than the original 0.1
	var lags: Dictionary = _unit_lags(old_presenter)  # each unit's place in the pack: 0 = fastest, 1 = slowest
	for view in old_presenter.unit_views_by_id.values():
		if view.unit["isParty"] and view.unit["hp"] > 0:
			var lag: float = float(lags.get(str(view.unit["id"]), 1.0))
			view.hide_chrome()
			view.hold_run = true     # nothing left over from the fight may change its animation now
			view.play_state("run")   # a unit with no run animation just keeps its idle
			# Everyone runs forward together; then each unit falls steadily further behind the fastest as the
			# forest scrolls past (never closing the gap), and after the forest stops the slower ones run up
			# to their marks, arriving up to WAVE_RUN_VARIANCE after the fastest.
			var behind_max: float = minf(lag * WAVE_FALL_BEHIND_FRAC * vp.x, maxf(0.0, view.rest_position.x - view.size * 0.2))   # a back-row unit may fall back nearly to the screen edge
			var catch_up: float = lag * WAVE_RUN_VARIANCE
			var total: float = WAVE_TRAVEL_TIME + catch_up
			var tw := create_tween()
			tw.tween_method(_move_in_pack.bind(view, view.rest_position, run_dx, behind_max, catch_up), 0.0, total, total)
			tw.tween_callback(func():
				if is_instance_valid(view):
					view.hold_run = false
					view.play_state("idle"))
	if background_layer != null:
		_start_travel(WAVE_TRAVEL_TIME)   # the forest scrolls from the first moment of the run, for as long as the FASTEST unit takes

## Where a unit is `t` seconds into the run, as an offset from its mark (rest). All units share the forward
## run and the drift home; on top of that each falls back by `behind_max` as the scroll goes on, growing
## smoothly and never shrinking until the scroll has stopped (t = WAVE_TRAVEL_TIME), then runs up to its mark.
func _move_in_pack(t: float, view: Node, rest: Vector2, run_dx: float, behind_max: float, catch_up: float) -> void:
	if not is_instance_valid(view):
		return
	var d: float = WAVE_TRAVEL_TIME
	var fwd: float = WAVE_RUN_MIN
	var x_off: float
	if t <= d:
		var run_part: float
		if t < fwd:
			run_part = run_dx * sin(clampf(t / fwd, 0.0, 1.0) * PI / 2.0)                 # out to the running position
		else:
			var u: float = clampf((t - fwd) / maxf(0.01, d - fwd), 0.0, 1.0)
			run_part = run_dx * (1.0 - (1.0 - cos(u * PI)) / 2.0)                       # eases home as the scroll ends
		var fall_back: float = behind_max * (1.0 - cos(clampf(t / d, 0.0, 1.0) * PI)) / 2.0
		x_off = run_part - fall_back
	else:
		var v: float = clampf((t - d) / maxf(0.01, catch_up), 0.0, 1.0) if catch_up > 0.0 else 1.0
		x_off = -behind_max * (1.0 - (1.0 - cos(v * PI)) / 2.0)                          # run up to the mark
	view.position = Vector2(rest.x + x_off, view.position.y)

## The background does all of its scrolling here, not during the run-right leg
## (_animate_wave_transition doesn't touch it at all). It always continues in
## the same forward direction, never reversing, so distance keeps accumulating
## wave over wave like genuine continuous travel. It starts the instant the
## party begins its retreat (only once they've reached their "running"
## position) and stops exactly when the party finishes settling back at its
## starting position. _on_battle_finished awaits this same WAVE_RETREAT_TIME
## before calling run_enemies_entering(), so enemies don't start arriving until
## this motion has stopped. The party's own "shift right then return to
## center" is just a framing trick; the background is what sells continuous
## forward travel down the road, so it only ever moves the one way.
func _slowest_party_spd(old_presenter: Node) -> float:
	var slowest := INF
	for v in old_presenter.unit_views_by_id.values():
		if v.unit["isParty"] and v.unit["hp"] > 0:
			slowest = minf(slowest, float(v.unit["base"]["spd"]))
	return slowest if slowest < INF and slowest > 0.0 else 1.0

## How long a unit takes to run, as a share of the slowest unit's, so some units
## get ahead and others lag and they reach their marks at different times: a
## steeper speed curve than a straight ratio, a small fixed offset per unit
## (from its id, so it is the same every time it is asked) so even equal-speed
## units don't arrive together, and never faster than MIN_RATIO or slower than
## the slowest (1.0).
const RUN_VARIANCE_EXP := 1.6
const RUN_JITTER := 0.5           # +-25%
const RUN_MIN_RATIO := 0.3

static func run_time_ratio(uid: String, spd: float, slowest: float) -> float:
	var base: float = pow(slowest / maxf(1.0, spd), RUN_VARIANCE_EXP)
	var jitter: float = 1.0 + (float(absi(uid.hash()) % 1000) / 1000.0 - 0.5) * RUN_JITTER
	return clampf(base * jitter, RUN_MIN_RATIO, 1.0)

func _spd_time_ratio(view: Node, slowest: float) -> float:
	return run_time_ratio(str(view.unit["id"]), float(view.unit["base"]["spd"]), slowest)

## Each living party unit's place in the pack: 0 = the fastest runner, 1 = the slowest.
func _unit_lags(old_presenter: Node) -> Dictionary:
	var slowest: float = _slowest_party_spd(old_presenter)
	var ratios := {}
	for view in old_presenter.unit_views_by_id.values():
		if view.unit["isParty"] and view.unit["hp"] > 0:
			ratios[str(view.unit["id"])] = _spd_time_ratio(view, slowest)
	return pack_lags(ratios)

static func pack_lags(ratios: Dictionary) -> Dictionary:
	var lags := {}
	if ratios.size() <= 1:
		for id in ratios:
			lags[id] = 1.0
		return lags
	var lo := INF
	var hi := -INF
	for id in ratios:
		lo = minf(lo, float(ratios[id]))
		hi = maxf(hi, float(ratios[id]))
	for id in ratios:
		lags[id] = clampf((float(ratios[id]) - lo) / maxf(0.05, hi - lo), 0.0, 1.0)
	return lags

## From the start of the run until the last (slowest) unit has reached its mark: the scroll ends when the
## fastest one does (WAVE_TRAVEL_TIME), and the slowest arrives WAVE_RUN_VARIANCE after that.
func _wave_total_time(_old_presenter: Node) -> float:
	return WAVE_TRAVEL_TIME + WAVE_RUN_VARIANCE

## The units' whole run (forward, fall back, catch up) is now one path per unit started by
## _animate_wave_transition, so there is nothing left to start here. Kept because callers still call it.
func _animate_wave_retreat(_old_presenter: Node) -> void:
	pass

## Units heal before they run forward: the party's health bars fill up to what
## the wave's recovery gives them (start_wave has already worked that out on
## the new units), with a green +N over each unit, while everyone is still
## standing where they fought.
func _animate_wave_heal(old_presenter: Node) -> void:
	if old_presenter == null:
		return
	var targets := {}
	for u in g.get("units", []):
		targets[str(u["id"])] = float(u["hp"])
	var any = old_presenter.heal_party_to(targets, WAVE_HEAL_TIME)
	if any:
		await get_tree().create_timer(WAVE_HEAL_TIME + 0.2).timeout

## Mirrors the real doStep()'s post-battle branch (afterWaveCleared() on a
## win, onWipe() on a loss) -- on_wipe already rebuilds g["battle"] at the
## checkpoint wave internally (it calls start_wave itself), so only a WIN
## needs a separate start_wave(wave+1) call here.
var _road_changing := 0   # wave changes in progress (the watchdog leaves those alone)

func _on_battle_finished(outcome: String, from: Node = null) -> void:
	# Only the Road's current presenter may advance the Road; a stray one
	# finishing would advance the wave a second time.
	if from != null and from != current_presenter:
		return
	_road_changing += 1
	await _on_battle_finished_inner(outcome)
	_road_changing -= 1

## A safety net for the Road not resuming after quests: every few seconds, with
## no side fight, tutorial or wave change under way, the Road must have a
## running, visible fight. If not, it is restarted, and what was wrong goes
## into the stats (features: roadWatchdog:<reason>) so real reports show the
## cause.
const ROAD_WATCHDOG_SEC := 3.0
var _watchdog_strikes := 0

## The last few things that happened to the Road, newest last. When the watchdog has to step in, these
## say what led up to it (the watchdog hides the bug; this is how the bug gets found).
const CRUMB_LIMIT := 16
var _crumbs: Array = []

func _crumb(what: String) -> void:
	_crumbs.append("%.1fs %s" % [Time.get_ticks_msec() / 1000.0, what])
	if _crumbs.size() > CRUMB_LIMIT:
		_crumbs.pop_front()

## One line describing the Road's state, for a watchdog report.
func _road_state_text(p) -> String:
	var bits: Array = ["wave %s" % str(g.get("wave", "?")),
		"roadChanging %d" % _road_changing,
		"openPanel %s" % (str(open_panel.name) if open_panel != null and is_instance_valid(open_panel) else "none")]
	if p == null or not is_instance_valid(p):
		bits.append("presenter none")
	else:
		bits.append("presenter visible=%s paused=%s started=%s over=%s" % [str(p.visible), str(p.loop_paused), str(p.loop_started()), str(p.battle.get("over"))])
	return ", ".join(bits)

func _road_watchdog() -> void:
	if g.is_empty() or g.get("mc") == null or g.get("sideBattle") != null or _road_changing > 0:
		_watchdog_strikes = 0
		return
	if tutorial != null and (tutorial.holds_road() or tutorial.active != ""):
		_watchdog_strikes = 0
		return
	var p = current_presenter
	var reason := ""
	if p == null or not is_instance_valid(p):
		reason = "noFight"
	elif not p.visible:
		reason = "hidden"
	elif p.loop_paused:
		reason = "paused"
	elif p.loop_started() and p.battle.get("over") != null:
		reason = "overNotAdvanced"
	if reason == "":
		_watchdog_strikes = 0
		return
	# two checks in a row, so a normal moment between steps isn't mistaken
	_watchdog_strikes += 1
	if _watchdog_strikes < 2:
		return
	_watchdog_strikes = 0
	Analytics.add("features", "roadWatchdog:" + reason)
	# which step it follows, as a short code (the first word of the newest breadcrumb)
	var last: String = str(_crumbs[_crumbs.size() - 1]).get_slice(" ", 1) if not _crumbs.is_empty() else "none"
	Analytics.add("features", "roadWatchdog:%s:after:%s" % [reason, last])
	push_warning("Road watchdog (%s): %s | recent: %s" % [reason, _road_state_text(p), " > ".join(_crumbs.slice(maxi(0, _crumbs.size() - 8)))])
	match reason:
		"noFight":
			_begin_next_fight()
		"hidden":
			p.show()
			p.set_loop_paused(false, "watchdogHidden")
		"paused":
			p.set_loop_paused(false, "watchdogPaused")
		"overNotAdvanced":
			_on_battle_finished(str(p.battle["over"]), p)

func _on_battle_finished_inner(outcome: String) -> void:
	_crumb("battleFinished:%s" % outcome)
	_record_road_wave(outcome == "party")
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
		refresh_hud()
		save_game()
		_spawn_reward_drops(events, aether_before, lore_before, marks_before)
		# A one-time popup congratulating the player on finishing the tutorial,
		# awaited before the wave-transition animation below so the player
		# actually reads it (the just-finished boss encounter stays on screen
		# behind it, as the welcome-back popup shows over the live game rather
		# than a blank screen).
		for e in events:
			if e.get("kind") == "tutorial_complete":
				await _show_tutorial_complete_popup()
				break
		for e in events:
			if e.get("kind") == "enrage_intro":
				await _show_enrage_intro_popup()
				break
		# The milestone-companion event (still named "boss_companion" though it can
		# fire on a non-boss wave; see after_wave_cleared) gets the same
		# awaited-popup treatment as tutorial_complete above.
		for e in events:
			if e.get("kind") == "boss_companion":
				await _show_companion_joined_popup(e["id"])
				break
		# After wave 20 the player gets a piece of equipment and a popup about it:
		# the same awaited-popup shape as the two above.
		for e in events:
			if e.get("kind") == "tutorial_equip":
				await _show_tutorial_equip_popup(e["id"])
				break
		# The finished battlefield (units, HP bars, log / status buttons) stays on
		# screen through the run animation and is freed only once its own retreat
		# finishes, not the moment the fight ends. light_up_wave runs on this same
		# (about-to-be-freed) presenter, so the circle glows as the party runs to
		# the next encounter; the new presenter then opens already showing it lit,
		# via the cleared_waves passed into its own start_battle call.
		#
		# The full sequence is strictly ordered, not concurrent: (1) the party runs
		# right, (2) it retreats / settles (background_layer's retreat tween is
		# started in the same call, with the same WAVE_RETREAT_TIME, so it always
		# stops at the moment the party does; see _animate_wave_retreat), (3)
		# enemies run in immediately once the party has stopped (no held pause),
		# (4) only once they have arrived does the battle loop start.
		if cleared_wave % ENV_WAVES == 0 and g.get("sideBattle") == null and current_presenter != null and _no_living_enemies(current_presenter):
			await _gate_ascension()
			return
		var old_presenter = current_presenter
		await _animate_wave_heal(old_presenter)
		_animate_wave_transition(old_presenter)
		if old_presenter != null:
			old_presenter.light_up_wave(cleared_wave)
		_animate_wave_retreat(old_presenter)
		# Every time below is in seconds from the moment the party starts running.
		var total: float = _wave_total_time(old_presenter)       # the last ally has reached its mark
		if old_presenter != null:
			old_presenter.drain_enrage(total * 0.8)   # the enrage bar empties while the party runs
		# Enemies run in too, with the same spread. The next fight is built now,
		# with its party and its on-screen UI held back, so its enemies can be
		# running in while the forest is still scrolling.
		await _begin_next_fight(true, true, false, true)
		var next = current_presenter
		if next == null or next == old_presenter:
			# a quest/dungeon/Arena fight started during the run: finish the run, drop the old picture and stop
			await get_tree().create_timer(total).timeout
			if old_presenter != null and is_instance_valid(old_presenter):
				old_presenter.queue_free()
			if current_presenter == old_presenter:
				current_presenter = null
			return
		next.set_chrome_visible(false)
		# the first enemy arrives just after the first ally (who is at its mark when the scroll ends)
		var first_arrival: float = WAVE_TRAVEL_TIME + ENEMY_AFTER_ALLY
		var enemy_start: float = maxf(0.0, first_arrival - ENEMY_FAST_RUN_TIME)
		await get_tree().create_timer(enemy_start).timeout
		if is_instance_valid(next) and next == current_presenter:
			next.run_enemies_in_pack(ENEMY_FAST_RUN_TIME, WAVE_RUN_VARIANCE)
		# the new turn order slides in a little before the swap, over the old strip
		var early: float = minf(TURN_ORDER_EARLY, maxf(0.0, total - enemy_start))
		await get_tree().create_timer(maxf(0.0, total - enemy_start - early)).timeout
		if is_instance_valid(next) and next == current_presenter:
			if old_presenter != null and is_instance_valid(old_presenter):
				old_presenter.hide_turn_order()
			next.show_turn_order_early()
		await get_tree().create_timer(early).timeout
		# the allies are all at their marks: swap the old picture for the new one
		if old_presenter != null and is_instance_valid(old_presenter):
			old_presenter.queue_free()
		if not (is_instance_valid(next) and next == current_presenter):
			return
		_dock_presenter(next)
		next.set_chrome_visible(true)
		next.reveal_party(CHROME_FADE_TIME)
		# combat starts once the last enemy has arrived
		await get_tree().create_timer(maxf(0.0, first_arrival + WAVE_RUN_VARIANCE - total)).timeout
		if is_instance_valid(next) and next == current_presenter:
			next.begin_combat()
	else:
		_record_wipe()
		FarroadProgression.on_wipe(g)
		refresh_hud()
		save_game()
		# A wipe hides the checkpoint jump behind a fade to black instead of
		# announcing it with text -- the field swap happens while the screen
		# is fully black, so the return to an earlier wave reads as a scene
		# transition rather than a called-out event.
		await _fade_out()
		if current_presenter != null:
			current_presenter.queue_free()
			current_presenter = null
		_refresh_background()
		await _begin_next_fight()
		await _fade_in()

const FADE_HALF_SEC := 0.5
## How long before the swap to the next wave the new turn order starts sliding in.
const TURN_ORDER_EARLY := 0.5

## ===== The ascent: after the wave 100, 200, ... boss =====
## A glowing gate appears on the right and opens, stairs descend from it, the party runs up them and
## through, and the next environment begins on the other side.
const GATE_APPEAR_TIME := 0.9
const GATE_OPEN_TIME := 0.8
const GATE_STAIRS_TIME := 1.0
const GATE_RUN_TO_STAIRS := 0.9
const GATE_RUN_UP_STAIRS := 1.3
const GATE_FADE_THROUGH := 0.35
const GATE_RUN_STAGGER := 0.3   # seconds between one unit setting off and the next

## The gate is only for a fight that was really won: nothing hostile left standing on the field.
func _no_living_enemies(pr: Node) -> bool:
	for v in pr.unit_views_by_id.values():
		if not v.unit["isParty"] and v.unit["hp"] > 0:
			return false
	return true

func _gate_ascension() -> void:
	_crumb("gateAscension")
	var old_presenter = current_presenter
	await _animate_wave_heal(old_presenter)
	var s: float = bvp.y / BG_ART_H
	var gate := AscensionGate.new()
	# the doorway's base-left corner; the gate (120 art px wide) must stay on screen
	var door := _bpos + Vector2(minf(bvp.x * 0.85, bvp.x - 82.0 * s), 205.0 * s)
	var lowest_top := -1.0   # the stairs stop just short of the lowest party unit
	for v in old_presenter.unit_views_by_id.values():
		if v.unit["isParty"] and v.unit["hp"] > 0:
			lowest_top = maxf(lowest_top, v.global_position.y - v.size * 0.5)
	gate.setup(door, s, lowest_top)
	add_child(gate)
	move_child(gate, old_presenter.get_index())   # behind the units, above the background
	for view in old_presenter.unit_views_by_id.values():
		if not view.unit["isParty"] and view.unit["hp"] <= 0:
			view.visible = false
		elif view.unit["isParty"] and view.unit["hp"] > 0:
			view.hide_chrome()
	var tw := create_tween()
	tw.tween_method(gate.set_appear, 0.0, 1.0, GATE_APPEAR_TIME)
	tw.tween_method(gate.set_open, 0.0, 1.0, GATE_OPEN_TIME)
	tw.tween_method(gate.set_stairs, 0.0, 1.0, GATE_STAIRS_TIME)
	await tw.finished
	# the party runs along the ground to the foot of the stairs, up them, and into the light
	var foot: Vector2 = gate.stair_foot()
	var top: Vector2 = gate.door_point()
	# the closest unit to the stairs goes first, then the next, and so on; a unit
	# waits (standing, not running in place) until it is its turn
	var order: Array = []
	for view in old_presenter.unit_views_by_id.values():
		if view.unit["isParty"] and view.unit["hp"] > 0:
			order.append(view)
	order.sort_custom(func(a, b): return a.global_position.distance_to(foot) < b.global_position.distance_to(foot))
	var last := 0.0
	for i in order.size():
		var view = order[i]
		var delay: float = float(i) * GATE_RUN_STAGGER
		var lift := Vector2(0.0, -view.size * 0.3)
		last = maxf(last, delay + GATE_RUN_TO_STAIRS + GATE_RUN_UP_STAIRS + GATE_FADE_THROUGH)
		var ut := create_tween()
		ut.tween_interval(delay)
		ut.tween_callback(func():
			if is_instance_valid(view):
				view.hold_run = true
				view.play_state("run"))
		ut.tween_property(view, "global_position", foot + lift + Vector2(0.0, float(i) * 3.0), GATE_RUN_TO_STAIRS)
		ut.tween_property(view, "global_position", top + lift, GATE_RUN_UP_STAIRS)
		ut.tween_property(view, "modulate:a", 0.0, GATE_FADE_THROUGH)
	await get_tree().create_timer(last + 0.2).timeout
	# a flash of light as they pass through, then the new land
	fade_overlay.color = Color(1.0, 0.96, 0.8, 0.0)
	await _fade_out()
	if is_instance_valid(gate):
		gate.queue_free()
	if current_presenter != null:
		current_presenter.queue_free()
		current_presenter = null
	_refresh_background()
	await _begin_next_fight()
	await _fade_in()
	fade_overlay.color = Color(0, 0, 0, 0)

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

## ===== wave-clear reward drop animation =====
## Icon x-fractions duplicated from the target panels' own _build_icon_tab
## calls (all at icon_size = 0.11 * vp.x, y = 0.93 * vp.y): UnitsPanel 0.0133,
## PartyPanel 0.1367, ExpeditionPanel 0.3833. Duplicated per file, like the
## panels' own icon positions.
const ICON_SIZE_FRAC := 0.11
const ICON_Y_FRAC := 0.93
const UNITS_ICON_X_FRAC := 0.0288
const PARTY_ICON_X_FRAC := 0.1675
const EXPEDITION_ICON_X_FRAC := 0.3063

const REWARD_FLYER_TIME := 0.7
const REWARD_FLYER_STAGGER := 0.12

func _icon_center(x_frac: float) -> Vector2:
	if wide:
		var btn = _ribbon_icon_for_frac(x_frac)
		if btn != null and is_instance_valid(btn):
			return btn.global_position + btn.size / 2.0
	var icon_size: float = vp.x * ICON_SIZE_FRAC
	return Vector2(vp.x * x_frac + icon_size / 2.0, vp.y * ICON_Y_FRAC + icon_size / 2.0)

## Aether / lore / marks are snapshotted before after_wave_cleared / start_wave
## run and diffed against the current values. That covers every plain per-wave
## Aether / Marks gain and duplicate-drop Lore conversion, which have no
## dedicated event of their own, without adding new event kinds to the engine
## layer. Each captured typed event (action / cond -> Gambits, equip ->
## Equipment, boss_companion(_roll) -> Party) spawns its own flyer too. It is
## fire-and-forget, not awaited by the caller, with one small reusable helper
## rather than a bespoke animation per reward kind.
func _spawn_reward_drops(events: Array, aether_before: float, lore_before: float, marks_before: float) -> void:
	var start := _bpos + Vector2(bvp.x / 2.0, bvp.y * (0.15 + 0.58) / 2.0)
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
		# Lore has no HUD figure: it is per-action and lives under Units -> Lore,
		# so the flyer's destination is there instead of a currency cell.
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
	lbl.add_theme_font_size_override("font_size", int(vp.y * 0.0196))
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	# an outline so rewards stand out against the field
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 5)
	lbl.position = start
	lbl.z_index = 5
	add_child(lbl)
	move_child(lbl, get_child_count() - 1)
	var tw := create_tween()
	tw.tween_property(lbl, "position", end, REWARD_FLYER_TIME)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, REWARD_FLYER_TIME).set_delay(REWARD_FLYER_TIME * 0.4)
	await tw.finished
	lbl.queue_free()

## ===== QUESTS side battles =====
## The presentation half of starting a side battle; the state change itself is
## FarroadProgression.start_side_battle(). The Road has no player-facing
## play / pause / speed control to preserve (it always auto-plays), so pausing
## and hiding current_presenter (the same set_loop_paused every panel uses,
## plus hiding it, since the side battle needs the same on-field space rather
## than a small popup) is all it takes.
func _enter_side_battle(enemies: Array, wave: int, meta: Dictionary, prebuilt: Dictionary = {}) -> void:
	_crumb("sideBattleStart:%s" % str(meta.get("kind", "?")))
	if not FarroadProgression.start_side_battle(g, enemies, wave, meta, prebuilt):
		return
	_side_started_ms = Time.get_ticks_msec()
	if current_presenter != null:
		current_presenter.set_loop_paused(true, "sideBattle")
		_crumb("hideRoad")
		current_presenter.hide()
		if current_presenter.log_popup.visible:
			current_presenter.log_popup.hide()
		if current_presenter.status_popup.visible:
			current_presenter.status_popup.hide()
	_refresh_background()
	await _spawn_side_presenter(false)

## A fresh presenter for the current side-battle wave; the enemies run in
## before the fight starts, like on the Road. `reveal_party` fades the
## party's bars back in after a between-wave run.
func _spawn_side_presenter(reveal_party: bool) -> void:
	side_presenter = BattlePresenter.new()
	side_presenter.crumb_sink = _crumb
	side_presenter.wipes_lookup = show_wipes_popup
	side_presenter.goals_open = open_goals_window
	side_presenter.goals_count = func() -> int: return Goals.claimable_count(g)
	side_presenter.battle_finished.connect(_on_side_battle_finished)
	side_presenter.recovery_lookup = func(uid): return FarroadProgression.recovery_of(g, str(uid))
	side_presenter.catchup_lookup = func(): return FarroadProgression.catchup_mul(g)
	side_presenter.title_lookup = func(uid): return FarroadProgression.unit_title(g, str(uid))
	side_presenter.action_info = func(aid, host):
		overlay_host_override = host
		show_action_detail_popup(str(aid))
	_fit_presenter(side_presenter)
	add_child(side_presenter)
	_dock_presenter(side_presenter)
	_raise_self_hosted_overlays()
	await get_tree().process_frame
	var sp = side_presenter
	var sm: Dictionary = g["sideBattle"]["meta"]
	sp.analytics_ctx = str(sm.get("kind", "quest"))
	match sp.analytics_ctx:
		"quest": sp.analytics_key = "%s#%d" % [sm.get("uid", "?"), int(sm.get("stage", 0)) + 1]
		"dungeon": sp.analytics_key = "%s#t%d#w%d" % [sm.get("direction", "?"), int(sm.get("tier", 0)), int(sm.get("waveIndex", 0)) + 1]
		"pvp": sp.analytics_key = str(sm.get("rival", "")) if str(sm.get("rival", "")) != "" else "code"
	sp.start_battle(g["battle"], g["battle"]["units"], true, {}, reveal_party, false)
	sp.call("set_status_override", _side_battle_label_text(g["sideBattle"]["meta"]))
	if reveal_party:
		sp.reveal_party(CHROME_FADE_TIME)
	sp.call("run_enemies_entering")
	await get_tree().create_timer(ENEMY_RUN_IN_TIME).timeout
	if is_instance_valid(sp):
		sp.begin_combat()

## Replaces the side presenter's own "Wave N" text (BattlePresenter.
## set_status_override) with the quest/dungeon's own name while a side
## battle is active -- the Road's own presenter/label are never touched,
## so nothing needs restoring once the side battle resolves.
func _side_battle_label_text(meta: Dictionary) -> String:
	if meta["kind"] == "pvp":
		return "PvP — vs %s" % (meta["team"] if str(meta.get("team", "")) != "" else meta["owner"] + "'s team")
	if meta["kind"] == "training":
		return "Training"
	if meta["kind"] == "quest":
		return "%s's Quest — Stage %d/5" % [meta["name"], int(meta["stage"]) + 1]
	if meta["kind"] == "raid":
		return "Raid — %s" % meta["name"]
	if meta["kind"] == "path":
		return "%s%s" % [meta["name"], " — Boss" if meta.get("boss", false) else ""]
	return "%s — Wave %d/%d" % [meta["name"], int(meta["waveIndex"]) + 1, int(meta["totalWaves"])]

## ===== Training dummies (TrainingSetup.gd) =====
## Opened from the Gambits editor's Test button and from the Quests tab --
## both call this, so it is one and the same screen.
func open_training() -> void:
	if g.get("sideBattle") != null:
		return
	if wide and shell != null:
		_open_training_in_dock()
		return
	var o := _build_detail_overlay(Palette.BORDER_LEATHER, true, true)
	var setup := TrainingSetup.new()
	setup.build(o["vbox"], g, func():
		if is_instance_valid(o["backdrop"]):
			o["backdrop"].queue_free()
		_start_training())
	await _finish_detail_overlay(o)

## Wide window: the training setup sits in the dock beside the fight.
func _open_training_in_dock() -> void:
	_close_all_popups()
	open_panel = null
	var scroll := ScrollContainer.new()
	scroll.set_meta("arena", true)   # closed the same way as the Arena page
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)
	shell.page_host.add_child(scroll)
	shell.show_page("Training", true)
	if not shell.page_back.pressed.is_connected(_on_road_pressed):
		shell.page_back.pressed.connect(_on_road_pressed)
	scroll.tree_exited.connect(_arena_page_gone)
	var setup := TrainingSetup.new()
	setup.build(vbox, g, func():
		if is_instance_valid(scroll):
			scroll.queue_free()
		_start_training())

func _start_training() -> void:
	if g.get("sideBattle") != null:
		return
	_close_all_popups()
	_enter_side_battle(FarroadProgression.training_enemies(g), int(g.get("wave", 1)), {"kind": "training"})
	_clear_training_buttons()
	# the buttons sit right next to the "Training" text above the enrage bar
	await get_tree().process_frame
	var title: Label = side_presenter.wave_progress_label if side_presenter != null and is_instance_valid(side_presenter) else null
	var bx: float = (title.global_position.x + title.get_minimum_size().x + bvp.x * 0.025) if title != null else bvp.x * 0.30
	var by: float = (title.global_position.y) if title != null else _bpos.y + bvp.y * 0.60
	var bh: float = (title.get_minimum_size().y if title != null else vp.y * 0.03) + 4.0
	training_end_btn = Button.new()
	training_end_btn.text = "End training"
	training_end_btn.position = Vector2(bx, by - 2.0)
	training_end_btn.custom_minimum_size = Vector2(0, bh)
	training_end_btn.add_theme_font_size_override("font_size", int(vp.y * 0.017))
	training_end_btn.pressed.connect(_end_training)
	add_child(training_end_btn)
	training_refill_btn = Button.new()
	training_refill_btn.text = "Reset"
	training_refill_btn.custom_minimum_size = Vector2(0, bh)
	training_refill_btn.add_theme_font_size_override("font_size", int(vp.y * 0.017))
	training_refill_btn.pressed.connect(_refill_dummies)
	add_child(training_refill_btn)
	await get_tree().process_frame
	if is_instance_valid(training_refill_btn) and is_instance_valid(training_end_btn):
		training_refill_btn.position = Vector2(training_end_btn.position.x + training_end_btn.size.x + 8.0, by - 2.0)

var training_end_btn: Button
var training_refill_btn: Button

func _clear_training_buttons() -> void:
	for b in [training_end_btn, training_refill_btn]:
		if b != null and is_instance_valid(b):
			b.queue_free()
	training_end_btn = null
	training_refill_btn = null

func _training_running() -> bool:
	var sb = g.get("sideBattle")
	return sb != null and str((sb as Dictionary).get("meta", {}).get("kind", "")) == "training"

func _end_training() -> void:
	if not _training_running():
		return
	if side_presenter != null and is_instance_valid(side_presenter):
		side_presenter.battle_finished.disconnect(_on_side_battle_finished)
		side_presenter.queue_free()
		side_presenter = null
	_resolve_side_battle("enemy", true)

## Back to full HP (the dummies that were knocked down to 1 too).
func _refill_dummies() -> void:
	if not _training_running():
		return
	for u in g["battle"]["units"]:
		if not u["isParty"]:
			u["hp"] = u["maxHp"]
	if side_presenter != null and is_instance_valid(side_presenter):
		for v in side_presenter.unit_views_by_id.values():
			v.update_hp()

## Called by QuestsPanel.
func attempt_quest(uid: String) -> void:
	var prep := FarroadProgression.prep_quest_attempt(g, uid)
	if prep.is_empty():
		return
	quests_panel.popup.hide()
	_enter_side_battle(prep["enemies"], prep["wave"], prep["meta"])

## Starts a raid attempt (Arena > Raids): your fielded team against this week's boss.
## Paths (Quests > Trials): the run window, starting a run, and going to a node.
func open_paths_window() -> void:
	PathsWindow.open(self)

func path_start() -> void:
	if g.get("sideBattle") != null:
		return
	Paths.new_run(g, Time.get_unix_time_from_system())
	save_game()
	open_paths_window()

func path_retreat() -> void:
	var ev := Paths.retreat(g, Time.get_unix_time_from_system())
	refresh_hud()
	save_game()
	if ev["ended"]:
		_show_path_result_popup(ev)

## A node was chosen: a fight starts; an event opens its choice in the window.
## A Paths fight that was running when the game closed is fought again from the start (the node was
## recorded before it began), so closing the app can't dodge a loss.
func _resume_path_fight() -> void:
	if g.get("sideBattle") != null or not Paths.active(g):
		return
	var fight = Paths.run(g).get("fight")
	if fight is Array and (fight as Array).size() == 2:
		path_fight(int(fight[0]), int(fight[1]))

func path_fight(row: int, col: int) -> void:
	if g.get("sideBattle") != null or not Paths.active(g):
		return
	# remembered before the fight starts, so closing or killing the app mid-fight can't dodge a loss:
	# the same node is fought again when the game loads (see _resume_path_fight)
	Paths.run(g)["fight"] = [row, col]
	save_game()
	var f := Paths.build_fight(g, Paths.run(g), row, col)
	_hide_open_panel()
	_close_arena()
	_enter_side_battle([], int(f["wave"]), f["meta"], f["battle"])

func _show_path_result_popup(event: Dictionary) -> void:
	var o := _build_detail_overlay(Palette.GOLD_PRESSED, false, true)
	var vbox: VBoxContainer = o["vbox"]
	var title := Label.new()
	title.add_theme_font_size_override("font_size", int(vp.y * 0.034))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	if event["victory"]:
		title.text = "Path complete!"
	elif event["ended"]:
		title.text = "The run is over"
	elif event["levelCleared"]:
		title.text = "Level cleared!"
	else:
		title.text = "Victory"
	vbox.add_child(title)
	for t in event["drops"]:
		vbox.add_child(_wrap_label("• " + str(t)))
	for n in event["lost"]:
		var lost_lbl := _wrap_label("%s was lost." % str(n))
		lost_lbl.modulate = Color(1.0, 0.6, 0.55)
		vbox.add_child(lost_lbl)
	if event["ended"]:
		var r := Paths.run(g)
		var res: Dictionary = r.get("result", {})
		vbox.add_child(_wrap_label("Levels cleared: %d of %d.  Rows: %d." % [int(res.get("cleared", 0)), Paths.LEVELS, int(res.get("rows", 0))], true))
		vbox.add_child(_wrap_label("Reward: %d Crystal." % int(event["crystal"]), true))
	var again := Button.new()
	again.text = "Close" if event["ended"] else "Continue"
	UiKit.primary(again)
	again.pressed.connect(func():
		o["backdrop"].queue_free()
		if not event["ended"]:
			open_paths_window())
	vbox.add_child(again)
	await _finish_detail_overlay(o)

func attempt_raid() -> void:
	var prep := Raids.start_attempt(g, Time.get_unix_time_from_system())
	if prep.is_empty():
		return
	save_game()   # the used attempt is kept even if the game is killed mid-fight
	_hide_open_panel()
	_close_arena()
	_enter_side_battle(prep["enemies"], int(prep["wave"]), prep["meta"])

func enter_dungeon(id: String) -> void:
	var prep := FarroadProgression.prep_dungeon_attempt(g, id, Time.get_unix_time_from_system())
	if prep.is_empty():
		return
	quests_panel.popup.hide()
	_enter_side_battle(prep["enemies"], prep["wave"], prep["meta"])

func _on_side_battle_finished(outcome: String) -> void:
	_resolve_side_battle(outcome, false)

## Give Up is for quests only (dungeons can't be abandoned mid-crawl). It is
## instant: it queue_free()s side_presenter directly rather than waiting for
## another beat. Godot's Tween / coroutine machinery cleans up safely when the
## node it is bound to is freed mid-animation (the same unconditional
## queue_free() a Road wipe relies on), so no BattlePresenter-side abort flag
## is needed.
func give_up_quest() -> void:
	if g.get("sideBattle") == null or g["sideBattle"]["meta"]["kind"] != "quest":
		return
	side_presenter.battle_finished.disconnect(_on_side_battle_finished)
	side_presenter.queue_free()
	side_presenter = null
	_resolve_side_battle("enemy", true)

func _resolve_side_battle(result: String, gave_up: bool) -> void:
	_crumb("sideBattleEnd:%s" % result)
	var side_meta: Dictionary = (g["sideBattle"]["meta"] as Dictionary).duplicate() if g.get("sideBattle") != null else {}
	var event := FarroadProgression.finish_side_battle(g, result, gave_up, Time.get_unix_time_from_system())
	if event["kind"] != "dungeon_wave_advance" and event["kind"] != "training_done":
		_record_side_battle(side_meta, str(event["kind"]))
	if event["kind"] == "dungeon_wave_advance":
		# Quests and dungeons use the same movement between waves as the Road: the
		# party runs on, settles, the next wave runs in, then the fight starts
		# (the Road's own sequence in _on_battle_finished).
		var old_side = side_presenter
		_animate_wave_transition(old_side)
		_animate_wave_retreat(old_side)
		await get_tree().create_timer(_wave_total_time(old_side)).timeout
		if is_instance_valid(old_side):
			old_side.queue_free()
		if g.get("sideBattle") == null:
			return
		await _spawn_side_presenter(true)
		return
	if side_presenter != null:
		side_presenter.queue_free()
		side_presenter = null
	_refresh_background()   # back to the Road's environment
	if current_presenter != null:
		_crumb("showRoad")
		current_presenter.show()
		_dock_presenter(current_presenter)
		current_presenter.set_loop_paused(false, "sideBattleEnd")
	else:
		# Recovery path for the race _begin_next_fight() guards against:
		# a Road win/wipe that was already mid-await when this side battle
		# started ran its own cleanup (current_presenter freed and nulled)
		# but skipped rebuilding a new one, deferring that to right here --
		# now that g["sideBattle"] is clear again, it's finally safe to.
		_begin_next_fight()
	if event["kind"] == "training_done":
		_clear_training_buttons()
	elif str(event["kind"]).begins_with("pvp"):
		if pvp_skip_btn != null and is_instance_valid(pvp_skip_btn):
			pvp_skip_btn.queue_free()
		_show_pvp_result_popup(event)
	elif event["kind"] == "raid_done":
		_show_raid_result_popup(event)
	elif event["kind"] == "path_node":
		_show_path_result_popup(event)
	else:
		quests_panel.show_result(event)
		_show_quest_result_popup(event)
	refresh_hud()
	save_game()

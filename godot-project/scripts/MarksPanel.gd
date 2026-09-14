extends Node
## Milestone 3, Step 3g: the MARKS tab -- gacha pulls. Structural sibling
## of EquipmentPanel.gd, but with no unit-tab row -- MARKS is a single
## global screen, not a per-unit editor.
##
## FarroadProgression.do_pull(g) stays pure (g-mutation only, no UI/live-
## sync side effects, matching every other orchestration function's own
## discipline) -- this panel is what notifies GameController after a pull:
## _notify_currency_changed() always (marks/aether/lore can all change),
## and -- only when the result actually fielded a new companion -- the
## SAME _sync_party_change() PartyPanel already uses (a pulled-and-fielded
## companion is functionally identical to a PartyPanel field action, no
## real-JS precedent either way, same class of Godot-only enhancement).
##
## No drop-banner/toast system exists anywhere in this port yet (wave
## drops already return this same shape of event and nothing renders them
## either) -- a real one is out of this step's scope. A pull's result
## shows as a plain "Last pull: ..." text line inside this popup instead.

var g: Dictionary
var _vp: Vector2
var _parent: Node

var toggle_button: Button
var popup: PopupPanel
var card_container: VBoxContainer
var last_pull_result: Dictionary = {}

func setup(new_g: Dictionary, vp: Vector2, parent: Node) -> void:
	g = new_g
	_vp = vp
	_parent = parent
	_build_ui(parent)

## Same reasoning/limitation as every sibling panel's own reflow() -- see
## GambitsPanel.reflow's comment.
func reflow(new_vp: Vector2) -> void:
	_vp = new_vp
	if toggle_button:
		toggle_button.queue_free()
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.6300, _vp.y * 0.93), icon_size, "Marks", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# Sixth of 8 evenly-spaced icons across the bottom row: Gambits 0.0133,
	# Party 0.1367, Aether 0.2600, Lore 0.3833, Equip 0.5067, this one
	# 0.6300, Expedition 0.7533, Quests 0.8767 -- adding QuestsPanel's icon
	# meant recomputing all 8 x-fractions ((1-8*0.11)/9 ~= 0.0133 margin/gap,
	# replacing the 7-icon layout's 0.02 at icon size 0.12), so the other
	# panels' own _build_ui/reflow fractions were updated too (duplicated
	# per file, same convention, no shared base).
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.6300, _vp.y * 0.93), icon_size, "Marks", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var popup_size := Vector2(_vp.x * 0.85, _vp.y * 0.85)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = popup_size - Vector2(20, 20)
	popup.add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(popup_size.x - 40, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(root_vbox)

	var title := Label.new()
	title.text = "MARKS"
	title.add_theme_font_size_override("font_size", 20)
	root_vbox.add_child(title)

	card_container = VBoxContainer.new()
	card_container.add_theme_constant_override("separation", 10)
	root_vbox.add_child(card_container)

## Same opaque-panel convention every sibling panel already established --
## the default theme's PopupPanel background isn't fully opaque.
func _style_popup(p: PopupPanel) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.border_color = Color(0.3, 0.3, 0.34, 1.0)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.24, 0.24, 0.29)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(0.32, 0.32, 0.38)
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn

func _on_toggle_pressed() -> void:
	_refresh_card()
	popup.popup_centered(Vector2(_vp.x * 0.85, _vp.y * 0.85))
	_notify_battle_paused(true)

## Pauses BattlePresenter's beat-by-beat loop while this popup is open --
## same pattern as every sibling panel's own copy (see
## BattlePresenter.loop_paused's own comment for why this exists).
func _notify_battle_paused(paused: bool) -> void:
	if _parent and _parent.has_method("_set_battle_paused"):
		_parent.call("_set_battle_paused", paused)

## Same dynamic has_method()+call() pattern AetherPanel's own copy uses --
## _parent is typed as a plain Node here, no compile-time GameController
## dependency.
func _notify_currency_changed() -> void:
	if _parent and _parent.has_method("_refresh_hud"):
		_parent.call("_refresh_hud")

## Same pattern PartyPanel's own _notify_party_changed uses.
func _notify_party_changed() -> void:
	if _parent and _parent.has_method("_sync_party_change"):
		_parent.call("_sync_party_change")

func _refresh_card() -> void:
	for c in card_container.get_children():
		c.queue_free()
	if not FarroadProgression.pulls_unlocked(g):
		_build_locked_card()
	else:
		_build_unlocked_card()

## Mirrors renderMarks()'s locked branch (farroad-ui.js:2233-2242).
func _build_locked_card() -> void:
	var header := Label.new()
	header.text = "Pulls open at wave %d." % FarroadProgression.MARKS_UNLOCK_WAVE
	header.add_theme_font_size_override("font_size", 16)
	card_container.add_child(header)

	var marks := int(g.get("marks", 0))
	var banked_lbl := Label.new()
	banked_lbl.text = "Banked %d Marks — no cap, nothing is being wasted · reached wave %d of %d." % [
		marks, int(g.get("farthest", 1)), FarroadProgression.MARKS_UNLOCK_WAVE]
	banked_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(banked_lbl)

	var pulls_waiting := marks / FarroadProgression.MARKS_PER_PULL
	var waiting_lbl := Label.new()
	waiting_lbl.text = "That is %d pull%s waiting for you at the unlock." % [pulls_waiting, "" if pulls_waiting == 1 else "s"]
	card_container.add_child(waiting_lbl)

	var explain_lbl := Label.new()
	explain_lbl.text = ("The curated run to wave %d hands you a specific tool every two waves in a " +
		"designed order; random pulls arriving mid-sequence would cut across it. The bank opens the " +
		"moment that sequence ends.") % FarroadProgression.MARKS_UNLOCK_WAVE
	explain_lbl.modulate = Color(0.65, 0.7, 0.65)
	explain_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(explain_lbl)

## Mirrors renderMarks()'s unlocked branch (farroad-ui.js:2243-2263).
func _build_unlocked_card() -> void:
	var cost := FarroadProgression.pull_cost(g.get("wave", 1))
	var marks: float = g.get("marks", 0.0)

	var header := HBoxContainer.new()
	var pull_lbl := Label.new()
	pull_lbl.text = "Pull"
	pull_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(pull_lbl)
	var cost_lbl := Label.new()
	cost_lbl.text = "%d Marks each" % cost
	cost_lbl.modulate = Color(0.65, 0.7, 0.65)
	header.add_child(cost_lbl)
	card_container.add_child(header)

	var bar_bg := ColorRect.new()
	bar_bg.custom_minimum_size = Vector2(_vp.x * 0.7, 10)
	bar_bg.color = Color(0.15, 0.15, 0.15)
	var bar_fg := ColorRect.new()
	var frac: float = clampf(marks / float(cost), 0.0, 1.0)
	bar_fg.size = Vector2(_vp.x * 0.7 * frac, 10)
	bar_fg.color = Color(0.85, 0.65, 0.15)
	var bar_wrap := Control.new()
	bar_wrap.custom_minimum_size = Vector2(_vp.x * 0.7, 10)
	bar_wrap.add_child(bar_bg)
	bar_wrap.add_child(bar_fg)
	card_container.add_child(bar_wrap)

	var pull_btn := Button.new()
	var available: bool = marks >= cost
	pull_btn.text = "PULL — %d Marks" % cost
	pull_btn.disabled = not available
	_style_pull_button(pull_btn, available)
	pull_btn.pressed.connect(_on_pull_pressed)
	card_container.add_child(pull_btn)

	var pity_n := int(g.get("pullsSinceUnit", 0))
	var odds_lbl := Label.new()
	odds_lbl.text = "Rolls across everything: %d%% action · %d%% gambit condition · %d%% equipment · %d%% companion — guaranteed a companion every %d pulls regardless of odds (%d/%d since your last one)." % [
		roundi(FarroadProgression.PULL_ODDS["action"] * 100), roundi(FarroadProgression.PULL_ODDS["cond"] * 100),
		roundi(FarroadProgression.PULL_ODDS["equip"] * 100), roundi(FarroadProgression.PULL_ODDS["unit"] * 100),
		FarroadProgression.PULL_PITY_AT, pity_n, FarroadProgression.PULL_PITY_AT]
	odds_lbl.modulate = Color(0.65, 0.7, 0.65)
	odds_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(odds_lbl)

	var explain_lbl := Label.new()
	explain_lbl.text = ("Duplicate actions and gambits convert to Lore; duplicate units convert to Aether; " +
		"duplicate equipment just adds to your stock. You OWN every unit you pull — the party is the %d " +
		"you field, and extras stay benched but yours.") % FarroadProgression.PARTY_CAP
	if g["party"].size() >= FarroadProgression.PARTY_CAP:
		explain_lbl.text += " Party full — new units arrive benched."
	explain_lbl.modulate = Color(0.65, 0.7, 0.65)
	explain_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(explain_lbl)

	if not last_pull_result.is_empty():
		var result_lbl := Label.new()
		result_lbl.text = "Last pull: %s" % _describe_pull_result(last_pull_result)
		result_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card_container.add_child(result_lbl)

func _style_pull_button(btn: Button, available: bool) -> void:
	var bg := Color(0.55, 0.42, 0.08) if available else Color(0.22, 0.13, 0.13)
	var bg_hover := Color(0.7, 0.55, 0.12) if available else Color(0.26, 0.15, 0.15)
	var font := Color(1.0, 0.93, 0.72) if available else Color(0.6, 0.45, 0.45)
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = bg
	normal_style.set_corner_radius_all(4)
	normal_style.set_content_margin_all(6)
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = bg_hover
	hover_style.set_corner_radius_all(4)
	hover_style.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.add_theme_stylebox_override("disabled", normal_style)
	btn.add_theme_color_override("font_color", font)
	btn.add_theme_color_override("font_disabled_color", font)
	btn.add_theme_color_override("font_hover_color", font)

func _describe_pull_result(r: Dictionary) -> String:
	match r["kind"]:
		"unit":
			var def = FarroadCore.roster_by_id(r["id"])
			var name: String = def["name"] if def else r["id"]
			var pity_tag := " (pity)" if r.get("pity") else ""
			var fielded_txt := "Fielded immediately." if r["fielded"] else "Benched — party is full, but yours."
			return "New companion%s: %s. %s" % [pity_tag, name, fielded_txt]
		"unit_dup":
			return "Every unit already owned — converted to +%d Aether." % int(r["aetherGain"])
		"equip":
			var item = FarroadCore.EQUIPMENT.get(r["id"])
			var iname: String = item["name"] if item else r["id"]
			return ("Duplicate equipment: %s (now own %d)." % [iname, r["ownedCount"]]) if r["duplicate"] else "New equipment: %s." % iname
		"action":
			var act = FarroadCore.ACTIONS.get(r["id"])
			var aname: String = act["name"] if act else r["id"]
			return "Duplicate action, converted to +1 Lore: %s." % aname if r["duplicate"] else "New action: %s." % aname
		"cond":
			return "Duplicate gambit condition, converted to +1 Lore: %s." % FarroadCore.cond_label(r["id"]) if r["duplicate"] else "New gambit condition: %s." % FarroadCore.cond_label(r["id"])
		_:
			return ""

func _on_pull_pressed() -> void:
	var result := FarroadProgression.do_pull(g)
	if result.is_empty():
		return
	last_pull_result = result
	_notify_currency_changed()
	if result["kind"] == "unit" and result.get("fielded"):
		_notify_party_changed()
	_refresh_card()

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
## Always an Array now (even a single Pull stores a 1-entry array) --
## Ian: "Pull x10 button for marks" needed a result shape that scales to
## many pulls at once without a separate single-vs-batch data path.
var last_pull_results: Array = []

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
	toggle_button = _build_icon_tab(_parent, Vector2(_vp.x * 0.2600, _vp.y * 0.93), icon_size, "Marks", _on_toggle_pressed)

func _build_ui(parent: Node) -> void:
	# 24-item batch's own Group C6 recomputed the (now 8-icon, Shop added)
	# bottom row: Units 0.0133, Party 0.1367, this one 0.2600, Expedition
	# 0.3833, Road (GameController's own button, moved next to Expedition
	# to stay near true center) 0.5067, Quests 0.6300, Settings 0.7533,
	# Shop 0.8767 -- same 0.11*vp.x icon size/0.93*vp.y row as before, just
	# recomputed.
	var icon_size: float = _vp.x * 0.11
	toggle_button = _build_icon_tab(parent, Vector2(_vp.x * 0.2600, _vp.y * 0.93), icon_size, "Marks", _on_toggle_pressed)

	popup = PopupPanel.new()
	_style_popup(popup)
	parent.add_child(popup)
	popup.popup_hide.connect(func(): _notify_battle_paused(false))

	var popup_size := Vector2(_vp.x * 0.96, _vp.y * 0.84)
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
	style.bg_color = Palette.BG_PARCHMENT
	style.border_color = Palette.BORDER_LEATHER
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", style)

## Same icon-square style every sibling panel's own copy uses (duplicated
## here, different script, no shared base).
## icon, when provided, shows a real icon texture instead of/alongside
## the placeholder text -- every EXISTING call site passes no icon
## (unchanged behavior) until real button art exists (Ian: "prepare for
## real button/icon assets").
func _build_icon_tab(parent: Node, pos: Vector2, size: float, label_text: String, callback: Callable, icon: Texture2D = null) -> Button:
	var btn := Button.new()
	btn.text = label_text
	if icon != null:
		btn.icon = icon
		btn.expand_icon = true
	btn.position = pos
	btn.custom_minimum_size = Vector2(size, size)
	btn.clip_text = true
	btn.add_theme_font_size_override("font_size", maxi(9, int(size * 0.24)))
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Palette.BTN_NORMAL
	normal_style.set_corner_radius_all(int(size / 2.0))
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Palette.BTN_HOVER
	hover_style.set_corner_radius_all(int(size / 2.0))
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn

func _on_toggle_pressed() -> void:
	if _parent and _parent.has_method("_panel_opening"):
		_parent.call("_panel_opening", self)
	_refresh_card()
	popup.popup(Rect2i(Vector2i(_vp.x * 0.02, _vp.y * 0.07), Vector2i(_vp.x * 0.96, _vp.y * 0.84)))
	_notify_battle_paused(true)
	# Ian: "add tutorial pop-ups the first time each page/tab is opened" --
	# see GameController._maybe_show_tab_tutorial's own comment.
	if _parent and _parent.has_method("_maybe_show_tab_tutorial"):
		await _parent.call("_maybe_show_tab_tutorial", "marks")

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
	explain_lbl.modulate = Palette.TEXT_DIM
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
	cost_lbl.modulate = Palette.TEXT_DIM
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

	# Ian: "Pull x10 button for marks." Gated on affording all 10 up front
	# (same silent-refusal convention the single Pull button already uses
	# via its own disabled state) -- never a partial bulk pull that leaves
	# the player wondering why it only did some of them.
	var cost_x10 := cost * 10
	var available_x10: bool = marks >= cost_x10
	var pull_x10_btn := Button.new()
	pull_x10_btn.text = "PULL x10 — %d Marks" % cost_x10
	pull_x10_btn.disabled = not available_x10
	_style_pull_button(pull_x10_btn, available_x10)
	pull_x10_btn.pressed.connect(_on_pull_x10_pressed)
	card_container.add_child(pull_x10_btn)

	var pity_n := int(g.get("pullsSinceUnit", 0))
	var odds_lbl := Label.new()
	odds_lbl.text = "Rolls across everything: %d%% action · %d%% gambit condition · %d%% equipment · %d%% companion — guaranteed a companion every %d pulls regardless of odds (%d/%d since your last one)." % [
		roundi(FarroadProgression.PULL_ODDS["action"] * 100), roundi(FarroadProgression.PULL_ODDS["cond"] * 100),
		roundi(FarroadProgression.PULL_ODDS["equip"] * 100), roundi(FarroadProgression.PULL_ODDS["unit"] * 100),
		FarroadProgression.PULL_PITY_AT, pity_n, FarroadProgression.PULL_PITY_AT]
	odds_lbl.modulate = Palette.TEXT_DIM
	odds_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(odds_lbl)

	var explain_lbl := Label.new()
	explain_lbl.text = ("Duplicate actions and gambits convert to Lore; duplicate units convert to Aether; " +
		"duplicate equipment just adds to your stock. You OWN every unit you pull — the party is the %d " +
		"you field, and extras stay benched but yours.") % FarroadProgression.PARTY_CAP
	if g["party"].size() >= FarroadProgression.PARTY_CAP:
		explain_lbl.text += " Party full — new units arrive benched."
	explain_lbl.modulate = Palette.TEXT_DIM
	explain_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_container.add_child(explain_lbl)

	if not last_pull_results.is_empty():
		var result_lbl := Label.new()
		result_lbl.text = "Last pull: %s" % _describe_pull_results(last_pull_results)
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
			var noun: String = "charge action" if r.get("isCharge") else "action"
			return "Duplicate %s, converted to +1 Lore on it: %s." % [noun, aname] if r["duplicate"] else "New %s: %s." % [noun, aname]
		"cond":
			if not r["duplicate"]:
				return "New gambit condition: %s." % FarroadCore.cond_label(r["id"])
			# 24-item batch, Group D6: name the action that actually received
			# the Lore (do_pull now reports it as loreActionId).
			return "Duplicate gambit condition (%s), converted to +1 Lore on %s." % [
				FarroadCore.cond_label(r["id"]), _action_name(r.get("loreActionId", ""))]
		_:
			return ""

func _action_name(aid: String) -> String:
	var act = FarroadCore.ACTIONS.get(aid)
	return act["name"] if act else (aid if aid != "" else "an action")

func _on_pull_pressed() -> void:
	var result := FarroadProgression.do_pull(g)
	if result.is_empty():
		return
	last_pull_results = [result]
	_notify_currency_changed()
	if result["kind"] == "unit" and result.get("fielded"):
		_notify_party_changed()
	_refresh_card()

func _on_pull_x10_pressed() -> void:
	var results := []
	var fielded_any := false
	for i in range(10):
		var result := FarroadProgression.do_pull(g)
		if result.is_empty():
			break
		results.append(result)
		if result["kind"] == "unit" and result.get("fielded"):
			fielded_any = true
	if results.is_empty():
		return
	last_pull_results = results
	_notify_currency_changed()
	if fielded_any:
		_notify_party_changed()
	_refresh_card()

## Single pull: reuses the existing per-kind description exactly. Batch
## pull: aggregate counts per kind (dedicated tallies for action/cond
## duplicate-vs-new, since that distinction is the headline info there),
## plus every NEW companion called out by name specifically -- those are
## the outcomes worth reading individually even inside a batch summary.
func _describe_pull_results(results: Array) -> String:
	if results.size() == 1:
		return _describe_pull_result(results[0])
	var new_units: Array = []
	var unit_dups := 0
	var new_actions := 0
	var dup_actions := 0
	var new_conds := 0
	var dup_conds := 0
	var new_equip := 0
	var dup_equip := 0
	# 24-item batch, Group D6: "list how much aether and what actions got
	# lore from duplicate each pull" -- tallied per action name, in the
	# order each first appeared.
	var dup_aether := 0
	var lore_by_action: Dictionary = {}
	for r in results:
		match r["kind"]:
			"unit":
				var def = FarroadCore.roster_by_id(r["id"])
				new_units.append(def["name"] if def else r["id"])
			"unit_dup":
				unit_dups += 1
				dup_aether += int(r.get("aetherGain", 0))
			"action":
				if r["duplicate"]:
					dup_actions += 1
					var an := _action_name(r["id"])
					lore_by_action[an] = int(lore_by_action.get(an, 0)) + 1
				else:
					new_actions += 1
			"cond":
				if r["duplicate"]:
					dup_conds += 1
					var cn := _action_name(r.get("loreActionId", ""))
					lore_by_action[cn] = int(lore_by_action.get(cn, 0)) + 1
				else:
					new_conds += 1
			"equip":
				if r["duplicate"]:
					dup_equip += 1
				else:
					new_equip += 1
	var parts: Array = []
	parts.append("%d pull%s" % [results.size(), "" if results.size() == 1 else "s"])
	if not new_units.is_empty():
		parts.append("new companion%s: %s" % ["" if new_units.size() == 1 else "s", ", ".join(new_units)])
	if unit_dups > 0:
		parts.append("%d duplicate companion%s -> +%d Aether" % [unit_dups, "" if unit_dups == 1 else "s", dup_aether])
	if new_actions > 0 or dup_actions > 0:
		parts.append("%d new / %d duplicate action%s" % [new_actions, dup_actions, "" if (new_actions + dup_actions) == 1 else "s"])
	if new_conds > 0 or dup_conds > 0:
		parts.append("%d new / %d duplicate gambit%s" % [new_conds, dup_conds, "" if (new_conds + dup_conds) == 1 else "s"])
	if new_equip > 0 or dup_equip > 0:
		parts.append("%d new / %d duplicate equipment" % [new_equip, dup_equip])
	if not lore_by_action.is_empty():
		var lore_bits: Array = []
		for an2 in lore_by_action.keys():
			lore_bits.append("%s +%d" % [an2, lore_by_action[an2]])
		parts.append("Lore: " + ", ".join(lore_bits))
	return "; ".join(parts) + "."

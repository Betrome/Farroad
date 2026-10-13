class_name PullResults
extends RefCounted
## The box that shows what a pull gave: one card per item, revealed one after
## another with a small pop, rarer ones glowing. A duplicate then converts in
## front of you -- the card dims and a "+N Lore" / "+N Aether" orb rises out of
## it -- and the totals sit underneath. Skip finishes it all at once.

const RARITY_COL := {"common": Color("eeeadf"), "rare": Color("95b6dd"), "legendary": Color("eda35d")}
const AETHER_COL := Color("e4a83f")
const LORE_COL := Color("709fe8")

## What one pull result looks like as a card.
static func describe(r: Dictionary) -> Dictionary:
	var kind: String = str(r.get("kind", ""))
	var out := {"tag": "", "name": "?", "rarity": "common", "sub": "", "dup": false, "aether": 0, "lore": 0, "loreOn": "", "pity": bool(r.get("pity", false))}
	match kind:
		"unit":
			var def = FarroadCore.roster_by_id(str(r["id"]))
			out["tag"] = "NEW COMPANION"
			out["name"] = def["name"] if def else str(r["id"])
			out["rarity"] = str(def.get("rarity", "common")) if def else "common"
			out["sub"] = "Joins your party" if r.get("fielded") else "Benched: the party is full, but yours"
		"unit_dup":
			out["tag"] = "DUPLICATE"
			out["name"] = str(r.get("name", "Companion"))
			out["rarity"] = str(r.get("rarity", "common"))
			out["dup"] = true
			out["aether"] = int(r.get("aetherGain", 0))
			if str(r.get("loreActionId", "")) != "":
				out["lore"] = 1
				out["loreOn"] = _action_name(str(r["loreActionId"]))
		"action":
			var act: Dictionary = FarroadCore.ACTIONS.get(str(r["id"]), {})
			var charge: bool = bool(act.get("isCharge", false))
			out["name"] = str(act.get("name", r["id"]))
			out["rarity"] = str(act.get("rarity", "common"))
			if r.get("duplicate"):
				out["tag"] = "DUPLICATE " + ("CHARGE ACTION" if charge else "ACTION")
				out["dup"] = true
				out["lore"] = 1
				out["loreOn"] = out["name"]
			else:
				out["tag"] = "NEW " + ("CHARGE ACTION" if charge else "ACTION")
				out["sub"] = "Plus 1 Lore" if charge else ""
		"cond":
			out["name"] = FarroadCore.cond_label(str(r["id"]))
			if r.get("duplicate"):
				out["tag"] = "DUPLICATE GAMBIT"
				out["dup"] = true
				out["aether"] = int(r.get("aetherGain", 0))
			else:
				out["tag"] = "NEW GAMBIT"
		"equip":
			var item: Dictionary = FarroadCore.EQUIPMENT.get(str(r["id"]), {})
			out["name"] = str(item.get("name", r["id"]))
			out["rarity"] = str(item.get("rarity", "common"))
			out["tag"] = "GEAR" + (" (now %d)" % int(r.get("ownedCount", 1)) if r.get("duplicate") else "")
	return out

static func _action_name(aid: String) -> String:
	return str(FarroadCore.ACTIONS.get(aid, {}).get("name", aid))

## Fills `vbox` (inside a detail overlay) with the cards and the footer.
## `host` is any node in the tree (used for tweens and timers).
static func build(vbox: VBoxContainer, results: Array, vp: Vector2) -> void:
	var cards: Array = []
	var infos: Array = []
	var grid := GridContainer.new()
	grid.columns = 1 if results.size() == 1 else 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(grid)
	var totals := {"aether": 0, "lore": 0, "newUnits": 0, "new": 0, "dups": 0}
	for r in results:
		var info := describe(r)
		infos.append(info)
		if info["dup"]:
			totals["dups"] += 1
			totals["aether"] += int(info["aether"])
			totals["lore"] += int(info["lore"])
		else:
			totals["new"] += 1
			if str(r.get("kind", "")) == "unit":
				totals["newUnits"] += 1
		var card := _make_card(info)
		card.modulate.a = 0.0
		grid.add_child(card)
		cards.append(card)

	var footer := Label.new()
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.modulate.a = 0.0
	var bits: Array = []
	if totals["new"] > 0:
		bits.append("%d new" % totals["new"])
	if totals["dups"] > 0:
		bits.append("%d duplicate%s" % [totals["dups"], "" if totals["dups"] == 1 else "s"])
	if totals["aether"] > 0:
		bits.append("+%d Aether" % totals["aether"])
	if totals["lore"] > 0:
		bits.append("+%d Lore" % totals["lore"])
	footer.text = "  ·  ".join(bits)
	footer.add_theme_color_override("font_color", UiKit.TEXT_DIM)
	vbox.add_child(footer)

	var state := {"skip": false}
	var skip := Button.new()
	skip.text = "Skip"
	skip.pressed.connect(func():
		state["skip"] = true
		skip.queue_free())
	if results.size() > 1:
		vbox.add_child(skip)
		vbox.move_child(skip, grid.get_index())      # Ian: Skip sits at the top, above the cards
	_play(vbox, cards, infos, footer, state)

static func _rarity_color(rarity: String) -> Color:
	return RARITY_COL.get(rarity, RARITY_COL["common"])

static func _make_card(info: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rar: String = str(info["rarity"])
	var st := UiKit.card_style(8, false)
	if rar != "common":
		st.border_color = _rarity_color(rar)
		st.set_border_width_all(2)
	card.add_theme_stylebox_override("panel", st)
	card.pivot_offset = Vector2(60, 30)
	var v := VBoxContainer.new()
	v.name = "Box"
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)
	var tag := Label.new()
	tag.name = "Tag"
	tag.text = str(info["tag"]) + ("  ·  PITY" if info["pity"] else "")
	tag.add_theme_font_size_override("font_size", 11)
	tag.add_theme_color_override("font_color", UiKit.TEXT_DIM)
	tag.clip_text = true
	v.add_child(tag)
	var nm := Label.new()
	nm.name = "Name"
	nm.text = str(info["name"])
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nm.add_theme_font_size_override("font_size", 16)
	nm.add_theme_color_override("font_color", _rarity_color(rar))
	v.add_child(nm)
	var sub := Label.new()
	sub.name = "Sub"
	sub.text = str(info["sub"])
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", UiKit.TEXT_DIM)
	sub.visible = str(info["sub"]) != ""
	v.add_child(sub)
	return card

## The reveal: cards pop in one after another; each duplicate then converts.
static func _play(host: Control, cards: Array, infos: Array, footer: Label, state: Dictionary) -> void:
	var n: int = cards.size()
	var gap: float = minf(0.22, 2.6 / float(maxi(1, n)))
	for i in n:
		if not is_instance_valid(host) or not host.is_inside_tree():
			return
		var card: PanelContainer = cards[i]
		var info: Dictionary = infos[i]
		if state["skip"]:
			card.modulate.a = 1.0
			_settle_dup(card, info)
			continue
		card.modulate.a = 0.0
		card.scale = Vector2(0.88, 0.88)
		var tw := host.create_tween().set_parallel(true)
		tw.tween_property(card, "modulate:a", 1.0, 0.18)
		tw.tween_property(card, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		if str(info["rarity"]) != "common" or str(info["tag"]).begins_with("NEW COMPANION"):
			_glow(host, card, _rarity_color(str(info["rarity"])))
		if info["dup"]:
			_convert(host, card, info)
		await host.get_tree().create_timer(gap).timeout
	if is_instance_valid(footer):
		var ft := footer.create_tween()
		ft.tween_property(footer, "modulate:a", 1.0, 0.25)

## A soft pulse of the card's border colour as it lands.
static func _glow(host: Node, card: Control, col: Color) -> void:
	var flash := ColorRect.new()
	flash.color = Color(col, 0.0)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(flash)
	var tw := host.create_tween()
	tw.tween_property(flash, "color:a", 0.30, 0.12)
	tw.tween_property(flash, "color:a", 0.0, 0.45)
	tw.tween_callback(flash.queue_free)

## The duplicate converts: the name dims and shrinks a touch, an orb with the
## gain rises out of the card, and the tag becomes the result.
static func _convert(host: Control, card: Control, info: Dictionary) -> void:
	var nm: Label = card.get_node_or_null("Box/Name")
	var tag: Label = card.get_node_or_null("Box/Tag")
	await host.get_tree().create_timer(0.42).timeout
	if not is_instance_valid(card):
		return
	var gains: Array = []
	if int(info["aether"]) > 0:
		gains.append(["+%d Aether" % int(info["aether"]), AETHER_COL])
	if int(info["lore"]) > 0:
		gains.append(["+%d Lore" % int(info["lore"]), LORE_COL])
	if nm != null:
		var tw := host.create_tween()
		tw.tween_property(nm, "modulate:a", 0.35, 0.3)
	var k := 0
	for gain in gains:
		_orb(host, card, str(gain[0]), gain[1], float(k) * 0.14)
		k += 1
	_settle_dup(card, info, 0.55)

static func _settle_dup(card: Control, info: Dictionary, delay: float = 0.0) -> void:
	if not info["dup"]:
		return
	var tag: Label = card.get_node_or_null("Box/Tag")
	var sub: Label = card.get_node_or_null("Box/Sub")
	var parts: Array = []
	if int(info["aether"]) > 0:
		parts.append("+%d Aether" % int(info["aether"]))
	if int(info["lore"]) > 0:
		parts.append("+%d Lore%s" % [int(info["lore"]), (" on " + str(info["loreOn"])) if str(info["loreOn"]) != "" and str(info["loreOn"]) != str(info["name"]) else ""])
	var apply := func():
		if is_instance_valid(sub):
			sub.text = "→ " + "  ".join(parts)
			sub.visible = true
			sub.add_theme_color_override("font_color", AETHER_COL if int(info["aether"]) > 0 else LORE_COL)
	if delay <= 0.0:
		apply.call()
	elif is_instance_valid(card) and card.is_inside_tree():
		card.get_tree().create_timer(delay).timeout.connect(apply)

## A small glowing label that pops, rises and fades out of the card.
static func _orb(host: Node, card: Control, text: String, col: Color, delay: float) -> void:
	var orb := Label.new()
	orb.text = text
	orb.add_theme_font_size_override("font_size", 18)
	orb.add_theme_color_override("font_color", col)
	orb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	orb.add_theme_constant_override("outline_size", 4)
	orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	orb.modulate.a = 0.0
	orb.z_index = 20
	card.add_child(orb)
	orb.position = Vector2(card.size.x * 0.25, card.size.y * 0.35)
	orb.pivot_offset = Vector2(20, 10)
	orb.scale = Vector2(0.6, 0.6)
	var tw := host.create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.set_parallel(true)
	tw.tween_property(orb, "modulate:a", 1.0, 0.12)
	tw.tween_property(orb, "scale", Vector2(1.25, 1.25), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().set_parallel(true)
	tw.tween_property(orb, "position:y", orb.position.y - 34.0, 0.55).set_ease(Tween.EASE_OUT)
	tw.tween_property(orb, "modulate:a", 0.0, 0.55).set_delay(0.2)
	tw.chain().tween_callback(orb.queue_free)

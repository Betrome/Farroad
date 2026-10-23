class_name RaidsWindow
extends RefCounted
## The Raids tab of the Arena screen: this week's boss, what it is strong and weak against, how much of it
## you've taken off, your attempts today, and last week's reward to claim. See Raids.gd.

const STRONG_COLOR := Color(1.0, 0.62, 0.55)
const WEAK_COLOR := Color(0.62, 1.0, 0.66)

static func build(gc: GameController, box: VBoxContainer) -> void:
	var now: float = Time.get_unix_time_from_system()
	var spec := Raids.spec(Raids.week_of(now))
	Raids.refresh(gc.g, now)

	# last week's reward, if one is waiting
	var pend: Array = gc.g["raid"].get("pending", [])
	if not pend.is_empty():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var best: Dictionary = Raids.tier_by_id(String(pend[pend.size() - 1]["tier"]))
		var lbl := Label.new()
		lbl.text = "Last week's raid: %s tier." % best["name"] if pend.size() == 1 else "%d finished weeks to claim." % pend.size()
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		var claim := Button.new()
		claim.text = "Claim"
		UiKit.primary(claim)
		claim.pressed.connect(func():
			var paid := Raids.claim_pending(gc.g, Time.get_unix_time_from_system())
			gc.refresh_hud()
			gc.save_game()
			claim.text = "+%d Crystal, +%d Marks, +%d Distilled" % [paid["crystal"], paid["marks"], paid["distilled"]]
			claim.disabled = true)
		row.add_child(claim)
		box.add_child(row)

	var title := Label.new()
	title.text = String(spec["name"])
	title.add_theme_font_size_override("font_size", int(gc.vp.y * 0.03))
	box.add_child(title)
	var left: float = float(Seasons.season_end(Raids.week_of(now))) - now
	var sub := Label.new()
	sub.text = "This week's raid boss. A new one arrives in %s." % GoalsWindow.eta_text(left)
	sub.modulate = Palette.TEXT_DIM
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(sub)

	# what it is strong and weak against, up front
	var lines := Raids.describe(spec)
	for i in lines.size():
		var l := Label.new()
		l.text = lines[i]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if i == 0:
			l.modulate = STRONG_COLOR
		elif i == 1:
			l.modulate = WEAK_COLOR
		box.add_child(l)

	# its HP this week
	var pool := Raids.pool(gc.g, now)
	var done := Raids.damage_done(gc.g, now)
	var pct := Raids.pct_done(gc.g, now)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = clampf(1.0 - pct, 0.0, 1.0)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, maxf(14.0, gc.vp.y * 0.02))
	box.add_child(bar)
	var hp_lbl := Label.new()
	hp_lbl.text = "Boss HP left: %.0f%%.  You have taken off %.1f%% of it." % [maxf(0.0, 1.0 - pct) * 100.0, pct * 100.0]
	hp_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hp_lbl)
	var tier := Raids.tier_for(pct)
	var next_tier: Dictionary = {}
	for t in Raids.TIERS:
		if pct < float(t["min"]):
			next_tier = t   # TIERS runs best first, so the last one not yet reached is the next
	var tier_lbl := Label.new()
	tier_lbl.text = ("Tier so far: %s." % tier["name"] if not tier.is_empty() else "No tier yet.") \
		+ ((" Next: %s at %d%%." % [next_tier["name"], roundi(float(next_tier["min"]) * 100.0)]) if not next_tier.is_empty() else " The boss is down.")
	tier_lbl.modulate = Palette.TEXT_DIM
	tier_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(tier_lbl)

	# the attempt
	var tries := Raids.attempts_left(gc.g, now)
	var party_ok: bool = not (gc.g["party"] as Array).is_empty()
	var go := Button.new()
	go.text = "Fight (%d of %d attempts left today)" % [tries, Raids.ATTEMPTS_PER_DAY]
	go.disabled = tries <= 0 or pct >= 1.0 or gc.g.get("sideBattle") != null or not party_ok
	UiKit.primary(go)
	go.pressed.connect(func(): gc.attempt_raid())
	box.add_child(go)
	var how := Label.new()
	how.text = "Your fielded party fights. Attempts come back at 00:00 UTC. Damage from every attempt counts toward the week."
	how.modulate = Palette.TEXT_DIM
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(how)

	# the reward tiers
	var th := Label.new()
	th.text = "WEEKLY REWARDS (by share of the boss's HP)"
	th.add_theme_font_size_override("font_size", 14)
	box.add_child(th)
	for i in range(Raids.TIERS.size() - 1, -1, -1):
		var t: Dictionary = Raids.TIERS[i]
		var r := Label.new()
		r.text = "%s, %d%%: %d Crystal, %d Marks%s" % [t["name"], roundi(float(t["min"]) * 100.0), int(t["crystal"]),
			int(t["pulls"]) * FarroadProgression.pull_cost(1), (", %d Distilled Aether" % int(t["distilled"])) if int(t["distilled"]) > 0 else ""]
		r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		r.modulate = Palette.TEXT_DIM
		box.add_child(r)

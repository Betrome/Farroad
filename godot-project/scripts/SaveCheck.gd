class_name SaveCheck
extends RefCounted
## Cloud-save anti-cheat (runs on the PvP server). An uploaded save is
## compared with the last one accepted from that player, using the server's
## own clock for the time between them (a player can change their phone's
## clock, not the server's). It can't replay an idle game, so it checks
## ceilings: how far the Road can go, and how much Aether, Marks and Crystal
## can be earned, in that much time. The ceilings are deliberately generous
## (several times the fastest real play) so honest players never trip them;
## an edited save usually overshoots by thousands of times.

## Fastest a Road wave can be cleared, offline catch-up included (seconds).
const MIN_WAVE_SEC := 4.0
## Head room on every earnings ceiling.
const SLACK := 5.0
const FLAT_AETHER := 2000.0
const FLAT_MARKS := 500.0
const FLAT_CRYSTAL := 30.0
## Crystal comes from dungeons and quests: generously, this many per hour.
const CRYSTAL_PER_HOUR := 40.0
## A first upload has no earlier save to compare with: it's held to what a
## whole game up to its furthest wave could have earned, this many times over
## (replays, idle, expeditions and months of play all fit well inside).
const LIFETIME_MUL := 60.0

## Rewards claimed in one go can't be seen in the save's history: Arena season rewards (the server
## pays those itself), raid weeks and Paths Crystal (both client-only), and Distilled Aether, which turns
## into unit levels. So the server keeps a credit per player: season claims add exactly what they paid,
## raid and Paths rewards accrue with real time (up to 8 weeks of backlog), and every accepted upload
## draws down what it gained beyond the normal earning ceilings. How often a player uploads can't
## change what they're allowed in total.
const WEEK_SEC := 604800.0
const BACKLOG_WEEKS := 8.0
const RAID_CRYSTAL_WEEK := 30.0     # raid Platinum (10) + the community boss's top milestone (20)
const RAID_MARKS_WEEK := 800.0      # 8 pulls
const RAID_DISTILLED_WEEK := 4.0
const PATHS_CRYSTAL_DAY := 5.0

## A new player's credit: one week's worth to start with.
static func new_credit(now: int) -> Dictionary:
	return {"crystal": RAID_CRYSTAL_WEEK + PATHS_CRYSTAL_DAY * 7.0, "marks": RAID_MARKS_WEEK, "distilled": RAID_DISTILLED_WEEK, "at": now}

## Adds what accrued since the credit was last brought up to date (in place).
static func accrue(credit: Dictionary, now: int) -> void:
	var dt: float = maxf(0.0, float(now) - float(credit.get("at", now)))
	var weeks: float = dt / WEEK_SEC
	var cap_c: float = BACKLOG_WEEKS * (RAID_CRYSTAL_WEEK + PATHS_CRYSTAL_DAY * 7.0)
	var cap_m: float = BACKLOG_WEEKS * RAID_MARKS_WEEK
	var cap_d: float = BACKLOG_WEEKS * RAID_DISTILLED_WEEK
	var c: float = float(credit.get("crystal", 0.0))
	var m: float = float(credit.get("marks", 0.0))
	var d: float = float(credit.get("distilled", 0.0))
	credit["crystal"] = minf(c + weeks * (RAID_CRYSTAL_WEEK + PATHS_CRYSTAL_DAY * 7.0), maxf(c, cap_c))
	credit["marks"] = minf(m + weeks * RAID_MARKS_WEEK, maxf(m, cap_m))
	credit["distilled"] = minf(d + weeks * RAID_DISTILLED_WEEK, maxf(d, cap_d))
	credit["at"] = now

## A season claim the server just paid.
static func add_claim(credit: Dictionary, crystal: float, marks: float, distilled: float) -> void:
	credit["crystal"] = float(credit.get("crystal", 0.0)) + crystal
	credit["marks"] = float(credit.get("marks", 0.0)) + marks
	credit["distilled"] = float(credit.get("distilled", 0.0)) + distilled

## The Aether-equivalent of one Distilled Aether in this save: the dearest next level (at the floor discount).
static func distilled_value(snap: Dictionary) -> float:
	var lvl: Dictionary = snap.get("lvl", {}) if snap.get("lvl") is Dictionary else {}
	var dearest := 0.0
	for uid in lvl:
		var l := int(lvl[uid])
		dearest = maxf(dearest, float(FarroadProgression.exp_for(l + 1) - FarroadProgression.exp_for(l)))
	return maxf(1.0, dearest * FarroadProgression.DISCOUNT_FLOOR)

## "" when the new save is possible after `prev` with `elapsed` seconds
## between them (prev = {} for a first upload), else why not.
static func check(prev: Dictionary, snap: Dictionary, elapsed: float, credit: Dictionary = {}) -> String:
	if not (snap is Dictionary) or not snap.has("farthest") or not snap.has("lvl"):
		return "bad_save"
	var far_new := int(snap.get("farthest", 1))
	var far_old := int(prev.get("farthest", 1)) if not prev.is_empty() else 1
	if far_new < 1 or far_new > 1000000:
		return "bad_save"
	if not _levels_ok(snap):
		return "bad_levels"
	if prev.is_empty():
		var cap_a := lifetime_aether(far_new)
		if wealth(snap) > cap_a:
			return "too_rich"
		if float(snap.get("marks", 0)) > lifetime_marks(far_new):
			return "too_many_marks"
		return ""
	elapsed = maxf(0.0, elapsed)
	if far_new > far_old + int(elapsed / MIN_WAVE_SEC) + 30:
		return "too_far"
	var gained := wealth(snap) - wealth(prev)
	if gained > aether_ceiling(maxi(far_new, far_old), elapsed) + float(credit.get("distilled", 0.0)) * distilled_value(snap):
		return "too_rich"
	var marks_gained := float(snap.get("marks", 0)) - float(prev.get("marks", 0))
	if marks_gained > marks_ceiling(maxi(far_new, far_old), elapsed) + float(credit.get("marks", 0.0)):
		return "too_many_marks"
	var crystal_gained := float(snap.get("crystal", 0)) - float(prev.get("crystal", 0))
	if crystal_gained > FLAT_CRYSTAL + CRYSTAL_PER_HOUR * elapsed / 3600.0 + float(credit.get("crystal", 0.0)):
		return "too_much_crystal"
	return ""

static func _levels_ok(snap: Dictionary) -> bool:
	var lvl = snap.get("lvl", {})
	if not (lvl is Dictionary):
		return false
	for uid in lvl:
		var l = lvl[uid]
		if not (l is int or l is float) or int(l) < 1 or int(l) > Ranked.MAX_LEVEL:
			return false
	return true

## Aether on hand plus the least the levels it holds could have cost (the
## catch-up discount at its floor), so Aether hidden in levels still counts.
static func wealth(snap: Dictionary) -> float:
	var w := float(snap.get("aether", 0)) + float(snap.get("pendingIdleAether", 0))
	var lvl: Dictionary = snap.get("lvl", {})
	for uid in lvl:
		w += float(FarroadProgression.exp_for(int(lvl[uid]))) * FarroadProgression.DISCOUNT_FLOOR
	var bank: Dictionary = snap.get("bank", {}) if snap.get("bank") is Dictionary else {}
	for uid in bank:
		w += float(bank[uid])
	return w

## The most Aether a player at `far` could earn in `sec` seconds: Road waves
## back to back at the fastest pace, idle income and eight expeditions, all
## with plenty of head room.
## The largest catch-up multiplier a player could have earned under (see
## FarroadProgression.catchup_mul), as head room.
const CATCHUP_HEADROOM := 1.0 + FarroadProgression.CATCHUP_MAX_BONUS

static func aether_ceiling(far: int, sec: float) -> float:
	var per_wave: float = FarroadProgression.kill_reward(far, FarroadProgression.enemy_count(far))["aether"]
	var road: float = per_wave * sec / MIN_WAVE_SEC
	var idle: float = FarroadProgression.idle_per_sec(far)["aether"] * sec
	var exped: float = 8.0 * per_wave * FarroadProgression.EXPED_REWARD_MUL * sec / 60.0
	var bosses: float = float(FarroadProgression.boss_aether(far)) * (sec / (MIN_WAVE_SEC * 20.0) + 1.0)
	return FLAT_AETHER + SLACK * CATCHUP_HEADROOM * (road + idle + exped + bosses)

static func marks_ceiling(far: int, sec: float) -> float:
	var per_wave: float = FarroadProgression.kill_reward(far, FarroadProgression.enemy_count(far))["marks"]
	var road: float = per_wave * sec / MIN_WAVE_SEC
	var idle: float = FarroadProgression.idle_per_sec(far)["marks"] * sec
	var exped: float = 8.0 * per_wave * FarroadProgression.EXPED_REWARD_MUL * sec / 60.0
	return FLAT_MARKS + SLACK * CATCHUP_HEADROOM * (road + idle + exped)

## Everything a game up to wave `far` could plausibly hold, for a first upload.
static func lifetime_aether(far: int) -> float:
	var t := 0.0
	for w in range(1, far + 1):
		var cu: float = FarroadProgression.catchup_mul({"farthest": w})
		t += FarroadProgression.kill_reward(w, FarroadProgression.enemy_count(w))["aether"] * cu
		if FarroadProgression.is_boss_wave(w):
			t += float(FarroadProgression.boss_aether(w)) * cu
	return FLAT_AETHER * 5.0 + LIFETIME_MUL * t

static func lifetime_marks(far: int) -> float:
	var t := 0.0
	for w in range(1, far + 1):
		t += FarroadProgression.kill_reward(w, FarroadProgression.enemy_count(w))["marks"] * FarroadProgression.catchup_mul({"farthest": w})
	return FLAT_MARKS * 5.0 + LIFETIME_MUL * t

## After an accepted upload: draws down the credit by what the save gained beyond the normal ceilings.
static func spend_credit(credit: Dictionary, prev: Dictionary, snap: Dictionary, elapsed: float) -> void:
	if prev.is_empty():
		return
	elapsed = maxf(0.0, elapsed)
	var far: int = maxi(int(snap.get("farthest", 1)), int(prev.get("farthest", 1)))
	var crystal_over: float = float(snap.get("crystal", 0)) - float(prev.get("crystal", 0)) - (FLAT_CRYSTAL + CRYSTAL_PER_HOUR * elapsed / 3600.0)
	var marks_over: float = float(snap.get("marks", 0)) - float(prev.get("marks", 0)) - marks_ceiling(far, elapsed)
	var wealth_over: float = wealth(snap) - wealth(prev) - aether_ceiling(far, elapsed)
	credit["crystal"] = maxf(0.0, float(credit.get("crystal", 0.0)) - maxf(0.0, crystal_over))
	credit["marks"] = maxf(0.0, float(credit.get("marks", 0.0)) - maxf(0.0, marks_over))
	credit["distilled"] = maxf(0.0, float(credit.get("distilled", 0.0)) - ceil(maxf(0.0, wealth_over) / distilled_value(snap)))

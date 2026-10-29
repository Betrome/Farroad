class_name FarroadSave
extends RefCounted
## Turns the live game state into a plain snapshot (serialize) and back (deserialize).
## Neither touches the filesystem: the caller passes in the time and the parsed JSON,
## so both stay pure and testable. SaveStore.gd reads and writes the actual file.

## Save format version, stored as "v" in every snapshot.
##   1  everything up to the versioned-migration change (the "v" was never read back)
##   2  one-off migrations below run once, for saves older than this
##   3  gear is no longer owned in copies: equipInv is 1 per piece and the levels live in gearLevel
##      (an older build would read such a save as a one-copy inventory and save the levels away)
## To change the format: bump VERSION, add a `_migrate_to_N(g)` step and call it from `_migrate`
## for saves with from_v < N. Plain "this field didn't exist yet" defaults need no step; the
## default-fill in deserialize() covers them for any old save.
const VERSION := 3

## True when the snapshot was written by a newer build than this one. Loading it here would
## silently drop fields this build doesn't know and then save the result over it.
static func is_from_newer_build(snap: Dictionary) -> bool:
	return int(snap.get("v", 1)) > VERSION

## The fields saved as-is. Anything not listed (the live battle, units, enemies) is rebuilt on load.
## "lore" (one global total) was replaced by "loreByAction" (one total per action); an old
## global total is not carried over, every action starts at 0.
const FIELDS: Array[String] = ["wave", "farthest", "bossesCleared", "aether", "loreByAction", "marks", "crystal", "wipes", "enemiesDefeated",
	"party", "partyPresets", "loadoutSets", "gearSets", "rows", "wipeLog", "appearance", "approach", "pvp", "actions", "conditions", "actionCounts", "condCounts", "bonuses", "recovery",
	"loadout", "hpCarry", "chargeCarry", "touched", "clearedWaves", "dropsGranted", "lvl", "bank", "maxLevelEver", "owned",
	"enrage", "idleAcc", "dropQueue", "dropHistory", "pullsSinceUnit", "pullsSinceAff",
	"dropGains", "mc", "expeditions", "dungeons", "quests", "directions",
	"affinities", "statInvest", "equipInv", "gearLevel", "equipped",
	"superBossQuests", "superBossesUnlocked", "superBossesCleared",
	"pendingIdleAether", "pendingIdleMarks", "mcRespecs", "mcRespecGranted", "trainingSetup", "goals", "distilled", "raid", "path", "chest"]

## Deep copy through JSON. Safe because saved fields are only plain Dictionaries, Arrays and numbers/strings.
static func _clone(v: Variant) -> Variant:
	if v == null:
		return null
	return JSON.parse_string(JSON.stringify(v))

## @param g    live game state
## @param now  caller-supplied Unix timestamp (Time.get_unix_time_from_system()) --
##             kept a parameter, not a call, so this stays pure and testable.
static func serialize(g: Dictionary, now: int) -> Dictionary:
	var snap := {"v": VERSION, "savedAt": now, "seed": g["seed"], "rngCalls": g["rng"].calls if g.get("rng") else 0,
		"rngState": g["rng"].a if g.get("rng") else 0}
	for k in FIELDS:
		snap[k] = _clone(g.get(k))
	# Fields only this version of the game has (the web version never had them), kept out of
	# FIELDS and saved as their own top-level keys: the Catalogue's seen enemies, which tab
	# tutorials were shown, the guided tutorials' progress, and a forced next pull.
	snap["seenArch"] = _clone(g.get("seenArch"))
	snap["seenTabTutorial"] = _clone(g.get("seenTabTutorial"))
	snap["tutorials"] = _clone(g.get("tutorials"))
	snap["tutorialSkip"] = g.get("tutorialSkip", false)
	snap["forcedPull"] = g.get("forcedPull")
	return snap

## Runs the one-off format migrations a snapshot written at version `from_v` still needs.
static func _migrate(g: Dictionary, from_v: int) -> void:
	if from_v < 2:
		_migrate_to_2(g)
	if from_v < 3:
		_migrate_to_3(g)

## v2 -> v3: duplicate gear copies become levels, and one piece is never worn twice.
static func _migrate_to_3(g: Dictionary) -> void:
	FarroadProgression.migrate_gear(g)

## v1 -> v2: the migrations that used to run on every load, now run once.
static func _migrate_to_2(g: Dictionary) -> void:
	# Magibolt replaced Ember as the starter: older saves gain it, and every
	# loadout slot still on Ember switches to it (Ember stays owned, so any
	# Lore in it isn't lost -- and it's no longer shared between units).
	if not g["actions"].has("magibolt"):
		g["actions"].append("magibolt")
		for uid in (g.get("loadout", {}) as Dictionary).keys():
			for sl in g["loadout"][uid]:
				if sl.get("action") == "ember":
					sl["action"] = "magibolt"
	# Keen (crit) was removed from Lore: refund the difference its removal makes to that action's
	# price into the action's own Lore pool, then strip it.
	for aid in g["bonuses"].keys():
		var b: Dictionary = g["bonuses"][aid]
		if not b or not b.get("keen"):
			continue
		var without := {}
		for k in b.keys():
			if k != "keen":
				without[k] = b[k]
		var refund: int = FarroadCore.bonus_spend({"x": b}) - FarroadCore.bonus_spend({"x": without})
		g["loreByAction"][aid] = float(g["loreByAction"].get(aid, 0.0)) + float(refund)
		b.erase("keen")


## Rebuilds the live game state from a parsed snapshot, filling in anything an older save lacks.
## The random generator is restored from its saved state (rngState); a save from before that
## existed only has a draw count, so it is replayed that many draws from the seed.
static func deserialize(snap: Dictionary) -> Dictionary:
	if snap.is_empty():
		return {}
	var rng := FarroadCore.make_rng(snap.get("seed", 7))
	var calls: int = int(snap.get("rngCalls", 0))
	if snap.has("rngState"):
		# the generator's whole state is one 32-bit number: restore it directly (no replay)
		rng.a = int(snap["rngState"]) & 0xFFFFFFFF
		rng.calls = calls
	else:
		# an older save that only counted draws: replay them once; the next save stores the state
		for i in range(calls):
			rng.next()
	var g := {"seed": snap.get("seed", 7), "rng": rng, "battle": null, "units": null,
		"enemies": null, "over": null, "sideBattle": null, "roadBattle": null}
	for k in FIELDS:
		g[k] = _clone(snap.get(k))

	# Defend against a snapshot saved by an older build that predates a field --
	# fall back to new_game()'s own defaults rather than crashing on load.
	if not g.get("party") or g["party"].is_empty():
		g["party"] = ["kesh"]
	if not g.get("actions") or g["actions"].is_empty():
		g["actions"] = ["strike", "magibolt"]
	if not g.get("conditions") or g["conditions"].is_empty():
		g["conditions"] = ["none"]
	for k in ["actionCounts", "condCounts", "bonuses", "recovery", "loadout", "hpCarry", "chargeCarry", "touched",
		"clearedWaves", "lvl", "bank", "owned"]:
		g[k] = g.get(k) if g.get(k) != null else {}

	if not g.get("loreByAction"):
		g["loreByAction"] = {}
	_migrate(g, int(snap.get("v", 1)))

	# dropsGranted is stricter than clearedWaves: an old save without it is seeded from clearedWaves,
	# so an already-cleared wave doesn't drop its reward again
	if not g.get("dropsGranted"):
		g["dropsGranted"] = _clone(g.get("clearedWaves")) if g.get("clearedWaves") else {}
	if not g["lvl"].get("kesh"):
		g["lvl"]["kesh"] = 1
	if g["bank"].get("kesh") == null:
		g["bank"]["kesh"] = 0
	if not g["owned"].get("kesh"):
		g["owned"]["kesh"] = 1
	g["maxLevelEver"] = g.get("maxLevelEver") if g.get("maxLevelEver") else 1
	g["wave"] = g.get("wave") if g.get("wave") else 0
	g["farthest"] = g.get("farthest") if g.get("farthest") else 1
	g["bossesCleared"] = g.get("bossesCleared") if g.get("bossesCleared") else 0
	g["aether"] = g.get("aether") if g.get("aether") else 0
	g["loreByAction"] = g.get("loreByAction") if g.get("loreByAction") else {}
	g["marks"] = g.get("marks") if g.get("marks") else 0
	g["crystal"] = g.get("crystal") if g.get("crystal") else 0
	g["wipes"] = g.get("wipes") if g.get("wipes") else 0
	g["enemiesDefeated"] = g.get("enemiesDefeated") if g.get("enemiesDefeated") else 0
	g["goals"] = g.get("goals") if g.get("goals") is Dictionary else {}
	g["distilled"] = int(g.get("distilled")) if g.get("distilled") else 0
	g["raid"] = g.get("raid") if g.get("raid") is Dictionary else {}
	g["path"] = g.get("path") if g.get("path") is Dictionary else {}
	g["chest"] = g.get("chest") if g.get("chest") is Dictionary else {}
	g["pendingIdleAether"] = g.get("pendingIdleAether") if g.get("pendingIdleAether") else 0.0
	g["pendingIdleMarks"] = g.get("pendingIdleMarks") if g.get("pendingIdleMarks") else 0.0
	g["mcRespecs"] = int(g.get("mcRespecs")) if g.get("mcRespecs") else 0
	g["mcRespecGranted"] = bool(g.get("mcRespecGranted")) if g.get("mcRespecGranted") != null else false
	g["idleAcc"] = g.get("idleAcc") if g.get("idleAcc") else 0
	g["enrage"] = g.get("enrage") != false
	g["seenArch"] = _clone(snap.get("seenArch")) if snap.get("seenArch") else {}
	g["seenTabTutorial"] = _clone(snap.get("seenTabTutorial")) if snap.get("seenTabTutorial") else {}
	# guided tutorials (Tutorial.gd); a save from before them is migrated by
	# Tutorial.migrate (anything already passed counts as done)
	g["tutorials"] = _clone(snap.get("tutorials")) if snap.get("tutorials") is Dictionary else null
	g["tutorialSkip"] = bool(snap.get("tutorialSkip", false))
	g["forcedPull"] = snap.get("forcedPull")

	# saves from before expeditions existed just get an empty list
	if not g.get("expeditions"):
		g["expeditions"] = []
	if not g.get("rows"):
		g["rows"] = {}
	if not g.get("loadoutSets"):
		g["loadoutSets"] = {}
	if not g.get("gearSets"):
		g["gearSets"] = {}
	if not g.get("partyPresets"):
		g["partyPresets"] = []
	if not g.get("wipeLog"):
		g["wipeLog"] = []
	if not g.get("appearance"):
		g["appearance"] = {}
	if not g.get("approach"):
		g["approach"] = {}
	if not (g.get("pvp") is Dictionary):
		g["pvp"] = {"wins": 0, "losses": 0, "history": []}
	if not g.get("dungeons"):
		g["dungeons"] = []
	if not g.get("superBossQuests"):
		g["superBossQuests"] = []
	if not g.get("superBossesUnlocked"):
		g["superBossesUnlocked"] = 0
	if not g.get("superBossesCleared"):
		g["superBossesCleared"] = {}
	if not g.get("quests"):
		g["quests"] = {}
	if not g["quests"].get("kesh"):
		g["quests"]["kesh"] = {"stage": 0, "frozen": []}

	var dirs: Array[String] = ["west", "northwest", "southwest", "north", "south",
		"northeast", "southeast", "east"]
	if not g.get("directions"):
		g["directions"] = {}
	for dir in dirs:
		if not g["directions"].get(dir):
			g["directions"][dir] = {"maxDepth": 0, "dungeonsUnlocked": 0}
	for exp in g.get("expeditions", []):
		if not exp.get("direction"):
			exp["direction"] = "west"
	g["pullsSinceUnit"] = g.get("pullsSinceUnit") if g.get("pullsSinceUnit") else 0
	g["pullsSinceAff"] = g.get("pullsSinceAff") if g.get("pullsSinceAff") else 0
	if not g.get("affinities"):
		g["affinities"] = {}
	if not g["affinities"].get("kesh"):
		g["affinities"]["kesh"] = {}
	if not g.get("statInvest"):
		g["statInvest"] = {}
	if not g["statInvest"].get("kesh"):
		g["statInvest"]["kesh"] = {}
	if not g.get("equipInv"):
		g["equipInv"] = {}
	if not g.get("equipped"):
		g["equipped"] = {}
	if not g["equipped"].get("kesh"):
		g["equipped"]["kesh"] = {}
	g["gearLevel"] = g.get("gearLevel") if g.get("gearLevel") is Dictionary else {}
	return g

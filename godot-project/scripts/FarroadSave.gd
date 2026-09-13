class_name FarroadSave
extends RefCounted
## Ported save/load layer -- GDScript counterpart to src/farroad-save.js.
## Headless by design, like the two scripts it sits alongside: serialize/
## deserialize never touch the filesystem themselves (`now` and the parsed
## snapshot are passed in by the caller), so they stay pure and testable the
## same way the real module's own smoke-test round-trip works. Reading and
## writing the actual save FILE (Godot's `user://` -- see MODULES.md's
## localStorage-equivalent note) is GameController's job (Step 3b), the same
## way farroad-ui.js (not farroad-save.js) owns localStorage in the real game.

const VERSION := 1

## Plain fields copied as-is -- mirrors FIELDS (farroad-save.js:25-102)
## exactly, field-for-field, same order.
const FIELDS: Array[String] = ["wave", "farthest", "bossesCleared", "aether", "lore", "marks", "wipes",
	"party", "actions", "conditions", "actionCounts", "condCounts", "bonuses", "recovery",
	"loadout", "hpCarry", "touched", "clearedWaves", "dropsGranted", "lvl", "bank", "maxLevelEver", "owned",
	"enrage", "idleAcc", "dropQueue", "dropHistory", "pullsSinceUnit",
	"dropGains", "mc", "expeditions", "dungeons", "quests", "directions",
	"affinities", "statInvest", "equipInv", "equipped",
	"superBossQuests", "superBossesUnlocked", "superBossesCleared"]

## JSON round-trip is Godot's own equivalent of JS's `JSON.parse(JSON.stringify(v))`
## deep-clone -- values here are always plain Dictionaries/Arrays/primitives
## (game-state fields, never a live RNG/Battle object), so this is safe.
static func _clone(v: Variant) -> Variant:
	if v == null:
		return null
	return JSON.parse_string(JSON.stringify(v))

## @param g    live game state
## @param now  caller-supplied Unix timestamp (Time.get_unix_time_from_system()) --
##             kept a parameter, not a call, so this stays pure and testable.
static func serialize(g: Dictionary, now: int) -> Dictionary:
	var snap := {"v": VERSION, "savedAt": now, "seed": g["seed"], "rngCalls": g["rng"].calls if g.get("rng") else 0}
	for k in FIELDS:
		snap[k] = _clone(g.get(k))
	return snap

## @param snap parsed snapshot Dictionary (caller does the JSON parse)
##
## RNG NOTE: RNG's internal state is a plain field here (unlike JS's closure),
## but it's reseeded and fast-forwarded the same way regardless -- reaching
## the identical internal state because the generator is a pure function of
## (seed, call count), matching farroad-save.js's own documented approach.
static func deserialize(snap: Dictionary) -> Dictionary:
	if snap.is_empty():
		return {}
	var rng := FarroadCore.make_rng(snap.get("seed", 7))
	var calls: int = snap.get("rngCalls", 0)
	for i in range(calls):
		rng.next()
	var g := {"seed": snap.get("seed", 7), "rng": rng, "battle": null, "units": null,
		"enemies": null, "over": null}
	for k in FIELDS:
		g[k] = _clone(snap.get(k))

	# Defend against a snapshot saved by an older build that predates a field --
	# fall back to new_game()'s own defaults rather than crashing on load.
	if not g.get("party") or g["party"].is_empty():
		g["party"] = ["kesh"]
	if not g.get("actions") or g["actions"].is_empty():
		g["actions"] = ["strike", "ember"]
	if not g.get("conditions") or g["conditions"].is_empty():
		g["conditions"] = ["none"]
	for k in ["actionCounts", "condCounts", "bonuses", "recovery", "loadout", "hpCarry", "touched",
		"clearedWaves", "lvl", "bank", "owned"]:
		g[k] = g.get(k) if g.get(k) != null else {}

	# v2.11 MIGRATION: Keen (crit) retired from Lore entirely -- refund the
	# difference this action's own triangular price drops by once keen no
	# longer counts toward its stack total, then strip it.
	for aid in g["bonuses"].keys():
		var b: Dictionary = g["bonuses"][aid]
		if not b or not b.get("keen"):
			continue
		var without := {}
		for k in b.keys():
			if k != "keen":
				without[k] = b[k]
		var refund: int = FarroadCore.bonus_spend({"x": b}) - FarroadCore.bonus_spend({"x": without})
		g["lore"] = g.get("lore", 0) + refund
		b.erase("keen")

	# v2.9: dropsGranted is a stricter gate than clearedWaves -- seed it from
	# clearedWaves for a save from before this field existed, so an
	# already-cleared wave isn't granted its drop again.
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
	g["lore"] = g.get("lore") if g.get("lore") else 0
	g["marks"] = g.get("marks") if g.get("marks") else 0
	g["wipes"] = g.get("wipes") if g.get("wipes") else 0
	g["idleAcc"] = g.get("idleAcc") if g.get("idleAcc") else 0
	g["enrage"] = g.get("enrage") != false

	# v2.9 MIGRATION: pre-multi-expedition saves aren't handled here (that
	# legacy 'expedition'/'expeditionLog' shape predates this whole feature
	# on the Godot side -- nothing to migrate FROM yet) -- a genuinely new or
	# post-this-feature save just default-fills [].
	if not g.get("expeditions"):
		g["expeditions"] = []
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
	return g

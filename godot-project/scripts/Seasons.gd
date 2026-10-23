class_name Seasons
extends RefCounted
## Weekly Arena seasons (Ian). Shared by the server (which closes a season and decides each
## player's tier) and the game (which shows the season and pays the reward).
##
## A season is one week, Monday 00:00 UTC to the next Monday 00:00 UTC (one clock for everyone, so it
## can't be each player's local midnight; the game shows the countdown in local time). When a season
## ends, every player with at least MIN_FIGHTS fights that season gets a tier from their final rating
## (the top TOP_N get Champion), their rating is pulled halfway back to the starting rating for the
## new season, and the reward waits for them to claim it the next time they open the Arena.
##
## The server only runs seasons when it is started with FARROAD_SEASONS=1 (or --seasons); until then
## nothing here has any effect.

const MIN_FIGHTS := 5
const TOP_N := 3
const CARRY := 0.5   # the share of a rating's distance from the starting rating kept into the next season

## Best tier first. `min` is the final rating needed; Champion also needs a top-TOP_N finish.
## Rewards: Crystals, Marks as a number of pulls' worth (so they scale with progress), and
## Distilled Aether (one unit level each).
const TIERS: Array = [
	{"id": "champion", "name": "Champion", "min": 1250, "top": true, "crystal": 25, "pulls": 10, "distilled": 5},
	{"id": "platinum", "name": "Platinum", "min": 1200, "top": false, "crystal": 12, "pulls": 5, "distilled": 3},
	{"id": "gold", "name": "Gold", "min": 1100, "top": false, "crystal": 7, "pulls": 3, "distilled": 2},
	{"id": "silver", "name": "Silver", "min": 1050, "top": false, "crystal": 4, "pulls": 2, "distilled": 1},
	{"id": "bronze", "name": "Bronze", "min": -100000, "top": false, "crystal": 2, "pulls": 1, "distilled": 1},
]

## The season number a moment belongs to (weeks since the first Monday, 1970-01-05).
static func season_of(ts) -> int:
	var day := int(floor(float(ts) / 86400.0))
	return int(floor(float(day + 3) / 7.0))

## When a season ends (the start of the next one), as unix seconds.
static func season_end(season: int) -> int:
	return ((season + 1) * 7 - 3) * 86400

static func tier_by_id(id: String) -> Dictionary:
	for t in TIERS:
		if String(t["id"]) == id:
			return t
	return TIERS[TIERS.size() - 1]

## The tier a finished season earns: `rank` is 1 for the best rating among the qualifiers.
static func tier_for(rating: int, rank: int) -> Dictionary:
	for t in TIERS:
		if bool(t["top"]):
			if rank <= TOP_N and rating >= int(t["min"]):
				return t
		elif rating >= int(t["min"]):
			return t
	return TIERS[TIERS.size() - 1]

## A rating carried into the next season.
static func carried_rating(rating: float, start: float) -> int:
	return int(round(start + (rating - start) * CARRY))

## Pays a claimed reward (the tier's own numbers, looked up by id so the server only sends the tier).
## Returns {"crystal": n, "marks": n, "distilled": n} for the popup.
static func pay(g: Dictionary, tier_id: String) -> Dictionary:
	var t := tier_by_id(tier_id)
	var marks: int = int(t["pulls"]) * FarroadProgression.pull_cost(int(g.get("wave", 1)))
	g["crystal"] = int(g.get("crystal", 0)) + int(t["crystal"])
	g["marks"] = float(g.get("marks", 0)) + float(marks)
	g["distilled"] = int(g.get("distilled", 0)) + int(t["distilled"])
	return {"crystal": int(t["crystal"]), "marks": marks, "distilled": int(t["distilled"])}

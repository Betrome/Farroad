class_name AutoInvest
extends RefCounted
## Smarter auto-spend for the Aether tab: spends a unit's budget on whatever buys the most
## strength per Aether, instead of an even split.
##
## Every purchase (a level, a Recovery step, an Evade or crit step, an affinity point) is scored by
## how much it raises the unit's estimated combat strength, divided by its cost, and the best one is
## bought, over and over, until the budget runs out.
##
## The strength estimate is the log of (damage output x survival):
##   damage   = the unit's attack stats weighted by how much of its loadout uses each (crits count),
##              times its affinity bonus for the elements its actions use
##   survival = HP x its DEF/RES against the current wave's enemy scaling x evade x Recovery x its
##              average affinity resistance
##   plus a little for speed (more turns).
## So a point goes where it multiplies the most, and levels stop being the default: when one is
## expensive, a cheap Evade step or affinity point wins instead.
##
## plan() works out the purchases without changing anything; apply() then buys them through the
## normal spending functions (so goals, analytics and costs behave exactly as a manual purchase).

const SPEED_WEIGHT := 0.6          # how much speed counts next to damage and survival
const RECOVERY_VALUE := 0.8        # share of a Recovery step's HP that is worth having
const ELEMENT_AXES := ["fire", "water", "earth", "air", "light", "dark"]
const MAX_STEPS := 4000

## What a unit's loadout leans on: {"atk": share, "mag": share, "el": {axis: share}}.
static func _loadout_shares(g: Dictionary, uid: String) -> Dictionary:
	var atk := 0.0
	var mag := 0.0
	var el := {}
	var total := 0.0
	for slot in g.get("loadout", {}).get(uid, []):
		var a = FarroadCore.ACTIONS.get(String(slot.get("action", "")))
		if a == null:
			continue
		var w: float = maxf(0.1, float(a.get("power", 1.0)))
		total += w
		if String(a.get("camp", "atk")) == "mag":
			mag += w
		else:
			atk += w
		var ax := String(a.get("element", ""))
		if ax != "":
			el[ax] = float(el.get(ax, 0.0)) + w
	if total <= 0.0:
		return {"atk": 0.5, "mag": 0.5, "el": {}}
	for k in el.keys():
		el[k] = float(el[k]) / total
	return {"atk": atk / total, "mag": mag / total, "el": el}

## ln of the strength estimate for the unit as it stands in `g`.
static func strength(g: Dictionary, uid: String, shares: Dictionary) -> float:
	var def = FarroadCore.roster_by_id(uid)
	if def == null:
		return 0.0
	var st := FarroadProgression.stats_at(uid, def["stats"], def["hp"], FarroadProgression.level_of(g, uid))
	FarroadProgression.apply_pct_stat_investment(g, uid, st)
	FarroadProgression.apply_equipment_stats(g, uid, st)
	var crit_gain: float = FarroadCore.CRIT_MUL - 1.0
	var atk_term: float = maxf(1.0, float(st["atk"])) * (1.0 + minf(FarroadCore.CAP_CRIT, float(st["atkCrit"])) * crit_gain)
	var mag_term: float = maxf(1.0, float(st["mag"])) * (1.0 + minf(FarroadCore.CAP_CRIT, float(st["magCrit"])) * crit_gain)
	var ln_off: float = float(shares["atk"]) * log(atk_term) + float(shares["mag"]) * log(mag_term)
	var aff := FarroadProgression.effective_affinity(g, uid)
	for ax in (shares["el"] as Dictionary).keys():
		ln_off += float(shares["el"][ax]) * log(FarroadCore._aff_dealt(FarroadCore.affinity_mul(float(aff.get(ax, 0.0)))))
	var k: float = FarroadCore.K_BASE * FarroadCore.wave_scale(float(maxi(1, int(g.get("wave", 1)))))
	var evade: float = minf(float(st["evade"]), FarroadCore.CAP_EVADE)
	var ln_surv: float = log(maxf(1.0, float(st["hp"]))) \
		+ 0.5 * log((k + float(st["def"])) / k) + 0.5 * log((k + float(st["res"])) / k) \
		- log(1.0 - evade) + log(1.0 + RECOVERY_VALUE * FarroadProgression.recovery_of(g, uid))
	# what the unit takes from each element, averaged over the six (the enemy's element is unknown)
	var ln_res := 0.0
	for ax in ELEMENT_AXES:
		ln_res -= log(FarroadCore._aff_taken(FarroadCore.affinity_mul(float(aff.get(ax, 0.0))))) / float(ELEMENT_AXES.size())
	return ln_off + ln_surv + ln_res + SPEED_WEIGHT * log(maxf(1.0, float(st["spd"])))

## Candidate purchases right now: [{kind, arg, cost}] (kind: level / recovery / stat / affinity).
static func _candidates(g: Dictionary, uid: String) -> Array:
	var out: Array = []
	var lvl_cost: int = maxi(1, FarroadProgression.cost_next(g, uid) - int(FarroadProgression.exp_of(g, uid)))
	out.append({"kind": "level", "arg": "", "cost": lvl_cost})
	if not FarroadProgression.recovery_maxed(g, uid):
		out.append({"kind": "recovery", "arg": "", "cost": FarroadProgression.recovery_cost(g, uid)})
	for st in FarroadProgression.PCT_STAT_KEYS:
		if not FarroadProgression.pct_stat_maxed(g, uid, st):
			out.append({"kind": "stat", "arg": st, "cost": FarroadProgression.pct_stat_cost(st, FarroadProgression.pct_stat_purchased(g, uid, st))})
	for ax in FarroadProgression.AFFINITY_AXES:
		out.append({"kind": "affinity", "arg": ax, "cost": FarroadProgression.affinity_cost_to_next(FarroadProgression.affinity_purchased(g, uid).get(ax, 0))})
	return out

## Makes one purchase's effect on `g` (no Aether changes); returns what undoes it.
static func _mutate(g: Dictionary, uid: String, c: Dictionary) -> Callable:
	match String(c["kind"]):
		"level":
			var l0: int = FarroadProgression.level_of(g, uid)
			var bank0 = g["bank"].get(uid, 0)
			var max0: int = int(g.get("maxLevelEver", 1))
			g["lvl"][uid] = l0 + 1
			g["bank"][uid] = 0
			g["maxLevelEver"] = maxi(max0, l0 + 1)
			return func():
				g["lvl"][uid] = l0
				g["bank"][uid] = bank0
				g["maxLevelEver"] = max0
		"recovery":
			var r0 = g["recovery"].get(uid, 0)
			g["recovery"][uid] = int(r0) + 1
			return func(): g["recovery"][uid] = r0
		"stat":
			if not g["statInvest"].has(uid):
				g["statInvest"][uid] = {}
			var s0 = g["statInvest"][uid].get(String(c["arg"]), 0)
			g["statInvest"][uid][String(c["arg"])] = int(s0) + 1
			return func(): g["statInvest"][uid][String(c["arg"])] = s0
		_:
			if not g["affinities"].has(uid):
				g["affinities"][uid] = {}
			var a0 = g["affinities"][uid].get(String(c["arg"]), 0)
			g["affinities"][uid][String(c["arg"])] = int(a0) + 1
			return func(): g["affinities"][uid][String(c["arg"])] = a0

## A copy of `g` for planning: everything a purchase changes is its own copy, the rest is shared (read only).
static func _scratch(g: Dictionary) -> Dictionary:
	var sg := g.duplicate(false)
	for k in ["lvl", "bank", "recovery", "statInvest", "affinities"]:
		sg[k] = (g.get(k, {}) as Dictionary).duplicate(true)
	return sg

## What `budget` Aether would buy for `uid`: {"steps": [...], "spent": N, "power_before": P, "power_after": P}
## (Power as the game shows it; "gain_pct" is the strength estimate's own gain, for tuning only).
## `g` is left exactly as it was.
static func plan(real_g: Dictionary, uid: String, budget: float) -> Dictionary:
	var g := _scratch(real_g)
	var shares := _loadout_shares(g, uid)
	var left: float = budget
	var steps: Array = []
	var start := strength(g, uid, shares)
	var power_before: int = FarroadProgression.unit_power(g, uid)
	var now := start
	var guard := 0
	while guard < MAX_STEPS:
		guard += 1
		var best: Dictionary = {}
		var best_score := 0.0
		var best_after := now
		for c in _candidates(g, uid):
			if float(c["cost"]) > left:
				continue
			var u: Callable = _mutate(g, uid, c)
			var after := strength(g, uid, shares)
			u.call()
			var score: float = (after - now) / float(c["cost"])
			if score > best_score:
				best_score = score
				best = c
				best_after = after
		if best.is_empty():
			break
		_mutate(g, uid, best)
		left -= float(best["cost"])
		now = best_after
		steps.append(best)
	var power_after: int = FarroadProgression.unit_power(g, uid)
	return {"steps": steps, "spent": budget - left, "gain_pct": (exp(now - start) - 1.0) * 100.0,
		"power_before": power_before, "power_after": power_after}

## Buys a plan's steps through the normal spending functions. Returns the Aether actually spent.
static func apply(g: Dictionary, uid: String, p: Dictionary) -> float:
	var spent := 0.0
	for c in p["steps"]:
		var before := float(g["aether"])
		match String(c["kind"]):
			"level": FarroadProgression.spend_feed(g, uid, int(c["cost"]))
			"recovery": FarroadProgression.spend_recovery(g, uid)
			"stat": FarroadProgression.spend_pct_stat(g, uid, String(c["arg"]))
			_: FarroadProgression.spend_affinity(g, uid, String(c["arg"]))
		spent += before - float(g["aether"])
	return spent

## A short human summary of a plan: ["3 levels (12 -> 15)", "2 Recovery", "Evade +4", ...].
static func describe(g: Dictionary, uid: String, p: Dictionary) -> Array:
	var levels := 0
	var rec := 0
	var stats := {}
	var aff := {}
	for c in p["steps"]:
		match String(c["kind"]):
			"level": levels += 1
			"recovery": rec += 1
			"stat": stats[c["arg"]] = int(stats.get(c["arg"], 0)) + 1
			_: aff[c["arg"]] = int(aff.get(c["arg"], 0)) + 1
	var out: Array = []
	if levels > 0:
		var l0 := FarroadProgression.level_of(g, uid)
		out.append("Level %d to %d" % [l0, l0 + levels])
	if rec > 0:
		out.append("Recovery +%d" % rec)
	var names := {"evade": "Evade", "atkCrit": "ATK crit", "magCrit": "MAG crit"}
	for k in stats.keys():
		out.append("%s +%d" % [names.get(k, str(k)), stats[k]])
	for k in aff.keys():
		out.append("%s affinity +%d" % [String(k).capitalize(), aff[k]])
	return out

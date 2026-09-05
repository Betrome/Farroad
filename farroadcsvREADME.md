# Farroad content CSVs — authoring guide

Four files, pulled from the shipped build (`farroad-prototype-v0.9.html`, content version v2.8), not from the GDD. One row per entity. Add a row, send it back, and I can implement it.

- `farroad-actions.csv` — 46 actions (25 equippable, 13 party charge, 3 enemy charge, 4 enemy basic, 1 inert)
- `farroad-units.csv` — 5 authored units (the pool is designed for 25; 20 are unwritten)
- `farroad-gambit-conditions.csv` — 30 conditions
- `farroad-enemies.csv` — 6 archetypes plus the boss modifier

**Yes, I can implement your additions.** Fill in a row and I'll wire it into the build. The columns below are exactly what the code reads, so a complete row needs no further questions. Leave a cell blank when it doesn't apply.

---

## Column meanings

### actions

| column | meaning | valid range |
|---|---|---|
| `kind` | which list it lives in | `equippable`, `charge`, `enemy_charge`, `enemy_basic`, `inert` |
| `camp` | damage type | `atk` (uses ATK vs DEF) or `mag` (uses MAG vs RES) |
| `power` | damage/heal multiplier | 0 for non-damaging. 0.43–4.20 in the current set |
| `power_dynamic` | prose description if power is computed by a `powerFn` | leave blank for flat power |
| `rank` | time cost — **higher is slower** | 0.65–2.10 |
| `initiative` | `1/rank`, the player-facing "how often this lets me act" | derived, don't set |
| `target` | shape | `foe`, `allFoes`, `ally`, `allAllies`, `self`, `deadAlly` |
| `hits` | separate damage rolls, each rolling crit | 1, 3 (Flurry), 9 (Ninefold) |
| `applies_status` | status inflicted | see status list below |
| `status_turns` | duration | 2–4 |
| `def_pierce` | fraction of DEF ignored | 0–0.85 |
| `crit_bonus` | flat crit added | 0–0.30 |
| `crit_dynamic` | prose if crit is computed by a `critFn` | Execute only |
| `charge_gain` | charge added when this fires (non-charge actions) | 16–45 |
| `charge_cost` | gauge to fill before firing (charge actions) | base 100 |
| `lore_bonuses_applicable` | which upgrades do anything — **derived from the other fields**, don't set |

**Statuses.** Debuffs: `sundered` (DEF), `frail` (RES), `enfeebled` (ATK ×0.75), `dulled` (MAG + healing), `slowed` (−33% turns), `blinded` (+30% miss), `burning` (5%/turn). Buffs: `hasted`, `warded` (×0.60 incoming), `taunted`, `surging` (2× charge), `bracing`, `regen` (6%/turn), `blurred` (+0.20 evade).

### units

`row` is `front` (×1.35 physical taken) or `back` (×0.75). Stat budget across the five authored units runs 270–560 HP and 84–124 SPD; a new unit should sit inside those unless it's deliberately extreme. `atk_crit`/`mag_crit` are 0.03–0.12 and are **not scaled by level** — they stay put for the whole run, so treat them as an identity trait rather than a growth stat. Every unit needs a unique `charge_action`.

### enemies

`hp_multiplier` is applied to a wave-scaled base. `damage_taken_multiplier` is derived from DEF/evade/block against the Roadwolf reference (1.00) — it's the honest measure of how tanky an archetype really is, and it's why Barrow Knight at 0.54 feels so different from Mire Hound at 1.16. Enemy crit is **not scaled by depth or level**, so 0.03–0.08 is the whole range at every wave.

### gambit conditions

`reads_the_action` marks the two conditions (`foe_lacks_debuff`, `ally_lacks_buff`) that inspect the action they're paired with rather than just battle state. `needs_multiple_foes` marks conditions that return false with one foe — a new condition of this kind is dead in solo fights, which is most of the first 20 waves.

---

## Constraints a new entry must satisfy

**§6.0 — a conditional action must be WORSE than Strike when its condition is false.** This is the rule the whole gambit system rests on. If an action is good unconditionally, the gambit gating it is pointless and the player learns nothing. Strike is `power 1.00, rank 1.00` = 1.038 DPT including base crit. Worked examples in the shipped set:

- **Pierce** — same power, but `rank 1.50`. Wins against DEF > 1.4× yours, loses to Strike against anything soft.
- **Execute** — `power 0.65` flat and **cannot crit at all** above 30% HP: 0.63× Strike outside its window.
- **Onslaught** — ×2.20 on turn one, ×0.65 after.

Put the penalty in **power**, not in `rank`. Swift pushes every action toward the same ×3.0 initiative ceiling, so a speed-based penalty erodes to nothing at full investment while a power gap survives.

**No auto-buys.** Every Lore bonus must be dead on at least one action, and every action must have at least one bonus that does nothing for it. A new action that's a legal target for all ten bonuses is a red flag. (Current exception, known and flagged: `swift` is live on 12/12 under the logarithmic curve and is priced by initiative instead — 2 Lore on a slow action, 6 on a fast one.)

**Charge actions pay for upgrades in cadence.** Every stack adds +12 to the gauge; `thrifty` gives −15. A new charge action needs enough per-use payoff to be worth firing at gauge 220 after ten stacks — that's the design tension, so build for it.

**Relative, not absolute, thresholds.** A condition like "foe DEF ≥ 25" becomes always-true once stats scale. Compare against the acting unit (`DEF > 1.4× yours`), as `foe_armoured` does.

**Damage resolution order**, so a new action's effects land where you expect: evade → crit roll → base (`power × off × K/(K+defEff)`) → crit ×1.75 → block ×0.5 → ward ×0.60 → row ×0.70 → floor at 1. There is no damage variance roll; it was removed in v1.1.

**Negation asymmetry.** Physical is blocked at full strength and evaded at half; magic is the reverse. A sword gets parried, a spell goes wide.

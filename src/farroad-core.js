
/* =============================================================================
 * FARROAD CORE — combat unchanged since v0.6. v0.7 per-unit copies, v0.8 Lore
 * bonuses, v0.9 progression (bosses, checkpoints, curated onboarding, economy).
 * ========================================================================== */
window.FarroadCore=(function(){
'use strict';var F={};
function makeRNG(seed){var a=seed>>>0;var r={seed:seed>>>0,calls:0,
 next:function(){r.calls++;a=(a+0x6D2B79F5)|0;var t=Math.imul(a^(a>>>15),1|a);t=(t+Math.imul(t^(t>>>7),61|t))^t;return ((t^(t>>>14))>>>0)/4294967296;},
 nextInt:function(n){return Math.floor(r.next()*n);}};return r;}
/* v2.8: CAP_CRIT 0.70 -> 1.00. At 100% crit stops being variance and becomes a
   flat deterministic 1.75x, which suits a build that already removed the damage
   variance roll. Crit is NOT scaled by level for either side (statsAt and the
   enemy builder both copy atkCrit/magCrit straight from the base block), so
   raising the cap cannot let a deep enemy crit more than its archetype says. */
var TICK_K=10000,CRIT_MUL=1.75,BLOCK_MUL=.5,CAP_EVADE=.40,CAP_BLOCK=.50,CAP_CRIT=1.00,CHARGE_FULL=100,DET_VAR=16;
var BURN_PCT=0.05,REGEN_PCT=0.06;
/* ===== ELEMENTAL AFFINITIES (v2.10) =====
 * Fire/Water/Earth/Air/Light/Dark/Body/Spirit — one value per unit per axis,
 * used symmetrically: a unit's OWN value in an axis both boosts its output on
 * that axis (attacking/healing/buffing) and reduces/increases what it takes
 * on that axis (defending/being healed/being buffed). Logarithmic, hits
 * EXACTLY +-80% at +-AFFINITY_CAP (Math.min clamps the input, so the curve
 * plateaus there rather than only approaching it asymptotically).
 * Lives in CORE, not progression, despite reading like a growth/economy
 * curve — it is consumed directly inside resolveHit/healFor/apply below, and
 * core.js is loaded (and evaluated) before progression.js, so a P.* formula
 * would not exist yet at the point these functions need it. Exported as
 * F.affinityMul/F.AFFINITY_CAP for progression's cost curve and the UI's
 * AETHER tab to read the identical formula — same precedent as F.CAP_CRIT
 * below, exported for exactly this cross-module reason. */
var AFFINITY_CAP=20;
function affinityMul(raw){
 var s=raw<0?-1:1, a=Math.min(Math.abs(raw),AFFINITY_CAP);
 return s*0.80*Math.log(1+a)/Math.log(1+AFFINITY_CAP);}
/* Used by the 6 damage elements + Body (resolveHit, via affinityFactor
 * below): the actor's own raw value boosts their output, the OTHER side's
 * own raw value on the SAME axis MITIGATES what they take — a positive
 * Body/element affinity reduces damage taken on that axis, same shape
 * DEF/RES already have. */
function affTerm(atkRaw,defRaw){return (1+affinityMul(atkRaw))*(1-affinityMul(defRaw));}
/* Spirit (healFor, apply/magOf below) is NOT shaped like the other axes: the
 * TARGET's own Spirit must BOOST what they receive, not mitigate it — "a
 * Spirit-negative unit is genuinely hard to keep buffed/healed" means a
 * negative target Spirit has to make incoming heals/buffs WEAKER, and
 * affTerm's defense-shaped (1-mul(def)) term does the opposite for a
 * negative input (it INFLATES the result). Both sides boost here instead:
 * the caster's Spirit scales their own output same as everywhere else, and
 * the target's Spirit scales what lands on them in the SAME direction —
 * high Spirit receives stronger heals/buffs (and, symmetrically, is also
 * more strongly affected by a debuff landed on them — the flip side of that
 * same "attuned to magic effects" identity), low/negative Spirit receives
 * everything weaker.
 *
 * CAPPED at AFFINITY_BOOST_CAP, unlike affTerm — affTerm's defense side
 * (1-mul(def)) structurally cannot cross zero (mul itself is bounded at
 * ±0.80), but affBoost multiplies TWO (1+mul) terms together with no such
 * built-in ceiling (up to 1.8*1.8=3.24 unclamped). Measured consequence
 * before this cap existed: Warded's -40% base incoming-damage delta scaled
 * to -129.6% at both sides maxed — comfortably past the ±80% ceiling this
 * entire affinity system is supposed to guarantee, silently absorbed only
 * by resolveHit's incidental Math.max(1,damage) floor. Worse, the SAME
 * unclamped path feeds tcOf's Hasted multiplier, which has no such
 * incidental floor protecting it: enough Spirit stacked with Hasted could
 * push a unit's tick cost toward tcRaw's own Math.max(1,...) floor — a real
 * near-infinite-turns exploit, not just a wasted overshoot. 2.0 is chosen
 * so the largest base magnitude in STATUS_BASE_MAG (Warded/Hasted, -0.40)
 * caps out at EXACTLY -0.80 at the extreme — the same ±80% ceiling
 * AFFINITY_CAP already guarantees everywhere else in this feature, not an
 * arbitrary second number. Applies uniformly to healing too (healFor uses
 * this same helper) — a single shared bound, not a special case. */
var AFFINITY_BOOST_CAP=2.0;
function affBoost(a,b){return Math.min(AFFINITY_BOOST_CAP,(1+affinityMul(a))*(1+affinityMul(b)));}
/* Body always applies to a physical (camp==='atk') damage action — attacker's
   and defender's Body affinity. The action's own element (mandatory on every
   magic damage action, optional on physical, absent on heal/buff/debuff-only
   actions — those use Spirit, see healFor/apply) stacks multiplicatively on
   top if present, so a physical action carrying an elemental tag applies
   BOTH terms — a real, deliberately flagged-for-balance-testing swing. */
function affinityFactor(src,tgt,act){
 var m=1;
 if(act.camp==='atk')m*=affTerm(src.affinity.body,tgt.affinity.body);
 if(act.element)m*=affTerm(src.affinity[act.element],tgt.affinity[act.element]);
 return m;}
var ROW_PHYS=0.70,ROW_SPD=0.10,ROWMUL={front:1.35,back:0.75};
var ENRAGE_AFTER=20, ENRAGE_PCT=0.05;   /* grace in TOTAL battle turns (both sides), then +5%/turn */
/* ===== NEGATION PARITY + ASYMMETRY (v1.1) =====
 * Both camps are now subject to BOTH evade and block (magic could not be evaded
 * before; block already applied to both — confirmed at the old line 581, which
 * had no isPhys gate).
 * Asymmetry: a sword gets parried, a spell goes wide.
 *   physical -> block at full strength, evade at half
 *   magic    -> evade at full strength, block at half
 * At a defensive line of block 0.20 / evade 0.10 that reads as:
 *   sword  blocked 20%, missed  5%
 *   spell  blocked 10%, missed 10%
 * Measured: vs physical the two stats are worth exactly the same (5.3% each per
 * 10pp); vs magic evade is worth 4.3x block. So the matchup decides the buy,
 * which is the build decision this was for. */
var NEG={ atk:{blk:1.00,evd:0.50}, mag:{blk:0.50,evd:1.00} };
function clamp(x,lo,hi){return x<lo?lo:(x>hi?hi:x);}
function tcRaw(spd,rank){return Math.max(1,Math.round(TICK_K*rank/spd));}
/* ===== v2.0 RESCALE — the game now runs to THOUSANDS of waves =====
 * WAVE_KNEE softens the first waves; WAVE_EXP is the single growth exponent used
 * by EVERY enemy stat, so all ratios stay invariant and fight length cannot drift.
 * waveScale(1)=1, (200)=4.2, (1000)=13.7, (10000)=86. */
/* ===== v2.1: the enemy curve is FITTED TO THE PLAYER, not derived separately =====
 * Anchor (Ian): the starting unit reaches LV 100 around wave 1000, and levelling
 * continues past it. Everything else follows from that.
 *
 * Achievable level:  L(w) = 3.2 x sqrt(w) - 2.2   (decelerating — early levels
 *   fast, later ones slow, exactly the requested shape)
 * Enemy scale:       S(w) = 1 + (L(w) - 1) / 12.5
 *
 * Because unit stats are base + gain x (L-1) with gain ~ base/12.5, S(w) IS the
 * player's own multiplier at the level they can actually afford. Enemies cannot
 * outrun the player or fall behind — the mid-game shortfall (w500 needing LV 95
 * while affording 50) is gone by construction rather than by tuning income up.
 *   w10 LV11 x1.8 | w100 LV29 x3.3 | w1000 LV100 x8.9 | w10000 LV785 x63.8
 * Verified gap between afforded and needed level: ZERO at every checkpoint. */
var GAIN_RATIO=12.5;
function levelCurve(w){return Math.max(1,3.2*Math.sqrt(Math.max(1,w))-2.2);}
function waveScale(w){return 1+(levelCurve(w)-1)/GAIN_RATIO;}
/* K MUST SCALE WITH DEPTH. K sets where DEF halves damage. Holding it at 25 while
 * every stat grows makes mitigation collapse — at wave 1000 an enemy's DEF 274
 * against K 25 leaves 8% of damage getting through, so time-to-kill grows as the
 * SQUARE of the scale. Measured, party 3 vs 2 foes:
 *     K constant : 41b (w1) -> 784b (w1000) -> 3457b (w4000) -> unwinnable
 *     K scaled   : 41b (w1) ->  34b (w1000) ->   31b (w4000) ->  31b (w10000)
 * The dead level-scaling in the old K_of was a latent bug that only bites at scale.
 * K is per-WAVE, not per-level — it is a tuning knob for how much DEF matters. */
var K_BASE=25;
var CURRENT_WAVE=1;                      /* set by startWave, read by K_of */
function K_of(l){return K_BASE*waveScale(CURRENT_WAVE);}
function beatMs(n){return n<=14?900:(n<=28?700:(n<=44?520:400));}
/* v2.9: enemies now carry a row too (buildEnemies, front-half/back-half of
   up to 10). rowSpdMul drops the isParty gate so front-row enemies get the
   same tempo bonus front-row party gets — rowOut/rowIn (the back-row
   physical-damage discount) stay party-only below, since party->enemy
   targeting has no row awareness yet to make that discount a real,
   visible choice rather than invisible variance. */
function rowSpdMul(u){return (u.row==='front')?(1+ROW_SPD):1;}
function rowOut(u,p){return (u.isParty&&p&&u.row==='back')?ROW_PHYS:1;}
function rowIn(u,p){return (u.isParty&&p&&u.row==='back')?ROW_PHYS:1;}
var ST=['sundered','frail','enfeebled','dulled','slowed','blinded','burning','hasted','warded','taunted','surging','bracing','regen','blurred'];
var DEBUFFS=['sundered','frail','enfeebled','dulled','slowed','blinded','burning'];
var STATUS_INFO={sundered:{n:'Sundered',k:'d'},frail:{n:'Frail',k:'d'},enfeebled:{n:'Enfeebled',k:'d'},
 dulled:{n:'Dulled',k:'d'},slowed:{n:'Slowed',k:'d'},blinded:{n:'Blinded',k:'d'},burning:{n:'Burning',k:'d'},
 hasted:{n:'Hasted',k:'b'},warded:{n:'Warded',k:'b'},taunted:{n:'Taunted',k:'b'},surging:{n:'Surging',k:'b'},
 bracing:{n:'Bracing',k:'b'},regen:{n:'Regen',k:'b'},blurred:{n:'Blurred',k:'b'}};
function newSt(){var s={};for(var i=0;i<ST.length;i++)s[ST[i]]=0;return s;}
function has(u,id){return u.st[id]>0;}
/* ===== SPIRIT / STATUS MAGNITUDE (v2.10) =====
 * Every status effect's magnitude used to be a constant hardcoded at each of
 * the ~10 read sites below. STATUS_BASE_MAG pulls every one of those
 * constants into a single table (expressed as the DELTA from baseline, e.g.
 * Bracing's old x1.40 DEF is now +0.40) so apply() can scale it by the
 * caster's and target's Spirit affinity at the moment a status lands, and
 * store the RESULT (not the raw base) in u.stMag — a per-application
 * magnitude that sits alongside the existing turn counter in u.st.
 * Bracing carries TWO independent magnitudes (a DEF ratio AND a flat block
 * bonus) under one status id, so its entry is an object of sub-magnitudes
 * rather than a bare number; every other status has exactly one number.
 * DOT/regen (burning/regen) have no "baseline" to delta from — the whole
 * magnitude IS the delta (0 unburned -> BURN_PCT burned) — affTerm still
 * applies the same way, it just scales the entire figure rather than a
 * modifier on top of something else. */
var STATUS_BASE_MAG={enfeebled:-0.25,dulled:-0.25,bracing:{def:0.40,block:0.30},
 sundered:-0.25,frail:-0.25,blurred:0.20,warded:-0.40,slowed:0.50,hasted:-0.40,
 surging:1.00,burning:BURN_PCT,regen:REGEN_PCT};
/* @param key only for a multi-part status (bracing) — selects the sub-magnitude.
   Falls back to STATUS_BASE_MAG if u.stMag has nothing recorded for id (should
   not happen once apply() always populates it for a known id, but keeps a
   never-applied/edge-case read from silently reading undefined). */
function magOf(u,id,key){
 var m=(u.stMag&&u.stMag[id]!=null)?u.stMag[id]:STATUS_BASE_MAG[id];
 if(m==null)return 0;
 if(typeof m==='object')return key?(m[key]||0):0;
 return key?0:m;}
/* v2.10: gained a 4th param, casterSpirit — the unit APPLYING the status
   (self for a self-buff/self-taunt). Computes and stores this application's
   Spirit-scaled magnitude in u.stMag alongside the turn count in u.st;
   affTerm reads naturally here too — the caster's Spirit boosts the delta,
   the TARGET's own Spirit (u itself, the status-holder) mitigates how much
   it affects them, same symmetric shape as every other axis. */
function apply(u,id,t,casterSpirit){
 u.st[id]=t;
 var base=STATUS_BASE_MAG[id];
 if(base==null)return;
 var mul=affBoost(casterSpirit==null?0:casterSpirit,u.affinity.spirit);
 u.stMag=u.stMag||{};
 if(typeof base==='object'){
  var scaled={};for(var k in base)if(Object.prototype.hasOwnProperty.call(base,k))scaled[k]=base[k]*mul;
  u.stMag[id]=scaled;
 }else u.stMag[id]=base*mul;}
function effAtk(u){return u.base.atk*(1+(has(u,'enfeebled')?magOf(u,'enfeebled'):0));}
function effMag(u){return u.base.mag*(1+(has(u,'dulled')?magOf(u,'dulled'):0));}
function effDef(u){return u.base.def*(1+(has(u,'bracing')?magOf(u,'bracing','def'):0))*(1+(has(u,'sundered')?magOf(u,'sundered'):0));}
function effRes(u){return u.base.res*(1+(has(u,'frail')?magOf(u,'frail'):0));}
function effBlock(u){return u.base.block+(has(u,'bracing')?magOf(u,'bracing','block'):0);}
function effEvade(u){return u.base.evade+(has(u,'blurred')?magOf(u,'blurred'):0);}
function effChargeRate(u){return u.base.chargeRate*(1+(has(u,'surging')?magOf(u,'surging'):0));}
/* v2.9: an action's magnitude was hardcoded to ATK (physical) or MAG (magic)
   via camp — no action could scale off DEF/RES/SPD. statByKey lets an
   action opt into a different source stat via act.scaleStat, used below in
   resolveHit/healFor, for the new MC charge actions that scale with each
   stat. DEF/RES reuse the existing status-aware effDef/effRes (so e.g.
   Bracing/Sundered still apply); SPD has no such wrapper anywhere in the
   engine (Hasted/Slowed modify turn CADENCE via tcOf, never the raw stat
   itself), so this reads u.base.spd directly, consistent with that. camp
   is untouched by scaleStat — it still independently governs which crit
   stat/mitigation stat/row multiplier applies, only the ATTACKER's
   magnitude source changes. */
function statByKey(u,key){
 if(key==='mag')return effMag(u);
 if(key==='def')return effDef(u);
 if(key==='res')return effRes(u);
 if(key==='spd')return u.base.spd;
 return effAtk(u);}
function tcOf(u,rank){return tcRaw(u.base.spd*rowSpdMul(u),
 rank*(1+(has(u,'hasted')?magOf(u,'hasted'):0))*(1+(has(u,'slowed')?magOf(u,'slowed'):0)));}
function incomingMul(u){return 1+(has(u,'warded')?magOf(u,'warded'):0);}
/* v2.8: chargeCost is the gauge a charge action must FILL to fire. It was the
   global CHARGE_FULL for every charge action; it is now per-action so that
   upgrading a charge action can make it fire less often. */
function A(o){o.rank=o.rank||1;o.charge=o.charge||0;o.hits=o.hits||1;o.defPierce=o.defPierce||0;o.critBonus=o.critBonus||0;o.critFn=o.critFn||null;o.power=o.power||0;
 if(o.isCharge)o.chargeCost=o.chargeCost||CHARGE_FULL;return o;}
function costOfCharge(a){return (a&&a.chargeCost)||CHARGE_FULL;}
/* ACTIONS is generated from farroadactions.csv at build time (see
   build.js) -- window.FarroadContent.ACTIONS is the raw per-id field data;
   A() (above) applies the same defaulting every literal entry used to get
   inline. A handful of ids carry genuine executable logic a spreadsheet
   cell can't hold (a dynamic power/crit formula, or 'each hit re-rolls its
   own random target') -- ACTION_DYNAMIC merges those by id, hand-written,
   onto the CSV-generated base. See MODULES.md for which ids and why. */
var ACTIONS={};
Object.keys(window.FarroadContent.ACTIONS).forEach(function(id){
 ACTIONS[id]=A(window.FarroadContent.ACTIONS[id]);});
var ACTION_DYNAMIC={
 execute:{critFn:function(s,t){return (t&&t.hp/t.maxHp<=.30)?0.65:-1;}},
 vengeance:{powerFn:function(s){return 0.55+1.55*(1-s.hp/s.maxHp);}},
 onslaught:{powerFn:function(s){return s.turnsTaken===0?2.20:0.65;}},
 reckoning:{powerFn:function(s,t){return t?(2.0+4.5*(1-t.hp/t.maxHp)):2.0;}},
 ninefold:{randomPerHit:true}};
Object.keys(ACTION_DYNAMIC).forEach(function(id){
 if(ACTIONS[id])for(var k in ACTION_DYNAMIC[id])ACTIONS[id][k]=ACTION_DYNAMIC[id][k];});
var ATK_CAMP=['strike','pierce','cleave','flurry','execute','guardbreak','daunt','cripple','brace','vengeance','onslaught','rally'];
var MAG_CAMP=['ember','gale','sear','hex','smother','dazzle','siphon','mend','renew','recall','bulwark','blur','quicken'];
var EQUIPPABLE=ATK_CAMP.concat(MAG_CAMP);
var CHARGE_ACTIONS=['oath','ninefold','hearthlight','vowofstone','ashfall',
 'bloodfury','spellbrand','wardcurse','aegisstep','quicksilver',
 'heavystrike','wildfire','greatheal',
 'tideturn','lastlight','sunder','gravewind','reckoning','bulwarkoath','emberglut','hollowtoll',
 'atk_reckless','mag_lance','def_slam','res_strike','spd_flurry',
 'atk_cry','mag_font','def_bulwark','res_ward','spd_fleet'];
/* 21 of a target 25 authored (13 + the 3 MC generic starters + the 5 roster-
   expansion companions above). The remaining 4 are content, not design — the
   five axes above define where they sit; see VERIFICATION for the coverage
   grid. Plus 10 more (v2.9): one damage + one support per core stat, all MC
   rare-drop content, not tied to the original 25-unit-roster target above. */
/* ---- Lore bonuses (v0.8) ---- */
var SWIFT_CEIL=3.0, SWIFT_DECAY=0.88;
/* ===== PER-ACTION LINEAR STACK COST (v2.9) =====
 * Was a per-BONUS geometric curve: BONUS_GROWTH (1.15) compounded the price
 * of EACH bonus type's OWN stacks, and swift additionally had a speed-tiered
 * base (2/4/6 Lore) to stop it specifically being an auto-buy. Both were
 * scoped to a single (action, bonus) pair, which left a loophole: spreading
 * purchases across DIFFERENT bonus types on the same action never escalated
 * — stack 1 of five different bonuses on one action was five separate
 * "stack 1" base prices, so an action could still be maxed out cheaply as
 * long as no single bonus was stacked deep.
 * Replaced with a price keyed to the ACTION's total upgrade count — every
 * non-broad bonus on it, combined — instead of any one bonus's own count:
 * the Nth Lore upgrade bought for an action, whatever type it is, costs N.
 * A fresh action's first upgrade is 1 Lore; every further upgrade on that
 * SAME action costs one more than the last, directly taxing "put everything
 * into one action" instead of leaving the old per-bonus workaround. Swift's
 * speed-tiered base is retired along with it — the per-action counter now
 * discourages over-investing in any one action generally, not just swift
 * specifically, so the narrower mechanism is redundant. */
function actionBonusTotal(b){
 var t=0;Object.keys(b||{}).forEach(function(bid){if(bid!=='broad')t+=b[bid]||0;});
 return t;}
/* Broad stays exempt and flat, same reasoning as before this rework: it is a
   one-time unlock (applyBonuses flips behaviour the moment ONE stack exists;
   further stacks do nothing), not a repeatable magnitude buy — it neither
   pays into NOR counts toward the linear total the other bonuses escalate
   against. */
var BONUS_COST_BROAD=50;
function bonusPrice(a,bid,totalOnAction){
 if(bid==='broad')return BONUS_COST_BROAD;
 return (totalOnAction||0)+1;}
/* ===== LORE BONUSES =====
 * v2.2 (item 5): support actions had NO upgrade path — Mend did not scale at all
 * while attacks had piercing/keen/weighty. Six support bonuses added below.
 * Every one is DEAD on the wrong kind of action, so none is an auto-buy:
 *   potent/cleansing  -> heals only          broad     -> multi-ally targets only
 *   enduring          -> buffs only          deepening -> debuffs only
 *   thrifty           -> non-charge only     (charge actions spend, not build)
 * `weighty` remains the deliberate universal control that is never best. */
/* ===== v2.4 MERGES — 12 bonuses down to 9 =====
 * Three pairs were doing the same conceptual job on different action types:
 *   MAGNITUDE  weighty(+12% power) + potent(+18% heal)  -> POTENT
 *   CHARGE     surge(+8, all)      + thrifty(+12, non-charge) -> SURGE
 *   DURATION   lasting(+1 any status) + enduring(+2 buff) -> LASTING
 * The duration overlap was the one nobody had flagged: `enduring` was simply a
 * stronger `lasting` restricted to buffs — the same axis, not a mirror.
 * Merging weighty into potent also retires a measured dead option: weighty was
 * never the best pick on any build, and as a general magnitude bonus it now is.
 *
 * NOT MERGED, deliberately: lasting (duration) and deepening (status strength).
 * They look mergeable and are not — they are different AXES on the same target.
 * Fusing them would leave ONE status upgrade, which every status build would buy,
 * recreating exactly the auto-buy the deadness matrix exists to prevent. Kept
 * apart so a status build has to choose "lasts longer" against "bites harder". */
var BONUSES={
 swift:{n:'Swift',d:'corrective — big gains below ×1.00 initiative, little above it'},
 potent:{n:'Potent',d:'+15% to whatever it does — damage or healing',mag:true},
 lasting:{n:'Lasting',d:'+1 turn on the status it applies — nothing if it applies none'},
 deepening:{n:'Deepening',d:'debuff bites 25% harder — dead on buffs and on damage'},
 surge:{n:'Surge',d:'+10 charge gain — dead on charge actions themselves'},
 piercing:{n:'Piercing',d:'+0.15 armour pierce — worth most vs armour'},
 keen:{n:'Keen',d:'+8% crit — worth most on multi-hit'},
 broad:{n:'Broad',d:'+1 target covered — dead on a self or already-multi action'},
 cleansing:{n:'Cleansing',d:'the heal also strips one debuff — dead if it does not heal'},
 /* v2.8: the counterweight to CHARGE_UP_COST. Only a charge action has a gauge
    to make cheaper, so this is dead on all 22 equippable actions. */
 thrifty:{n:'Thrifty',d:'−15 charge cost — CHARGE ACTIONS ONLY, fires more often'}};
/* ===== v2.8 CHARGE ACTIONS ARE UPGRADABLE, AND UPGRADES COST CADENCE =====
 * Every stack on a charge action adds CHARGE_UP_COST to the gauge it must fill,
 * so buying power into it makes it fire less often. The multiplication that made
 * Oath a runaway is now PAID FOR in cadence instead of being prohibited.
 * Thrifty is the release valve: it buys the cadence back. The two are in real
 * tension — swift wins the early stacks (throughput is still climbing), thrifty
 * wins the late ones (throughput has plateaued and cost is all that is left).
 * The floor stops thrifty running away in its own right: 40 caps its total
 * benefit at 2.5x base cadence. */
var CHARGE_UP_COST=12, CHARGE_THRIFT=15, CHARGE_COST_MIN=40, CHARGE_COST_MAX=400;
/* Which bonuses can do anything at all to a given action. Powers the per-action
   filter in the LORE tab — the deadness that makes the system work was invisible,
   so players were shown options that provably do nothing. */
function bonusApplies(a,bid){
 if(!a)return false;
 switch(bid){
  /* swift is now DEAD on actions that are already quick — at ×1.25+ a stack is
     worth under 3%, so it is hidden rather than offered as a trap purchase. */
  /* under the logarithmic curve every action gains something, so swift stays
     live everywhere (its diminishing value on an already-fast action is a
     property of its own effect curve, SWIFT_CEIL/SWIFT_DECAY — unrelated to
     what it costs, which is now the same per-action counter every bonus uses). */
  case 'swift':     return true;
  case 'potent':    return !!a.power;
  case 'lasting':   return !!a.applies;
  case 'deepening': return !!(a.applies&&!isBuffStatus(a.applies));
  case 'surge':     return !a.isCharge;
  case 'piercing':  return !!(a.power&&a.camp==='atk'&&!a.heal);
  case 'keen':      return !!(a.power&&!a.heal);
  case 'broad':     return a.tk==='foe'||a.tk==='ally';
  case 'cleansing': return !!a.heal;
  case 'thrifty':   return !!a.isCharge;
 }
 return false;}
var BUFFS=['hasted','warded','taunted','surging','bracing','regen','blurred'];
function isBuffStatus(s){return BUFFS.indexOf(s)>=0;}
var PRISTINE=null;
function snapshot(){if(PRISTINE)return;PRISTINE={};
 EQUIPPABLE.concat(CHARGE_ACTIONS).forEach(function(id){var a=ACTIONS[id];
  PRISTINE[id]={power:a.power,rank:a.rank,charge:a.charge,defPierce:a.defPierce,critBonus:a.critBonus,turns:a.turns,chargeCost:a.chargeCost};});}
function applyBonuses(map){snapshot();
 Object.keys(PRISTINE).forEach(function(id){var a=ACTIONS[id],p=PRISTINE[id];for(var k in p)a[k]=p[k];});
 Object.keys(map||{}).forEach(function(aid){var b=map[aid],a=ACTIONS[aid];if(!a||!b)return;
  /* ===== v2.5 SWIFT REWORK — corrective, not accelerator =====
   * Was rank ×0.92 per stack, i.e. a flat ~8% speed-up on everything, which made
   * it live on 9/9 actions and a confirmed 100% auto-buy.
   * Now it operates on INITIATIVE (1/rank) with the step keyed to where the action
   * already sits: below ×1.00 each stack adds +0.20 and cannot overshoot past
   * 1.00; at or above ×1.00 each stack adds only +0.035.
   * So it FIXES sluggish actions fast and barely moves quick ones — which both
   * restores its dead case and gives heavy, slow, high-power actions a way to buy
   * out of their tempo problem. */
  /* ===== v2.6 SWIFT — single logarithmic curve to an ABSOLUTE ceiling =====
   * init(n) = 3.0 - (3.0 - init0) x 0.88^n
   * The ×3.0 is a hard ceiling on the RESULTING initiative multiplier, not 3x the
   * action's base. Because the ceiling is shared, a slow action has more headroom
   * than a fast one, so early stacks are worth more on slow actions with no
   * special case: first stack is +42% on Pierce, +24% on Strike, +11% on Brace. */
  if(b.swift){var ini=1/a.rank;
   ini=SWIFT_CEIL-(SWIFT_CEIL-ini)*Math.pow(SWIFT_DECAY,b.swift);
   a.rank=1/ini;}
  if(b.weighty)a.power=a.power*(1+0.12*b.weighty);
  if(b.piercing)a.defPierce=Math.min(0.85,(a.defPierce||0)+0.15*b.piercing);
  if(b.keen)a.critBonus=(a.critBonus||0)+0.08*b.keen;
  /* --- v2.4 merged set --- */
  if(b.surge&&!a.isCharge)a.charge=(a.charge||0)+10*b.surge;        /* +thrifty */
  if(b.lasting&&a.applies)a.turns=(a.turns||3)+b.lasting;           /* +enduring */
  if(b.potent&&a.power)a.power=a.power*(1+0.15*b.potent);           /* +weighty */
  if(b.cleansing&&a.heal)a.cleanse=(a.cleanse||0)+b.cleansing;
  if(b.broad){                       /* single -> all, for allies or foes */
   if(a.tk==='ally')a.tk='allAllies';
   else if(a.tk==='foe')a.tk='allFoes';}
  if(b.deepening&&a.applies&&!isBuffStatus(a.applies))a.deepen=(a.deepen||0)+0.25*b.deepening;
  /* v2.8: charge cost is recomputed from the FULL stack count every time, so it
     stays correct when a stack is refunded. Thrifty is excluded from the count
     that raises cost — otherwise buying the discount would pay for itself. */
  if(a.isCharge){var ups=0;
   Object.keys(b).forEach(function(k){if(k!=='thrifty')ups+=b[k]||0;});
   a.chargeCost=Math.max(CHARGE_COST_MIN,Math.min(CHARGE_COST_MAX,
    CHARGE_FULL+CHARGE_UP_COST*ups-CHARGE_THRIFT*(b.thrifty||0)));}});}
/* Reconstructs total Lore spent from final stack counts, not stacks x
   today's price, same reasoning as the v2.9 bugfix this replaced: a re-spend
   from scratch (e.g. after a save round-trip) must always land on the same
   total the player actually paid. Since price now depends only on the
   ACTION's running total (not on which bonus each purchase was — see
   bonusPrice/actionBonusTotal above), the total cost of K non-broad stacks
   on one action is the closed-form triangular sum 1+2+...+K =
   K*(K+1)/2, regardless of how those K stacks are split across bonus types
   or the order they were bought in — no need to replay a purchase sequence. */
function bonusSpend(map){var n=0;
 Object.keys(map||{}).forEach(function(aid){
  var b=map[aid],total=actionBonusTotal(b);
  n+=total*(total+1)/2;
  n+=(b.broad||0)*BONUS_COST_BROAD;});
 return n;}
function living(b,p){var o=[];for(var i=0;i<b.units.length;i++){var u=b.units[i];if(u.hp>0&&p(u))o.push(u);}return o;}
function foes(b,u){return living(b,function(x){return x.isParty!==u.isParty;});}
function allies(b,u){return living(b,function(x){return x.isParty===u.isParty;});}
function deadAllies(b,u){var o=[];for(var i=0;i<b.units.length;i++){var x=b.units[i];if(x.hp<=0&&x.isParty===u.isParty)o.push(x);}return o;}
function hpPct(u){return u.hp/u.maxHp;}
function byLowestHp(l){var b=null;for(var i=0;i<l.length;i++)if(!b||hpPct(l[i])<hpPct(b))b=l[i];return b;}
function byHighestHp(l){var b=null;for(var i=0;i<l.length;i++)if(!b||hpPct(l[i])>hpPct(b))b=l[i];return b;}
function anyDebuff(u){for(var i=0;i<DEBUFFS.length;i++)if(has(u,DEBUFFS[i]))return true;return false;}
var PREF={wolf:function(u,hp){return 1+1.5*(1-hp);},knight:function(u){return u.row==='front'?2.5:.4;},
 hound:function(u){return u.row==='back'?2.2:.6;},ox:function(){return 1;},
 priest:function(u,hp){return 1+1.0*(1-hp);},shrike:function(){return 1;}};
var PREF_TEXT={wolf:'lunges at whoever is hurt',knight:'engages the front line',
 hound:'darts past the line at your back rank',ox:'indiscriminate',
 priest:'opportunist — prefers the wounded',shrike:'indiscriminate'};
function threatOf(src,u){var w=ROWMUL[u.row||'front']||1;
 if(has(u,'taunted'))w*=8;var p=PREF[src.arch];if(p)w*=p(u,hpPct(u));return Math.max(.01,w);}
function threatTable(b,src){var f=foes(b,src),o=[],tot=0,i;
 for(i=0;i<f.length;i++){var w=threatOf(src,f[i]);o.push({u:f[i],w:w});tot+=w;}
 for(i=0;i<o.length;i++)o[i].p=o[i].w/tot;return o;}
function defFoe(b,u){var f=foes(b,u);if(!f.length)return null;
 if(!u.isParty){var t=threatTable(b,u),i;
  if(b.det){var bi=0;for(i=1;i<t.length;i++)if(t[i].w>t[bi].w)bi=i;return t[bi].u;}
  var r=b.rng.next(),acc=0;
  for(i=0;i<t.length;i++){acc+=t[i].p;if(r<=acc)return t[i].u;}return t[t.length-1].u;}
 for(var j=0;j<f.length;j++)if(has(f[j],'taunted'))return f[j];
 if(b.det||f.length===1)return f[0];return f[b.rng.nextInt(f.length)];}
function C(id,label,grp,fn){return {id:id,label:label,group:grp,resolve:fn};}
/* v0.9 FIX: thresholds are RELATIVE. Absolute ones (e.g. "DEF >= 25") become
   always-true by ~wave 15 because enemy DEF scales at S^0.98. Relative ones are
   scale-invariant and keep meaning at every depth. */
var CONDITIONS=[
 C('none','— always —','',function(){return {ok:true,target:null};}),
 C('foe_any','Foe: any','Foe',function(u,b){var t=defFoe(b,u);return {ok:!!t,target:t};}),
 C('foe_lowest_hp','Foe: lowest HP','Foe',function(u,b){var t=byLowestHp(foes(b,u));return {ok:!!t,target:t};}),
 C('foe_highest_hp','Foe: highest HP','Foe',function(u,b){var t=byHighestHp(foes(b,u));return {ok:!!t,target:t};}),
 C('foe_hp_gte_70','Foe: HP ≥ 70%','Foe',function(u,b){var f=foes(b,u);for(var i=0;i<f.length;i++)if(hpPct(f[i])>=.70)return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('foe_hp_lte_30','Foe: HP ≤ 30%','Foe',function(u,b){var f=foes(b,u);for(var i=0;i<f.length;i++)if(hpPct(f[i])<=.30)return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('foe_armoured','Foe: armoured (DEF > 1.4× yours)','Foe',function(u,b){var f=foes(b,u);
   for(var i=0;i<f.length;i++)if(effDef(f[i])>1.4*effDef(u))return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('foe_warded','Foe: resistant (RES > 1.4× yours)','Foe',function(u,b){var f=foes(b,u);
   for(var i=0;i<f.length;i++)if(effRes(f[i])>1.4*effRes(u))return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('foe_fast','Foe: faster than you','Foe',function(u,b){var f=foes(b,u);
   for(var i=0;i<f.length;i++)if(f[i].base.spd>u.base.spd)return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('foe_3plus','Foe: 3+ present','Foe',function(u,b){var f=foes(b,u);return {ok:f.length>=3,target:defFoe(b,u)};}),
 C('foe_charging','Foe: charge ≥ 70%','Foe',function(u,b){var f=foes(b,u);
   for(var i=0;i<f.length;i++)if(f[i].chargeAction&&f[i].charge>=70)return {ok:true,target:f[i]};
   return {ok:false,target:null};}),
 /* ===== v2.2 MULTI-ENEMY CONDITIONS (item 4) =====
  * The multi-enemy space was thin — focus-fire measured +16.2% at two foes and was
  * one of very few conditions with proven value. These cover three distinct axes
  * rather than being variations on "pick a foe":
  *   TARGET SELECTION  softest DEF / softest RES / most dangerous
  *   GROUP STATE       all hurt / all healthy / most already weakened / isolated
  *   THREAT ASSESSMENT a healer is present / this one acts next
  * Softest-DEF and softest-RES are the automation half of the DEF/RES pair now
  * shown on the unit cards — the UI teaches the read, these let you act on it. */
 C('foe_softest_def','Foe: softest DEF of the group','Foe',function(u,b){
   var f=foes(b,u);if(f.length<2)return {ok:false,target:null};
   var t=f[0];for(var i=1;i<f.length;i++)if(effDef(f[i])<effDef(t))t=f[i];
   return {ok:true,target:t};}),
 C('foe_softest_res','Foe: softest RES of the group','Foe',function(u,b){
   var f=foes(b,u);if(f.length<2)return {ok:false,target:null};
   var t=f[0];for(var i=1;i<f.length;i++)if(effRes(f[i])<effRes(t))t=f[i];
   return {ok:true,target:t};}),
 C('foe_most_dangerous','Foe: hardest hitter','Foe',function(u,b){
   var f=foes(b,u);if(!f.length)return {ok:false,target:null};
   var t=f[0];for(var i=1;i<f.length;i++)if(effAtk(f[i])>effAtk(t))t=f[i];
   return {ok:true,target:t};}),
 C('foe_acts_next','Foe: acts next','Foe',function(u,b){
   var f=foes(b,u);if(!f.length)return {ok:false,target:null};
   var t=f[0];for(var i=1;i<f.length;i++)if(f[i].nextActAt<t.nextActAt)t=f[i];
   return {ok:true,target:t};}),
 C('foe_healer_present','Foes: a healer among them','Foe',function(u,b){
   var f=foes(b,u);
   for(var i=0;i<f.length;i++){var sl=f[i].slots||[];
    for(var j=0;j<sl.length;j++){var a=ACTIONS[sl[j].action];
     if(a&&a.heal)return {ok:true,target:f[i]};}}
   return {ok:false,target:null};}),
 C('foe_pack_hurt','Foes: ALL below 50% HP','Foe',function(u,b){
   var f=foes(b,u);if(f.length<2)return {ok:false,target:null};
   for(var i=0;i<f.length;i++)if(hpPct(f[i])>=.50)return {ok:false,target:null};
   return {ok:true,target:byLowestHp(f)};}),
 C('foe_pack_healthy','Foes: NONE below 70% HP','Foe',function(u,b){
   var f=foes(b,u);if(f.length<2)return {ok:false,target:null};
   for(var i=0;i<f.length;i++)if(hpPct(f[i])<.70)return {ok:false,target:null};
   return {ok:true,target:byHighestHp(f)};}),
 C('foe_mostly_weakened','Foes: most already weakened','Foe',function(u,b){
   var f=foes(b,u);if(f.length<2)return {ok:false,target:null};
   var n=0;for(var i=0;i<f.length;i++)if(anyDebuff(f[i]))n++;
   if(n*2<=f.length)return {ok:false,target:null};
   for(var j=0;j<f.length;j++)if(!anyDebuff(f[j]))return {ok:true,target:f[j]};
   return {ok:true,target:defFoe(b,u)};}),
 C('foe_isolated','Foe: last one standing','Foe',function(u,b){
   var f=foes(b,u);return {ok:f.length===1,target:f[0]||null};}),
 C('foe_2plus','Foe: 2+ present','Foe',function(u,b){var f=foes(b,u);
   return {ok:f.length>=2,target:defFoe(b,u)};}),
 C('foe_lacks_debuff','Foe: lacks this debuff','Foe',function(u,b,act){var f=foes(b,u);
   if(!act||!act.applies){var t=defFoe(b,u);return {ok:!!t,target:t};}
   for(var i=0;i<f.length;i++)if(!has(f[i],act.applies))return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('foe_not_weakened','Foe: not weakened','Foe',function(u,b){var f=foes(b,u);for(var i=0;i<f.length;i++)if(!anyDebuff(f[i]))return {ok:true,target:f[i]};return {ok:false,target:null};}),
 C('ally_hp_lte_60','Ally: HP ≤ 60%','Ally',function(u,b){var a=allies(b,u),c=[];for(var i=0;i<a.length;i++)if(hpPct(a[i])<=.60)c.push(a[i]);var t=byLowestHp(c);return {ok:!!t,target:t};}),
 C('ally_hp_lte_30','Ally: HP ≤ 30%','Ally',function(u,b){var a=allies(b,u),c=[];for(var i=0;i<a.length;i++)if(hpPct(a[i])<=.30)c.push(a[i]);var t=byLowestHp(c);return {ok:!!t,target:t};}),
 C('ally_lowest_hp','Ally: lowest HP','Ally',function(u,b){var t=byLowestHp(allies(b,u));return {ok:!!t,target:t};}),
 C('ally_is_dead','Ally: is down','Ally',function(u,b){var d=deadAllies(b,u);return {ok:d.length>0,target:d[0]||null};}),
 C('ally_lacks_buff','Ally: lacks this buff','Ally',function(u,b,act){var a=allies(b,u);
   if(!act||!act.applies){var t=byLowestHp(a);return {ok:!!t,target:t};}
   for(var i=0;i<a.length;i++)if(!has(a[i],act.applies))return {ok:true,target:a[i]};return {ok:false,target:null};}),
 C('self_hp_lte_50','Self: HP ≤ 50%','Self',function(u){return {ok:hpPct(u)<=.50,target:u};}),
 C('self_first_turn','Self: first turn','Self',function(u){return {ok:u.turnsTaken===0,target:u};})];
/* v2.9: fill out HP conditions to a full 10% ladder (10-90, both directions)
 * for every group — Ian found the existing handful (self_hp_lte_50,
 * ally_hp_lte_60/30, foe_hp_gte_70/lte_30) too sparse to express finer
 * thresholds. Those five keep their exact ids/behaviour unchanged — GATE_FOR/
 * PRI (farroad-ui.js) and one enemy archetype's own default gambit
 * (priest, ROSTER above, cond:'ally_hp_lte_60') reference them by name —
 * this only ADDS the missing deciles, generated rather than hand-typed
 * ~49 times, using the exact same resolver shape each group's existing
 * entries already use (Foe: first-match loop; Ally: filter + byLowestHp;
 * Self: direct check). */
(function(){
 var existing={};CONDITIONS.forEach(function(c){existing[c.id]=1;});
 var gte=function(x,v){return x>=v;}, lte=function(x,v){return x<=v;};
 function foeTest(cmp,v){return function(u,b){var f=foes(b,u);
  for(var i=0;i<f.length;i++)if(cmp(hpPct(f[i]),v))return {ok:true,target:f[i]};
  return {ok:false,target:null};};}
 function allyTest(cmp,v){return function(u,b){var a=allies(b,u),c=[];
  for(var i=0;i<a.length;i++)if(cmp(hpPct(a[i]),v))c.push(a[i]);
  var t=byLowestHp(c);return {ok:!!t,target:t};};}
 function selfTest(cmp,v){return function(u){return {ok:cmp(hpPct(u),v),target:u};};}
 var GROUPS=[['Foe','foe',foeTest],['Ally','ally',allyTest],['Self','self',selfTest]];
 var added=[];
 [10,20,30,40,50,60,70,80,90].forEach(function(pct){
  var v=pct/100;
  GROUPS.forEach(function(g){
   var group=g[0],prefix=g[1],mk=g[2];
   var gteId=prefix+'_hp_gte_'+pct, lteId=prefix+'_hp_lte_'+pct;
   if(!existing[gteId])added.push(C(gteId,group+': HP ≥ '+pct+'%',group,mk(gte,v)));
   if(!existing[lteId])added.push(C(lteId,group+': HP ≤ '+pct+'%',group,mk(lte,v)));});});
 CONDITIONS=CONDITIONS.concat(added);})();
function condById(id){for(var i=0;i<CONDITIONS.length;i++)if(CONDITIONS[i].id===id)return CONDITIONS[i];return CONDITIONS[0];}
function resolveTarget(act,ct,u,b){var k=act.tk;
 if(k==='self')return u;
 if(k==='foe'||k==='allFoes'){if(ct&&ct.isParty!==u.isParty&&ct.hp>0)return ct;return defFoe(b,u);}
 if(k==='ally'||k==='allAllies'){if(ct&&ct.isParty===u.isParty&&ct.hp>0)return ct;return byLowestHp(allies(b,u));}
 if(k==='deadAlly'){if(ct&&ct.isParty===u.isParty&&ct.hp<=0)return ct;return deadAllies(b,u)[0]||null;}
 return null;}
function defaultAffinity(){return {fire:0,water:0,earth:0,air:0,light:0,dark:0,body:0,spirit:0};}
function makeUnit(cfg){var d={hp:100,atk:10,mag:10,def:10,res:10,spd:100,atkCrit:.05,magCrit:.05,chargeRate:1,block:.03,evade:.03};
 for(var k in (cfg.stats||{}))if(Object.prototype.hasOwnProperty.call(cfg.stats,k))d[k]=cfg.stats[k];
 var aff=defaultAffinity();
 for(var ak in (cfg.affinity||{}))if(Object.prototype.hasOwnProperty.call(cfg.affinity,ak))aff[ak]=cfg.affinity[ak];
 return {id:cfg.id,name:cfg.name,isParty:!!cfg.isParty,level:cfg.level||1,slotIndex:cfg.slotIndex||0,base:d,
  maxHp:cfg.maxHp!=null?cfg.maxHp:d.hp,hp:cfg.hp!=null?cfg.hp:d.hp,charge:cfg.charge||0,
  chargeAction:cfg.chargeAction||null,slots:cfg.slots||[{cond:'none',action:'strike'},{cond:'none',action:'strike'}],
  st:newSt(),stMag:{},affinity:aff,nextActAt:0,alternateFlag:0,turnsTaken:0,enrageN:0,
  row:cfg.row||null,arch:cfg.arch||null,thorns:cfg.thorns||0,isBoss:!!cfg.isBoss};}
function makeBattle(units,opts){opts=opts||{};
 var b={units:units,t:0,beat:0,elapsedMs:0,log:[],over:null,rng:opts.rng||makeRNG(1),det:!!opts.deterministic,
  gambitMode:'topdown',smartHeal:true,enrage:!!opts.enrage};
 for(var i=0;i<units.length;i++){var u=units[i];u.st=newSt();u.stMag={};u.nextActAt=tcOf(u,1.00);u.turnsTaken=0;u.enrageN=0;u.alternateFlag=0;}
 return b;}
function pickNext(b){var best=null;
 for(var i=0;i<b.units.length;i++){var u=b.units[i];if(u.hp<=0)continue;
  if(!best){best=u;continue;}if(u.nextActAt<best.nextActAt){best=u;continue;}if(u.nextActAt>best.nextActAt)continue;
  if(u.isParty!==best.isParty){if(u.isParty)best=u;continue;}
  if(u.base.spd!==best.base.spd){if(u.base.spd>best.base.spd)best=u;continue;}
  if(u.slotIndex<best.slotIndex)best=u;}
 return best;}
function needsHeal(b,u){var a=allies(b,u);for(var i=0;i<a.length;i++)if(a[i].hp<a[i].maxHp)return true;return false;}
function chooseFrom(u,b,state){
 if(u.chargeAction&&state.charge>=costOfCharge(ACTIONS[u.chargeAction]))
  return {actionId:u.chargeAction,target:null,via:'charge full → override'};
 var s=u.slots,n=s.length,allNone=true,i,r,act;
 for(i=0;i<n;i++)if(s[i].cond!=='none')allNone=false;
 if(allNone){var idx=state.alternateFlag%n;state.alternateFlag=(state.alternateFlag+1)%n;
  var a0=ACTIONS[s[idx].action];
  if(b.smartHeal&&a0&&a0.heal&&!needsHeal(b,u))return {actionId:'strike',target:null,via:'alternate (heal skipped)'};
  if(b.smartHeal&&a0&&a0.tk==='deadAlly'&&deadAllies(b,u).length===0)return {actionId:'strike',target:null,via:'alternate (nobody down)'};
  return {actionId:s[idx].action,target:null,via:'alternate → slot '+(idx+1)};}
 for(i=0;i<n;i++){act=ACTIONS[s[i].action];r=condById(s[i].cond).resolve(u,b,act);
  if(r.ok)return {actionId:s[i].action,target:r.target,via:'slot '+(i+1)+' ['+condById(s[i].cond).label+'] ✓'};}
 return {actionId:'strike',target:null,via:'all false → implicit Strike'};}
function choose(u,b){var st={charge:u.charge,alternateFlag:u.alternateFlag};var r=chooseFrom(u,b,st);u.alternateFlag=st.alternateFlag;return r;}
function resolveHit(src,tgt,act,b,pv){var det=b.det,rng=b.rng,isPhys=act.camp==='atk';
 var o={isPhys:isPhys,evaded:false,crit:false,blocked:false,actionName:act.name,targetName:tgt.name};
 var NG=NEG[act.camp]||NEG.atk;
 /* v1.1: BOTH camps can now be evaded, with camp-specific effectiveness */
 o.negBlk=NG.blk;o.negEvd=NG.evd;
 o.evadeChance=clamp(effEvade(tgt)*NG.evd+(has(src,'blinded')?.30:0),0,CAP_EVADE+.30);
 o.evadeRoll=det?1:rng.next();
 if(o.evadeRoll<o.evadeChance){o.evaded=true;o.damage=0;return o;}
 /* v2.7: critFn is the conditional twin of powerFn — a crit bonus that reads the
    target. Execute uses it so its payoff sits in crit rather than power. Crit is
    hard-capped at CAP_CRIT (0.70) and multiplies by CRIT_MUL (1.75), so ANY
    critFn payoff is bounded at ~1.5x expected; power scaling was unbounded and
    compounded with every swift purchase. That bound is the whole point. */
 var cb=(act.critBonus||0)+(act.critFn?act.critFn(src,tgt):0);
 o.critChance=clamp((isPhys?src.base.atkCrit:src.base.magCrit)+cb,0,CAP_CRIT);
 o.critRoll=det?1:rng.next();o.crit=o.critRoll<o.critChance;
 o.K=K_of(src.level);o.off=act.scaleStat?statByKey(src,act.scaleStat):(isPhys?effAtk(src):effMag(src));
 o.defRaw=isPhys?effDef(tgt):effRes(tgt);o.defEff=o.defRaw*(1-(act.defPierce||0));o.mit=o.K/(o.K+o.defEff);
 o.affMul=affinityFactor(src,tgt,act);
 o.power=pv;o.base=pv*o.off*o.mit*o.affMul;
 /* v1.1: VARIANCE ROLL REMOVED. Base damage is now deterministic — the (randInt
    (0,30)+240)/256 term is gone. Measured consequence: the fight does NOT become
    metronomic, because crit and block already supplied nearly all the spread —
    coefficient of variation is 0.26 both with and without the roll. What it buys
    is legibility, not tunability: the log now shows a base number that is exactly
    reproducible. It does NOT make heal thresholds exactly safe, because crit
    still spikes 1.75x — the max single hit only moves 6.59% -> 6.25% of max HP. */
 o.varRoll=null;o.variance=1;
 var d=o.base;o.afterVariance=d;
 if(o.crit)d*=CRIT_MUL;
 o.blockChance=clamp(effBlock(tgt)*NG.blk,0,CAP_BLOCK);o.blockRoll=det?1:rng.next();o.blocked=o.blockRoll<o.blockChance;
 if(o.blocked)d*=BLOCK_MUL;
 o.wardMul=incomingMul(tgt);d*=o.wardMul;
 o.rowOut=rowOut(src,isPhys);o.rowIn=rowIn(tgt,isPhys);d*=o.rowOut*o.rowIn;
 o.preFloor=d;o.damage=Math.max(1,Math.floor(d));return o;}
function healFor(src,tgt,act,b,pv){
 var v=pv*(act.scaleStat?statByKey(src,act.scaleStat):effMag(src))*affBoost(src.affinity.spirit,tgt.affinity.spirit);
 var amt=Math.max(1,Math.floor(v)),before=tgt.hp;tgt.hp=Math.min(tgt.maxHp,tgt.hp+amt);
 return {heal:true,targetName:tgt.name,amount:tgt.hp-before};}
function step(b){
 if(b.over)return null;var u=pickNext(b);if(!u){b.over='draw';return null;}
 b.t=u.nextActAt;b.beat+=1;var ms=beatMs(b.beat);b.elapsedMs+=ms;
 var e={beat:b.beat,t:b.t,ms:ms,actorId:u.id,actorName:u.name,isParty:u.isParty,
  chargeBefore:u.charge,hits:[],heals:[],totalDamage:0,notes:[],dot:0,regen:0,thorns:0};
 if(has(u,'burning')){var dot=Math.max(1,Math.ceil(magOf(u,'burning')*u.maxHp));u.hp=Math.max(0,u.hp-dot);e.dot=dot;}
 if(has(u,'regen')&&u.hp>0){var rg=Math.max(1,Math.ceil(magOf(u,'regen')*u.maxHp)),bf=u.hp;u.hp=Math.min(u.maxHp,u.hp+rg);e.regen=u.hp-bf;}
 for(var si=0;si<ST.length;si++)if(u.st[ST[si]]>0)u.st[ST[si]]--;
 if(u.hp<=0){e.actionId='none';e.actionName='(burned out)';e.via='—';e.rank=1;e.chargeAfter=u.charge;
  b.log.push(e);checkEnd(b);return e;}
 var ch=choose(u,b);var act=ACTIONS[ch.actionId]||ACTIONS.strike;
 e.actionId=act.id;e.actionName=act.name;e.via=ch.via;e.isCharge=!!act.isCharge;e.rank=act.rank;
 e.tickCost=tcOf(u,act.rank);
 var primary=resolveTarget(act,ch.target,u,b);
 e.targetName=primary?primary.name:null;
 if(!primary&&act.tk!=='self'){e.notes.push('no legal target');}
 else{
  var pv=act.powerFn?act.powerFn(u,primary):act.power;
  var targets=[];
  if(act.tk==='allFoes')targets=foes(b,u);else if(act.tk==='allAllies')targets=allies(b,u);
  else if(act.tk==='self')targets=[u];else targets=[primary];
  if(act.revive){if(primary&&primary.hp<=0){primary.hp=Math.max(1,Math.floor(primary.maxHp*act.revive));primary.st=newSt();primary.stMag={};
    e.notes.push('revived '+primary.name);}}
  else if(act.heal){for(var i=0;i<targets.length;i++)e.heals.push(healFor(u,targets[i],act,b,pv));
   if(act.cleanse){for(var j=0;j<targets.length;j++){for(var k=0;k<DEBUFFS.length;k++){
     if(has(targets[j],DEBUFFS[k])){targets[j].st[DEBUFFS[k]]=0;e.notes.push('cleansed '+DEBUFFS[k]);break;}}}}}
  else if(pv>0){for(var h=0;h<(act.hits||1);h++){var tl=act.randomPerHit?[defFoe(b,u)]:targets;
    for(var ti=0;ti<tl.length;ti++){var tg=tl[ti];if(!tg||tg.hp<=0)continue;
     var r=resolveHit(u,tg,act,b,pv);e.hits.push(r);e.totalDamage+=r.damage;tg.hp=Math.max(0,tg.hp-r.damage);
     if(act.lifesteal&&r.damage>0){var hb=u.hp;u.hp=Math.min(u.maxHp,u.hp+Math.floor(r.damage*act.lifesteal));
      if(u.hp>hb)e.heals.push({heal:true,targetName:u.name,amount:u.hp-hb});}}}
    if(act.tk==='allFoes'){var refl=0;
     for(var z=0;z<targets.length;z++)if(targets[z].thorns)refl+=Math.max(1,Math.round(targets[z].thorns*targets[z].maxHp));
     if(refl>0){u.hp=Math.max(0,u.hp-refl);e.thorns=refl;e.notes.push('thorns −'+refl);}}}
  if(act.applies){for(var m=0;m<targets.length;m++){if(targets[m].hp>0){var already=has(targets[m],act.applies);
    apply(targets[m],act.applies,act.turns,u.affinity.spirit);
    e.notes.push((already?'refreshed ':'applied ')+act.applies+' on '+targets[m].name);}}}
  if(act.selfTaunt){apply(u,'taunted',act.selfTaunt,u.affinity.spirit);e.notes.push('taunting');}}
 if(act.isCharge)u.charge-=costOfCharge(act);else u.charge+=act.charge*effChargeRate(u);
 e.chargeAfter=u.charge;u.turnsTaken+=1;u.nextActAt=b.t+tcOf(u,act.rank);
 /* ENRAGE (v1.0, on by default; v2.9 gate reworked). Was gated on the
    ENEMY'S OWN TURNS (grace of 8), which meant a fast enemy raced to its own
    enrage threshold in real fight-time regardless of how the fight was
    actually going, sometimes ramping up before the party had a real chance
    to respond — a crippling start. Gate is now the battle's TOTAL turn
    count (b.beat, both sides combined, grace of 20) instead, so enrage
    timing tracks how long the FIGHT has run rather than how fast any one
    enemy happens to act. Once the gate is open, growth is still applied
    per-unit-action (u.enrageN counts THIS unit's own actions taken since
    the gate opened, same +5%/turn compounding as before) — a fast enemy
    still racks up stacks faster than a slow one from that point on, same as
    always, it just can no longer get there ahead of the fight itself.
    (This does give up the old Slow/Cripple-delays-enrage synergy the gate
    used to have for free, since the gate itself is no longer keyed to any
    one unit's own turn count.) */
 if(b.enrage&&!u.isParty&&u.hp>0&&b.beat>ENRAGE_AFTER){
  u.enrageN=(u.enrageN||0)+1;
  u.base.atk=u.base.atk*(1+ENRAGE_PCT);
  e.enrageStacks=u.enrageN;
  e.notes.push('enraged ×'+e.enrageStacks+' (+'+Math.round(ENRAGE_PCT*100)+'% ATK)');}
 b.log.push(e);checkEnd(b);return e;}
function checkEnd(b){var pa=false,fa=false;
 for(var i=0;i<b.units.length;i++)if(b.units[i].hp>0){if(b.units[i].isParty)pa=true;else fa=true;}
 if(!fa)b.over='party';else if(!pa)b.over='enemy';}
function preview(b,count){count=count||6;var sim=[];
 for(var i=0;i<b.units.length;i++){var u=b.units[i];if(u.hp<=0)continue;
  sim.push({u:u,at:u.nextActAt,charge:u.charge,alternateFlag:u.alternateFlag});}
 var out=[];
 for(var n=0;n<count&&sim.length;n++){var best=sim[0];
  for(var j=0;j<sim.length;j++){var s=sim[j];if(s===best)continue;
   if(s.at<best.at){best=s;continue;}if(s.at>best.at)continue;
   if(s.u.isParty!==best.u.isParty){if(s.u.isParty)best=s;continue;}
   if(s.u.base.spd!==best.u.base.spd){if(s.u.base.spd>best.u.base.spd)best=s;continue;}
   if(s.u.slotIndex<best.u.slotIndex)best=s;}
  var st={charge:best.charge,alternateFlag:best.alternateFlag};
  var ch=chooseFrom(best.u,b,st);var act=ACTIONS[ch.actionId]||ACTIONS.strike;
  out.push({unitName:best.u.name,isParty:best.u.isParty,at:best.at,actionName:act.name,
   actionId:act.id,rank:act.rank,isCharge:!!act.isCharge,cost:tcOf(best.u,act.rank)});
  best.at+=tcOf(best.u,act.rank);best.alternateFlag=st.alternateFlag;
  best.charge=act.isCharge?best.charge-costOfCharge(act):best.charge+act.charge*effChargeRate(best.u);}
 return out;}
/* v1.0 RETUNE: the 65% global multiplier was a debug crutch, and one that switched
   off at wave 20 would have doubled enemy strength exactly as the player gained
   their second character - a cliff disguised as a design. The intended difficulty
   is now NATIVE: these are the real numbers and DIFFICULTY sits at 1.00 in play.
   ATK values below are the old ones x0.96, baked in. HP was left alone because
   scaling enemy HP measured almost inert - what kills a solo character is damage
   taken, not pool size - so the growth exponent on ATK is the primary lever
   (1.02 -> 0.80 in buildEnemies). */
/* ARCH is generated from farroadenemies.csv at build time (see build.js) --
   window.FarroadContent.ARCH is already in this exact shape (key/name/
   hpMul/atk/mag/def/res/spd/atkCrit/magCrit/evade/block/thorns/
   chargeAction/slots). No ARCH.boss entry -- boss enemies are synthesized
   at combat-build time from ox's shape + wolf's HP (see buildEnemies in
   farroad-ui.js), a design this doesn't change. magCrit and chargeAction
   are now genuine per-archetype CSV fields (were: a single hardcoded 0.04
   global, and a hardcoded key==='ox'/'hound' check -- both generalized,
   seeded to match prior behavior exactly). */
var ARCH=window.FarroadContent.ARCH;
var ROT=['wolf','knight','hound','ox','priest','shrike'];
var REF={def:12,evade:.05,block:.00};
function dmgTakenMul(a){var K=25;
 return ((K/(K+a.def))/(K/(K+REF.def)))*((1-a.evade)/(1-REF.evade))*((1-a.block*.5)/(1-REF.block*.5));}
/* ROSTER is generated from farroadunits.csv at build time (see build.js) --
   window.FarroadContent.ROSTER is already in this exact shape (id/name/
   role/row/hp/chargeAction/stats), no per-entry logic to merge back in --
   unlike ACTIONS, every roster field is plain data today. */
var ROSTER=window.FarroadContent.ROSTER;
F.makeRNG=makeRNG;F.tcRaw=tcRaw;F.tcOf=tcOf;F.beatMs=beatMs;F.CHARGE_FULL=CHARGE_FULL;
/* v2.9: exported because buildEnemies (progression scope) now clamps scaled
   enemy crit against CAP_CRIT. The progression IIFE is a SEPARATE scope under
   'use strict', so a bare CAP_CRIT there is a ReferenceError, not a silent
   undefined — the same failure mode as the v0.9 WAVE_EXP bug. */
F.CAP_CRIT=CAP_CRIT;F.CRIT_MUL=CRIT_MUL;
F.ST=ST;F.DEBUFFS=DEBUFFS;F.STATUS_INFO=STATUS_INFO;F.has=has;F.hpPct=hpPct;
F.effAtk=effAtk;F.effMag=effMag;F.effDef=effDef;F.effRes=effRes;
/* v2.10: exported for progression's affinity-cost curve and the UI's AETHER
   tab, which both need the exact same curve the combat formula itself uses
   (see the AFFINITY_CAP/affinityMul comment above for why this lives here
   rather than in progression.js). */
F.affinityMul=affinityMul;F.AFFINITY_CAP=AFFINITY_CAP;F.defaultAffinity=defaultAffinity;
F.AFFINITY_BOOST_CAP=AFFINITY_BOOST_CAP;
F.ACTIONS=ACTIONS;F.ATK_CAMP=ATK_CAMP;F.MAG_CAMP=MAG_CAMP;F.EQUIPPABLE=EQUIPPABLE;F.CHARGE_ACTIONS=CHARGE_ACTIONS;
F.BONUSES=BONUSES;F.applyBonuses=applyBonuses;F.bonusSpend=bonusSpend;
/* Pre-bonus baseline per action (power/rank/charge/defPierce/critBonus/turns/
   chargeCost) — exported so the LORE tab can diff the live (post-bonus)
   ACTIONS entry against this to show a "total bonus effect" summary,
   without re-deriving the per-bonus math applyBonuses already owns.
   snapshot() is idempotent and safe to call before the first real
   applyBonuses() — it no-ops once PRISTINE is populated. */
F.pristineOf=function(id){snapshot();return PRISTINE[id]||null;};
F.bonusApplies=bonusApplies;F.bonusPrice=bonusPrice;F.actionBonusTotal=actionBonusTotal;
F.BONUS_COST_BROAD=BONUS_COST_BROAD;
F.SWIFT_CEIL=SWIFT_CEIL;F.SWIFT_DECAY=SWIFT_DECAY;
F.costOfCharge=costOfCharge;F.CHARGE_UP_COST=CHARGE_UP_COST;
F.CHARGE_THRIFT=CHARGE_THRIFT;F.CHARGE_COST_MIN=CHARGE_COST_MIN;
F.CONDITIONS=CONDITIONS;F.condById=condById;F.foes=foes;F.allies=allies;F.PREF_TEXT=PREF_TEXT;
F.makeUnit=makeUnit;F.makeBattle=makeBattle;F.step=step;F.preview=preview;
F.ARCH=ARCH;F.ROT=ROT;F.dmgTakenMul=dmgTakenMul;F.ROSTER=ROSTER;
F.ENRAGE_AFTER=ENRAGE_AFTER;F.ENRAGE_PCT=ENRAGE_PCT;
/* WAVE_EXP was exported here until v2.1 replaced the exponent model with
   levelCurve(); the stale reference threw during core init under 'use strict',
   so window.FarroadCore was never assigned and the whole page died. */
F.waveScale=waveScale;F.K_BASE=K_BASE;F.levelCurve=levelCurve;F.GAIN_RATIO=GAIN_RATIO;
F.setWave=function(w){CURRENT_WAVE=w;};F.getK=function(){return K_of(1);};
F.enrageStacks=function(u){return u.enrageN||0;};
return F;})();


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
var ROW_PHYS=0.70,ROW_SPD=0.10,ROWMUL={front:1.35,back:0.75};
var ENRAGE_AFTER=8, ENRAGE_PCT=0.05;   /* grace in the enemy's OWN turns, then +5%/turn */
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
function rowSpdMul(u){return (u.isParty&&u.row==='front')?(1+ROW_SPD):1;}
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
function apply(u,id,t){u.st[id]=t;}
function effAtk(u){return u.base.atk*(has(u,'enfeebled')?.75:1);}
function effMag(u){return u.base.mag*(has(u,'dulled')?.75:1);}
function effDef(u){return u.base.def*(has(u,'bracing')?1.40:1)*(has(u,'sundered')?.75:1);}
function effRes(u){return u.base.res*(has(u,'frail')?.75:1);}
function effBlock(u){return u.base.block+(has(u,'bracing')?.30:0);}
function effEvade(u){return u.base.evade+(has(u,'blurred')?.20:0);}
function effChargeRate(u){return u.base.chargeRate*(has(u,'surging')?2.0:1);}
function tcOf(u,rank){return tcRaw(u.base.spd*rowSpdMul(u),rank*(has(u,'hasted')?.60:1)*(has(u,'slowed')?1.50:1));}
function incomingMul(u){return has(u,'warded')?.60:1;}
/* v2.8: chargeCost is the gauge a charge action must FILL to fire. It was the
   global CHARGE_FULL for every charge action; it is now per-action so that
   upgrading a charge action can make it fire less often. */
function A(o){o.rank=o.rank||1;o.charge=o.charge||0;o.hits=o.hits||1;o.defPierce=o.defPierce||0;o.critBonus=o.critBonus||0;o.critFn=o.critFn||null;o.power=o.power||0;
 if(o.isCharge)o.chargeCost=o.chargeCost||CHARGE_FULL;return o;}
function costOfCharge(a){return (a&&a.chargeCost)||CHARGE_FULL;}
var ACTIONS={
 strike:A({id:'strike',name:'Strike',camp:'atk',tk:'foe',power:1.00,rank:1.00,charge:20,note:'Starter. DPT 1.00.'}),
 ember:A({id:'ember',name:'Ember',camp:'mag',tk:'foe',power:1.05,rank:1.05,charge:21,note:'Starter. Hits RES; full power from the back rank.'}),
 mend:A({id:'mend',name:'Mend',camp:'mag',tk:'ally',power:1.20,rank:1.05,charge:22,heal:true,note:'Heal 1.20 × MAG. The +277% lesson.'}),
 /* v0.9 FIX: niche actions must LOSE outside their niche or the conditional is pointless.
    Pierce was pow 1.30 / pierce .40 / rank 1.30 -> a flat upgrade to Strike, so "always
    Pierce" beat "Pierce when armoured". Repriced to win ONLY against heavy armour. */
 pierce:A({id:'pierce',name:'Pierce',camp:'atk',tk:'foe',power:1.00,rank:1.50,charge:26,defPierce:.75,
   note:'Ignores 75% DEF but slow — wins vs armour, LOSES to Strike vs anything soft.'}),
 cleave:A({id:'cleave',name:'Cleave',camp:'atk',tk:'allFoes',power:.66,rank:1.30,charge:27,note:'All foes, physical.'}),
 flurry:A({id:'flurry',name:'Flurry',camp:'atk',tk:'foe',power:.43,hits:3,rank:1.25,charge:26,note:'3 hits, each rolls crit.'}),
 /* v2.7 EXECUTE — payoff moved from POWER into CRIT.
  * Power is now FLAT 0.80 and reads nothing about the target. The whole HP
  * condition lives in critFn: crit is CAPPED at 0.70 and multiplies by 1.75, so
  * the in-window uplift is bounded at ~1.47x no matter how much is invested.
  * Power scaling was unbounded AND multiplied against every swift purchase,
  * which is what made Execute the convergence target.
  * §6.0 PENALTY: power 0.80 < Strike's 1.00, and out of window Execute cannot
  * crit at all. Out-of-window DPT 0.80 vs Strike 1.04 — 23% worse, and the gap
  * is a POWER gap so it survives swift investment (a rank-based penalty would
  * erode, since all actions converge on the same initiative ceiling).
  * Rank drops 1.45 -> 1.00: at 1.45 the bounded crit payoff could not overcome
  * the speed loss and Execute was worse than Strike even inside its window.
  * v2.8: power 0.80 -> 0.65 (Ian's call) to widen the in/out spread and pull the
  * gambit uplift back toward the original +17.1%. The penalty is deeper, not
  * different in kind — power is still FLAT and still reads nothing about HP.
  * v2.8: CAP_CRIT is now 1.00, so a keen-stacked build can take the in-window
  * crit from 70% to a guaranteed 100%. The payoff is still bounded — 1.75x is
  * the most a crit can ever be worth — so the convergence fix is unaffected. */
 execute:A({id:'execute',name:'Execute',camp:'atk',tk:'foe',power:0.65,rank:1.00,charge:29,
   note:'Flat 0.65 power. Crits ALWAYS at ≤30% HP; CANNOT crit above it.',
   critFn:function(s,t){return (t&&t.hp/t.maxHp<=.30)?0.65:-1;}}),
 guardbreak:A({id:'guardbreak',name:'Guard Break',camp:'atk',tk:'foe',power:.85,rank:1.10,charge:24,applies:'sundered',turns:3,note:'Sundered.'}),
 daunt:A({id:'daunt',name:'Daunt',camp:'atk',tk:'foe',power:.60,rank:1.00,charge:22,applies:'enfeebled',turns:3,note:'Enfeebled — ATK ×0.75.'}),
 cripple:A({id:'cripple',name:'Cripple',camp:'atk',tk:'foe',power:.70,rank:1.15,charge:25,applies:'slowed',turns:3,note:'Slowed — 33% fewer enemy turns. The best non-heal rule.'}),
 brace:A({id:'brace',name:'Brace',camp:'atk',tk:'self',rank:.65,charge:30,applies:'bracing',turns:2,note:'Fast, high charge.'}),
 vengeance:A({id:'vengeance',name:'Vengeance',camp:'atk',tk:'foe',power:1.00,rank:1.30,charge:26,note:'0.55 at full HP → 2.10 near death.',
   powerFn:function(s){return 0.55+1.55*(1-s.hp/s.maxHp);}}),
 onslaught:A({id:'onslaught',name:'Onslaught',camp:'atk',tk:'foe',power:1.00,rank:1.45,charge:29,note:'×2.20 first turn, ×0.65 after.',
   powerFn:function(s){return s.turnsTaken===0?2.20:0.65;}}),
 rally:A({id:'rally',name:'Rally',camp:'atk',tk:'self',rank:.75,charge:45,applies:'surging',turns:3,note:'Doubles charge rate.'}),
 gale:A({id:'gale',name:'Gale',camp:'mag',tk:'allFoes',power:.62,rank:1.30,charge:27,note:'All foes, magic — safe vs thorns.'}),
 sear:A({id:'sear',name:'Sear',camp:'mag',tk:'foe',power:.62,rank:1.10,charge:24,applies:'burning',turns:3,note:'Burning.'}),
 hex:A({id:'hex',name:'Hex',camp:'mag',tk:'foe',power:.68,rank:1.05,charge:23,applies:'frail',turns:3,note:'Frail — cuts RES.'}),
 smother:A({id:'smother',name:'Smother',camp:'mag',tk:'foe',power:.60,rank:1.05,charge:23,applies:'dulled',turns:3,note:'Dulled — cuts enemy MAG and healing.'}),
 dazzle:A({id:'dazzle',name:'Dazzle',camp:'mag',tk:'foe',power:.58,rank:1.00,charge:22,applies:'blinded',turns:3,note:'Blinded.'}),
 siphon:A({id:'siphon',name:'Siphon',camp:'mag',tk:'foe',power:1.00,rank:1.30,charge:26,lifesteal:.50,note:'Heals you 50% of damage.'}),
 renew:A({id:'renew',name:'Renew',camp:'mag',tk:'ally',rank:1.15,charge:24,applies:'regen',turns:4,note:'Regen 4 turns.'}),
 recall:A({id:'recall',name:'Recall',camp:'mag',tk:'deadAlly',rank:1.60,charge:33,revive:.35,note:'Revive at 35% HP.'}),
 bulwark:A({id:'bulwark',name:'Bulwark',camp:'mag',tk:'ally',rank:.90,charge:28,applies:'warded',turns:2,note:'Warded — ×0.60 incoming.'}),
 blur:A({id:'blur',name:'Blur',camp:'mag',tk:'ally',rank:.90,charge:28,applies:'blurred',turns:3,note:'+0.20 evade.'}),
 quicken:A({id:'quicken',name:'Quicken',camp:'mag',tk:'ally',rank:1.40,charge:28,applies:'hasted',turns:3,note:'Hasted.'}),
 oath:A({id:'oath',name:"Wayfarer's Oath",camp:'atk',tk:'foe',power:4.20,rank:1.80,isCharge:true,critBonus:.30,note:'CHARGE · Kesh.'}),
 ninefold:A({id:'ninefold',name:'Ninefold Rain',camp:'atk',tk:'foe',power:.48,hits:9,rank:1.90,isCharge:true,randomPerHit:true,note:'CHARGE · Vey.'}),
 hearthlight:A({id:'hearthlight',name:'Hearthlight',camp:'mag',tk:'allAllies',power:2.40,rank:1.65,isCharge:true,heal:true,cleanse:1,note:'CHARGE · Ansa.'}),
 vowofstone:A({id:'vowofstone',name:'Vow of Stone',camp:'atk',tk:'allAllies',rank:1.55,isCharge:true,applies:'warded',turns:3,selfTaunt:3,note:'CHARGE · Dorrek.'}),
 ashfall:A({id:'ashfall',name:'Ashfall',camp:'mag',tk:'allFoes',power:1.90,rank:2.00,isCharge:true,applies:'burning',turns:3,note:'CHARGE · Mirel.'}),
 /* ===== ROSTER EXPANSION 5->10 (prereq for roadmap item 4) =====
  * Idle quests need units to actually BE benched, which needs a roster bigger
  * than PARTY_CAP — these five exist to make "owned but not fielded" a real,
  * sustained state instead of a transient one. Stats/growth are bounded by
  * the ORIGINAL five's own min/max (see P.MC_STAT_RANGE/MC_GROWTH_RANGE in
  * progression.js) — new combinations within the existing envelope, not new
  * extremes, so nothing here silently changes what the customisable MC can
  * reach. Acquired via Marks pulls only (doPull() already draws from all of
  * ROSTER generically) — no boss-milestone wave is assigned to any of them. */
 bloodfury:A({id:'bloodfury',name:'Bloodfury',camp:'atk',tk:'foe',power:3.60,rank:1.70,isCharge:true,critBonus:.40,lifesteal:.25,note:'CHARGE · Skarn. Big single-target hit, heavy crit bonus, partial lifesteal — a reckless crit-fisher that sustains itself.'}),
 spellbrand:A({id:'spellbrand',name:'Spellbrand',camp:'atk',tk:'foe',power:3.20,rank:1.60,isCharge:true,defPierce:.20,applies:'frail',turns:3,note:'CHARGE · Sorin. Armor-piercing blade strike that sears the target Frail — melee delivery, magic payload.'}),
 wardcurse:A({id:'wardcurse',name:'Warding Curse',camp:'mag',tk:'allFoes',power:.65,rank:1.75,isCharge:true,applies:'enfeebled',turns:4,note:'CHARGE · Nyra. Light AoE damage plus Enfeebled on every foe — shuts down enemy offense from the back line.'}),
 aegisstep:A({id:'aegisstep',name:'Aegis Step',camp:'mag',tk:'self',rank:1.45,isCharge:true,applies:'blurred',turns:3,selfTaunt:3,note:'CHARGE · Brenn. Self Blurred (+0.20 evade) plus self-taunt — draws every attack, then dodges most of them. The dodge-tank answer to Vow of Stone.'}),
 quicksilver:A({id:'quicksilver',name:'Quicksilver Blessing',camp:'mag',tk:'allAllies',power:1.40,rank:1.55,isCharge:true,heal:true,applies:'hasted',turns:2,note:'CHARGE · Sael. Light party heal plus Hasted — trades raw healing for tempo.'}),
 /* ===== MC GENERIC STARTERS (roadmap item 2) =====
  * The customisable MC needs an opening charge action that ISN'T one of the
  * "corner" actions below — those were deliberately written to occupy space
  * the plain kind axis (damage-physical / damage-magic / heal) does NOT, so
  * offering them as a first pick would start every custom character on a
  * build-around rather than a baseline. These three ARE that plain baseline:
  * no attached status, no lifesteal, no conditional scaling — just the kind
  * axis's three basic values, at the same rank/power a signature move gets
  * (see oath/ashfall/hearthlight above) minus the one flourish each of those
  * has (critBonus / burning / cleanse), with power nudged up slightly to
  * compensate for going without it. Not tied to a companion identity, since
  * the MC's name is the player's own. */
 heavystrike:A({id:'heavystrike',name:'Heavy Strike',camp:'atk',tk:'foe',power:4.20,rank:1.80,
  isCharge:true,note:'CHARGE · Bulk physical damage to one foe.'}),
 wildfire:A({id:'wildfire',name:'Wildfire',camp:'mag',tk:'allFoes',power:2.10,rank:2.00,
  isCharge:true,note:'CHARGE · Bulk magic damage to all foes.'}),
 greatheal:A({id:'greatheal',name:'Great Heal',camp:'mag',tk:'allAllies',power:2.60,rank:1.65,
  isCharge:true,heal:true,note:'CHARGE · Heals the whole party.'}),
 /* ===== CHARGE ACTION DESIGN SPACE (v2.1) =====
  * 25 units need 25 charge actions that are NOT 25 damage numbers. Five axes:
  *   1 SHAPE     one foe / all foes / one ally / all allies / self / the dead
  *   2 KIND      damage / heal / buff / debuff / revive / RESOURCE (charge, tempo)
  *   3 TIMING    instant burst / persistent for N turns / conditional payload
  *   4 COST      rank — cheap-and-frequent vs expensive-and-rare
  *   5 CONDITION unconditional vs scaling off battle state (HP, foe count, statuses)
  * The five originals cover: single burst (Oath), multi-hit random (Ninefold),
  * party heal+cleanse (Hearthlight), party buff+taunt (Vow), AoE damage+DoT (Ashfall).
  * The eight below deliberately occupy CORNERS the originals do not, to prove the
  * space is real. Remaining 12 are content work, not design work. */
 tideturn:A({id:'tideturn',name:'Tideturn',camp:'mag',tk:'allAllies',rank:1.50,isCharge:true,
   applies:'hasted',turns:3,note:'CHARGE · RESOURCE/TEMPO. Hastes the whole party — buys turns, deals nothing.'}),
 lastlight:A({id:'lastlight',name:'Last Light',camp:'mag',tk:'deadAlly',rank:1.70,isCharge:true,
   revive:.80,note:'CHARGE · REVIVE. Brings an ally back at 80% — the only full recovery in the game.'}),
 sunder:A({id:'sunder',name:'Sundering Vow',camp:'atk',tk:'allFoes',rank:1.60,isCharge:true,
   applies:'sundered',turns:4,power:0.55,note:'CHARGE · DEBUFF-first. Light damage, but strips DEF from everything.'}),
 gravewind:A({id:'gravewind',name:'Gravewind',camp:'mag',tk:'allFoes',rank:1.75,isCharge:true,
   applies:'slowed',turns:4,power:0.70,note:'CHARGE · TEMPO DENIAL. Slows every foe — fewer enemy turns, slower enrage.'}),
 reckoning:A({id:'reckoning',name:'Reckoning',camp:'atk',tk:'foe',rank:1.90,isCharge:true,power:1.00,
   powerFn:function(s,t){return t?(2.0+4.5*(1-t.hp/t.maxHp)):2.0;},
   note:'CHARGE · CONDITIONAL. ×2.0 at full HP rising to ×6.5 on a nearly-dead target.'}),
 bulwarkoath:A({id:'bulwarkoath',name:'Bulwark Oath',camp:'mag',tk:'allAllies',rank:1.45,isCharge:true,
   applies:'warded',turns:4,note:'CHARGE · CHEAP/FREQUENT. Low rank, fires often, party-wide ×0.60 incoming.'}),
 emberglut:A({id:'emberglut',name:'Ember Glut',camp:'mag',tk:'self',rank:0.90,isCharge:true,
   applies:'surging',turns:4,note:'CHARGE · RESOURCE. Very cheap; doubles its own charge rate to chain into the next.'}),
 hollowtoll:A({id:'hollowtoll',name:'Hollow Toll',camp:'mag',tk:'allFoes',rank:2.10,isCharge:true,power:1.35,
   lifesteal:.60,note:'CHARGE · SUSTAIN-AoE. Hits everything and heals the caster 60% of the total.'}),
 /* ===== ENEMY CHARGE ACTIONS (v1.0) =====
    Enemies now have every stat the party has except Recovery, and chargeRate was
    already among them - it simply had nothing to spend charge on. These give it a
    sink. The gauge is visible on the enemy card and the `foe_charging` condition
    lets the player write rules against it, so a telegraphed special is something
    to play around rather than a surprise. */
 wardensmaul:A({id:'wardensmaul',name:"Warden's Maul",camp:'atk',tk:'foe',power:3.10,rank:1.75,
   isCharge:true,critBonus:.10,note:'CHARGE · boss. Heavy single target.'}),
 sunderingroar:A({id:'sunderingroar',name:'Sundering Roar',camp:'atk',tk:'allAllies',rank:1.50,
   isCharge:true,applies:'enfeebled',turns:3,note:'CHARGE · Stone Ox. Enfeebles the party.'}),
 quickenedhowl:A({id:'quickenedhowl',name:'Quickened Howl',camp:'atk',tk:'self',rank:1.20,
   isCharge:true,applies:'hasted',turns:3,note:'CHARGE · Mire Hound. Hastes itself.'}),
 /* Enemy basic actions need a `charge` value or the gauge never moves: A() defaults
    charge to 0, so before v1.0 an enemy with a chargeAction could never have fired
    it. Values mirror the party's charge-per-rank so gauges fill at a similar pace. */
 bite:A({id:'bite',name:'Bite',camp:'atk',tk:'foe',power:1.00,rank:1.00,charge:19}),
 rake:A({id:'rake',name:'Rake',camp:'atk',tk:'foe',power:.85,rank:.85,charge:16}),
 maul:A({id:'maul',name:'Maul',camp:'atk',tk:'foe',power:1.45,rank:1.45,charge:26}),
 knitbone:A({id:'knitbone',name:'Knit Bone',camp:'mag',tk:'ally',power:1.15,rank:1.20,heal:true,charge:21}),
 wait:A({id:'wait',name:'Wait',camp:'atk',tk:'self',rank:1.00,inert:true})};
var ATK_CAMP=['strike','pierce','cleave','flurry','execute','guardbreak','daunt','cripple','brace','vengeance','onslaught','rally'];
var MAG_CAMP=['ember','gale','sear','hex','smother','dazzle','siphon','mend','renew','recall','bulwark','blur','quicken'];
var EQUIPPABLE=ATK_CAMP.concat(MAG_CAMP);
var CHARGE_ACTIONS=['oath','ninefold','hearthlight','vowofstone','ashfall',
 'bloodfury','spellbrand','wardcurse','aegisstep','quicksilver',
 'heavystrike','wildfire','greatheal',
 'tideturn','lastlight','sunder','gravewind','reckoning','bulwarkoath','emberglut','hollowtoll'];
/* 21 of a target 25 authored (13 + the 3 MC generic starters + the 5 roster-
   expansion companions above). The remaining 4 are content, not design — the
   five axes above define where they sit; see VERIFICATION for the coverage
   grid. */
/* ---- Lore bonuses (v0.8) ---- */
var BONUS_COST=2;
var SWIFT_CEIL=3.0, SWIFT_DECAY=0.88;
/* Swift's Lore price rises with how fast the action ALREADY is. The logarithmic
   curve alone leaves swift live on every action (a fast action still gains +11%
   on its first stack), which is the auto-buy shape Ian asked to remove. Rather
   than special-casing the curve, the CURVE stays universal and the PRICE varies:
   2 Lore on a sluggish action, 6 on an already-quick one. */
function swiftCost(a){var ini=1/((a&&a.rank)||1);
 return ini<0.85?BONUS_COST:(ini<1.15?BONUS_COST*2:BONUS_COST*3);}
/* ===== ESCALATING STACK COST =====
 * Every bonus's Lore price used to be FLAT per stack forever — the 1st and
 * the 50th cost the same. With idle Marks (and the duplicates they can't
 * help but produce at endgame, once everything is already owned) landing in
 * the tens of thousands over long play, flat pricing meant no bonus ever
 * stopped being an auto-buy; it just took longer to afford the next one.
 * BONUS_GROWTH multiplies the base price by itself once per stack ALREADY
 * owned, so cost rises every level rather than staying constant: at the
 * default 1.15, stack 1 is still base price, stack 11 is ~4x base, stack 21
 * is ~16x, stack 31 is ~66x — a real soft cap without an arbitrary hard one.
 * Swift keeps its existing speed-tiered BASE price (2/4/6 Lore) — this
 * multiplies ON TOP of that, it doesn't replace it. */
var BONUS_GROWTH=1.15;
/* Broad is exempt from both the escalation above and the flat BONUS_COST
   below it applies to. It's not a per-stack magnitude bonus like the others
   — applyBonuses() flips the action from single- to multi-target the moment
   ONE stack exists (`if(b.broad){...}`) and every stack after that does
   nothing. A strong one-time unlock priced like a repeatable magnitude
   bonus was underpriced, so it gets its own flat cost instead of inheriting
   either curve. */
var BONUS_COST_BROAD=50;
function bonusPrice(a,bid,n){
 if(bid==='broad')return BONUS_COST_BROAD;
 var base=(bid==='swift')?swiftCost(a):BONUS_COST;
 return Math.max(1,Math.round(base*Math.pow(BONUS_GROWTH,n||0)));}
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
  /* under the logarithmic curve every action gains something, so swift is live
     everywhere and is priced by swiftCost() instead of being hidden. */
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
/* v2.9 BUGFIX: this counted stacks and multiplied by the flat BONUS_COST, which
   stopped being true in v2.6 when swift became priced by the action's initiative
   (2, 4 or 6). Free Lore was therefore overstated on any swift purchase and the
   player could spend past their total. Now each stack is priced the same way the
   LORE tab prices it — including the per-stack escalation above, so a re-spend
   from scratch (e.g. after a save round-trip) always reconstructs the same total
   rather than assuming every owned stack cost today's flat rate. */
function bonusSpend(map){var n=0;
 Object.keys(map||{}).forEach(function(aid){var a=ACTIONS[aid];
  Object.keys(map[aid]).forEach(function(bid){
   var stacks=map[aid][bid]||0;
   for(var i=0;i<stacks;i++)n+=bonusPrice(a,bid,i);});});
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
function condById(id){for(var i=0;i<CONDITIONS.length;i++)if(CONDITIONS[i].id===id)return CONDITIONS[i];return CONDITIONS[0];}
function resolveTarget(act,ct,u,b){var k=act.tk;
 if(k==='self')return u;
 if(k==='foe'||k==='allFoes'){if(ct&&ct.isParty!==u.isParty&&ct.hp>0)return ct;return defFoe(b,u);}
 if(k==='ally'||k==='allAllies'){if(ct&&ct.isParty===u.isParty&&ct.hp>0)return ct;return byLowestHp(allies(b,u));}
 if(k==='deadAlly'){if(ct&&ct.isParty===u.isParty&&ct.hp<=0)return ct;return deadAllies(b,u)[0]||null;}
 return null;}
function makeUnit(cfg){var d={hp:100,atk:10,mag:10,def:10,res:10,spd:100,atkCrit:.05,magCrit:.05,chargeRate:1,block:.03,evade:.03};
 for(var k in (cfg.stats||{}))if(Object.prototype.hasOwnProperty.call(cfg.stats,k))d[k]=cfg.stats[k];
 return {id:cfg.id,name:cfg.name,isParty:!!cfg.isParty,level:cfg.level||1,slotIndex:cfg.slotIndex||0,base:d,
  maxHp:cfg.maxHp!=null?cfg.maxHp:d.hp,hp:cfg.hp!=null?cfg.hp:d.hp,charge:cfg.charge||0,
  chargeAction:cfg.chargeAction||null,slots:cfg.slots||[{cond:'none',action:'strike'},{cond:'none',action:'strike'}],
  st:newSt(),nextActAt:0,alternateFlag:0,turnsTaken:0,row:cfg.row||null,arch:cfg.arch||null,thorns:cfg.thorns||0,isBoss:!!cfg.isBoss};}
function makeBattle(units,opts){opts=opts||{};
 var b={units:units,t:0,beat:0,elapsedMs:0,log:[],over:null,rng:opts.rng||makeRNG(1),det:!!opts.deterministic,
  gambitMode:'topdown',smartHeal:true,enrage:!!opts.enrage};
 for(var i=0;i<units.length;i++){var u=units[i];u.st=newSt();u.nextActAt=tcOf(u,1.00);u.turnsTaken=0;u.alternateFlag=0;}
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
 o.K=K_of(src.level);o.off=isPhys?effAtk(src):effMag(src);
 o.defRaw=isPhys?effDef(tgt):effRes(tgt);o.defEff=o.defRaw*(1-(act.defPierce||0));o.mit=o.K/(o.K+o.defEff);
 o.power=pv;o.base=pv*o.off*o.mit;
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
function healFor(src,tgt,act,b,pv){var v=pv*effMag(src);   /* v1.1: variance removed here too */
 var amt=Math.max(1,Math.floor(v)),before=tgt.hp;tgt.hp=Math.min(tgt.maxHp,tgt.hp+amt);
 return {heal:true,targetName:tgt.name,amount:tgt.hp-before};}
function step(b){
 if(b.over)return null;var u=pickNext(b);if(!u){b.over='draw';return null;}
 b.t=u.nextActAt;b.beat+=1;var ms=beatMs(b.beat);b.elapsedMs+=ms;
 var e={beat:b.beat,t:b.t,ms:ms,actorId:u.id,actorName:u.name,isParty:u.isParty,
  chargeBefore:u.charge,hits:[],heals:[],totalDamage:0,notes:[],dot:0,regen:0,thorns:0};
 if(has(u,'burning')){var dot=Math.max(1,Math.ceil(BURN_PCT*u.maxHp));u.hp=Math.max(0,u.hp-dot);e.dot=dot;}
 if(has(u,'regen')&&u.hp>0){var rg=Math.max(1,Math.ceil(REGEN_PCT*u.maxHp)),bf=u.hp;u.hp=Math.min(u.maxHp,u.hp+rg);e.regen=u.hp-bf;}
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
  if(act.revive){if(primary&&primary.hp<=0){primary.hp=Math.max(1,Math.floor(primary.maxHp*act.revive));primary.st=newSt();
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
    apply(targets[m],act.applies,act.turns);
    e.notes.push((already?'refreshed ':'applied ')+act.applies+' on '+targets[m].name);}}}
  if(act.selfTaunt){apply(u,'taunted',act.selfTaunt);e.notes.push('taunting');}}
 if(act.isCharge)u.charge-=costOfCharge(act);else u.charge+=act.charge*effChargeRate(u);
 e.chargeAfter=u.charge;u.turnsTaken+=1;u.nextActAt=b.t+tcOf(u,act.rank);
 /* ENRAGE (v1.0, on by default). Counted in the ENEMY'S OWN TURNS, not beats and
    not rounds - CTB has no rounds, and beats are global and abstract, whereas a
    stack that ticks when you watch that unit act is legible. It also means a
    Slowed enemy enrages more slowly, so Cripple answers the clock as well as the
    damage - a synergy that falls out of the definition rather than being added.
    Grace of 8 own-turns, then +5%/turn. Ian asked for 5 turns; at 5 the effect on
    offensive gambits largely evaporates (Cripple +2.0% vs +14.7% at 8). */
 if(b.enrage&&!u.isParty&&u.hp>0&&u.turnsTaken>ENRAGE_AFTER){
  u.base.atk=u.base.atk*(1+ENRAGE_PCT);
  e.enrageStacks=u.turnsTaken-ENRAGE_AFTER;
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
var ARCH={
 wolf:{key:'wolf',name:'Roadwolf',hpMul:1.00,atk:21,def:12,res:8,spd:92,atkCrit:.04,evade:.05,block:.00,
  slots:[{cond:'none',action:'bite'},{cond:'none',action:'bite'}]},
 knight:{key:'knight',name:'Barrow Knight',hpMul:.85,atk:19,def:34,res:20,spd:84,atkCrit:.03,evade:.02,block:.10,
  slots:[{cond:'none',action:'bite'},{cond:'none',action:'bite'}]},
 hound:{key:'hound',name:'Mire Hound',hpMul:.60,atk:15,def:8,res:6,spd:124,atkCrit:.08,evade:.10,block:.00,
  slots:[{cond:'none',action:'rake'},{cond:'none',action:'rake'}]},
 ox:{key:'ox',name:'Stone Ox',hpMul:1.60,atk:27,def:20,res:14,spd:70,atkCrit:.05,evade:.01,block:.05,
  slots:[{cond:'none',action:'maul'},{cond:'none',action:'maul'}]},
 priest:{key:'priest',name:'Fen Priest',hpMul:.55,atk:12,mag:23,def:14,res:22,spd:96,atkCrit:.03,evade:.03,block:.02,
  slots:[{cond:'ally_hp_lte_60',action:'knitbone'},{cond:'none',action:'bite'}]},
 shrike:{key:'shrike',name:'Thorn Shrike',hpMul:.80,atk:17,def:14,res:26,spd:100,atkCrit:.05,evade:.06,block:.00,thorns:.06,
  slots:[{cond:'none',action:'bite'},{cond:'none',action:'bite'}]}};
var ROT=['wolf','knight','hound','ox','priest','shrike'];
var REF={def:12,evade:.05,block:.00};
function dmgTakenMul(a){var K=25;
 return ((K/(K+a.def))/(K/(K+REF.def)))*((1-a.evade)/(1-REF.evade))*((1-a.block*.5)/(1-REF.block*.5));}
var ROSTER=[
 {id:'kesh',name:'Kesh',role:'attacker',row:'front',hp:430,chargeAction:'oath',stats:{atk:26,mag:18,def:20,res:16,spd:100,atkCrit:.05,magCrit:.05,chargeRate:1,block:.03,evade:.03}},
 {id:'ansa',name:'Ansa',role:'healer',row:'back',hp:320,chargeAction:'hearthlight',stats:{atk:14,mag:26,def:14,res:22,spd:96,atkCrit:.04,magCrit:.06,chargeRate:1,block:.02,evade:.04}},
 {id:'dorrek',name:'Dorrek',role:'tank',row:'front',hp:560,chargeAction:'vowofstone',stats:{atk:22,mag:10,def:30,res:20,spd:84,atkCrit:.04,magCrit:.03,chargeRate:1,block:.10,evade:.02}},
 {id:'vey',name:'Vey',role:'rogue',row:'front',hp:300,chargeAction:'ninefold',stats:{atk:24,mag:12,def:14,res:12,spd:124,atkCrit:.12,magCrit:.04,chargeRate:1,block:.02,evade:.10}},
 {id:'mirel',name:'Mirel',role:'mage',row:'back',hp:270,chargeAction:'ashfall',stats:{atk:12,mag:30,def:12,res:20,spd:92,atkCrit:.03,magCrit:.10,chargeRate:1,block:.02,evade:.04}},
 /* Roster expansion 5->10, pull-only (no boss-milestone wave assigned) — see
    the CHARGE ACTIONS comment above for why these bounds and this shape. */
 {id:'skarn',name:'Skarn',role:'berserker',row:'front',hp:340,chargeAction:'bloodfury',stats:{atk:25,mag:10,def:13,res:13,spd:110,atkCrit:.11,magCrit:.03,chargeRate:1,block:.02,evade:.05}},
 {id:'sorin',name:'Sorin',role:'battlemage',row:'front',hp:380,chargeAction:'spellbrand',stats:{atk:20,mag:20,def:17,res:15,spd:98,atkCrit:.06,magCrit:.06,chargeRate:1,block:.04,evade:.04}},
 {id:'nyra',name:'Nyra',role:'warden',row:'back',hp:310,chargeAction:'wardcurse',stats:{atk:15,mag:21,def:17,res:20,spd:90,atkCrit:.04,magCrit:.07,chargeRate:1,block:.04,evade:.04}},
 {id:'brenn',name:'Brenn',role:'sentinel',row:'front',hp:480,chargeAction:'aegisstep',stats:{atk:13,mag:11,def:18,res:19,spd:102,atkCrit:.04,magCrit:.04,chargeRate:1,block:.03,evade:.09}},
 {id:'sael',name:'Sael',role:'courier',row:'back',hp:290,chargeAction:'quicksilver',stats:{atk:12,mag:24,def:12,res:16,spd:114,atkCrit:.03,magCrit:.07,chargeRate:1,block:.02,evade:.06}}];
F.makeRNG=makeRNG;F.tcRaw=tcRaw;F.tcOf=tcOf;F.beatMs=beatMs;F.CHARGE_FULL=CHARGE_FULL;
/* v2.9: exported because buildEnemies (progression scope) now clamps scaled
   enemy crit against CAP_CRIT. The progression IIFE is a SEPARATE scope under
   'use strict', so a bare CAP_CRIT there is a ReferenceError, not a silent
   undefined — the same failure mode as the v0.9 WAVE_EXP bug. */
F.CAP_CRIT=CAP_CRIT;F.CRIT_MUL=CRIT_MUL;
F.ST=ST;F.DEBUFFS=DEBUFFS;F.STATUS_INFO=STATUS_INFO;F.has=has;F.hpPct=hpPct;
F.effAtk=effAtk;F.effMag=effMag;F.effDef=effDef;F.effRes=effRes;
F.ACTIONS=ACTIONS;F.ATK_CAMP=ATK_CAMP;F.MAG_CAMP=MAG_CAMP;F.EQUIPPABLE=EQUIPPABLE;F.CHARGE_ACTIONS=CHARGE_ACTIONS;
F.BONUSES=BONUSES;F.BONUS_COST=BONUS_COST;F.applyBonuses=applyBonuses;F.bonusSpend=bonusSpend;
F.bonusApplies=bonusApplies;F.swiftCost=swiftCost;F.bonusPrice=bonusPrice;F.BONUS_GROWTH=BONUS_GROWTH;
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
F.enrageStacks=function(u){return Math.max(0,u.turnsTaken-ENRAGE_AFTER);};
return F;})();

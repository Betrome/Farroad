
/* ===== FAIL LOUDLY =====
 * A ReferenceError inside the render chain used to kill the page SILENTLY: the
 * button stayed bound, the handler threw, and nothing visibly happened. Any
 * uncaught error now paints a banner instead of dying quietly. */
window.onerror=function(msg,src,line,col){
 var b=document.getElementById('errbar');
 if(!b){b=document.createElement('div');b.id='errbar';
  b.style.cssText='position:fixed;left:0;right:0;top:0;z-index:999;background:#5a1e1e;'+
   'color:#ffd9d9;font:14px/1.5 ui-monospace,monospace;padding:10px 12px;'+
   'border-bottom:2px solid #e87a68;white-space:pre-wrap';
  document.body.insertBefore(b,document.body.firstChild);}
 b.textContent='⚠ SCRIPT ERROR — the build is broken:\n'+msg+'\n(line '+line+':'+col+')';
 return false;};
(function(){
'use strict';
var C=window.FarroadCore, P=window.FarroadProgression, Save=window.FarroadSave;
var $=function(s){return document.querySelector(s);};
var SAVE_KEY='farroad-save-v1';

var G;   /* game state */
/* @param mc optional {name,stats,hp,growth,chargeAction} from character
   creation (see applyCustomMC below) — null keeps the hardcoded Kesh. */
function newGame(seed,mc){
 return {seed:seed||7, rng:C.makeRNG(seed||7), wave:0, farthest:1, bossesCleared:0,
  aether:0, lore:0, marks:0, wipes:0,
  party:['kesh'], actions:P.STARTER_ACTIONS.slice(), conditions:['none'],
  actionCounts:{}, condCounts:{}, bonuses:{}, recovery:{}, loadout:{}, hpCarry:{}, touched:{},
  /* v2.4: every reward keyed to a WAVE NUMBER rather than to progress is farmable
     by dying and replaying. This records which waves have ever been cleared. */
  clearedWaves:{},
  /* v2.9 BUGFIX: clearedWaves only gates a reward once a wave is actually WON,
     so wiping into an uncleared wave and re-entering it (onWipe -> startWave,
     same wave, no skipDrops) re-ran grantDrops every time — farmable Lore by
     repeatedly suiciding into a wave you haven't beaten yet. dropsGranted is a
     separate dict, set the first time grantDrops ever PROCESSES a wave
     (win or lose), so a retry is gated immediately instead of only after a
     clear — see grantDrops() for the actual gate. */
  dropsGranted:{},
  lvl:{kesh:1}, bank:{kesh:0}, maxLevelEver:1, owned:{kesh:1},
  /* v2.10: elemental affinities — PURCHASED points only (see the AETHER-
     investment comment above renderAether below); a custom MC's own
     baseline is separately all-0 by construction (defaultAffinity() in
     core.js), so kesh here starting at {} is genuinely neutral either way. */
  affinities:{kesh:{}},
  /* v2.10: Evade/ATK-Crit/MAG-Crit — same shape, PURCHASED STEPS only
     (see effectivePctStats below); a custom MC's own baseline is
     separately 0 (applyCustomMC), so kesh starting at {} is genuinely
     neutral either way, same reasoning as affinities immediately above.
     (Block was here too until Ian removed it — Body affinity already
     covers physical damage reduction, a second overlapping stat was
     redundant — see farroad-core.js.) */
  statInvest:{kesh:{}},
  /* v2.14: equipment — see farroad-save.js's FIELDS comment for the shape.
     equipInv is flat (no per-uid seeding needed); equipped is per-unit,
     kesh seeded the same way affinities/statInvest are just above. */
  equipInv:{}, equipped:{kesh:{}},
  battle:null, units:null, enemies:null, over:null, enrage:true, idleAcc:0,
  /* Live side-battle-in-progress state (quests/dungeons) — see MODULES.md.
     sideBattle is null outside a side fight; roadBattle parks the real
     G.battle object while one plays out. Both are transient, like G.battle
     itself — never in farroad-save.js FIELDS, never restored on reload. */
  sideBattle:null, roadBattle:null,
  mc:mc||null, expeditions:[], pullsSinceUnit:0,
  /* Discoverable content — see MODULES.md. dungeons: [] of fully-baked,
     frozen-difficulty repeatable fights found by expeditions. quests:
     {uid:{stage,frozen}} per-companion 5-battle progress, keyed only for
     owned units (kesh included, like every other owned-unit dict) —
     frozen[i] is {wave,enemies}, that stage's own baked wave-equivalent
     (derived from the player's power level at the time — see
     P.questStageWave) and enemy snapshot, populated lazily on FIRST
     attempt (win or lose) so a stage's difficulty is pinned to whenever
     the player actually first tries it, not re-derived on every retry. */
  dungeons:[], quests:{kesh:{stage:0,frozen:[]}},
  /* Per-direction persistent exploration progress — see MODULES.md.
     maxDepth is the DEEPEST exp.ew any expedition has ever reached in
     this direction, cumulative across every trip ever sent there (never
     reset when one expedition returns and another is sent) — what that
     direction's own P.DIRECTION_CONFIG[dir].unlockEvery-depth dungeon
     unlocks are checked against.
     dungeonsUnlocked is how many of this direction's dungeons have
     already been produced, so a save/reload can't re-trigger an unlock
     that already happened. */
  directions:newDirections()};}
function newDirections(){
 var d={};P.DIRECTIONS.forEach(function(dir){d[dir]={maxDepth:0,dungeonsUnlocked:0};});
 return d;}

/* Applies a player-built character onto the 'kesh' slot. This mutates the
   shared C.ROSTER/P.GROWTH.kesh entries in place rather than threading an
   override through every C.ROSTER lookup (buildParty, renderLore, the
   loadout editor's charge-action box, etc. — nine call sites) — the same
   pattern the row-toggle button already uses on C.ROSTER. Both tables are
   plain in-memory objects rebuilt fresh on every page load, so this is safe:
   it never touches anything persisted, only the live session's copy. A no-op
   when G.mc is null (an old save, or a fresh boot before creation runs),
   which leaves the hardcoded Kesh exactly as shipped. */
function applyCustomMC(){
 if(!G.mc)return;
 /* Back-fill for a save made before charge-action acquisition existed: it has
    chargeAction but no pool. Without this the swap UI never appears (needs
    length>1 to show at all) and a rare-drop duplicate-check would crash on
    an undefined array — treat "one fixed action" as "a pool of one". */
 if(!G.mc.acquiredCharges||!G.mc.acquiredCharges.length)G.mc.acquiredCharges=[G.mc.chargeAction];
 var keshDef=null;C.ROSTER.forEach(function(r){if(r.id==='kesh')keshDef=r;});
 if(!keshDef)return;
 keshDef.name=G.mc.name;
 keshDef.hp=G.mc.hp;
 keshDef.chargeAction=G.mc.chargeAction;
 /* v2.10: a custom MC starts NEUTRAL (0) in every affinity — character
    creation offers no affinity content at all (see the AETHER tab instead),
    so there is no authored baseline to carry over. Without this the kesh
    ROSTER row's own CSV-authored baseline (farroadunits.csv, used when
    Kesh is the untouched default) would leak into a custom MC's stats,
    exactly the "not neutral" bug this line exists to prevent. */
 keshDef.affinity=C.defaultAffinity();
 /* chargeRate is the one field NOT offered at creation (see P.MC_STAT_RANGE's
    comment — the five shipped units never vary it, so there is no already-
    played range to bound a choice against); it stays fixed at 1 same as
    every other unit.
    v2.10: atkCrit/magCrit/evade are ALSO no longer offered at creation
    (P.MC_STAT_KEYS dropped them — they level like affinities now, see
    G.statInvest/effectivePctStats below) — explicitly 0 here, same
    "genuinely neutral start" fix as keshDef.affinity above, and for the
    identical reason: G.mc.stats never carries these keys any more, so
    reading G.mc.stats.atkCrit etc. would silently write literal `undefined`
    onto keshDef.stats (a key IS present, makeUnit's hasOwnProperty merge
    WOULD copy it, overwriting the sane default with undefined) rather than
    the neutral baseline this is supposed to be. (Block isn't listed here
    at all any more — the stat itself is gone, see farroad-core.js.) */
 keshDef.stats={atk:G.mc.stats.atk,mag:G.mc.stats.mag,def:G.mc.stats.def,res:G.mc.stats.res,spd:G.mc.stats.spd,
  atkCrit:0,magCrit:0,chargeRate:1,evade:0};
 P.GROWTH.kesh={hp:G.mc.growth.hp,atk:G.mc.growth.atk,mag:G.mc.growth.mag,
  def:G.mc.growth.def,res:G.mc.growth.res,spd:G.mc.growth.spd};}
/* v2.10: "replace all mentions of Kesh with the name the player chooses."
   The internal id 'kesh' stays exactly what it is everywhere (a dict key,
   invisible to the player) — this is only about player-FACING text.
   Most of the UI already shows the right name for free, since it always
   reads C.ROSTER's own kesh row (applyCustomMC already keeps .name in
   sync with G.mc.name, or leaves the shipped default "Kesh" untouched
   when there's no custom MC). What DOESN'T get this for free is static
   authored prose living in the CSVs — quest story text, an action's own
   design note — which can't read live game state at compile/CSV-author
   time. mcName()/withMcName() are the render-time bridge: author-facing
   content writes the literal token {{name}}, this substitutes the
   CURRENT Kesh/custom-MC name in wherever that text is actually
   displayed. A no-op (returns the string unchanged) for any text that
   doesn't contain the token, so it's safe to wrap every note/story
   display site uniformly rather than special-casing the couple of CSV
   rows that use it today. */
function mcName(){
 var d=null;C.ROSTER.forEach(function(r){if(r.id==='kesh')d=r;});
 return d?d.name:'Kesh';}
function withMcName(text){return text?text.replace(/\{\{name\}\}/g,mcName()):text;}

/* Recovery: base + purchased steps, hard-capped at the measured saturation point. */
function recoveryOf(uid){
 var steps=(G.recovery&&G.recovery[uid])||0;
 return Math.min(P.REST_CAP, P.REST + P.REST_STEP*steps);}
function recoveryMaxed(uid){return recoveryOf(uid)>=P.REST_CAP-1e-9;}
/* v2.8: first step 70 -> 10 Aether. Recovery now starts at 0, so the first step
   is no longer an optimisation on top of a working baseline — it is the thing
   that makes the run survivable at all, and it has to be affordable before the
   player can discover that by dying. 10 is inside a single wave-1 kill (12.6).
   Growth stays at 1.45, so the CAP costs the same order as before (881 Aether
   for all ten steps vs 1,180 at base 70) — the change front-loads access, it
   does not make maxing recovery cheap. */
function recoveryCost(uid){return Math.round(10*Math.pow(1.45,(G.recovery&&G.recovery[uid])||0));}
/* With a relative cost curve, cumulative EXP no longer determines level on its own
   — the discount depends on R at the moment each level is bought. So level is
   tracked directly and unspent Aether sits in a per-unit bank. */
function expOf(uid){return (G.bank&&G.bank[uid])||0;}          /* unspent bank */
function levelOf(uid){return (G.lvl&&G.lvl[uid])||1;}
function ratchetR(){return G.maxLevelEver||1;}
/* Rarity (v2.12): a Rare/Legendary unit costs more per level than the
   unmodified, rarity-agnostic P.costToNext formula returns — layered on
   top at this UI choke point, same pattern pctStatBaseline's own
   C.ROSTER scan already established just above. P.costToNext itself
   stays pure/rarity-unaware, consistent with how affinity/PCT-stat
   investment are already layered rather than baked into core formulas. */
function rarityCostMul(uid){
 var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
 return C.RARITY_COST_MUL[(def&&def.rarity)||'common']||1;}
function costNext(uid){return Math.round(P.costToNext(levelOf(uid),ratchetR())*rarityCostMul(uid));}
function feedUnit(uid,amount){
 G.bank=G.bank||{};G.lvl=G.lvl||{};
 G.bank[uid]=(G.bank[uid]||0)+amount;
 var gained=0,guard=0,mul=rarityCostMul(uid);
 while(guard++<100000){
  var c=Math.round(P.costToNext(levelOf(uid),ratchetR())*mul);
  if(G.bank[uid]<c)break;
  G.bank[uid]-=c;G.lvl[uid]=levelOf(uid)+1;gained++;
  if(G.lvl[uid]>(G.maxLevelEver||1))G.maxLevelEver=G.lvl[uid];   /* the ratchet */
 }
 return gained;}
/* ===== ELEMENTAL AFFINITIES (v2.10) ===== see farroad-core.js (AFFINITY_CAP/
   affinityMul/affTerm — the combat formula) and farroad-progression.js
   (P.affinityCostToNext/P.POWER_PER_AFFINITY_POINT — the economy) for the
   rest of this feature. This is the UI layer's slice: combining a unit's
   authored baseline with its purchased investment into the effective value
   combat reads, and the AETHER tab controls that spend Aether on it. */
var AFFINITY_AXES=['fire','water','earth','air','light','dark','body','spirit'];
var AFFINITY_INFO={
 fire:{n:'Fire',d:'Damage dealt and taken by Fire-tagged attacks.'},
 water:{n:'Water',d:'Damage dealt and taken by Water-tagged attacks.'},
 earth:{n:'Earth',d:'Damage dealt and taken by Earth-tagged attacks.'},
 air:{n:'Air',d:'Damage dealt and taken by Air-tagged attacks.'},
 light:{n:'Light',d:'Damage dealt and taken by Light-tagged attacks.'},
 dark:{n:'Dark',d:'Damage dealt and taken by Dark-tagged attacks.'},
 body:{n:'Body',d:'Physical damage dealt and taken, on top of any element a physical attack also carries.'},
 spirit:{n:'Spirit',d:'In-combat healing given and received (including drain/lifesteal effects like Siphon), and how strongly buffs/debuffs land — as caster and as target. Does not affect Recovery, the separate between-wave stat.'}};
function affinityBaseline(uid){
 var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
 return (def&&def.affinity)||{};}
function affinityPurchased(uid){return (G.affinities&&G.affinities[uid])||{};}
/* Effective combat-time value = authored baseline + purchased points — see
   the "Data model" comment in the plan / P.powerLevel's affinity term for
   why these stay two separate numbers rather than one mutated figure. */
/* Equipment (v2.14): sums the 8 axes across whatever's sitting in
   G.equipped[uid]'s 5 slots — legs items carry no affinity by design
   (content-pipeline.js validates this), so summing all 5 slots
   unconditionally is safe, a legs item just contributes 0 everywhere. */
function equipmentAffinity(uid){
 var out={},equipped=(G.equipped&&G.equipped[uid])||{};
 AFFINITY_AXES.forEach(function(ax){out[ax]=0;});
 C.EQUIPMENT_SLOTS.forEach(function(slot){
  var id=equipped[slot],item=id&&C.EQUIPMENT[id];
  if(item)AFFINITY_AXES.forEach(function(ax){out[ax]+=item.affinity[ax]||0;});});
 return out;}
function effectiveAffinity(uid){
 var base=affinityBaseline(uid),purchased=affinityPurchased(uid),equip=equipmentAffinity(uid),out={};
 AFFINITY_AXES.forEach(function(ax){out[ax]=(base[ax]||0)+(purchased[ax]||0)+equip[ax];});
 return out;}
function affinityRaw(uid,axis){return (affinityBaseline(uid)[axis]||0)+(affinityPurchased(uid)[axis]||0);}
/* Stops offering a purchase once the EFFECTIVE raw hits the cap exactly —
   C.affinityMul plateaus there by construction (Math.min clamps the input),
   so a further point could not move the number even if bought. */
function affinityMaxed(uid,axis){return affinityRaw(uid,axis)>=C.AFFINITY_CAP;}
function affinityNextCost(uid,axis){return P.affinityCostToNext(affinityPurchased(uid)[axis]||0);}

/* ===== EVADE/CRIT INVESTMENT (v2.10) ===== see farroad-progression.js
   (P.PCT_STAT/P.pctStatCost/P.pctStatValue — the cost curve, mirroring
   Recovery's own shape) for the rest of this feature. Same UI-layer slice
   affinities already established: combine a unit's existing baseline
   (C.ROSTER[uid]/C.ARCH[key]'s own atkCrit/magCrit/evade — unchanged,
   already the only source before this feature existed) with purchased
   steps into the effective value P.statsAt's output gets overwritten with,
   AFTER P.statsAt runs (P.statsAt itself is untouched — it still just
   copies these 3 straight from base).
   Block was here too until Ian removed it entirely — Body affinity
   already covers physical damage reduction, a second overlapping stat
   was redundant (see farroad-core.js). */
var PCT_STAT_KEYS=['evade','atkCrit','magCrit'];
var PCT_STAT_INFO={
 evade:{n:'Evade',d:'Chance to take no damage at all.'},
 atkCrit:{n:'ATK Crit',d:'Chance for a physical attack to hit for '+C.CRIT_MUL+'x.'},
 magCrit:{n:'MAG Crit',d:'Chance for a magic attack to hit for '+C.CRIT_MUL+'x.'}};
function pctStatBaseline(uid,stat){
 var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
 return (def&&def.stats&&def.stats[stat])||0;}
function pctStatPurchased(uid,stat){return ((G.statInvest&&G.statInvest[uid]&&G.statInvest[uid][stat])||0);}
function pctStatValue(uid,stat){return P.pctStatValue(pctStatBaseline(uid,stat),stat,pctStatPurchased(uid,stat));}
function pctStatMaxed(uid,stat){return P.pctStatMaxed(pctStatBaseline(uid,stat),stat,pctStatPurchased(uid,stat));}
function pctStatNextCost(uid,stat){return P.pctStatCost(stat,pctStatPurchased(uid,stat));}
/* Overwrites st.evade/st.atkCrit/st.magCrit (already computed by
   P.statsAt, unmodified) with the investment-adjusted effective value —
   called right before a live C.makeUnit is built, same placement
   effectiveAffinity() already has. */
function applyPctStatInvestment(uid,st){
 PCT_STAT_KEYS.forEach(function(stat){st[stat]=pctStatValue(uid,stat);});
 return st;}

/* ===== EQUIPMENT (v2.14) ===== see farroad-core.js (EQUIPMENT_SLOTS/
   EQUIP_SPD_PENALTY_BASE/RARITY_POWER_MUL, C.EQUIPMENT — the compiled
   farroadequipment.csv) for the constants/content this reads. Same
   UI-layer slice affinity/PCT-stat investment already established:
   combine whatever's equipped into the effective value P.statsAt's
   output gets adjusted with, AFTER P.statsAt runs and right alongside
   applyPctStatInvestment. */
function equipOwnedCount(id){return (G.equipInv&&G.equipInv[id])||0;}
function equipInUseCount(id){
 var n=0;
 Object.keys(G.equipped||{}).forEach(function(uid){
  C.EQUIPMENT_SLOTS.forEach(function(slot){if(G.equipped[uid][slot]===id)n++;});});
 return n;}
function equipAvailableCount(id){return equipOwnedCount(id)-equipInUseCount(id);}
/* A hand item fits either hand1 or hand2; every other slot only fits its
   own exact name — EQUIPMENT_SLOTS' 5 positions collapse to the CSV's 4
   item kinds via this one substring rule (hand1/hand2 -> 'hand'). */
function equipKindForSlot(slot){return slot.indexOf('hand')===0?'hand':slot;}
/* Sums atk/mag/def/res/spd/evade across a unit's 5 equipped positions,
   then applies the marginal speed penalty (every NON-leg slot that's
   occupied, scaled by that item's own RARITY_POWER_MUL, summed once and
   rounded once — see EQUIP_SPD_PENALTY_BASE's comment in core.js for why
   not per-item). Mutates st in place, called right after
   applyPctStatInvestment, same placement/shape as that function. */
function applyEquipmentStats(uid,st){
 var equipped=(G.equipped&&G.equipped[uid])||{},spdPenalty=0;
 C.EQUIPMENT_SLOTS.forEach(function(slot){
  var id=equipped[slot],item=id&&C.EQUIPMENT[id];
  if(!item)return;
  ['atk','mag','def','res','spd'].forEach(function(k){if(item[k])st[k]+=item[k];});
  if(item.evade)st.evade+=item.evade;
  if(slot!=='legs')spdPenalty+=C.EQUIP_SPD_PENALTY_BASE*(C.RARITY_POWER_MUL[item.rarity]||1);});
 if(spdPenalty)st.spd=Math.round(st.spd-spdPenalty);
 return st;}
function equipItem(uid,slot,itemId){
 var item=C.EQUIPMENT[itemId];
 if(!item||item.slot!==equipKindForSlot(slot))return false;
 G.equipped=G.equipped||{};G.equipped[uid]=G.equipped[uid]||{};
 if(G.equipped[uid][slot]===itemId)return true;   /* no-op, already worn here */
 if(equipAvailableCount(itemId)<=0)return false;
 G.equipped[uid][slot]=itemId;
 return true;}
function unequipItem(uid,slot){
 G.equipped=G.equipped||{};G.equipped[uid]=G.equipped[uid]||{};
 delete G.equipped[uid][slot];}

function slotsFor(uid){return P.slotsAt(levelOf(uid));}
function ensureLoadout(uid){
 var want=slotsFor(uid);
 if(!G.loadout[uid])G.loadout[uid]=[{cond:'none',action:'strike'},{cond:'none',action:'strike'}];
 while(G.loadout[uid].length<want)G.loadout[uid].push({cond:'none',action:'strike'});
 if(G.loadout[uid].length>want)G.loadout[uid]=G.loadout[uid].slice(0,want);
 G.loadout[uid].forEach(function(s){if(G.actions.indexOf(s.action)<0)s.action='strike';
  if(G.conditions.indexOf(s.cond)<0)s.cond='none';});
 return G.loadout[uid];}

function buildParty(){
 var out=[];
 G.party.forEach(function(uid,i){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var st=P.statsAt(uid,def.stats,def.hp,levelOf(uid));
  applyPctStatInvestment(uid,st);
  applyEquipmentStats(uid,st);
  var mh=st.hp;
  /* Between-wave rest. Does NOT fix the multi-enemy wall (25/50/100% measured
     identical there) but it stops waves 1-7 compounding before Mend arrives. */
  var carry=G.hpCarry[uid];
  if(carry!=null)carry=Math.min(1,carry+recoveryOf(uid));
  var hp=(carry==null)?mh:Math.max(1,Math.round(mh*carry));
  out.push(C.makeUnit({id:uid,name:def.name,isParty:true,level:1,slotIndex:i,stats:st,
   maxHp:mh,hp:Math.min(hp,mh),row:def.row,chargeAction:def.chargeAction,
   affinity:effectiveAffinity(uid),
   slots:ensureLoadout(uid).map(function(s){return {cond:s.cond,action:s.action};})}));});
 return out;}

/* @param quiet skips the variety-roll sysLog line — used by expedition
   resolution (resolveExpedition() below), which builds enemies against its
   own synthetic wave counter and must not spam the ROAD log with them. */
function buildEnemies(w,quiet){
 var boss=P.isBossWave(w);
 /* post-wave-40: roll the count, then scale each body inversely to it */
 var variety=(!boss&&w>P.VARIETY_FROM);
 var n=boss?1:(variety?P.rollCount(G.rng,w):P.enemyCount(w));
 var vMul=variety?(P.countStrength(n)*P.bandRoll(G.rng)):1;
 if(variety&&!quiet)sysLog('<span class="dw">WAVE '+w+'</span> '+n+
  (n===1?' foe — <b style="color:var(--boss)">ELITE</b>':' foes')+
  ' <span class="tiny">· each at ×'+vMul.toFixed(2)+' strength</span>');
 C.setWave(w);                      /* K tracks the wave, not the level */
 var S=C.waveScale(w),out=[];       /* v2.0: one exponent for every enemy stat */
 for(var j=0;j<n;j++){
  var key=boss?'ox':P.archetypeFor(w,j), a=C.ARCH[key];
  var hpBase;
  if(boss){
   /* Size the boss against a NORMAL WAVE at this depth, not against one body.
      The first attempt multiplied the Stone Ox's own 1.60 hpMul by 2.66 and
      produced 116-740 beat fights - 4x to 35x a normal fight, not 1.3-1.5x. */
   var ref=C.ARCH.wolf;
   hpBase=200*ref.hpMul*C.dmgTakenMul(ref)*S*Math.max(1,P.enemyCount(w))*P.BOSS_LEN;
  } else hpBase=200*a.hpMul*C.dmgTakenMul(a)*S;
  /* DIFFICULTY scales HP *and* damage. Scaling HP alone measured as almost inert:
     runs still ended at the same waves, because what kills a solo character is
     enemy damage output, not the size of the pool it has to chew through. */
  /* v2.9 HARD SCALING: past P.HARD_FROM, enemies scale much harder — up to
     P.HARD_MAX at P.HARD_REF — layered on TOP of the wave-1..HARD_FROM curve
     above, which is untouched (hardMul==1 there). ATK/MAG take the full
     multiplier (the ask was "hit harder"); HP takes its square root — a
     bigger damage number, not a bigger sponge. Bosses get an additional flat
     multiplier on ATK/MAG (BOSS_HARD_EXTRA) so they scale past regular
     enemies, not just alongside them — see P.hardMul/P.BOSS_HARD_EXTRA. */
  hpBase*=P.DIFFICULTY*vMul*Math.sqrt(P.hardMul(w));
  var hardAtkMul=P.hardMul(w)*(boss?P.BOSS_HARD_EXTRA:1);
  var atkMul=(boss?1.10:1)*P.DIFFICULTY*vMul*hardAtkMul;
  /* ATK growth exponent 1.02 -> 0.80. At 1.02 enemy damage grew 3.10x by wave 20
     while a solo character grows 2.05x, so enemies outpaced the player by ~50%
     and the game was only survivable behind the 65% crutch. At 0.80 they track. */
  var ATK_EXP=0.80;
  out.push(C.makeUnit({id:'e'+j,name:(boss?'ROADWARDEN':a.name)+(n>1?' '+(j+1):''),
   isParty:false,level:1,slotIndex:10+j,arch:key,thorns:a.thorns||0,isBoss:boss,
   /* v2.9: enemies now carry a row too (first 5 slots front, next 5 back —
      see P.ENEMY_CAP). Only rowSpdMul reads it for enemies (front acts more
      often) — rowOut/rowIn (the back-row damage-mitigation discount) stay
      party-only, since party->enemy targeting has no row awareness to make
      that discount a real, visible choice rather than invisible variance. */
   row:j<5?'front':'back',
   stats:{hp:Math.max(8,Math.round(hpBase)),
    /* v2.0: ONE exponent for every stat, so no ratio can drift over 1000+ waves */
    atk:Math.max(1,Math.round(a.atk*S*atkMul)),
    mag:Math.round((a.mag||8)*S*P.DIFFICULTY*hardAtkMul),
    def:Math.round(a.def*S),res:Math.round(a.res*S),
    spd:boss?Math.round(a.spd*P.bossSpdMul(w)):a.spd,
    /* ===== v2.9: ENEMY CRIT NOW SCALES WITH DEPTH =====
     * Was atkCrit:a.atkCrit — frozen at the archetype constant forever, so the
     * only stat enemies never grew. Ian asked for it to live under the same
     * rules as the player's, including the raised 1.00 cap.
     * SCALED BY sqrt(S), NOT S. Linear in S reaches the cap around wave 2000,
     * and at 100% crit every enemy hit is a guaranteed x1.75 — that is a flat
     * 75% damage increase applied to the whole late game, a difficulty step
     * rather than texture, and it would also make crit STOP being variance,
     * removing the very thing that makes defensive stats worth buying.
     * sqrt(S) grows crit meaningfully (wolf 0.04 -> 0.15 by w3000, hound 0.08
     * -> 0.31) while never saturating inside a realistic run, so defence keeps
     * a growth story and crit stays probabilistic. Still capped at CAP_CRIT. */
    atkCrit:Math.min(C.CAP_CRIT,a.atkCrit*Math.sqrt(S)),
    /* v2.9: magCrit is now a genuine per-archetype ARCH field (farroadenemies.csv)
       instead of one hardcoded 0.04 for every archetype — falls back to 0.04
       only if an archetype somehow has none, matching the old global exactly. */
    magCrit:Math.min(C.CAP_CRIT,(a.magCrit||0.04)*Math.sqrt(S)),
    chargeRate:(boss?1.15:1),evade:a.evade},
   /* v1.0: enemies now carry EVERY stat the party has except Recovery, which is
      party-only by construction (recoveryOf() is only called in buildParty), so
      enemies never regain HP between waves — Ian's exclusion holds.
      chargeRate was always present but had no sink; these give it one.
      v2.9: chargeAction is now read straight off the archetype (ARCH[key].
      chargeAction, farroadenemies.csv) instead of a hardcoded key==='ox'/
      'hound' check — any archetype can carry one now, not just those two. */
   chargeAction:(boss?'wardensmaul':(a.chargeAction||null)),
   /* No Aether-investment layer for enemies — straight off the archetype's
      own CSV-authored baseline (farroadenemies.csv), unmodified. */
   affinity:a.affinity,
   slots:a.slots.map(function(s){return {cond:s.cond,action:s.action};})}));}
 return out;}

function sysLog(html,cls){
 var d=document.createElement('div');d.className='le sys';d.innerHTML=html;
 var L=$('#log');L.insertBefore(d,L.firstChild);}

/* ===== ELEMENT/CAMP ICONS (v2.11) =====
 * "Color code actions with icons... dependent on their element, same
 * with if physical or magical" — two ADDITIVE signals, not either/or:
 * every action always gets its camp icon (physical vs magic), and ALSO
 * an element icon+color on top when act.element is set (mandatory on
 * every magic damage action, optional on physical, absent on heal/
 * buff-only actions — content-pipeline.js's own build-time validation
 * already enforces the mandatory half). A physical action that also
 * carries an element (e.g. Spellbrand) shows both: ⚔️💧. */
var ELEMENT_GLYPH={
 fire:{icon:'🔥',n:'Fire',color:'var(--fire)'}, water:{icon:'💧',n:'Water',color:'var(--water)'},
 earth:{icon:'🪨',n:'Earth',color:'var(--earth)'}, air:{icon:'💨',n:'Air',color:'var(--air)'},
 light:{icon:'☀️',n:'Light',color:'var(--light)'}, dark:{icon:'🌑',n:'Dark',color:'var(--dark)'}};
/* HTML prefix (colored spans) for headings/titles — describeAction()'s
   callers, the LORE/GAMBITS detail boxes, combat log entries. */
function actionGlyph(a){
 if(!a)return '';
 var camp=a.camp==='atk'?{icon:'⚔️',n:'Physical',color:'var(--body)'}:{icon:'🔮',n:'Magic',color:'var(--magic)'};
 var h='<span style="color:'+camp.color+'" title="'+camp.n+'">'+camp.icon+'</span>';
 var e=a.element&&ELEMENT_GLYPH[a.element];
 if(e)h+='<span style="color:'+e.color+'" title="'+e.n+'">'+e.icon+'</span>';
 return h+' ';}
/* Plain-text prefix (no HTML/color) for native <select> option labels,
   which can't render markup — the icons alone still read fine there. */
function actionGlyphText(a){
 if(!a)return '';
 var h=a.camp==='atk'?'⚔️':'🔮';
 var e=a.element&&ELEMENT_GLYPH[a.element];
 return h+(e?e.icon:'')+' ';}

/* ===== RARITY BADGE (v2.12) ===== Common gets no badge — the absence
   already reads as default (same reasoning ELEMENT_GLYPH's camp icons
   use). HTML pill for headings/titles; plain-text tag for native <select>
   option labels, which can't render markup. Shared by both actions
   (a.rarity) and roster/arch units (r.rarity) — same 3-value field. */
function rarityTag(r){
 if(r==='rare')return ' <span class="rtag rare">RARE</span>';
 if(r==='legendary')return ' <span class="rtag legendary">LEGENDARY</span>';
 return '';}
function rarityTagText(r){
 if(r==='rare')return ' [RARE]';
 if(r==='legendary')return ' [LEGENDARY]';
 return '';}

/* ===== DROP NOTICE (v2.2) =====
 * A drop is one of the few genuinely NEW things that happens, and it was buried in
 * the log. This describes what arrived, what it does, and — during the curated run
 * — what it is FOR, which is what makes the sequence teach rather than accumulate.
 * Non-blocking: the banner persists until acknowledged and stacks while idling, so
 * a player back from an overnight session sees everything they collected. */
function describeAction(id){
 var a=C.ACTIONS[id];if(!a)return{name:id,body:''};
 var shape=(a.tk==='allFoes'?'all foes':a.tk==='allAllies'?'whole party':
   a.tk==='ally'?'one ally':a.tk==='self'?'self':a.tk==='deadAlly'?'a fallen ally':'one foe');
 var bits=[];
 bits.push((a.camp==='atk'?'physical':'magic')+' · hits '+shape);
 if(a.power)bits.push('power ×'+a.power+(a.hits>1?' × '+a.hits+' hits':''));
 if(a.heal)bits.push('HEALS');
 if(a.applies)bits.push('applies <b>'+a.applies+'</b> for '+(a.turns||3)+' turns');
 /* v2.19: was "ignores X% armour" regardless of camp — inaccurate once
    Piercing (core.js's BONUSES.piercing) stopped being physical-only;
    RES isn't "armour". */
 if(a.defPierce)bits.push('ignores '+Math.round(a.defPierce*100)+'% '+(a.camp==='atk'?'DEF':'RES'));
 if(a.lifesteal)bits.push('heals you '+Math.round(a.lifesteal*100)+'% of damage');
 if(a.revive)bits.push('revives at '+Math.round(a.revive*100)+'% HP');
 return {name:actionGlyph(a)+a.name+rarityTag(a.rarity),
  body:bits.join(' · ')+' · initiative '+initTag(a.rank)+
   ' <span style="color:var(--dimmer)">(higher acts more often)</span>',
  note:withMcName(a.note||'')};}
/* Equipment (v2.14) — same describeX shape as describeAction just above,
   used by both the wave-drop and pull notices so the two acquisition
   paths never describe an item differently. */
var EQUIP_SLOT_ICON={head:'🪖',body:'🛡️',legs:'🥾',hand:'🖐️'};
function describeEquipment(id){
 var e=C.EQUIPMENT[id];if(!e)return{name:id,body:''};
 var bits=[];
 ['atk','mag','def','res','spd'].forEach(function(k){if(e[k])bits.push(k.toUpperCase()+' +'+e[k]);});
 if(e.evade)bits.push('Evade +'+Math.round(e.evade*100)+'%');
 AFFINITY_AXES.forEach(function(ax){if(e.affinity[ax])bits.push(AFFINITY_INFO[ax].n+' affinity +'+e.affinity[ax]);});
 return {name:(EQUIP_SLOT_ICON[e.slot]||'')+' '+e.name+rarityTag(e.rarity),
  slotLabel:e.slot.charAt(0).toUpperCase()+e.slot.slice(1),
  body:e.slot.charAt(0).toUpperCase()+e.slot.slice(1)+' · '+bits.join(' · ')};}
/* v2.9: "what stat does this scale with" and "what has Lore bought it, in
   total" — both requested for the GAMBITS/LORE screens. scalesWith just
   names a.camp; bonusTotalSummary diffs the live (post-applyBonuses)
   ACTIONS entry against C.pristineOf(id) (the pre-bonus baseline core.js
   already keeps for exactly this) rather than re-deriving each bonus's
   math a second time here. */
function scalesWith(a){return a.camp==='mag'?'MAG':'ATK';}
function bonusTotalSummary(id){
 var a=C.ACTIONS[id],p=C.pristineOf(id);if(!a||!p)return '';
 var bits=[];
 if(a.power&&p.power&&a.power!==p.power)
  bits.push('+'+Math.round((a.power/p.power-1)*100)+'% '+(a.heal?'healing':'damage'));
 /* v2.19: was "armour pierce" regardless of camp — same fix as
    describeAction above, since Piercing now works on magic actions too. */
 if(a.defPierce!==p.defPierce)bits.push('+'+Math.round(((a.defPierce||0)-(p.defPierce||0))*100)+'% '+(a.camp==='atk'?'DEF':'RES')+' pierce');
 if(a.critBonus!==p.critBonus)bits.push('+'+Math.round(((a.critBonus||0)-(p.critBonus||0))*100)+'% crit');
 if(a.turns!==p.turns)bits.push('+'+((a.turns||0)-(p.turns||0))+' turn duration');
 if(a.rank!==p.rank)bits.push('×'+Math.round((1/a.rank)/(1/p.rank)*100)+'% initiative');
 if(a.isCharge&&a.chargeCost!==p.chargeCost)
  bits.push((a.chargeCost>p.chargeCost?'+':'')+Math.round(a.chargeCost-p.chargeCost)+' gauge');
 return bits.join(' · ');}
function pairingHint(id){
 var a=C.ACTIONS[id];if(!a)return '';
 if(a.heal)return 'Pairs with <b>Self: HP ≤ 50%</b> or <b>Ally: HP ≤ 60%</b>.';
 if(a.applies&&C.DEBUFFS.indexOf(a.applies)>=0)
  return 'Pairs with <b>Foe: lacks this debuff</b> so it is not wasted on a re-apply.';
 if(a.applies)return 'Pairs with <b>Ally: lacks this buff</b> to avoid overwriting it.';
 if(a.tk==='allFoes')return 'Pairs with <b>Foe: 2+ present</b> — a loss against a lone target.';
 if(a.defPierce)return 'Pairs with <b>Foe: armoured</b>; it loses to Strike on soft targets.';
 return 'Slot it as a catch-all, or gate it on a condition you already hold.';}
function pushDrop(entry){
 G.dropQueue=G.dropQueue||[];G.dropHistory=G.dropHistory||[];
 G.dropQueue.push(entry);G.dropHistory.unshift(entry);
 while(G.dropHistory.length>60)G.dropHistory.pop();
 renderDropNote();}
/* v2.11: "condense lore and aether gains into a single notice" — the
   bare, highly-repeatable duplicate-conversion cards (duplicate action/
   charge action/gambit -> +1 Lore, duplicate unit pull -> +N Aether)
   carry no real per-event narrative, just a number, and an idle catch-up
   that fires several in a row used to clutter the banner with one
   near-identical card each. These accumulate into a running total
   instead of pushing a new card — rendered as ONE synthetic card
   alongside the real dropQueue items. Boss Hoard/Welcome Back/quest
   rewards stay real pushDrop() cards — each has genuine per-event
   context (which wave, why), not just a bare number. */
function addDropGain(loreDelta,aetherDelta){
 G.dropGains=G.dropGains||{lore:0,aether:0};
 G.dropGains.lore+=loreDelta||0;G.dropGains.aether+=aetherDelta||0;
 renderDropNote();}
function renderDropNote(){
 var host=$('#dropnote');if(!host)return;
 var q=G.dropQueue||[];
 var gains=G.dropGains||{lore:0,aether:0};
 var hasGains=gains.lore>0||gains.aether>0;
 var count=q.length+(hasGains?1:0);
 if(!count){host.className='hidden';host.innerHTML='';return;}
 host.className='';
 var h='<div class="dn-h"><span class="dn-t">'+
  (count>1?count+' NEW THINGS':'SOMETHING NEW')+'</span>'+
  '<button class="mini" id="dnOk">Got it</button></div>';
 if(hasGains){
  var bits=[];
  if(gains.lore>0)bits.push('<b style="color:var(--lore)">+'+gains.lore+' Lore</b>');
  if(gains.aether>0)bits.push('<b style="color:var(--aether)">+'+Math.round(gains.aether)+' Aether</b>');
  h+='<div class="dn-item"><div class="dn-name">Duplicates <span class="dn-kind">GAINS</span></div>'+
   '<div class="dn-body">'+bits.join(', ')+' from duplicate drops and pulls.</div></div>';}
 q.forEach(function(d){
  h+='<div class="dn-item"><div class="dn-name">'+d.name+
   ' <span class="dn-kind">'+d.kind+(d.wave?' · wave '+d.wave:'')+'</span></div>'+
   (d.body?'<div class="dn-body">'+d.body+'</div>':'')+
   (d.why?'<div class="dn-why">▸ '+d.why+'</div>':'')+
   (d.pair?'<div class="dn-pair">'+d.pair+'</div>':'')+
   /* note: was written by every doPull() outcome (duplicate-unit trivia,
      pairing hints, "you now hold N copies") and read by NOTHING — dropped
      silently everywhere. Rendered here with the same dim treatment as
      `pair`, since unlike the fielded/benched question above (promoted to
      `why`), these are genuinely secondary asides. */
   (d.note?'<div class="dn-pair">'+d.note+'</div>':'')+'</div>';});
 host.innerHTML=h;
 var ok=$('#dnOk');if(ok)ok.onclick=function(){G.dropQueue=[];G.dropGains={lore:0,aether:0};renderDropNote();};}
function grantDrops(w){
 /* FIRST ATTEMPT ONLY, not first CLEAR — v2.9 bugfix (see dropsGranted in
    newGame()). Gate runs BEFORE computing drops so a gated call doesn't
    burn an RNG roll on a result it's about to discard (randomDrop(w) rolls
    for post-curated waves; P.dropsAt(w) is a pure lookup so this only
    matters there, but checking first either way is simpler than splitting
    the two cases). */
 if(G.dropsGranted[w]){
  sysLog('<span class="tiny">Wave '+w+' already attempted — no drop. '+
   'Rewards are granted once per wave, win or lose.</span>');
  return;}
 G.dropsGranted[w]=1;
 var drops=P.isCurated(w)?P.dropsAt(w):randomDrop(w);
 var curated=P.isCurated(w);
 drops.forEach(function(d){
  if(d.kind==='action'){
   G.actionCounts[d.id]=(G.actionCounts[d.id]||0)+1;
   var dup=G.actions.indexOf(d.id)>=0;
   if(!dup)G.actions.push(d.id); else G.lore+=1;
   var info=describeAction(d.id);
   if(dup){
    addDropGain(1,0);
   }else{
    pushDrop({wave:w,kind:'NEW ACTION',name:info.name,
     body:info.body+(info.note?'<br>'+info.note:''),
     why:curated&&d.why?d.why:null,
     pair:pairingHint(d.id)});}
   sysLog('<span class="dw">WAVE '+w+' · ACTION</span> <b>'+C.ACTIONS[d.id].name+'</b>');
  }else if(d.kind==='charge'){
   G.mc.acquiredCharges=G.mc.acquiredCharges||[];
   var dupC=G.mc.acquiredCharges.indexOf(d.id)>=0;
   if(!dupC)G.mc.acquiredCharges.push(d.id); else G.lore+=1;
   var infoC=describeAction(d.id);
   if(dupC){
    addDropGain(1,0);
   }else{
    pushDrop({wave:w,kind:'NEW CHARGE ACTION',name:infoC.name,
     body:infoC.body+(infoC.note?'<br>'+infoC.note:''),
     pair:'Swap to it any time from the GAMBITS tab — no cost, and Lore upgrades '+
      'are kept per action, so switching back restores what you bought.'});}
   sysLog('<span class="dw">WAVE '+w+' · CHARGE ACTION</span> <b>'+C.ACTIONS[d.id].name+'</b>');
  }else if(d.kind==='equip'){
   /* Equipment dupes are genuinely useful (dual-wielding a hand item, the
      same armor on two units) — unlike action/condition dupes just above,
      an equipment dupe is NEVER converted to Lore. It always increments
      the shared inventory count and always gets its own notice, worded
      differently for a first copy vs. an Nth. */
   G.equipInv=G.equipInv||{};
   G.equipInv[d.id]=(G.equipInv[d.id]||0)+1;
   var infoE=describeEquipment(d.id);
   var nOwned=G.equipInv[d.id];
   pushDrop({wave:w,kind:nOwned===1?'NEW EQUIPMENT':'EQUIPMENT (DUPLICATE)',name:infoE.name,
    body:infoE.body,
    why:curated&&d.why?d.why:null,
    pair:nOwned===1?'Equip it from the EQUIPMENT tab — no cost.':
     'You now own '+nOwned+'× '+C.EQUIPMENT[d.id].name+' — enough to equip it on more than one slot/unit at once.'});
   sysLog('<span class="dw">WAVE '+w+' · EQUIPMENT</span> <b>'+C.EQUIPMENT[d.id].name+'</b>');
  }else{
   G.condCounts[d.id]=(G.condCounts[d.id]||0)+1;
   var dup2=G.conditions.indexOf(d.id)>=0;
   if(!dup2)G.conditions.push(d.id); else G.lore+=1;
   var lab=C.condById(d.id).label;
   if(dup2){
    addDropGain(1,0);
   }else{
    pushDrop({wave:w,kind:'NEW GAMBIT CONDITION',name:lab,
     body:'A test you can put in front of any action. The first rule whose condition '+
      'is true is the one that fires.',
     why:curated&&d.why?d.why:null,
     pair:'Set it in the GAMBITS tab against an action it can gate.'});}
   sysLog('<span class="dw">WAVE '+w+' · CONDITION</span> <b>'+lab+'</b>');}});
 if(drops.length){autoEquip();buildGambits();renderEconomy();}}

/* AUTO-EQUIP. A curated drop installs itself into a sensible default rule, so the
   gambit screen is where you REFINE rather than where you must go to avoid dying.
   Without this a player who never opens the screen dies at wave 4-5 - the naive-
   player problem in its most acute form. Your edits are never overwritten. */
var GATE_FOR={foe_lacks_debuff:['sear','hex','cripple','smother','daunt'],
 foe_armoured:['pierce','hex','ember'],ally_lacks_buff:['bulwark'],
 self_hp_lte_50:['mend','bulwark'],foe_fast:['cripple','daunt'],
 ally_hp_lte_60:['mend'],foe_lowest_hp:['execute','strike'],
 foe_highest_hp:['gale','cleave','daunt'],foe_hp_gte_70:['gale','cleave','sear','hex']};
var PRI=['self_hp_lte_50','ally_hp_lte_60','ally_lacks_buff','foe_fast','foe_lacks_debuff',
 'foe_armoured','foe_highest_hp','foe_hp_gte_70','foe_lowest_hp'];
function autoEquip(){
 G.party.forEach(function(uid){
  if(G.touched&&G.touched[uid])return;          /* never override a hand-written rule */
  var s1=null;
  for(var i=0;i<PRI.length&&!s1;i++){var cd=PRI[i];
   if(G.conditions.indexOf(cd)<0)continue;
   var a=(GATE_FOR[cd]||[]).filter(function(x){return G.actions.indexOf(x)>=0;})[0];
   if(a)s1={cond:cd,action:a};}
  G.loadout[uid]=s1?[s1,{cond:'none',action:'strike'}]
                   :[{cond:'none',action:'strike'},{cond:'none',action:'strike'}];
  syncLoadout(uid);});}

function randomDrop(w){
 if(w%2!==0 && w%2!==1)return [];
 /* Rare charge-action drop — MC only (roadmap item 2), and only in the
    random-drop phase: rolled BEFORE the action/condition branch below and
    REPLACES that wave's drop rather than adding to it, so it costs the
    player their usual per-wave item rather than stacking a bonus on top.
    Never rolled during the curated run (grantDrops only calls randomDrop
    post wave-20), so the authored tutorial sequence is untouched. */
 if(G.mc&&G.rng.next()<P.MC_CHARGE_DROP_CHANCE){
  /* Rarity (v2.12): nested roll inside this same 10% gate — decide Legendary
     vs. Rare first, then pick uniformly within that tier (see
     MC_LEGENDARY_CHARGE_CHANCE in progression.js). */
  var chargePool=P.MC_CHARGE_DROP_POOL;
  var legendaryPool=chargePool.filter(function(id){return C.ACTIONS[id]&&C.ACTIONS[id].rarity==='legendary';});
  var rarePool=chargePool.filter(function(id){return !(C.ACTIONS[id]&&C.ACTIONS[id].rarity==='legendary');});
  var wantLegendary=legendaryPool.length>0 && G.rng.next()<P.MC_LEGENDARY_CHARGE_CHANCE;
  var pool=(wantLegendary?legendaryPool:rarePool);
  if(pool.length===0)pool=chargePool;
  return [{kind:'charge',id:pool[G.rng.nextInt(pool.length)],
   why:(wantLegendary?'legendary':'rare')+' charge-action drop'}];}
 /* Equipment (v2.14): same "replace, don't stack" shape as the charge gate
    above, but WITHOUT the G.mc guard — equipment drops for every run,
    companion-only included, same as the ordinary action/condition drop it
    replaces when it fires (see P.EQUIP_DROP_CHANCE's own comment). */
 if(G.rng.next()<P.EQUIP_DROP_CHANCE){
  var equipIds=Object.keys(C.EQUIPMENT);
  return [{kind:'equip',id:P.weightedEquipmentPick(G.rng,equipIds),why:'equipment drop'}];}
 var out=[];
 if(w%2===0){var pool=C.EQUIPPABLE;
  out.push({kind:'action',id:P.weightedActionPick(G.rng,pool),why:'random drop'});}
 else{var cp=C.CONDITIONS.filter(function(c){return c.id!=='none';});
  out.push({kind:'cond',id:cp[G.rng.nextInt(cp.length)].id,why:'random drop'});}
 return out;}

function startWave(w,skipDrops){
 /* skipDrops: used only when RESUMING a loaded save on the wave the player was
    already on. That wave has not been cleared, so grantDrops(w) would treat it
    as a fresh visit and hand out its curated/random drop a second time — the
    same class of bug the FIRST-CLEAR gate in grantDrops() exists to prevent,
    just triggered by a reload instead of a replay. Every other caller
    (boot, afterWaveCleared, onWipe) omits the flag and behaves as before. */
 G.wave=w; if(w>G.farthest)G.farthest=w;
 if(!skipDrops)grantDrops(w);
 C.applyBonuses(G.bonuses);
 var party=buildParty(), enemies=buildEnemies(w);
 G.units=party; G.enemies=enemies;
 G.battle=C.makeBattle(party.concat(enemies),{rng:G.rng,enrage:G.enrage});
 G.over=null;
 if(P.isBossWave(w))sysLog('<span class="bosstag">BOSS</span> <b>Wave '+w+' — the Roadwarden.</b>'+
  '<div class="tiny">Clearing it banks a checkpoint and hands you a new character.</div>');}

/* Shared "a new companion joins the roster" state mutation — used by the
   boss-milestone join, the boss unit-drop roll, and doPull()'s unit branch.
   Callers still build their own pushDrop/sysLog text (the three contexts
   read differently), this only owns the G.lvl/G.bank/G.owned/G.party side
   effects, which were previously duplicated verbatim at all three sites.
   v2.9: also the single choke point all 3 acquisition paths already run
   through for "unlock this companion's quest line exactly once" — read
   BEFORE the G.owned write below overwrites the signal. */
function joinCompanion(uid){
 if(!G.owned[uid])G.quests[uid]={stage:0,frozen:[]};
 G.lvl[uid]=1;G.bank[uid]=0;G.owned[uid]=1;
 G.affinities=G.affinities||{};if(!G.affinities[uid])G.affinities[uid]={};
 G.statInvest=G.statInvest||{};if(!G.statInvest[uid])G.statInvest[uid]={};
 G.equipped=G.equipped||{};if(!G.equipped[uid])G.equipped[uid]={};
 var fielded=G.party.length<P.PARTY_CAP;
 if(fielded)G.party.push(uid);
 return fielded;}
function afterWaveCleared(){
 /* class fix: FIRST-CLEAR gates every wave-number-keyed reward, not just drops.
    Kill and idle income stay repeatable — they are per-fight, not per-wave-number,
    so grinding a wave for Aether still works and is meant to. What can no longer
    be farmed: curated drops, random drops, boss hoards and milestone companions. */
 var firstClear=!G.clearedWaves[G.wave];
 G.clearedWaves[G.wave]=1;
 G.units.forEach(function(u){G.hpCarry[u.id]=u.hp/u.maxHp;});
 var r=P.killReward(G.wave,G.enemies.length);
 G.aether+=r.aether;G.marks+=r.marks*P.marksMul(G);
 if(P.isBossWave(G.wave)&&firstClear){
  G.bossesCleared++;
  /* BOSS HOARD. Sized against the measured cliff, not picked round: without it,
     w21 wins 82% and w22 wins 0%, because the recruit both starts from nothing and
     halves the shared pool. 120*w^1.2 takes w21-w26 to 100%. Larger payouts measure
     identical, so this is the saturation point rather than an arbitrary number. */
  var hoard=P.bossAether(G.wave);
  G.aether+=hoard;
  pushDrop({wave:G.wave,kind:'BOSS HOARD',
   name:'+'+hoard.toLocaleString()+' Aether',
   body:'About '+P.BOSS_AETHER_WAVES+' waves of income at this depth. Aether is EXP — '+
    'spend it in the AETHER tab on whichever companion you want stronger.',
   why:'Awarded for clearing the wave-'+G.wave+' boss.'});
  sysLog('<span class="bosstag">BOSS DOWN</span> <b>+'+hoard+
   ' <span style="color:var(--aether)">Aether</span></b>'+
   '<div class="tiny">The hoard is what keeps a new companion from making the party weaker.</div>');
  /* v2.0: a unit only at MILESTONE waves; every other boss pays Aether instead */
  var next=P.unitDueAt(G.wave);
  if(next&&G.party.indexOf(next)>=0)next=null;
  if(!next){
   var dup=P.dupUnitAether(G.wave);G.aether+=dup;
   sysLog('<span class="bosstag">BOSS DOWN</span> no new companion here — the hoard is '+
    '<b style="color:var(--aether)">+'+dup+' Aether</b> instead.'+
    (G.party.length>=5?'<div class="tiny">Roster is full, so every further unit reward converts '+
     'to Aether — the same rule that turns duplicate actions into Lore.</div>':
     '<div class="tiny">Next companion at wave '+
     (function(){for(var i=0;i<P.UNIT_WAVES.length;i++)if(P.UNIT_WAVES[i]>G.wave)return P.UNIT_WAVES[i];
      return '—';})()+'.</div>'));}
  if(next&&G.party.indexOf(next)<0&&G.party.length<5){
   /* v1.1: recruits join at LEVEL 1. A recruit's value is TURN ECONOMY, not stats —
      measured, each unit acts on its own clock and adding one adds 1.96x the action
      rate, so a LV1 body still nearly doubles what your side does per fight. */
   joinCompanion(next);   /* joins at LV 1, always fielded here — the outer if already checked room */
   (function(){var d0=null;C.ROSTER.forEach(function(r){if(r.id===next)d0=r;});
    var ca=d0&&d0.chargeAction?C.ACTIONS[d0.chargeAction]:null;
    var lean=d0?(d0.stats.mag>d0.stats.atk?'caster — leans MAG':
      (d0.stats.def>=28?'wall — leans DEF/HP':
      (d0.stats.spd>=115?'fast — leans SPD':'attacker — leans ATK'))):'';
    pushDrop({wave:G.wave,kind:'NEW COMPANION',name:(d0?d0.name:next)+' (LV 1)',
     body:lean+(d0?' · HP '+d0.hp+' ATK '+d0.stats.atk+' MAG '+d0.stats.mag+
      ' DEF '+d0.stats.def+' SPD '+d0.stats.spd:''),
     why:'Their stats are poor and it does not matter — they act on their own clock, '+
      'so your side now takes roughly twice as many actions per fight.',
     pair:ca?('⚡ Charge action: <b>'+ca.name+'</b> — '+withMcName(ca.note||'')):''});})();
   var nm='';C.ROSTER.forEach(function(x){if(x.id===next)nm=x.name;});
   sysLog('<span class="bosstag">BOSS DOWN</span> <b>'+nm+' joins you</b> at LV 1.'+
    '<div class="tiny">Their stats are poor and it does not matter — they act on their own '+
    'clock, so your side now takes roughly twice as many actions per fight. Early levels are '+
    'cheap, so they close the gap fast.</div>');}
  sysLog('<span class="ckpt">✔ CHECKPOINT banked at wave '+(G.bossesCleared*P.BOSS_EVERY)+
   '. A wipe now returns you here, not to wave 1.</span>');
  if(G.wave>=P.BOSS_EVERY)sysLog('<span class="tiny">Curated drops end. Drops are random from here — '+
   'duplicates now appear, which is where <b style="color:var(--lore)">Lore</b> comes from.</span>');}
 /* v2.9: a 10% companion-drop chance on EVERY boss clear, independent of
    firstClear/milestone eligibility — repeatable by re-grinding a boss,
    same spirit as killReward staying repeatable. Added because the
    milestone schedule alone (P.UNIT_WAVES, a handful of fixed waves) left
    long stretches with zero chance at a new companion — Ian reported
    reaching wave 400+ without a 3rd unit. Independent roll from the
    milestone join above, so a milestone boss can grant both. */
 if(P.isBossWave(G.wave)&&G.rng.next()<0.10){
  var bossAvail=C.ROSTER.filter(function(r){return !G.owned[r.id];});
  if(bossAvail.length){
   var bossPick=bossAvail[G.rng.nextInt(bossAvail.length)];
   var bossFielded=joinCompanion(bossPick.id);
   var bca=bossPick.chargeAction?C.ACTIONS[bossPick.chargeAction]:null;
   pushDrop({wave:G.wave,kind:'BOSS COMPANION DROP',name:bossPick.name+' (LV 1)',
    body:capRole(bossPick.role)+' · '+bossPick.row+' row'+
     (bca?'<br>⚡ Charge action: <b>'+bca.name+'</b> — '+withMcName(bca.note||''):''),
    why:(bossFielded?'Fielded immediately.'
      :'<b>Benched</b> — your party of '+P.PARTY_CAP+' is full, but this companion is yours and can be swapped in.')});
   sysLog('<span class="bosstag">BOSS DOWN</span> <b>'+bossPick.name+' joins you</b> at LV 1 '+
    '<span class="tiny">(10% boss companion roll)</span>.');}}}

function onWipe(){
 G.wipes++;
 var back=P.checkpoint(G.bossesCleared);
 sysLog('<b style="color:var(--bad)">PARTY WIPED</b> — returned to wave '+back+
  ' <span class="ckpt">(last boss checkpoint)</span>.<div class="tiny">Lost '+
  Math.max(0,G.wave-back)+' waves. Idle rate is unchanged: it keys off your farthest wave ('+
  G.farthest+'), so failure never costs income.</div>');
 G.hpCarry={};
 startWave(back);}

/* --------------------------------------------------------------- save --- */
function doSave(){
 try{
  var snap=Save.serialize(G,Date.now());
  localStorage.setItem(SAVE_KEY,JSON.stringify(snap));
 }catch(e){sysLog('<span style="color:var(--bad)">Autosave failed: '+e.message+'</span>');}}
/* Saves happen automatically after every change — no manual Save/Load buttons.
   renderAll() is called from essentially every state-mutating action in this
   file (wave transitions, purchases, gambit/loadout edits, pulls, resets), so
   hooking autoSave() there covers "after each change" without touching every
   call site individually. Throttled to 2s of wall-clock time because renderAll
   also fires on every combat BEAT during active play — unthrottled, that is
   dozens of localStorage writes per second at 10x speed. idle-income accrual
   (tick(), below) bypasses renderAll and gets its own explicit call. */
var lastAutoSave=0;
function autoSave(){
 var now=Date.now();if(now-lastAutoSave<2000)return;lastAutoSave=now;doSave();}
function readSavedSnapshot(){
 try{var raw=localStorage.getItem(SAVE_KEY);return raw?JSON.parse(raw):null;}
 catch(e){return null;}}
/* Real offline simulation — replaces the old flat-rate estimate. Plays the
   actual road forward using the SAME functions live play uses (startWave,
   C.step, afterWaveCleared, onWipe), for however many waves fit in the
   capped elapsed time, at the SAME per-wave time cost P.wavesPerHour() is
   itself derived from (20s fight-equivalent + P.travelSec(w)). Because it's
   the real engine and not an estimate, a wipe can genuinely happen while
   you're away and send you back to your last checkpoint — Ian chose full
   fidelity over the GDD §1.4 "offline never wipes" rule. It's still not
   that section's full node/Waymark estimator (this prototype has no node
   map to advance along), just the same combat core run unattended, which is
   exactly the shape the smoke test's 200-fight headless batch proved out.
   G.battle must already be valid before this runs (see tryResumeSave) —
   this only ever ADVANCES from wherever the caller left it. */
function simulateOfflineProgress(snap){
 var elapsedSec=Math.max(0,(Date.now()-(snap.savedAt||Date.now()))/1000);
 if(elapsedSec<5)return;
 var capped=Math.min(elapsedSec,P.OFFLINE_CAP_SEC);
 var waveBefore=G.wave,wipesBefore=G.wipes,aetherBefore=G.aether,marksBefore=G.marks;
 /* Ambient idle trickle for the whole capped stretch — this runs alongside
    combat during live play too (tick()'s G.idleAcc branch), independent of
    whether any individual wave is won, so it's credited for the full
    duration regardless of how many whole waves the loop below fits in. */
 var r=P.idlePerSec(G.farthest);
 G.aether+=r.aether*capped;G.marks+=r.marks*P.marksMul(G)*capped;
 var remaining=capped,guard=0;
 while(remaining>0&&guard++<200000){
  if(!G.battle)break;
  var cost=20+P.travelSec(G.wave);
  if(cost>remaining)break;
  var beatGuard=0;
  while(!G.battle.over&&beatGuard++<4000)C.step(G.battle);
  if(G.battle.over==='party'){afterWaveCleared();startWave(G.wave+1);}
  else if(G.battle.over==='enemy'){onWipe();}
  else break;                     /* shouldn't happen — safety valve, not a real path */
  remaining-=cost;}
 var waveDelta=G.wave-waveBefore,wipeDelta=G.wipes-wipesBefore;
 var aetherGain=Math.round(G.aether-aetherBefore),marksGain=G.marks-marksBefore;
 var awayTxt=elapsedSec>=3600?(elapsedSec/3600).toFixed(1)+' hours':Math.max(1,Math.round(elapsedSec/60))+' minutes';
 var progressTxt=waveDelta>0?('cleared '+waveDelta+' wave'+(waveDelta===1?'':'s')+', now at wave '+G.wave)
   :'not enough time passed to clear another wave';
 var wipeTxt=wipeDelta>0?(' Wiped '+wipeDelta+' time'+(wipeDelta===1?'':'s')+' — back to checkpoint.'):'';
 /* v2.9: moved from a sysLog() line (only visible on the ROAD tab, easy to
    miss on open) into the "SOMETHING NEW" banner (pushDrop/renderDropNote)
    — "let's change the welcome back idle rewards message to be under the
    'something new' section." Same content, just surfaced where it can't be
    missed regardless of which tab is showing. */
 pushDrop({name:'Welcome back',kind:'idle rewards',
  body:awayTxt+' away'+(elapsedSec>P.OFFLINE_CAP_SEC?' (capped at '+(P.OFFLINE_CAP_SEC/3600)+'h)':'')+
   ' — '+progressTxt+'.'+wipeTxt,
  why:'Earned <b style="color:var(--aether)">+'+aetherGain+' Aether</b> and '+
   '<b style="color:var(--marks)">+'+Math.floor(marksGain)+' Marks</b>.'});}

/* ===== EXPEDITIONS (roadmap item 4, phase 1) =====
 * A benched party (1-5 units) can be sent exploring in real wall-clock time.
 * Resolution reuses the exact shape of simulateOfflineProgress() above —
 * elapsed real seconds, capped, spent on battles at the same per-wave pacing
 * — but against the expedition's OWN synthetic wave counter (G.expedition.ew)
 * and its own party/battle objects, entirely separate from G.wave/G.battle,
 * so an expedition can resolve without disturbing a fight the player is
 * actively watching. The one shared piece of engine state is C.setWave()'s
 * module-level CURRENT_WAVE (read by K_of() for damage mitigation) — every
 * enemy build here bumps it to the expedition's synthetic wave, so it is
 * always restored to G.wave before returning control, never left pointing
 * at expedition state for the main battle to read by accident. */
/* v2.9: multiple concurrent expeditions — "I want multiple parties to be
   able to go on expeditions in different directions." Was a single
   G.expedition (object|null); now G.expeditions (array, [] when none
   active). The old single expedTimer/scheduleExpeditionCheck below this
   comment assumed exactly one pending arrival and doesn't generalize to N
   without a timer-per-expedition map — dropped entirely in favor of two
   plain interval loops near the bottom of this file: a ~15s resolution
   poll covering every active expedition (resolveAllExpeditions), and a
   separate ~1s live-counter tick that only patches timer text (see
   renderExpedition/updateExpeditionTimers below) without rebuilding any
   DOM, so it can't tear a button out from under an in-progress click the
   way a full rebuild would. */
function benchedUnits(){
 return Object.keys(G.owned).filter(function(uid){return G.party.indexOf(uid)<0&&!isOnExpedition(uid);});}
function isOnExpedition(uid){
 return G.expeditions.some(function(e){return e.partyIds.indexOf(uid)>=0;});}
function pushExpeditionLog(exp,text){
 exp.log=exp.log||[];
 exp.log.unshift({at:Date.now(),text:text});
 while(exp.log.length>40)exp.log.pop();}
function buildExpeditionParty(partyIds,hpFrac){
 var out=[];
 partyIds.forEach(function(uid,i){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var st=P.statsAt(uid,def.stats,def.hp,levelOf(uid));
  applyPctStatInvestment(uid,st);
  applyEquipmentStats(uid,st);
  var mh=st.hp;
  var frac=(hpFrac==null)?1:Math.min(1,hpFrac+recoveryOf(uid));
  var hp=Math.max(1,Math.round(mh*frac));
  out.push(C.makeUnit({id:uid,name:def.name,isParty:true,level:1,slotIndex:i,stats:st,
   maxHp:mh,hp:Math.min(hp,mh),row:def.row,chargeAction:def.chargeAction,
   affinity:effectiveAffinity(uid),
   slots:ensureLoadout(uid).map(function(s){return {cond:s.cond,action:s.action};})}));});
 return out;}
/* Grants whatever the expedition has banked into the real economy and
   removes it from G.expeditions — reached once a party that has turned
   back (exp.homeAt set, whether by the HP threshold or a recall) actually
   arrives home; see beginReturnTrip() below. Its own log goes with it —
   "unique expedition logs for each group that clear after they've been
   collected upon their return" — nothing copies exp.log anywhere else
   first, so it simply ceases to exist alongside exp. */
/* v2.9: expeditions must be MANUALLY collected — "what they've found isn't
   added until then." Only reachable once exp.arrivedAt is set (checkArrival
   below); grants exp.bank into the real economy and removes the expedition.
   Was settleExpedition(exp,reason), auto-called the moment homeAt passed —
   see checkArrival for the new arrival-only notify step that replaced that
   auto-call. */
function collectExpedition(id){
 var exp=null;G.expeditions.forEach(function(e){if(e.id===id)exp=e;});
 if(!exp||!exp.arrivedAt)return;
 var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 G.aether+=exp.bank.aether;G.marks+=exp.bank.marks;
 sysLog('<b>Expedition collected.</b> <span class="tiny">'+names+' — earned '+
  '<b style="color:var(--aether)">+'+Math.round(exp.bank.aether)+' Aether</b> and '+
  '<b style="color:var(--marks)">+'+Math.floor(exp.bank.marks)+' Marks</b> over '+exp.ew+' wave'+
  (exp.ew===1?'':'s')+'.</span>');
 G.expeditions=G.expeditions.filter(function(e){return e.id!==exp.id;});}
/* Turning back — whether the HP threshold tripped it or the player recalled
   the party — is not instant: the trip home takes HALF the real time the
   party has been out (measured from exp.startedAt to this decision
   moment), same road, half the ground already covered. Rewards stay in
   exp.bank, not the real economy, until collectExpedition() actually
   fires — recalling doesn't bank anything early, it just decides "turn back
   now" instead of later. A recall placed right after departure still reads
   as instant: awaySec is ~0 there, so the computed trip is ~0 too.
   decisionMoment is a real timestamp rather than "now": a big catch-up pass
   (resolveExpedition below) can cross the turn-back threshold partway
   through a long absence, so the return-trip clock has to start from THAT
   point, not from whenever the player happens to check back in. */
function beginReturnTrip(exp,decisionMoment,reason){
 if(exp.homeAt)return;
 var awaySec=Math.max(0,(decisionMoment-exp.startedAt)/1000);
 exp.homeAt=decisionMoment+(awaySec/2)*1000;
 var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 pushExpeditionLog(exp,names+' — '+reason+' Heading home now.');
 checkArrival(exp);}
/* Validates and starts a new expedition. Every unit must be owned,
   currently benched (not in G.party), and not already out on a DIFFERENT
   expedition — several parties can be out at once now, but a given unit
   can only be on one of them at a time. v2.9: a direction is now required
   (one of P.DIRECTIONS) and must not already be occupied by another
   active expedition — 8 named lanes IS the concurrent-expedition cap, not
   a separate counter. */
function sendExpedition(partyIds,direction){
 if(!partyIds||!partyIds.length||partyIds.length>P.PARTY_CAP)return false;
 if(P.DIRECTIONS.indexOf(direction)<0)return false;
 if(G.expeditions.some(function(e){return e.direction===direction;}))return false;
 var seen={};
 for(var i=0;i<partyIds.length;i++){
  var uid=partyIds[i];
  if(seen[uid])return false;seen[uid]=1;
  if(!G.owned[uid]||G.party.indexOf(uid)>=0||isOnExpedition(uid))return false;}
 var exp={id:'exp'+Date.now()+'_'+Math.floor(Math.random()*1e6),
  partyIds:partyIds.slice(),direction:direction,startedAt:Date.now(),lastResolvedAt:Date.now(),
  ew:1,hpFrac:1,bank:{aether:0,marks:0},homeAt:null,arrivedAt:null,log:[]};
 G.expeditions.push(exp);
 var names=partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 pushExpeditionLog(exp,names+' set out to explore '+P.DIRECTION_LABELS[direction]+'.');
 sysLog('<b>Expedition departs.</b> <span class="tiny">'+names+' head '+
  P.DIRECTION_LABELS[direction]+' into the road beyond.</span>');
 return true;}
/* The real-time resolution loop for ONE expedition — see
   simulateOfflineProgress() above for the identical shape this mirrors.
   Called (via resolveAllExpeditions below) from tryResumeSave() (catch-up
   on load) and from a periodic poll while the tab stays open, so it must
   be safe to call often and cheap to no-op when nothing has happened yet.
   Once a party has turned back (homeAt set) there is no more combat to
   resolve — just a real-time wait — so that branch skips the battle loop
   entirely and only checks whether it's arrived yet. */
/* Scales a fresh buildEnemies() list in place — hp via sqrt(mul), atk/mag
   via mul directly (same asymmetric shape the old dungeon-discovery roll
   used) — shared by regular expedition nodes, bonus fights, and scheduled
   dungeon waves so a direction's difficulty multiplier (and DUNGEON_LEN
   on top, for a dungeon boss) always scales enemies the same way. */
function applyStatMul(enemies,mul){
 var hpMul=Math.sqrt(mul);
 enemies.forEach(function(u){
  u.base.hp=Math.max(1,Math.round(u.base.hp*hpMul));u.maxHp=u.base.hp;u.hp=u.base.hp;
  u.base.atk=Math.max(1,Math.round(u.base.atk*mul));
  u.base.mag=Math.round(u.base.mag*mul);});
 return enemies;}
/* v2.17: "each direction has a themed affinity" — sibling to applyStatMul
   just above, same shape and same call sites, adding the direction's own
   axis (P.DIRECTION_CONFIG[dir].affinity) ON TOP of whatever an enemy's
   archetype already carries (u.affinity is a fresh per-instance object —
   see makeUnit/defaultAffinity in farroad-core.js — so mutating it here
   never touches the shared ARCH-level affinity source). The main Road
   (buildEnemies with no direction) and companion quests never call this —
   theming is a directional-content thing, not a game-wide one. */
function applyDirectionAffinity(enemies,dir){
 var ax=P.DIRECTION_CONFIG[dir]&&P.DIRECTION_CONFIG[dir].affinity;
 if(!ax)return enemies;
 enemies.forEach(function(u){u.affinity[ax]=(u.affinity[ax]||0)+P.DIRECTION_AFFINITY_BONUS;});
 return enemies;}
/* The FIRST time an expedition is observed past its homeAt, mark arrival
   and notify — does NOT grant exp.bank into the real economy or remove
   the expedition (see collectExpedition below). Replaces the old
   auto-settle-on-arrival behavior — "expeditions must be manually
   collected... what they've found isn't added until then." Guarded by
   exp.arrivedAt so this fires exactly once per expedition. */
function checkArrival(exp){
 if(exp.arrivedAt||!exp.homeAt||Date.now()<exp.homeAt)return;
 exp.arrivedAt=Date.now();
 var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 pushExpeditionLog(exp,names+' arrived home — awaiting collection.');
 pushDrop({name:names+"'s expedition has returned",kind:'EXPEDITION RETURNED',
  body:'Waiting: +'+Math.round(exp.bank.aether)+' Aether, +'+Math.floor(exp.bank.marks)+' Marks.',
  why:'Collect it from the EXPEDITION tab to add it to your totals.'});}
function resolveExpedition(exp){
 if(exp.homeAt){checkArrival(exp);return;}
 var elapsedSec=Math.max(0,(Date.now()-exp.lastResolvedAt)/1000);
 if(elapsedSec<5)return;
 var resolveStartedAt=exp.lastResolvedAt;
 var capped=Math.min(elapsedSec,P.EXPED_CAP_SEC);
 var mul=P.directionMul(exp.direction);
 var remaining=capped,guard=0,savedWave=G.wave,turnedBack=false;
 while(remaining>0&&guard++<200000){
  var cost=20+P.travelSec(exp.ew);
  if(cost>remaining)break;
  var party=buildExpeditionParty(exp.partyIds,exp.hpFrac);
  var enemies=applyDirectionAffinity(applyStatMul(buildEnemies(exp.ew,true),mul),exp.direction);
  var battle=C.makeBattle(party.concat(enemies),{rng:G.rng,enrage:G.enrage});
  var beatGuard=0;
  while(!battle.over&&beatGuard++<4000)C.step(battle);
  if(battle.over==='party'){
   var r=P.killReward(exp.ew,enemies.length);
   exp.bank.aether+=r.aether*mul;exp.bank.marks+=r.marks*P.marksMul(G)*mul;
   if(P.isBossWave(exp.ew))exp.bank.aether+=P.bossAether(exp.ew)*mul;
   var alive=party.filter(function(u){return u.hp>0;});
   exp.hpFrac=alive.length?
    alive.reduce(function(s,u){return s+u.hp/u.maxHp;},0)/alive.length:0;
   exp.ew++;
   rollExpeditionDiscovery(exp,mul);   /* bonus fight only now — see below */
   /* Deterministic per-direction dungeon schedule — replaces the old
      random dungeon-discovery roll. maxDepth is cumulative across every
      expedition ever sent this direction, never reset per trip, so a
      short-lived trip still contributes real, permanent progress toward
      the next unlock. The while (not if) loop matters for a big catch-up
      pass that crosses more than one 100-multiple in one go — none
      skipped. */
   var dp=G.directions[exp.direction];
   dp.maxDepth=Math.max(dp.maxDepth,exp.ew);
   var targetTier=Math.floor(dp.maxDepth/P.DIRECTION_CONFIG[exp.direction].unlockEvery);
   while(targetTier>dp.dungeonsUnlocked){
    dp.dungeonsUnlocked++;
    unlockDirectionDungeon(exp.direction,dp.dungeonsUnlocked);}
  }else{
   exp.hpFrac=0;                  /* wiped outright — same as hitting the floor below */
  }
  remaining-=cost;
  if(exp.hpFrac<P.EXPED_RETURN_HP_FRAC){turnedBack=true;break;}}
 C.setWave(savedWave);            /* restore CURRENT_WAVE for K_of() before returning */
 exp.lastResolvedAt=Date.now();
 if(turnedBack)beginReturnTrip(exp,resolveStartedAt+(capped-remaining)*1000,
  'injuries mounted and the party turned back.');}
/* Serializes a live enemy unit (from buildEnemies) into a plain, JSON-safe
   cfg-shaped snapshot — the exact fields C.makeUnit needs to reconstruct
   an equivalent FRESH unit later, none of the per-battle-instance runtime
   fields (st/nextActAt/charge/enrageN/...) a live unit also carries,
   which must never be persisted or reused across separate fights. */
function bakeEnemySnapshot(u){
 return {name:u.name,arch:u.arch,thorns:u.thorns,isBoss:u.isBoss,row:u.row,
  chargeAction:u.chargeAction,slots:u.slots.map(function(s){return {cond:s.cond,action:s.action};}),
  stats:{hp:u.base.hp,atk:u.base.atk,mag:u.base.mag,def:u.base.def,res:u.base.res,spd:u.base.spd,
   atkCrit:u.base.atkCrit,magCrit:u.base.magCrit,chargeRate:u.base.chargeRate,evade:u.base.evade},
  /* v2.17: without this, a dungeon's frozen enemies silently lost their
     applyDirectionAffinity theming (and any other affinity) on the very
     first bake — this snapshot used to carry stats only, never affinity,
     so unitsFromSnapshots() below reconstructed every enemy back at
     defaultAffinity()'s flat zeros regardless of what the live unit had
     when it was baked. Caught before shipping the theming feature, not
     after. */
  affinity:u.affinity};}
/* Reconstructs FRESH C.makeUnit() instances from a list of frozen
   snapshots (a dungeon's `enemies`, or one quest stage's `frozen[i]`) —
   called every time that fight is (re-)entered, never reusing a live
   object across attempts (a fight mutates hp/status directly on the unit,
   so replaying the same object a second time would start it
   partway-damaged from the last attempt). */
function unitsFromSnapshots(snapshots){
 return snapshots.map(function(snap,j){
  return C.makeUnit({id:'e'+j,name:snap.name,isParty:false,level:1,slotIndex:10+j,
   arch:snap.arch,thorns:snap.thorns||0,isBoss:snap.isBoss,row:snap.row,
   stats:snap.stats,chargeAction:snap.chargeAction,slots:snap.slots,affinity:snap.affinity});});}
/* "Let's add discoverable bonus fights/events... and discoverable
   dungeons." Rolled once per WON expedition node (see the call site in
   resolveExpedition above) — a flat per-opportunity chance, same shape as
   the existing rare-charge-drop roll. On a hit, splits into a one-off
   bonus fight (common: an extra encounter at the party's current
   exp.ew, resolved immediately against the same party, logged either
   way) or a dungeon discovery (rarer: bakes a FROZEN, difficulty-static
   snapshot of the encounter — scaled up by DUNGEON_LEN, "slightly harder
   than the Road" — into G.dungeons for the main party to repeat later). */
/* v2.9 CORRECTION: dungeons are no longer part of this roll (see
   unlockDirectionDungeon below — a fixed per-direction schedule now) —
   this is bonus-fight-only. `mul` is the calling expedition's own
   direction multiplier, passed through rather than recomputed so this
   and resolveExpedition never disagree on it. */
function rollExpeditionDiscovery(exp,mul){
 if(G.rng.next()>=P.EXPED_DISCOVERY_CHANCE)return;
 var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 var bEnemies=applyDirectionAffinity(applyStatMul(buildEnemies(exp.ew,true),mul),exp.direction);
 var bParty=buildExpeditionParty(exp.partyIds,exp.hpFrac);
 var bBattle=C.makeBattle(bParty.concat(bEnemies),{rng:G.rng,enrage:G.enrage});
 var bGuard=0;
 while(!bBattle.over&&bGuard++<4000)C.step(bBattle);
 if(bBattle.over==='party'){
  var br=P.killReward(exp.ew,bEnemies.length);
  var bAether=br.aether*mul,bMarks=br.marks*P.marksMul(G)*mul;
  exp.bank.aether+=bAether;exp.bank.marks+=bMarks;
  pushExpeditionLog(exp,names+' won a bonus fight along the way — +'+
   Math.round(bAether)+' Aether, +'+Math.floor(bMarks)+' Marks.');
 }else{
  pushExpeditionLog(exp,names+' were ambushed in a bonus fight and had to disengage — no reward.');}}
/* Builds one new multi-wave dungeon for `dir` at unlock number `tier`
   (1st, 2nd, ... dungeon this direction has produced) — cfg.waveCount-1
   regular waves, all at the SAME frozen depth (tier*cfg.unlockEvery,
   scaled by the direction's own difficulty — "a normal fight at this
   depth, in this direction"), then a forced boss wave (same depth rounded
   up to the nearest boss wave via P.nextBossWave, scaled by the direction
   multiplier AND DUNGEON_LEN on top — a dungeon's own boss hits harder
   than a same-depth Road boss would, mirroring how the old single-fight
   dungeons already used DUNGEON_LEN for "slightly harder"). Each wave
   keeps its OWN frozen `wave` value (not just enemies) since the regular
   waves and the boss wave are frozen at DIFFERENT depths — see
   finishSideBattle()'s dungeon-advance branch, which re-sets C.setWave
   per wave rather than once for the whole run. cfg (P.DIRECTION_CONFIG[dir],
   farroaddungeons.csv) is independently editable per direction — a
   different wave count, unlock pace, difficulty, or boss name per lane,
   not one shared shape for all 8. */
function unlockDirectionDungeon(dir,tier){
 var cfg=P.DIRECTION_CONFIG[dir],mul=cfg.mul;
 var baseWave=tier*cfg.unlockEvery;
 /* unlockEvery (100 by default) can land on a multiple of BOSS_EVERY
    (20), which would otherwise make baseWave itself a boss wave —
    buildEnemies would silently give every "regular" wave a single
    boss-tier enemy instead of a normal multi-enemy fight. Regular waves
    build one wave short of the unlock depth in that case; the FINAL wave
    is still deliberately forced onto a real boss wave via P.nextBossWave,
    which for a baseWave that's already a boss wave correctly resolves to
    baseWave itself. */
 var regularWave=P.isBossWave(baseWave)?baseWave-1:baseWave;
 var waves=[];
 for(var i=0;i<cfg.waveCount-1;i++){
  var enemies=applyDirectionAffinity(applyStatMul(buildEnemies(regularWave,true),mul),dir);
  waves.push({wave:regularWave,enemies:enemies.map(bakeEnemySnapshot)});}
 var bossWave=P.nextBossWave(baseWave-1);
 var bossEnemies=applyDirectionAffinity(applyStatMul(buildEnemies(bossWave,true),mul*P.DUNGEON_LEN),dir);
 if(cfg.bossName)bossEnemies.forEach(function(u){u.name=cfg.bossName;});
 waves.push({wave:bossWave,enemies:bossEnemies.map(bakeEnemySnapshot)});
 var label=cfg.label;
 var dungeon={id:'dgn'+Date.now()+'_'+Math.floor(Math.random()*1e6),
  name:label+' Dungeon (depth '+baseWave+')',direction:dir,tier:tier,waves:waves,clears:0};
 G.dungeons.push(dungeon);
 sysLog('<b>A new dungeon has opened up to the '+label+'.</b> '+
  '<span class="tiny">'+baseWave+' depth reached.</span>');
 pushDrop({name:dungeon.name,kind:'DUNGEON UNLOCKED',
  body:'A new dungeon has opened up to the '+label+' — '+baseWave+' depth reached.',
  why:'Repeatable any time from the QUESTS tab — '+(cfg.waveCount-1)+
   ' wave'+(cfg.waveCount-1===1?'':'s')+' then a boss.'});}
/* Resolves every active expedition in one pass — slice() first so
   settling one mid-loop (settleExpedition reassigns G.expeditions via
   filter) can't skip its neighbor. */
function resolveAllExpeditions(){
 G.expeditions.slice().forEach(function(exp){resolveExpedition(exp);});}
/* Player-initiated early return for ONE expedition, by id: catch up on
   whatever real time has passed for it (which may itself trigger and even
   fully resolve an auto turn-back), then decide to turn back right now if
   it isn't already doing so — same half-time trip an auto turn-back gets
   (see beginReturnTrip), so rewards don't bank until it actually arrives.
   A no-op if the id no longer matches anything active, if it's already
   heading home, or if it already settled during the catch-up above. */
function recallExpedition(id){
 var exp=null;G.expeditions.forEach(function(e){if(e.id===id)exp=e;});
 if(!exp)return;
 resolveExpedition(exp);
 if(G.expeditions.indexOf(exp)>=0&&!exp.homeAt)beginReturnTrip(exp,Date.now(),'recalled.');}

/* Only called once, at boot — there is no manual Load button (autosave means
   there is nothing to manually load FROM except what boot already resumes).
   Returns false on first-ever visit or a corrupt/missing save, which tells the
   caller to fall back to a brand-new game. */
function tryResumeSave(){
 var snap=readSavedSnapshot();
 if(!snap)return false;
 var loaded=Save.deserialize(snap,C);
 if(!loaded){sysLog('<span style="color:var(--bad)">Save was corrupt — starting a fresh run.</span>');return false;}
 G=loaded;
 applyCustomMC();
 $('#log').innerHTML='';
 /* Rebuild the battle for the wave the player was actually on BEFORE
    simulating forward — skipDrops:true because that wave was not cleared
    when saved, so grantDrops(w) must not treat resuming it as a fresh
    visit. Once G.battle is valid, simulateOfflineProgress can step it
    forward exactly like live play would, including past this same wave. */
 startWave(G.wave||1,true);
 simulateOfflineProgress(snap);   /* logs its own "Welcome back" line when time has actually passed */
 resolveAllExpeditions();   /* catch up every active expedition the same way */
 buildGambits();renderAll();
 return true;}

/* ---------------------------------------------------------------- loop --- */
var playing=false,timer=null,speed=1,lastActor=null;
var mcExpedPick=[];   /* UI-only: units checked in the expedition party picker */
var mcDirPick=null;   /* UI-only: direction chosen in the expedition send picker */
function doStep(){
 if(!G.battle)return;
 /* Live quest/dungeon side battle in progress — mirrors the Row shape
    below exactly, swapping afterWaveCleared/startWave/onWipe (Road-only
    side effects) for finishSideBattle(). See MODULES.md. */
 if(G.sideBattle){
  if(G.battle.over==='party'){finishSideBattle('party');renderAll();return;}
  if(G.battle.over==='enemy'){finishSideBattle('enemy');renderAll();return;}
  var se=C.step(G.battle);
  if(se){lastActor=se.actorId;logEntry(se);}
  if(G.battle.over==='enemy'){finishSideBattle('enemy');renderAll();return;}
  renderTick();
  return;}
 if(G.battle.over==='party'){afterWaveCleared();startWave(G.wave+1);renderAll();return;}
 if(G.battle.over==='enemy'){onWipe();renderAll();return;}
 var e=C.step(G.battle);
 if(e){lastActor=e.actorId;logEntry(e);}
 if(G.battle.over==='enemy'){onWipe();renderAll();return;}
 /* v2.9 BUGFIX: this used to call the full renderAll() every single beat —
    with travel now auto-starting on load, that meant AETHER/LORE/MARKS/
    EXPEDITION's entire tab content (host.innerHTML='' + rebuild, fresh
    button listeners every time) was being torn down and rebuilt dozens of
    times a second at higher speeds, REGARDLESS of which tab the player was
    actually looking at. None of that content changes from an ordinary
    combat beat (leveling, Lore, pulls, and expeditions all need an
    explicit button click elsewhere to change anything) — only the purse
    numbers, the battle view, and the log genuinely need to update every
    beat. A click landing while a tick-driven rebuild replaced the button
    out from under it is "occasionally have to click twice" — renderTick()
    (below) skips exactly the parts that don't need per-beat freshness;
    wave-transition beats above still use the full renderAll(), since
    afterWaveCleared()/onWipe() CAN change owned units/drops/checkpoints. */
 renderTick();}
function tick(){
 doStep();
 G.idleAcc+=1;
 if(G.idleAcc>=6){var r=P.idlePerSec(G.farthest);
  /* v2.7: no cap. Pre-unlock Marks run at 45% so the bank at wave 40 is a
     sensible size on its own rather than being clipped after the fact. */
  G.aether+=Math.round(r.aether);G.marks+=r.marks*P.marksMul(G);
  G.idleAcc=0;renderPurse();autoSave();}
 if(!playing)return;
 timer=setTimeout(tick,C.beatMs(Math.max(1,G.battle.beat+1))/speed);}
/* Pure label/class sync, no tick() — split out so finishSideBattle() (see
   below) can reflect "still traveling" after a side battle ends WITHOUT
   re-entering tick(). play() calling tick() is what starts a NEW
   self-rescheduling setTimeout chain; calling it from code that is
   itself already running inside a live tick()->doStep() call stack (as
   finishSideBattle() is) spawns a SECOND parallel chain on top of the one
   still unwinding back up the stack — neither chain is ever cancelled, so
   the Road silently runs twice as fast, compounding by one extra chain
   per side battle finished while already traveling. This was a real,
   shipped bug — "the Road speeds up after a dungeon/quest, worse each
   time" — see MODULES.md. */
function syncPlayBtn(){
 $('#btnPlay').textContent=playing?(G.sideBattle?'⏸ Fighting':'⏸ Rest'):(G.sideBattle?'▶ Resume':'▶ Travel');
 $('#btnPlay').classList.toggle('on',playing);}
function play(){playing=true;syncPlayBtn();tick();}
function stop(){playing=false;clearTimeout(timer);syncPlayBtn();}

/* ===== LIVE SIDE BATTLES (quests/dungeons) =====
   Was: attemptQuestStage()/enterDungeon() resolved headlessly, synchronously,
   in a tight while(!battle.over) loop — the same shape expedition catch-up
   uses — so nothing was ever visibly watched (Ian's report: "it just says
   the next stage is available... there aren't any actual battles").
   G.battle is already a bare, reassignable pointer — renderUnits()/
   renderRail() already read it generically — so a side fight just points
   G.battle at ITS OWN battle object and lets the existing doStep()/tick()/
   play()/stop() loop drive it forward exactly like Road travel does,
   pausing the real Road battle (parked in G.roadBattle) for the duration.
   Only doStep()'s wave-transition branch and renderHead()'s labels needed
   to learn to tell the two apart (via G.sideBattle) — see MODULES.md. */
function startSideBattle(enemies,wave,meta){
 if(G.sideBattle)return false;   /* one at a time — see renderQuests()'s busy-gate */
 var wasPlaying=playing;if(playing)stop();
 G.roadBattle=G.battle;
 var savedWave=G.wave;
 C.setWave(wave);   /* stays pinned for the whole visible fight — K_of() reads it every beat */
 var party=buildExpeditionParty(G.party,1);
 G.battle=C.makeBattle(party.concat(enemies),{rng:G.rng,enrage:G.enrage});
 G.sideBattle={savedWave:savedWave,wasPlaying:wasPlaying,wave:wave,meta:meta};
 lastActor=null;
 play();
 return true;}
/* result: 'party' (won) or 'enemy' (lost) — matches battle.over's own values.
   Reward/log logic here is the exact tail attemptQuestStage()/enterDungeon()
   used to run inline, right after their own synchronous while-loop — moved
   here verbatim, reading from meta instead of closure variables, since the
   fight now finishes asynchronously (many doStep() calls later). */
/* @param gaveUp true only for a voluntary quest abort (giveUpQuest() below)
   — same 'enemy' result as a real defeat for every reward/state purpose
   (no stage advance, no penalty either way), but the log/drop wording
   should say the player called it off, not that the party was beaten. */
function finishSideBattle(result,gaveUp){
 var sb=G.sideBattle,meta=sb.meta;
 /* Multi-wave dungeon, won this wave, more waves left — advance IN PLACE
    rather than fully resolving. Deliberately does NOT touch G.roadBattle/
    G.sideBattle/playing (only G.battle + CURRENT_WAVE change) — mirrors
    how the Road's own startWave() swaps in a fresh battle object without
    touching the play/pause state. Party units carry over (not rebuilt),
    so whatever HP/charge survived the last wave carries into the next —
    real attrition across the run, per Ian's ask (full HP/0 charge only
    at the very start of an attempt, not every wave). */
 if(meta.kind==='dungeon'&&result==='party'&&meta.waveIndex<meta.totalWaves-1){
  var curDungeon=null;G.dungeons.forEach(function(d){if(d.id===meta.dungeonId)curDungeon=d;});
  var survivors=G.battle.units.filter(function(u){return u.isParty;});
  meta.waveIndex++;
  var nextWave=curDungeon.waves[meta.waveIndex];
  C.setWave(nextWave.wave);
  sb.wave=nextWave.wave;   /* keep renderUnits()'s enemy level-tag pinned to THIS wave, not the last */
  var nextEnemies=unitsFromSnapshots(nextWave.enemies);
  G.battle=C.makeBattle(survivors.concat(nextEnemies),{rng:G.rng,enrage:G.enrage});
  lastActor=null;
  return;}
 C.setWave(sb.savedWave);
 G.battle=G.roadBattle;G.roadBattle=null;G.sideBattle=null;lastActor=null;
 if(meta.kind==='quest'){
  var q=G.quests[meta.uid];
  if(result==='party'){
   q.stage++;
   /* v2.10: Aether reward, scaling 100 (stage 1) -> 500 (stage 5) — see
      P.questStageAether. meta.stage is the 0-based stage JUST cleared. */
   var reward=P.questStageAether(meta.stage);
   G.aether+=reward;
   pushDrop({name:meta.name+' — stage '+(meta.stage+1)+' of 5',kind:'QUEST',body:meta.story,
    why:(q.stage>=5?meta.name+'\'s quest line is complete.':'Stage '+(q.stage+1)+' is now available.')+
     ' +'+reward+' Aether.'});
   sysLog('<b>Quest stage cleared.</b> <span class="tiny">'+meta.name+' — stage '+(meta.stage+1)+' of 5. '+
    '<b style="color:var(--aether)">+'+reward+' Aether</b>.</span>');
  }else if(gaveUp){
   pushDrop({name:meta.name+' — stage '+(meta.stage+1)+' of 5',kind:'QUEST ABANDONED',
    body:'The attempt was called off.',why:'No penalty — try again any time.'});
   sysLog('<b>Quest attempt called off.</b> <span class="tiny">'+meta.name+
    ' — no penalty, try again any time.</span>');
  }else{
   pushDrop({name:meta.name+' — stage '+(meta.stage+1)+' of 5',kind:'QUEST FAILED',
    body:'The party was defeated.',why:'No penalty — try again any time.'});
   sysLog('<b>Quest attempt failed.</b> <span class="tiny">'+meta.name+
    ' — the party was defeated. No penalty, try again any time.</span>');}
 }else{
  var dungeon=null;G.dungeons.forEach(function(d){if(d.id===meta.dungeonId)dungeon=d;});
  if(result==='party'&&dungeon){
   dungeon.clears++;
   /* Reward is sized off the dungeon's own tier depth and direction —
      NOT any single internal wave's own numbers, since regular waves are
      all frozen at the same depth and the boss wave alone would
      undersell a full clear. */
   var rewardWave=meta.tier*P.DIRECTION_CONFIG[meta.direction].unlockEvery;
   var mul=P.directionMul(meta.direction);
   var r=P.killReward(rewardWave,meta.totalWaves);
   var dAether=r.aether*mul,dMarks=r.marks*P.marksMul(G)*mul;
   G.aether+=dAether;G.marks+=dMarks;
   pushDrop({name:dungeon.name,kind:'DUNGEON CLEARED',
    body:'Earned +'+Math.round(dAether)+' Aether and +'+Math.floor(dMarks)+' Marks.',
    why:'Cleared all '+meta.totalWaves+' waves, including the boss.'});
   sysLog('<b>Dungeon cleared.</b> <span class="tiny">'+dungeon.name+' — earned '+
    '<b style="color:var(--aether)">+'+Math.round(dAether)+' Aether</b> and '+
    '<b style="color:var(--marks)">+'+Math.floor(dMarks)+' Marks</b>.</span>');
  }else{
   pushDrop({name:dungeon?dungeon.name:'Dungeon',kind:'DUNGEON FAILED',
    body:'The party was defeated'+(meta.waveIndex>0?' on wave '+(meta.waveIndex+1)+
     ' of '+meta.totalWaves:'')+'.',why:'No penalty — try again any time.'});
   sysLog('<b>Dungeon attempt failed.</b> <span class="tiny">'+(dungeon?dungeon.name:'')+
    ' — the party was defeated. No penalty, try again any time.</span>');}}
 /* startSideBattle() unconditionally called play() to auto-run the fight,
    so `playing` is still true here regardless of whether the Road itself
    was traveling before. If it WAS: this function is running from inside
    doStep(), itself called from the side battle's own still-executing
    tick() — that same call stack will naturally continue on to tick()'s
    own `timer=setTimeout(tick,...)` line right after this function
    returns, now correctly scheduling the ROAD's next beat (G.battle is
    already reassigned above). Just syncing the button label is enough;
    calling play() here would call tick() a SECOND time and spawn a
    parallel, never-cancelled setTimeout chain (see syncPlayBtn()'s
    comment). If it WASN'T playing before: stop() is safe to call here
    (it never calls tick()) and correctly prevents that same still-live
    call stack from rescheduling itself further. */
 if(sb.wasPlaying)syncPlayBtn();else stop();}

/* -------------------------------------------------------------- render --- */
/* ===== INITIATIVE MULTIPLIER (v1.0 presentation) =====
 * The player-facing speed number is now 1/rank: "how often this lets me act",
 * where HIGHER IS FASTER. Rank 0.67 -> x1.50, rank 1.00 -> x1.00, rank 1.25 ->
 * x0.80. This is a pure display change - no rank or power value moved. The raw
 * tick cost is kept in the title attribute for debugging.
 * v2.9: shown as a whole number (×150/×100/×80, i.e. the multiplier x100),
 * not two decimal places (×1.50/×1.00/×0.80) — Ian found the decimals hard
 * to read at a glance. Still purely a display change; initMul's actual
 * multiplier is untouched, only initStr's formatting rounds it. */
function initMul(rank){return (1/rank);}
function initStr(rank){var m=initMul(rank);
 return '×'+Math.round(m*100);}
function initClass(rank){var m=initMul(rank);
 return m>=1.15?'ini fast':(m<=0.85?'ini slow':'ini');}
function initTag(rank,tick){
 return '<span class="'+initClass(rank)+'" title="raw tick cost '+(tick==null?'—':tick)+
  ' · rank '+rank+'">'+initStr(rank)+'</span>';}
/* ===== DEF / RES PAIR (v1.1 UI) =====
 * Shown together because the decision is comparative — 34 DEF against 12 RES is
 * what tells you to reach for magic, and RES alone tells you nothing.
 * EFFECTIVE values, not base: Bracing raises DEF x1.40, Sundered cuts it to
 * x0.75, Frail cuts RES to x0.75. A player reading a base number while Sundered
 * was active would be reading a stat that is not the one being used.
 * The lower of the two is highlighted, but ONLY when the gap is >= 15% — a
 * DEF 20 / RES 19 split is noise and flagging it would train the player to
 * trust a distinction that does not pay. */
function defResPair(u){
 var d=C.effDef(u), r=C.effRes(u);
 var dMod=C.has(u,'bracing')||C.has(u,'sundered');
 var rMod=C.has(u,'frail');
 var lo=Math.min(d,r), hi=Math.max(d,r);
 var gap=hi>0?(hi-lo)/hi:0;
 var flagD=(gap>=0.15&&d<r), flagR=(gap>=0.15&&r<d);
 function cell(name,val,flag,mod){
  return '<span class="dr'+(flag?' soft':'')+'">'+name+' '+Math.round(val)+
   (mod?'<i class="mod">*</i>':'')+'</span>';}
 return '<span class="drpair">'+cell('DEF',d,flagD,dMod)+
  '<span class="drsep">/</span>'+cell('RES',r,flagR,rMod)+
  (flagD||flagR?'<span class="drhint">'+(flagD?'physical':'magic')+' lands harder</span>':'')+
  '</span>';}
/* v2.11: "note on enemies and units on the road if there are any
   affinities they're weak to." u.affinity is already the EFFECTIVE
   value (baseline+investment for a party unit, baseline only for an
   enemy — computed once at build time, see effectiveAffinity()/
   buildEnemies()) so this just reads it straight off the live unit,
   no recomputation. Omitted entirely when nothing is negative — most
   units/enemies today have nothing to show here, and a silent line is
   better than an always-present "Weak to: (none)". */
function weaknessLine(u){
 if(!u.affinity)return '';
 var weak=[];
 AFFINITY_AXES.forEach(function(ax){if((u.affinity[ax]||0)<0)weak.push(AFFINITY_INFO[ax].n);});
 return weak.length?'<div class="tiny mono" style="color:var(--bad)">Weak to: '+weak.join(', ')+'</div>':'';}
function pct(a,b){return Math.max(0,Math.min(100,100*a/b));}
/* C.ROSTER stores role lowercase ('attacker', etc.) — capitalized only at
   display time so the stored value stays a plain identifier-ish string. */
function capRole(s){return s?s.charAt(0).toUpperCase()+s.slice(1):s;}
function pills(u){var h='';for(var i=0;i<C.ST.length;i++){var id=C.ST[i];if(u.st[id]>0){var f=C.STATUS_INFO[id];
 h+='<span class="pill '+(f.k==='d'?'d':'b')+'">'+f.n+' '+u.st[id]+'</span>';}}return h;}
function renderPurse(){
 $('#cAether').textContent=Math.floor(G.aether);
 $('#cLore').textContent=Math.floor(G.lore);
 $('#cMarks').textContent=Math.floor(G.marks);
 /* v2.9: per-5-minutes with 2 decimals, not per-minute rounded to a whole
    number — at depth the per-minute Marks figure rounds to 0 and reads as
    "income stopped" even though it's still trickling in (e.g. ~0.26/min at
    wave 558 displayed as a flat "0"). x300 (5 min) with .toFixed(2) keeps a
    real, non-zero-looking number much further into the run. */
 var r=P.idlePerSec(G.farthest),el=$('#idleRate');
 if(el)el.textContent='idle: '+(r.aether*300).toFixed(2)+' Aether/5min · '+
  (r.marks*P.marksMul(G)*300).toFixed(2)+' Marks/5min';}
function renderUnits(){
 var host=$('#units');host.innerHTML='';
 if(!G.battle)return;
 G.battle.units.forEach(function(u){
  var d=document.createElement('div');
  d.className='unit'+(lastActor===u.id?' act':'')+(u.hp<=0?' down':'');
  var tag=u.isParty?'<span class="rowtag '+(u.row==='front'?'front':'')+'" data-row="'+u.id+'">'+
    (u.row==='front'?'FRONT':'BACK')+'</span>'
   :'<span class="tiny">'+(u.isBoss?'boss':(C.PREF_TEXT[u.arch]||''))+'</span>';
  /* v2.9: level readout next to every name — "that'll help players get a
     feel for what level their units should be at, and for the difficulty
     of the wave." Party level is the real, Aether-invested levelOf(); an
     enemy has no such stat, so its "level" is levelCurve(wave) rounded —
     the same wave->level-equivalent curve waveScale() itself is built from
     (see farroad-core.js), already calibrated so its numbers read like a
     sane party level for that depth. Every enemy on the same wave shares
     that one number — a wave-difficulty proxy, not a precise per-enemy
     power rating (a boss is tougher than its number alone suggests, by
     design — see P.BOSS_HARD_EXTRA/bossSpdMul). */
  var lvl=u.isParty?levelOf(u.id):Math.round(C.levelCurve(G.sideBattle?G.sideBattle.wave:G.wave));
  d.innerHTML='<div class="spread"><span class="uname '+(u.isParty?'p':(u.isBoss?'b':'f'))+'">'+
   u.name+' <span class="tiny">Lv'+lvl+'</span>'+(u.hp<=0?' — DOWN':'')+' '+tag+'</span>'+
   '<span class="tiny mono">'+Math.max(0,Math.round(u.hp))+' / '+u.maxHp+'</span></div>'+
   '<div class="bar hp"><i style="width:'+pct(u.hp,u.maxHp)+'%"></i></div>'+
   (u.chargeAction?'<div class="spread" style="margin-top:3px"><span class="tiny"'+
     (!u.isParty?' style="color:var(--bad)"':'')+'>⚡ '+C.ACTIONS[u.chargeAction].name+
     (!u.isParty&&u.charge>=70?' — INCOMING':'')+'</span><span class="tiny mono">'+
     Math.round(u.charge)+'/100</span></div>'+
    '<div class="bar ch"><i style="width:'+Math.max(0,Math.min(100,u.charge))+'%'+
     (!u.isParty?';background:var(--bad)':'')+'"></i></div>':'')+
   '<div class="tiny mono" style="margin-top:3px">ATK '+Math.round(C.effAtk(u))+
    ' MAG '+Math.round(C.effMag(u))+' SPD '+u.base.spd+'</div>'+
   '<div class="tiny mono" style="margin-top:2px">'+defResPair(u)+'</div>'+
   weaknessLine(u)+
   (u.isParty?'<div class="tiny mono" style="color:var(--hp)">RECOVERY '+
     Math.round(recoveryOf(u.id)*100)+'%<span style="color:var(--dimmer)"> — HP regained between waves'+
     (recoveryMaxed(u.id)?' · at cap':'')+'</span></div>':'')+
   ((!u.isParty&&G.enrage)?(function(){
     /* Gate is now battle-wide (G.battle.beat vs C.ENRAGE_AFTER), not this
        unit's own turn count — see the ENRAGE comment in core.js's step().
        Once open, an enemy that hasn't acted since still reads "calm" until
        its own next turn actually applies a stack. */
     var st=C.enrageStacks(u),beat=G.battle.beat,gateOpen=beat>C.ENRAGE_AFTER;
     if(st>0)return '<div class="tiny" style="color:var(--bad)">⏱ ENRAGED ×'+st+' — +'+
       Math.round((Math.pow(1+C.ENRAGE_PCT,st)-1)*100)+'% damage, rising each of its turns</div>';
     if(gateOpen)return '<div class="tiny" style="color:var(--dimmer)">⏱ calm — enrages on its next turn</div>';
     return '<div class="tiny" style="color:var(--dimmer)">⏱ calm — enrages after turn '+C.ENRAGE_AFTER+
       ' <span style="color:var(--dim)">(now turn '+beat+')</span></div>';})():'')+
   '<div>'+pills(u)+'</div>';
  host.appendChild(d);});
 Array.prototype.forEach.call(host.querySelectorAll('[data-row]'),function(el){
  el.onclick=function(){var id=el.dataset.row;
   G.units.forEach(function(p){if(p.id===id)p.row=(p.row==='front')?'back':'front';});
   C.ROSTER.forEach(function(r){if(r.id===id)r.row=(r.row==='front')?'back':'front';});
   renderAll();};});}
function renderRail(){
 if(!G.battle)return;
 var pv=C.preview(G.battle,6),h=$('#rail');h.innerHTML='';
 pv.forEach(function(p,i){var el=document.createElement('div');
  el.className='chip '+(p.isParty?'p':'f')+(i===0?' now':'');
  var act=C.ACTIONS[p.actionId];var rk=(act||{}).rank||1;
  el.innerHTML='<div class="cn">'+p.unitName.split(' ')[0]+'</div><div class="ca">'+
   (p.isCharge?'⚡ ':'')+actionGlyph(act)+p.actionName+'</div><div class="ct mono">'+initTag(rk,p.cost)+'</div>';
  h.appendChild(el);});}
function renderHead(){
 /* Live side battle in progress — takes over the always-visible battle
    header instead of the Road's own wave/checkpoint readout. See
    startSideBattle()/finishSideBattle() and MODULES.md. */
 if(G.sideBattle){
  var m=G.sideBattle.meta;
  var label=m.kind==='quest'?(m.name+' — stage '+(m.stage+1)+' of 5'):
   (m.name+' — wave '+(m.waveIndex+1)+' of '+m.totalWaves+
    (m.waveIndex===m.totalWaves-1?' (BOSS)':''));
  $('#waveLbl').innerHTML='<span class="bosstag">'+(m.kind==='quest'?'QUEST':'DUNGEON')+'</span> '+label;
  var foeCount=G.battle.units.filter(function(u){return !u.isParty;}).length;
  $('#encLbl').textContent='· '+foeCount+(foeCount===1?' enemy':' enemies');
  $('#secLbl').textContent=(G.battle.elapsedMs/1000).toFixed(1)+'s';
  $('#ckptLbl').innerHTML='<span class="tiny">No penalty on a loss — try again any time.</span>';
  return;}
 var boss=P.isBossWave(G.wave);
 $('#waveLbl').innerHTML='Wave '+G.wave+(boss?' <span class="bosstag">BOSS</span>':'');
 $('#encLbl').textContent='· '+(G.enemies?G.enemies.length:0)+
  ((G.enemies&&G.enemies.length===1)?' enemy':' enemies')+' · party '+G.party.length;
 $('#secLbl').textContent=(G.battle?(G.battle.elapsedMs/1000).toFixed(1):'0.0')+'s';
 var nb=P.nextBossWave(G.wave)||'—';
 $('#ckptLbl').innerHTML='farthest <b>'+G.farthest+'</b> · checkpoint <b>'+P.checkpoint(G.bossesCleared)+
  '</b> · next boss <b>'+nb+'</b>'+(G.wipes?' · wipes '+G.wipes:'')+
  (P.isCurated(G.wave)?' · <span class="ckpt">curated drops</span>':' · <span class="tiny">random drops</span>');}
/* v2.9: "a value that accurately shows a player's total power level" —
   moved from inside the ROAD tab up to the always-visible header, next to
   the idle-rate line, so it's visible regardless of which tab is open.
   See P.powerLevel in progression.js for the formula (roster depth + unit
   levels + Lore levels + wave, each put on a comparable level-equivalent
   scale before summing). */
function renderPowerLevel(){
 var el=$('#powerLevel');if(!el)return;
 el.innerHTML='<b>POWER LEVEL <span class="mono" style="color:var(--charge)">'+
  P.powerLevel(G)+'</span></b>';}
function logEntry(e){
 var d=document.createElement('div');d.className='le '+(e.isParty?'p':'f');
 var tags='',calc='';
 if(e.hits.length){var h=e.hits[0];
  if(h.evaded)tags=' <span style="color:var(--bad)">EVADED</span>';
  else{if(h.crit)tags+=' <span style="color:var(--crit)">CRIT</span>';}
  calc=h.evaded
   ?('MISSED — evade '+(Math.round(h.evadeChance*1000)/10)+'%')
   :('base '+(Math.round(h.power*100)/100)+' × '+Math.round(h.off)+' × '+h.K+'/('+h.K+'+'+
     Math.round(h.defEff)+') = '+(Math.round(h.base*10)/10)+
     '\nno variance roll — base damage is deterministic'+
     (h.crit?'\ncrit ×1.75':'')+
     '\n→ floor '+h.damage);}
 var extra='';
 if(e.dot)extra+='<div class="note">🔥 −'+e.dot+'</div>';
 e.heals.forEach(function(x){extra+='<div class="note">✚ '+x.targetName+' +'+x.amount+'</div>';});
 e.notes.forEach(function(x){extra+='<div class="note">· '+x+'</div>';});
 d.innerHTML='<div class="lh"><span><span class="lt mono">b'+e.beat+'</span> <b>'+
  e.actorName.split(' ')[0]+'</b> → '+(e.isCharge?'⚡ ':'')+actionGlyph(C.ACTIONS[e.actionId])+e.actionName+
  (e.targetName?' <span class="lt">→ '+e.targetName+'</span>':'')+tags+'</span>'+
  '<span class="dmg mono">'+(e.hits.length?e.totalDamage:'—')+'</span></div>'+
  '<div class="via">'+e.via+' · initiative '+initTag(e.rank||1,e.tickCost)+'</div>'+
  (calc?'<div class="tapme">tap for the damage breakdown</div><div class="calc">'+calc+'</div>':'')+extra;
 /* Progressive disclosure: the summary line stays full size and the component
    breakdown expands on tap, rather than shrinking type to fit it all in. */
 if(calc)d.onclick=function(){d.classList.toggle('open');};
 var L=$('#log');L.insertBefore(d,L.firstChild);while(L.childNodes.length>120)L.removeChild(L.lastChild);}

/* ------------------------------------------------------------ economy UI --- */
/* v2.9: back to the one-at-a-time tab selector, same pattern GAMBITS uses —
   "let's change the UI for aether and lore to be like gambits with the
   tabs" (a brief compact-all-units-list pass came before this). Passes
   includeBenched=true to renderUnitTabs/currentSelectedUnit so benched
   units stay reachable here (that was the point of the compact pass, and
   this revert keeps it rather than silently dropping it). */
function renderAether(){
 var host=$('#aetherView');host.innerHTML='';
 renderUnitTabs(host,function(){renderAether();},true);
 var STEP=50;
 [currentSelectedUnit(true)].forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var L=levelOf(uid),x=expOf(uid),need=costNext(uid),have=0;
  var st=P.statsAt(uid,def.stats,def.hp,L), g=P.GROWTH[uid];
  var slots=P.slotsAt(L),nxt=P.nextSlotAt(L);
  var fielded=G.party.indexOf(uid)>=0;
  var box=document.createElement('div');box.style.marginBottom='10px';
  var prog=Math.max(0,Math.min(100,100*(x-have)/Math.max(1,need-have)));
  box.innerHTML='<div class="spread" style="margin-bottom:3px">'+
   '<span class="uname'+(fielded?' p':'')+'">'+def.name+rarityTag(def.rarity)+' <span class="tiny">'+capRole(def.role)+
    (fielded?'':(isOnExpedition(uid)?' · on expedition':' · benched'))+'</span></span>'+
   '<span class="nval">LV '+L+'</span></div>'+
   '<div class="bar"><i style="width:'+prog+'%;background:var(--aether)"></i></div>'+
   '<div class="tiny mono" style="margin-top:3px">'+Math.floor(x)+' / '+need+' to LV '+(L+1)+'</div>'+
   '<div class="tiny mono" style="margin-top:3px">hp '+st.hp+'  atk '+st.atk+'  mag '+st.mag+
    '  def '+st.def+'  res '+st.res+'  spd '+st.spd+'</div>'+
   '<div class="tiny" style="margin-top:2px;color:var(--dimmer)">per level: +'+g.hp+' hp, +'+g.atk+
    ' atk, +'+g.mag+' mag, +'+g.def+' def, +'+g.res+' res, +'+g.spd+' spd</div>'+
   '<div class="tiny" style="margin-top:2px">gambit slots <b>'+slots+'</b>'+
    (nxt?' <span style="color:var(--dimmer)">· '+(slots+1)+'th at LV '+nxt+'</span>':' <span class="ckpt">· max</span>')+'</div>'+
   '<div class="node" style="margin-top:6px"><div class="nname">Recovery</div>'+
     '<div class="bdesc">HP regained between waves.</div>'+
     '<div class="spread"><span class="tiny mono">'+Math.round(recoveryOf(uid)*100)+'% → '+
     (recoveryMaxed(uid)?'<b style="color:var(--hp)">at cap ('+Math.round(P.REST_CAP*100)+'%)</b>'
      :Math.round(Math.min(P.REST_CAP,recoveryOf(uid)+0.03)*100)+'%')+'</span>'+
    '<button class="mini rec" data-u="'+uid+'"'+
     ((recoveryMaxed(uid)||G.aether<recoveryCost(uid))?' disabled':'')+'>+3% <span class="ncost">'+
     recoveryCost(uid)+'</span></button></div></div>'+
   '<div class="row" style="margin-top:5px">'+
    '<button class="mini feed" data-u="'+uid+'" data-a="'+STEP+'"'+(G.aether>=STEP?'':' disabled')+'>+'+STEP+'</button>'+
    '<button class="mini feed" data-u="'+uid+'" data-a="'+(STEP*5)+'"'+(G.aether>=STEP*5?'':' disabled')+'>+'+(STEP*5)+'</button>'+
    '<button class="mini feed" data-u="'+uid+'" data-a="next"'+(G.aether>=(need-x)?'':' disabled')+'>→ LV '+(L+1)+' ('+Math.max(0,Math.ceil(need-x))+')</button>'+
   '</div>';
  host.appendChild(box);
  var pBox=document.createElement('div');pBox.style.marginTop='10px';
  var pRows='';
  PCT_STAT_KEYS.forEach(function(stat){
   var info=PCT_STAT_INFO[stat],cur=pctStatValue(uid,stat),maxed=pctStatMaxed(uid,stat),cost=pctStatNextCost(uid,stat);
   var next=Math.min(P.PCT_STAT[stat].cap,cur+P.PCT_STAT[stat].step);
   pRows+='<div class="node" style="margin-top:4px"><div class="nname">'+info.n+'</div>'+
    '<div class="bdesc">'+info.d+'</div>'+
    '<div class="spread"><span class="tiny mono">'+Math.round(cur*1000)/10+'% → '+
     (maxed?'<b style="color:var(--hp)">at cap</b>':Math.round(next*1000)/10+'%')+'</span>'+
    '<button class="mini pctbuy" data-u="'+uid+'" data-st="'+stat+'"'+
     ((maxed||G.aether<cost)?' disabled':'')+'>'+(maxed?'MAX':'+'+Math.round(P.PCT_STAT[stat].step*1000)/10+
      '% <span class="ncost">'+cost+'</span>')+'</button></div></div>';});
  pBox.innerHTML='<hr><div class="tiny" style="margin-bottom:6px"><b>EVADE / CRIT</b> — none of '+
   'these grow with level for any unit in the game (unchanged). Aether buys them up directly here '+
   'instead, same as Recovery, hard-capped at the same ceiling the combat formula has always enforced.</div>'+pRows;
  host.appendChild(pBox);
  var aBox=document.createElement('div');aBox.style.marginTop='10px';
  var aRows='';
  AFFINITY_AXES.forEach(function(axis){
   var info=AFFINITY_INFO[axis],raw=affinityRaw(uid,axis),pct=Math.round(C.affinityMul(raw)*100);
   var maxed=affinityMaxed(uid,axis),cost=affinityNextCost(uid,axis);
   aRows+='<div class="node" style="margin-top:4px"><div class="nname">'+info.n+'</div>'+
    '<div class="bdesc">'+info.d+'</div>'+
    '<div class="spread"><span class="tiny mono">'+(raw>=0?'+':'')+raw+' → '+(pct>=0?'+':'')+pct+'%</span>'+
    '<button class="mini affbuy" data-u="'+uid+'" data-ax="'+axis+'"'+
     ((maxed||G.aether<cost)?' disabled':'')+'>'+(maxed?'MAX':'+1 <span class="ncost">'+cost+'</span>')+'</button></div></div>';});
  aBox.innerHTML='<hr><div class="tiny" style="margin-bottom:6px"><b>AFFINITIES</b> — Fire, Water, Earth, '+
   'Air, Light and Dark scale damage dealt and taken by attacks of that element; Body does the same for '+
   'physical attacks; Spirit scales in-combat healing (including drain effects) and buff/debuff potency, both given and received. Like Evade, '+
   'none of these grow with level — Aether buys them up directly here instead, with '+
   'diminishing returns the higher any one climbs, capped at ±80%.</div>'+aRows;
  host.appendChild(aBox);});
 host.insertAdjacentHTML('beforeend','<hr><div class="tiny">Aether is a <b>shared pool</b>: you '+
  'choose who to level. A benched companion costs you real progress on the others, and a solo '+
  'character reaches the LV 10 third-slot threshold early <i>because</i> everything goes to them — '+
  'which is why slot count needs no special case for being alone.'+
  '<br><br><b>New units join at LV 1, and that is fine.</b> A recruit’s value is <b>turn '+
  'economy</b>, not stats. Every unit acts on its own clock — turn cadence depends only on that '+
  'unit’s SPD and the rank of the action it picks, with no party-size term anywhere — so a '+
  'second body takes <b>1.96×</b> the actions per fight even at LV 1. Measured across sizes 1-5, '+
  'actions per unit stay flat at ~200 per 10k ticks.'+
  '<br><br>The pool is split evenly, but levelling costs rise as <code>13 × L^1.55</code>, so the '+
  'same Aether buys a newcomer many cheap levels and a veteran one expensive one. The gap closes: '+
  'LV 14 vs LV 1 at recruitment → 16 vs 5 → 18 vs 9 → 22 vs 14. A dilution you grow '+
  'out of, not a drag you carry.</div>');
 Array.prototype.forEach.call(host.querySelectorAll('.rec'),function(el){
  el.onclick=function(){var u=el.dataset.u,c=recoveryCost(u);
   if(G.aether<c||recoveryMaxed(u))return;
   G.aether-=c;G.recovery=G.recovery||{};G.recovery[u]=(G.recovery[u]||0)+1;
   sysLog('<b class="dw">RECOVERY</b> → '+Math.round(recoveryOf(u)*100)+'%'+
    (recoveryMaxed(u)?'<div class="tiny">At the cap. Measured: above '+
     Math.round(P.REST_CAP*100)+'% it is worth nothing, so there is nothing more to buy.</div>':''));
   renderAll();};});
 Array.prototype.forEach.call(host.querySelectorAll('.feed'),function(el){
  el.onclick=function(){var u=el.dataset.u,a=el.dataset.a,L0=levelOf(u);
   var amt=(a==='next')?Math.max(0,Math.ceil(costNext(u)-expOf(u))):parseInt(a,10);
   if(G.aether<amt)return;G.aether-=amt;
   feedUnit(u,amt);
   var L1=levelOf(u);
   if(L1>L0){var nm='';C.ROSTER.forEach(function(r){if(r.id===u)nm=r.name;});
    var s1=P.slotsAt(L1);
    /* Generalized for the v2.9 6-slot schedule (was hardcoded "a third
       slot" back when P.SLOT_LEVELS capped at 4 total). */
    var ORD={3:'3rd',4:'4th',5:'5th',6:'6th'};
    sysLog('<b class="dw">LEVEL UP</b> '+nm+' → LV '+L1+
     (s1>P.slotsAt(L0)?'<div class="tiny" style="color:var(--charge)">A '+
      (ORD[s1]||s1+'th')+' gambit slot opens.</div>':''));}
   refreshLiveStats();renderAll();buildGambits();};});
 Array.prototype.forEach.call(host.querySelectorAll('.affbuy'),function(el){
  el.onclick=function(){var u=el.dataset.u,ax=el.dataset.ax,c=affinityNextCost(u,ax);
   if(G.aether<c||affinityMaxed(u,ax))return;
   G.aether-=c;G.affinities=G.affinities||{};G.affinities[u]=G.affinities[u]||{};
   G.affinities[u][ax]=(G.affinities[u][ax]||0)+1;
   sysLog('<b class="dw">AFFINITY</b> '+AFFINITY_INFO[ax].n+' → '+
    (affinityRaw(u,ax)>=0?'+':'')+affinityRaw(u,ax)+' ('+Math.round(C.affinityMul(affinityRaw(u,ax))*100)+'%)');
   refreshLiveStats();renderAll();};});
 Array.prototype.forEach.call(host.querySelectorAll('.pctbuy'),function(el){
  el.onclick=function(){var u=el.dataset.u,st=el.dataset.st,c=pctStatNextCost(u,st);
   if(G.aether<c||pctStatMaxed(u,st))return;
   G.aether-=c;G.statInvest=G.statInvest||{};G.statInvest[u]=G.statInvest[u]||{};
   G.statInvest[u][st]=(G.statInvest[u][st]||0)+1;
   sysLog('<b class="dw">'+PCT_STAT_INFO[st].n.toUpperCase()+'</b> → '+
    (Math.round(pctStatValue(u,st)*1000)/10)+'%'+
    (pctStatMaxed(u,st)?'<div class="tiny">At the cap — there is nothing more to buy.</div>':''));
   refreshLiveStats();renderAll();};});}

/* ===== EQUIPMENT TAB (v2.14) ===== structurally "pick one of a shared,
   contention-limited pool per slot" — the same problem GAMBITS' loadout
   <select> editor already solves for actions (disabling an option when
   something else already holds it), not AETHER's "buy an upgrade node"
   shape above. Mirrors that pattern, gating on OWNED COUNT instead of
   fielded-unit identity: an option is disabled only when nothing is left
   to equip and it isn't already this exact slot's occupant. */
var EQUIP_SLOT_LABEL={head:'Head',body:'Body',legs:'Legs',hand1:'Hand (left)',hand2:'Hand (right)'};
function renderEquipment(){
 var host=$('#equipmentView');host.innerHTML='';
 renderUnitTabs(host,function(){renderEquipment();},true);
 [currentSelectedUnit(true)].forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var equipped=(G.equipped&&G.equipped[uid])||{};
  var box=document.createElement('div');
  var h='<div class="uname" style="margin-bottom:6px">'+(def?def.name+rarityTag(def.rarity):uid)+'</div>';
  C.EQUIPMENT_SLOTS.forEach(function(slot){
   var kind=equipKindForSlot(slot), curId=equipped[slot];
   var opts='<option value="">— empty —</option>';
   Object.keys(C.EQUIPMENT).forEach(function(id){
    var item=C.EQUIPMENT[id];
    if(item.slot!==kind)return;
    var isCur=id===curId, avail=equipAvailableCount(id);
    /* Only list what's actually owned — equipOwnedCount(id)>0 always
       holds for isCur (can't have equipped something never owned), so
       this never hides the slot's current occupant. */
    if(equipOwnedCount(id)<=0)return;
    var dis=(avail<=0&&!isCur)?' disabled':'';
    opts+='<option value="'+id+'"'+(isCur?' selected':'')+dis+'>'+item.name+
     rarityTagText(item.rarity)+' (owned '+equipOwnedCount(id)+', '+avail+' available)</option>';});
   h+='<div class="slot" style="margin-bottom:6px">'+
    '<label>'+EQUIP_SLOT_LABEL[slot]+'</label>'+
    '<select class="eq-slot" data-slot="'+slot+'">'+opts+'</select>'+
    (curId&&C.EQUIPMENT[curId]?'<div class="tiny" style="margin-top:4px">'+
     describeEquipment(curId).body+'</div>':'')+
    '</div>';});
  box.innerHTML=h;host.appendChild(box);
  Array.prototype.forEach.call(box.querySelectorAll('.eq-slot'),function(el){
   el.onchange=function(){
    var slot=el.dataset.slot,val=this.value;
    if(val)equipItem(uid,slot,val);else unequipItem(uid,slot);
    refreshLiveStats();renderAll();};});});}

function refreshLiveStats(){
 if(!G.units)return;
 G.units.forEach(function(u){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===u.id)def=r;});
  if(!def)return;
  var st=P.statsAt(u.id,def.stats,def.hp,levelOf(u.id));
  applyPctStatInvestment(u.id,st);
  applyEquipmentStats(u.id,st);
  u.base.atk=st.atk;u.base.mag=st.mag;u.base.def=st.def;u.base.res=st.res;u.base.spd=st.spd;
  u.base.evade=st.evade;u.base.atkCrit=st.atkCrit;u.base.magCrit=st.magCrit;
  var fr=u.hp/u.maxHp;u.maxHp=st.hp;u.hp=Math.max(1,Math.round(st.hp*fr));
  u.affinity=effectiveAffinity(u.id);
  u.slots=ensureLoadout(u.id).map(function(s){return {cond:s.cond,action:s.action};});});}
/* v2.9: which actions currently matter — anyone owned's loadout slots plus
   charge action, protecting the MC's WHOLE acquired-charge pool (not just
   the currently-equipped one, since swapping between them is free and is
   documented to preserve Lore investment — see the GAMBITS charge-swap
   note). Used by the bulk-refund button below; deliberately checks
   G.owned/G.loadout rather than G.party, since a benched unit's equipped
   actions are still real investments, not "unused". */
function usedActions(){
 var used={};
 Object.keys(G.owned).forEach(function(uid){
  (G.loadout[uid]||[]).forEach(function(s){used[s.action]=1;});
  var rd=null;C.ROSTER.forEach(function(r){if(r.id===uid)rd=r;});
  if(rd&&rd.chargeAction)used[rd.chargeAction]=1;});
 if(G.mc&&G.mc.acquiredCharges)G.mc.acquiredCharges.forEach(function(id){used[id]=1;});
 return used;}
/* v2.9: who currently equips a given action, for LORE's global "used by"
   line — same owned-unit scan as usedActions() above, but keeping the
   holder list instead of collapsing to a boolean. Split active (a loadout
   slot or the unit's live chargeAction) from banked (sitting unequipped in
   the MC's acquiredCharges pool — usedActions() also counts these as
   "used", protecting their Lore investment, but nobody is actively firing
   them right now, so they read differently here). */
function actionHolders(aid){
 var active=[],banked=false;
 Object.keys(G.owned).forEach(function(uid){
  var holds=false;
  (G.loadout[uid]||[]).forEach(function(s){if(s.action===aid)holds=true;});
  var rd=null;C.ROSTER.forEach(function(r){if(r.id===uid)rd=r;});
  var mcOwns=(uid==='kesh'&&G.mc&&G.mc.acquiredCharges&&G.mc.acquiredCharges.length);
  var ca=mcOwns?G.mc.chargeAction:(rd&&rd.chargeAction);
  if(ca===aid)holds=true;
  if(holds)active.push(rd?rd.name:uid);
  else if(mcOwns&&G.mc.acquiredCharges.indexOf(aid)>=0)banked=true;});
 return {active:active,banked:banked};}
/* v2.16 (LORE regroup) — the inverse of actionHolders: given a unit, which
   action ids does it CURRENTLY have equipped (loadout slots, deduped,
   plus its live charge action)? Same chargeAction resolution GAMBITS'
   own loadout render already uses (mcOwns ? G.mc.chargeAction : the
   roster's fixed one), kept identical rather than re-derived. */
function unitActiveActions(uid){
 var ids=[];
 (G.loadout[uid]||[]).forEach(function(s){if(ids.indexOf(s.action)<0)ids.push(s.action);});
 var rd=null;C.ROSTER.forEach(function(r){if(r.id===uid)rd=r;});
 var mcOwns=(uid==='kesh'&&G.mc&&G.mc.acquiredCharges&&G.mc.acquiredCharges.length);
 var ca=mcOwns?G.mc.chargeAction:(rd&&rd.chargeAction);
 if(ca&&ids.indexOf(ca)<0)ids.push(ca);
 return ids;}
function renderLore(){
 var host=$('#loreView');host.innerHTML='';
 var spent=C.bonusSpend(G.bonuses),free=Math.max(0,G.lore-spent);
 if(!G.lore){host.innerHTML='<div class="tiny">No Lore yet. Lore comes from <b>duplicate</b> drops, '+
  'and the curated sequence never repeats itself — so it stays at zero until drops turn random '+
  'after the wave-20 boss. That is by design, not a stall.</div>';return;}
 /* Bulk refund: only offered when it would actually do something, and shows
    exactly how much Lore comes back before the player commits. */
 var used=usedActions();
 var unusedIds=Object.keys(G.bonuses).filter(function(aid){return !used[aid]&&G.bonuses[aid]&&
  Object.keys(G.bonuses[aid]).length;});
 var refundTotal=0;
 unusedIds.forEach(function(aid){var b=G.bonuses[aid],total=C.actionBonusTotal(b);
  refundTotal+=total*(total+1)/2+(b.broad||0)*C.BONUS_COST_BROAD;});
 /* Tab pool starts as G.actions (every loadout-slot basic the player has
    unlocked), plus any charge action currently in play — those are NEVER
    entries in G.actions (a companion's chargeAction is a fixed roster
    property, the MC's come from G.mc.acquiredCharges, neither goes through
    the drop/pull unlock path G.actions tracks), so they'd silently vanish
    from LORE without this — caught live: "charge actions aren't available
    on the Lore tab now." `used` (usedActions(), computed above) already
    scans exactly this same set for its own purposes, so reuse it rather
    than re-deriving it. */
 var actionIds=G.actions.slice();
 Object.keys(used).forEach(function(id){
  if(actionIds.indexOf(id)<0&&C.ACTIONS[id]&&C.ACTIONS[id].isCharge)actionIds.push(id);});
 /* active[] keys off ACTUALLY-equipped-right-now (actionHolders.active),
    not usedActions()'s broader "protected from refund" sense — those are
    different questions, and conflating them once produced "starred charge
    actions listed as banked on Kesh — not currently equipped": a banked-
    but-unequipped MC charge is refund-protected (used[aid]=true) while
    genuinely not in use anywhere, a real contradiction. `used` itself is
    untouched below — the refund button's own eligibility logic is a
    separate, correct concern and still needs the broader sense. */
 var active={};
 actionIds.forEach(function(aid){active[aid]=actionHolders(aid).active.length>0;});
 /* v2.16: "scrolling through them is unwieldy" — one button per action
    (a dozen-plus once drops turn random) wrapped into a long flat block.
    Grouped instead, into the two buckets LORE spend already cares about:
    the shared unit-tab row (same selectedUnitTab AETHER/GAMBITS/EQUIPMENT
    already use) picks a unit; a short row below shows just THAT unit's
    2-3 actively-equipped actions; everything nobody currently has
    equipped lives in one <select> under that. renderActionTabs (the old
    flat-row renderer) is retired — this was its only call site. */
 renderUnitTabs(host,function(){renderLore();},true);
 var curUid=currentSelectedUnit(true);
 var equippedIds=unitActiveActions(curUid).filter(function(id){return C.ACTIONS[id];});
 /* Ensure selectedActionTab is valid BEFORE the "which unit does it belong
    to" fixup below — currentSelectedAction() defaults a null/stale value
    to actionIds[0], so this also covers LORE's very first render, not
    just a later re-render with a stale selection. */
 currentSelectedAction(actionIds);
 /* Keep the equipped-row highlight and the dropdown's "selected" state
    honest on every render, not just on a tab click — if the action
    currently shown belongs to some OTHER unit (switched tabs elsewhere,
    or this is the very first render), snap to the newly-current unit's
    own first equipped action instead of leaving the row looking like
    nothing is picked while the panel below shows someone else's action. */
 if(active[selectedActionTab]&&equippedIds.indexOf(selectedActionTab)<0)
  selectedActionTab=equippedIds[0]||selectedActionTab;
 var curDef=null;C.ROSTER.forEach(function(r){if(r.id===curUid)curDef=r;});
 if(equippedIds.length){
  var eqBox=document.createElement('div');eqBox.className='row';
  eqBox.style.cssText='flex-wrap:wrap;margin-bottom:6px';
  eqBox.innerHTML=equippedIds.map(function(aid){var a=C.ACTIONS[aid];
   return '<button class="mini utab'+(aid===selectedActionTab?' on':'')+'" data-a="'+aid+'">'+
    actionGlyph(a)+a.name+rarityTag(a.rarity)+' <span class="tiny">Lv'+actionLevel(aid)+'</span></button>';}).join('');
  host.appendChild(eqBox);
  Array.prototype.forEach.call(eqBox.querySelectorAll('.utab'),function(el){
   el.onclick=function(){selectedActionTab=el.dataset.a;renderLore();};});
 }else{
  host.insertAdjacentHTML('beforeend','<div class="tiny" style="margin-bottom:6px">'+
   (curDef?curDef.name:curUid)+' has nothing equipped.</div>');}
 var unequippedIds=actionIds.filter(function(id){return !active[id];});
 if(unequippedIds.length){
  host.insertAdjacentHTML('beforeend','<label>Unequipped actions</label>');
  var uneqSel=document.createElement('select');uneqSel.id='loreUnequipped';
  uneqSel.style.marginBottom='6px';
  uneqSel.innerHTML=unequippedIds.map(function(id){var a=C.ACTIONS[id];
   return '<option value="'+id+'"'+(id===selectedActionTab?' selected':'')+'>'+
    actionGlyphText(a)+a.name+rarityTagText(a.rarity)+' — Lv'+actionLevel(id)+'</option>';}).join('');
  host.appendChild(uneqSel);
  uneqSel.onchange=function(){selectedActionTab=this.value;renderLore();};
  /* v2.16 FIX: the bulk-refund button used to sit right under the flat
     tab row, so it read as "acting on the list right above it". Moved
     with that list into the grouped layout — it operates on exactly the
     unequipped set this dropdown shows, so it belongs directly under it,
     not buried past it near the Lore-total line where a report came in
     that it looked like it had vanished. */
  if(unusedIds.length)host.insertAdjacentHTML('beforeend',
   '<button class="mini" id="btnRefundLore" style="margin-bottom:8px">'+
   'Refund '+refundTotal+' Lore from '+unusedIds.length+' unused action'+
   (unusedIds.length===1?'':'s')+'</button>');}
 /* "let's also make how much lore I have available to level more
    apparent" — was a single .tiny line easy to miss; now its own
    prominent, colored line matching how AETHER/MARKS/LORE currencies read
    in the purse bar up top. */
 host.insertAdjacentHTML('beforeend','<div style="margin-bottom:6px"><b style="color:var(--lore);font-size:15px">'+
  free+'</b> <span class="tiny">of '+Math.floor(G.lore)+' Lore free — each action\'s next upgrade costs '+
  'one more Lore than its last</span></div>');
 [currentSelectedAction(actionIds)].forEach(function(aid){
  var a=C.ACTIONS[aid];if(!a)return;var b=G.bonuses[aid]||{};
  var holders=actionHolders(aid);
  var box=document.createElement('div');box.className='bon';
  var totalBonus=bonusTotalSummary(aid);
  /* "let's list the descriptions for an action under their name when
     selected" — a.note is the same flavor/mechanical text GAMBITS already
     shows under each slot, just wasn't surfaced here before. */
  var h='<div class="spread"><b>'+(a.isCharge?'⚡ ':'')+actionGlyph(a)+a.name+rarityTag(a.rarity)+' <span class="tiny">Lv'+
   actionLevel(aid)+'</span></b><span class="tiny">cost '+
   Math.round(a.rank*100)+(a.isCharge?' · <b style="color:var(--charge)">gauge '+
    Math.round(C.costOfCharge(a))+'</b>':'')+'</span></div>'+
   (a.note?'<div class="tiny" style="margin-bottom:2px">'+withMcName(a.note)+'</div>':'')+
   '<div class="tiny" style="color:var(--dimmer);margin-bottom:2px">scales with <b>'+scalesWith(a)+
    '</b>'+(a.power?' · power ×'+a.power.toFixed(2):'')+'</div>'+
   '<div class="tiny" style="margin-bottom:2px;color:'+(holders.active.length?'var(--hp)':'var(--dimmer)')+'">'+
    (holders.active.length?'used by '+holders.active.join(', '):'unused')+
    /* "I also don't know if they can be refunded if the action is
       unused" — usedActions() (`used`, computed above) is exactly the
       refund button's own eligibility check, so state it plainly here
       instead of leaving it to guesswork. */
    (holders.active.length?'':(used[aid]?' — not refundable, kept as part of '+mcName()+'\'s charge pool'
     :' — refundable'))+'</div>'+
   (totalBonus?'<div class="tiny" style="color:var(--lore);margin-bottom:3px">Lore total: '+
    totalBonus+'</div>':'')+
   (a.isCharge?'<div class="tiny" style="color:var(--dimmer);margin-bottom:3px">'+
    'Every upgrade here adds +'+C.CHARGE_UP_COST+' to the gauge — it hits harder but '+
    'fires less often. <b>Thrifty</b> buys the cadence back.</div>':'');
  /* v2.4: show ONLY bonuses that can do something to this action. Hiding rather
     than greying — after the merges each action has 3-8 applicable bonuses out of
     9, so the filtered list is short and self-explanatory, whereas greying six
     dead rows on every action is the noise this was meant to remove. */
  var live=Object.keys(C.BONUSES).filter(function(bid){return C.bonusApplies(a,bid);});
  /* v2.9: price is now keyed to the ACTION's total upgrade count (every
     non-broad bonus on it, combined — see actionBonusTotal in core.js), not
     any one bonus's own stack count, so it's computed once per action and
     reused for every bonus row below rather than per-bonus. */
  var totalOnAction=C.actionBonusTotal(b);
  live.forEach(function(bid){
   var inf=C.BONUSES[bid],n=b[bid]||0;
   var price=C.bonusPrice(a,bid,totalOnAction);
   /* Broad is flat (see bonusPrice) and doesn't feed the counter above, so
      it never reads as "escalated" — every other bonus does the moment this
      action already has ANY upgrade on it, regardless of which bonus. */
   var escalated=(bid!=='broad'&&totalOnAction>0);
   /* v2.9 LAYOUT: was a single flex row holding the name, a full sentence of
      description AND three controls. At 375px the description had no min-width:0
      so it refused to shrink, pushing the −/count/+ group off the edge. Now the
      text is its own block and the controls sit on their own right-aligned row,
      which is also what makes the 44px touch targets fit. */
   h+='<div class="bslot">'+
    '<div class="bname">'+inf.n+' <b style="color:var(--crit)">'+price+' Lore</b></div>'+
    '<div class="bdesc">'+inf.d+
     (escalated?' <span style="color:var(--dimmer)">— this action\'s upgrade #'+(totalOnAction+1)+
      '; every upgrade on the same action costs one more.</span>':'')+
     '</div>'+
    '<div class="bctl">'+
     '<button class="mini bm" data-a="'+aid+'" data-b="'+bid+'"'+(n?'':' disabled')+'>−</button>'+
     '<span class="bstack">'+n+'</span>'+
     '<button class="mini bp" data-a="'+aid+'" data-b="'+bid+
      '" data-c="'+price+'"'+(free>=price?'':' disabled')+'>+ '+price+'</button>'+
    '</div></div>';});
  h+='<div class="tiny" style="margin-top:5px;color:var(--dimmer)">'+live.length+' of '+
   Object.keys(C.BONUSES).length+' upgrades apply to this action; the rest would do nothing.</div>';
  box.innerHTML=h;host.appendChild(box);});
 Array.prototype.forEach.call(host.querySelectorAll('.bp'),function(el){el.onclick=function(){
  var a=el.dataset.a,b=el.dataset.b;G.bonuses[a]=G.bonuses[a]||{};
  G.bonuses[a][b]=(G.bonuses[a][b]||0)+1;C.applyBonuses(G.bonuses);renderAll();};});
 Array.prototype.forEach.call(host.querySelectorAll('.bm'),function(el){el.onclick=function(){
  var a=el.dataset.a,b=el.dataset.b;if(!G.bonuses[a])return;
  G.bonuses[a][b]=Math.max(0,(G.bonuses[a][b]||0)-1);
  if(!G.bonuses[a][b])delete G.bonuses[a][b];C.applyBonuses(G.bonuses);renderAll();};});
 var refundBtn=$('#btnRefundLore');
 if(refundBtn)refundBtn.onclick=function(){
  if(!confirm('Refund '+refundTotal+' Lore from '+unusedIds.length+' action'+
   (unusedIds.length===1?'':'s')+' no one currently has equipped?'))return;
  unusedIds.forEach(function(aid){delete G.bonuses[aid];});
  C.applyBonuses(G.bonuses);renderAll();};}
function renderMarks(){
 var host=$('#marksView'),cost=P.pullCost(G.wave);
 var locked=!P.pullsUnlocked(G);
 var h='';
 if(locked){
  h+='<div class="pullbox"><b>Pulls open at wave '+P.MARKS_UNLOCK_WAVE+'.</b>'+
   '<div class="tiny" style="margin-top:4px">Banked <b style="color:var(--marks)">'+
   Math.floor(G.marks)+' Marks</b> — <b style="color:var(--hp)">no cap, nothing '+
   'is being wasted</b> · reached wave '+G.farthest+' of '+P.MARKS_UNLOCK_WAVE+'.</div>'+
   '<div class="tiny">That is '+Math.floor(G.marks/P.MARKS_PER_PULL)+' pull'+
   (Math.floor(G.marks/P.MARKS_PER_PULL)===1?'':'s')+' waiting for you at the unlock.</div>'+
   '<div class="tiny" style="margin-top:6px">The curated run to wave '+P.MARKS_UNLOCK_WAVE+
   ' hands you a specific tool every two waves in a designed order; random pulls arriving '+
   'mid-sequence would cut across it. The bank opens the moment that sequence ends.</div></div>';
 }else{
  var pct2=Math.max(0,Math.min(100,100*G.marks/cost));
  h+='<div class="pullbox"><div class="spread"><b>Pull</b>'+
   '<span class="tiny">'+cost+' Marks each</span></div>'+
   '<div class="bar" style="margin:6px 0"><i style="width:'+pct2+'%;background:var(--marks)"></i></div>'+
   /* v2.9: ONE button. Affordability is the only gate. */
   '<button class="pull" style="width:100%"'+(G.marks>=cost?'':' disabled')+'>PULL — '+cost+
   ' Marks</button>'+
   '<div class="tiny" style="margin-top:6px;color:var(--dimmer)">Rolls across everything: '+
   Math.round(P.PULL_ODDS.action*100)+'% action · '+Math.round(P.PULL_ODDS.cond*100)+
   '% gambit condition · '+Math.round(P.PULL_ODDS.equip*100)+'% equipment · '+
   Math.round(P.PULL_ODDS.unit*100)+'% companion — guaranteed a companion '+
   'every '+P.PULL_PITY_AT+' pulls regardless of odds ('+(G.pullsSinceUnit||0)+'/'+P.PULL_PITY_AT+
   ' since your last one).</div>'+
   '<div class="tiny" style="margin-top:6px">Duplicate actions and gambits convert to '+
   '<b style="color:var(--lore)">Lore</b>; duplicate units convert to '+
   '<b style="color:var(--aether)">Aether</b>; duplicate equipment just adds to your stock — '+
   'own 2 of the same piece to wear it on two hands or two units at once. You OWN every unit '+
   'you pull — the party is the '+P.PARTY_CAP+' you field, and extras stay benched but yours.'+
   (G.party.length>=P.PARTY_CAP?' <b>Party full — new units arrive benched.</b>':'')+
   '</div></div>';
 }
 /* v2.9: removed the "income scales with wave" line — not something the
    player acts on from this screen, and idle rate already has its own
    readout up in #idleRate. */
 host.innerHTML=h;
 Array.prototype.forEach.call(host.querySelectorAll('.pull'),function(el){
  el.onclick=function(){doPull();};});}
/* ===== v2.9 UNIFIED PULL =====
 * ONE pull, ONE cost, rolling across all three categories. The split
 * unit/action/gambit buttons are gone: three parallel economies asked the player
 * to choose a category they had no basis to choose between, and the cost was
 * identical anyway, so the choice carried no information.
 *
 * THE REPORTING BUG THIS ALSO FIXES: doPull previously announced results with
 * sysLog() alone. sysLog writes into #log — the battle log on the FIGHT tab —
 * but pulls are made from the ECONOMY tab, so the player never saw the result.
 * That is why a working pull was indistinguishable from a dead button. Every
 * outcome now goes through pushDrop(), the same banner the curated drops use,
 * which is non-blocking, stacks, and persists until acknowledged. */
/* Equipment (v2.14): "about as rare as units" (Ian) — equip gets the exact
   same 0.10 as unit, action/cond rebalanced down from .45/.45 to keep the
   table summing to 1. */
P.PULL_ODDS={unit:0.10, equip:0.10, action:0.40, cond:0.40};
/* v2.9 PITY: the 10% unit odds above mean a genuinely unlucky run could go
   very long stretches without a companion (the same complaint that drove
   the boss unit-drop above) — guarantee one at least every 30 pulls. Counts
   pulls since the last unit was actually obtained (by luck OR by pity),
   resetting in both outcomes of the 'unit' branch below (a fresh pull or a
   fully-collected-roster Aether conversion) since either way there was
   nothing more this pity cycle could have granted. */
P.PULL_PITY_AT=30;
function doPull(){
 var cost=P.pullCost(G.wave);
 if(!P.pullsUnlocked(G))return;      /* locked during the curated run */
 if(G.marks<cost)return;G.marks-=cost;
 G.pullsSinceUnit=(G.pullsSinceUnit||0)+1;
 var pity=G.pullsSinceUnit>=P.PULL_PITY_AT;
 var roll=G.rng.next(), O=P.PULL_ODDS;
 var kind=pity?'unit':((roll<O.unit)?'unit':
   ((roll<O.unit+O.equip)?'equip':
   ((roll<O.unit+O.equip+O.action)?'action':'cond')));
 if(kind==='unit'){
  G.pullsSinceUnit=0;   /* nothing more this pity cycle could grant, hit or not */
  /* v2.8 BUGFIX kept: filter on OWNED, not party. Collection and party are
     different things — a benched unit is still a real acquisition. */
  var avail=C.ROSTER.filter(function(r){return !G.owned[r.id];});
  if(!avail.length){
   /* Duplicate unit -> Aether. With 5 of a planned 25 units authored this is the
      COMMON case, not an edge case, so it must read as a result. */
   var dup=P.dupUnitAether(G.wave);G.aether+=dup;
   addDropGain(0,dup);}
  else{var pick=P.weightedRosterPick(G.rng,avail);
   var fielded=joinCompanion(pick.id);
   var ca=pick.chargeAction?C.ACTIONS[pick.chargeAction]:null;
   var st=pick.stats,lean=(st.mag>st.atk?'magic':'physical')+
    ', '+(st.def>=25?'sturdy':st.hp>=430?'durable':st.spd>=110?'very fast':'balanced');
   pushDrop({name:pick.name+rarityTag(pick.rarity),kind:pity?'PULL · PITY COMPANION':'PULL · NEW COMPANION',wave:G.wave,
    body:capRole(pick.role)+' · '+pick.row+' row · joins at LV 1 · leans '+lean+
     '<br>ATK '+st.atk+' · MAG '+st.mag+' · DEF '+st.def+' · RES '+st.res+' · SPD '+st.spd+
     (ca?'<br>⚡ Charge action: <b>'+ca.name+'</b> — '+withMcName(ca.note||''):''),
    /* why, not note — the "did this actually join my party" question is the
       whole point of the notification, so it gets the same prominent styling
       curated-teaching moments use, not the dim secondary-aside treatment. */
    why:(fielded?'Fielded immediately. The value is the extra actions per fight, not the stat line.'
      :'<b>Benched</b> — your party of '+P.PARTY_CAP+' is full, but this companion is yours and can be swapped in.')});}
 }else if(kind==='equip'){
  /* Same rule as the wave-drop branch in grantDrops: an equipment dupe is
     never converted to Lore, since owning more copies is genuinely useful
     (dual-wielding a hand item, the same armor on two units). */
  var equipIds=Object.keys(C.EQUIPMENT);
  var eid=P.weightedEquipmentPick(G.rng,equipIds);
  G.equipInv=G.equipInv||{};
  G.equipInv[eid]=(G.equipInv[eid]||0)+1;
  var infoE2=describeEquipment(eid);
  var nOwned2=G.equipInv[eid];
  pushDrop({name:infoE2.name,kind:nOwned2===1?'PULL · NEW EQUIPMENT':'PULL · EQUIPMENT (DUPLICATE)',wave:G.wave,
   body:infoE2.body,
   why:nOwned2===1?'Equip it from the EQUIPMENT tab — no cost.':
    'You now own '+nOwned2+'× '+C.EQUIPMENT[eid].name+' — enough to equip it on more than one slot/unit at once.'});
 }else if(kind==='action'){
  var id=P.weightedActionPick(G.rng,C.EQUIPPABLE);
  G.actionCounts[id]=(G.actionCounts[id]||0)+1;
  var d=describeAction(id);
  if(G.actions.indexOf(id)<0){G.actions.push(id);
   pushDrop({name:d.name,kind:'PULL · NEW ACTION',wave:G.wave,
    body:d.body,note:pairingHint(id)});}
  else{G.lore+=1;
   pushDrop({name:'+1 Lore',kind:'PULL · duplicate action',wave:G.wave,
    body:'Already held, so it converted to <b style="color:var(--lore)">+1 Lore</b> '+
     '— spend it in the LORE tab to upgrade an action you already use.'});}
 }else{
  var cp=C.CONDITIONS.filter(function(c){return c.id!=='none';});
  var c=cp[G.rng.nextInt(cp.length)];
  G.condCounts[c.id]=(G.condCounts[c.id]||0)+1;
  if(G.conditions.indexOf(c.id)<0){G.conditions.push(c.id);
   pushDrop({name:c.label,kind:'PULL · NEW GAMBIT CONDITION',wave:G.wave,
    body:'Tests <b>'+c.label+'</b> — '+(c.group==='Foe'?'reads the enemy side':
      c.group==='Ally'?'reads your own side':c.group==='Self'?'reads the acting unit':'always true')+
     '. Slot it in the GAMBITS tab to gate an action on it.',
    note:'A condition is only worth a slot if the action it gates is WORSE without it.'});}
  else{G.lore+=1;
   pushDrop({name:'+1 Lore',kind:'PULL · duplicate gambit',wave:G.wave,
    body:'Already held, so it converted to <b style="color:var(--lore)">+1 Lore</b>.'});}}
 buildGambits();renderAll();}
/* Absolute clock time for a log entry timestamp — "let's list timestamps
   on messages". Deliberately hour:minute only (no seconds, no date) —
   this is a same-session log, not a long-term history. */
function fmtClock(ts){
 var d=new Date(ts),h=d.getHours(),m=d.getMinutes();
 var ap=h>=12?'PM':'AM';h=h%12;if(h===0)h=12;
 return h+':'+(m<10?'0':'')+m+' '+ap;}
/* Shared by the away/ETA live counters below and by updateExpeditionTimers
   (the ~1s tick near the bottom of this file) — kept as one function so
   the two can never drift out of format agreement with each other. */
/* v2.9: "a live count... not 'about X minutes'" — was rounding to whole
   minutes/hours, so the on-screen text only visibly changed once a
   minute even though updateExpeditionTimers() was already recomputing it
   every second. Reformatted to a real ticking clock (M:SS / H:MM:SS); no
   other change needed — the existing 1s interval already repaints this
   live for both the away and returning states. */
function fmtDur(sec){
 sec=Math.max(0,Math.round(sec));
 var h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60),s=sec%60;
 return (h>0?h+':'+(m<10?'0':'')+m:''+m)+':'+(s<10?'0':'')+s;}
/* v2.9: multiple concurrent expeditions — was a single at-a-glance panel
   (if(exp){...}else{picker}), now zero or more active-expedition boxes
   (one per G.expeditions entry, each with its own live timer span
   #exp-timer-<id> and its own inline log) followed by the send picker,
   shown whenever any benched unit remains — "I want multiple parties to
   be able to go on expeditions in different directions", so the picker no
   longer disappears just because one expedition is already out. */
function renderExpedition(){
 var host=$('#expeditionView');if(!host)return;
 /* v2.9: party allocation moved here from the top of GAMBITS — "let's change
    party allocation to be under expedition." Fielding/benching and sending
    an expedition are both "who's doing what right now" decisions, and
    benched units are exactly the pool an expedition draws from, so the two
    now share a screen instead of a tab hop. See partyRosterHTML/
    wirePartyRoster below (built as a plain string + a separate wiring pass,
    not host.appendChild, since this function already assembles its own
    content as one string and sets host.innerHTML once at the end). */
 var h=partyRosterHTML();
 var returnedCount=0;
 G.expeditions.forEach(function(exp){
  var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
   return d?d.name:uid;}).join(', ');
  var dirLabel=P.DIRECTION_LABELS[exp.direction]||exp.direction;
  h+='<div class="slot" style="margin-bottom:8px"><div class="uname">'+names+
   ' <span class="tiny" style="color:var(--dimmer)">· '+dirLabel+'</span></div>';
  /* v2.9: three states now, not two — "expeditions must be manually
     collected... what they've found isn't added until then." arrivedAt
     set = sitting at home, waiting on the player; homeAt set (not yet
     arrived) = still travelling back; neither = still out exploring. */
  if(exp.arrivedAt){
   returnedCount++;
   h+='<div class="tiny mono" style="margin-top:2px;color:var(--aether)">Returned — ready to collect</div>';
  }else if(exp.homeAt){
   var etaSec=(exp.homeAt-Date.now())/1000;
   h+='<div class="tiny mono" style="margin-top:2px">Heading home — back in '+
    '<span id="exp-timer-'+exp.id+'">'+fmtDur(etaSec)+'</span></div>';
  }else{
   var awaySec=(Date.now()-exp.startedAt)/1000;
   h+='<div class="tiny mono" style="margin-top:2px">Away '+
    '<span id="exp-timer-'+exp.id+'">'+fmtDur(awaySec)+'</span> · reached wave '+exp.ew+'</div>';}
  h+='<div class="tiny mono" style="margin-top:2px">Banked '+Math.round(exp.bank.aether)+
   ' Aether, '+Math.floor(exp.bank.marks)+' Marks so far</div>';
  if(exp.arrivedAt)h+='<button class="mini expedCollect" data-id="'+exp.id+'" style="margin-top:6px">Collect</button>';
  else if(!exp.homeAt)h+='<button class="mini expedRecall" data-id="'+exp.id+'" style="margin-top:6px">Recall party</button>';
  var log=exp.log||[];
  if(log.length){
   h+='<div class="tiny" style="margin-top:8px;color:var(--dimmer)">LOG</div>';
   log.forEach(function(e){h+='<div class="tiny" style="margin-top:2px">'+
    '<span class="mono" style="color:var(--dimmer)">'+fmtClock(e.at)+'</span> '+e.text+'</div>';});}
  h+='</div>';});
 if(returnedCount>=2)h='<button class="mini" id="btnExpedCollectAll" style="margin-bottom:8px">Collect All ('+
  returnedCount+')</button>'+h;
 var bench=benchedUnits();
 mcExpedPick=mcExpedPick.filter(function(uid){return bench.indexOf(uid)>=0;});
 var occupied={};G.expeditions.forEach(function(e){occupied[e.direction]=1;});
 if(mcDirPick&&occupied[mcDirPick])mcDirPick=null;
 if(bench.length){
  h+='<div class="tiny" style="margin-bottom:6px">Send up to '+P.PARTY_CAP+' benched units '+
   'exploring in real time — click to pick them, then choose a direction. The longer they\'re '+
   'out, the harder what they meet gets, and they turn back on their own if hurt too badly. The '+
   'trip home takes half as long as they were out. Up to 8 parties can be out at once, one per '+
   'direction — easier directions pay less, harder ones pay more.</div>';
  bench.forEach(function(uid){
   var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
   var picked=mcExpedPick.indexOf(uid)>=0;
   h+='<div class="slot expick'+(picked?' on':'')+'" data-uid="'+uid+'" style="cursor:pointer">'+
    '<div class="uname">'+(d?d.name:uid)+'</div>'+
    '<div class="tiny">'+(d?capRole(d.role):'')+' · LV '+levelOf(uid)+'</div></div>';});
  h+='<div class="tiny" style="margin-top:8px;margin-bottom:4px;color:var(--dimmer)">DIRECTION</div>';
  h+='<div style="display:flex;flex-wrap:wrap;gap:4px">';
  P.DIRECTIONS.forEach(function(dir,i){
   var busy=!!occupied[dir],picked=mcDirPick===dir;
   var tag=i===0?'easiest':(i===P.DIRECTIONS.length-1?'hardest':'');
   h+='<button class="mini expedDir'+(picked?' on':'')+'" data-dir="'+dir+'"'+
    (busy?' disabled title="Already exploring"':'')+'>'+P.DIRECTION_LABELS[dir]+
    (tag?' · '+tag:'')+'</button>';});
  h+='</div>';
  h+='<button class="mini" id="btnExpedSend" style="margin-top:8px"'+
   (mcDirPick?'':' disabled title="Choose a direction first"')+'>Send expedition ('+
   mcExpedPick.length+'/'+P.PARTY_CAP+')</button>';
 }else if(!G.expeditions.length){
  h+='<div class="tiny">No benched units — everyone owned is already fielded.</div>';}
 host.innerHTML=h;
 wirePartyRoster(host);
 Array.prototype.forEach.call(host.querySelectorAll('.expick'),function(el){
  el.onclick=function(){var uid=el.dataset.uid,i=mcExpedPick.indexOf(uid);
   if(i>=0)mcExpedPick.splice(i,1);
   else if(mcExpedPick.length<P.PARTY_CAP)mcExpedPick.push(uid);
   renderExpedition();};});
 Array.prototype.forEach.call(host.querySelectorAll('.expedDir'),function(el){
  el.onclick=function(){mcDirPick=el.dataset.dir;renderExpedition();};});
 var sendBtn=$('#btnExpedSend');
 if(sendBtn)sendBtn.onclick=function(){
  if(sendExpedition(mcExpedPick,mcDirPick)){mcExpedPick=[];mcDirPick=null;renderAll();}};
 Array.prototype.forEach.call(host.querySelectorAll('.expedRecall'),function(el){
  el.onclick=function(){recallExpedition(el.dataset.id);renderAll();};});
 Array.prototype.forEach.call(host.querySelectorAll('.expedCollect'),function(el){
  el.onclick=function(){collectExpedition(el.dataset.id);renderAll();};});
 var collectAllBtn=$('#btnExpedCollectAll');
 if(collectAllBtn)collectAllBtn.onclick=function(){
  G.expeditions.filter(function(e){return e.arrivedAt;}).forEach(function(e){collectExpedition(e.id);});
  renderAll();};}
/* v2.9: the ~1s live-counter tick — "a live count of how long they've been
   out as well as how long until they return". Deliberately patches ONLY
   the timer spans' textContent, never calls renderExpedition() itself —
   a full rebuild every second would tear the picker/recall buttons out
   from under an in-progress click the same way the pre-fix tick() loop
   used to during travel (see doStep()/renderTick() above). No-ops
   instantly when the EXPEDITION tab isn't the visible one, or when
   nothing is out. */
function updateExpeditionTimers(){
 if(!G.expeditions.length)return;
 var panel=$('#tab-expedition');if(!panel||panel.classList.contains('hidden'))return;
 G.expeditions.forEach(function(exp){
  var el=document.getElementById('exp-timer-'+exp.id);if(!el)return;
  el.textContent=exp.homeAt?fmtDur((exp.homeAt-Date.now())/1000):fmtDur((Date.now()-exp.startedAt)/1000);});}
/* Resolves an already-discovered dungeon headlessly, against the CURRENT
   main party at full HP — same C.setWave()-bracket-and-restore pattern
   every other frozen/side fight in this file uses, so K_of()'s mitigation
   math uses the dungeon's OWN frozen discovery-wave, not whatever G.wave
   the player's real road progress happens to be at. Rewards are sized off
   that same frozen wave, not G.wave — otherwise discovering an easy early
   dungeon and farming it forever would silently inflate with the road's
   own difficulty, defeating the point of a frozen fight. No cost to
   attempt, no penalty on a loss — just try again any time. */
function enterDungeon(id){
 if(G.sideBattle)return;
 var dungeon=null;G.dungeons.forEach(function(d){if(d.id===id)dungeon=d;});
 if(!dungeon)return;
 var wave0=dungeon.waves[0];
 startSideBattle(unitsFromSnapshots(wave0.enemies),wave0.wave,
  {kind:'dungeon',dungeonId:id,name:dungeon.name,direction:dungeon.direction,tier:dungeon.tier,
   waveIndex:0,totalWaves:dungeon.waves.length});}
/* Resolves one companion's next quest stage headlessly against the
   current main party at full HP — that companion must already be
   fielded (validated again here, not just via the disabled button, in
   case state changed between render and click). The stage's enemies are
   baked into G.quests[uid].frozen[stage] on FIRST attempt (win OR lose)
   and reused on every retry after — "static difficulty" applies the same
   way it does to a discovered dungeon, just pinned to first ATTEMPT
   rather than acquisition, so a companion attempted long after being
   acquired still gets an approachable early stage instead of whatever
   wave the player is actually on. */
function attemptQuestStage(uid){
 if(G.sideBattle)return;
 var q=G.quests[uid];
 if(!q||q.stage>=5)return;
 if(G.party.indexOf(uid)<0)return;
 var line=P.QUEST_LINES[uid];if(!line)return;
 var stage=q.stage,step=line[stage],story=withMcName(step.story);
 q.frozen=q.frozen||[];
 /* Baked once, at first attempt — wave AND enemy stats both frozen then,
    so a later retry (after a loss, possibly with the player's power level
    having moved on) replays the exact same fight, never a re-scaled one. */
 if(!q.frozen[stage]){
  var rawWave=P.questStageWave(G,uid,stage);
  /* A boss stage (step.isBoss — farroadquests.csv, defaults TRUE only on
     stage 5 but isn't locked there) rounds UP to the nearest boss wave so
     buildEnemies() takes its single-powerful-enemy path, the same trick
     unlockDirectionDungeon() uses for a dungeon's own final wave. Only a
     small nudge off rawWave (boss waves land every 20 past wave 20), not
     a difficulty change beyond swapping the composition. */
  var wave=step.isBoss?P.nextBossWave(rawWave-1):rawWave;
  var fresh=buildEnemies(wave,true);
  q.frozen[stage]={wave:wave,enemies:fresh.map(bakeEnemySnapshot)};}
 var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
 var name=def?def.name:uid;
 startSideBattle(unitsFromSnapshots(q.frozen[stage].enemies),q.frozen[stage].wave,
  {kind:'quest',uid:uid,stage:stage,name:name,story:story});}
/* v2.10: lets the player back out of a quest attempt already in progress
   instead of waiting for the auto-battle to actually lose — same 'enemy'
   outcome finishSideBattle already grants for a real defeat (no stage
   advance, no penalty), just honestly worded as a give-up rather than a
   loss. Scoped to quests only, not dungeons — Ian's ask. */
function giveUpQuest(){
 if(!G.sideBattle||G.sideBattle.meta.kind!=='quest')return;
 finishSideBattle('enemy',true);}
/* "Let's add discoverable dungeons... repeated by the main party" +
   "quest lines of 5 battles for each new unit." One tab, two sections —
   both are main-party content, distinct from EXPEDITION's benched-party
   focus. */
function renderQuests(){
 var host=$('#questsView');if(!host)return;
 var busy=!!G.sideBattle;   /* a live side battle is already running — see startSideBattle() */
 var h='<div class="tiny" style="margin-bottom:4px;color:var(--dimmer)"><b>DUNGEONS</b> ('+
  G.dungeons.length+')</div>';
 if(!G.dungeons.length){
  h+='<div class="tiny">None yet — each direction unlocks its own dungeons as '+
   'expeditions push deeper into it.</div>';
 }else{
  G.dungeons.forEach(function(d){
   h+='<div class="slot" style="margin-bottom:6px"><div class="uname">'+d.name+'</div>'+
    '<div class="tiny mono" style="margin-top:2px">'+d.waves.length+' wave'+(d.waves.length===1?'':'s')+
     ' (ends in a boss) · cleared '+d.clears+' time'+(d.clears===1?'':'s')+'</div>'+
    '<button class="mini questEnter" data-id="'+d.id+'" style="margin-top:6px"'+
     (busy?' disabled title="A battle is already in progress"':'')+'>Enter</button></div>';});}
 h+='<hr><div class="tiny" style="margin-bottom:4px;color:var(--dimmer)"><b>COMPANION QUESTS</b></div>';
 var active=Object.keys(G.owned).filter(function(uid){return G.quests[uid]&&G.quests[uid].stage<5;});
 if(!active.length){
  h+='<div class="tiny">Nothing in progress.</div>';
 }else{
  active.forEach(function(uid){
   var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
   var name=def?def.name:uid, stage=G.quests[uid].stage, fielded=G.party.indexOf(uid)>=0;
   /* v2.10: the row for the quest actually being fought right now gets a
      Give Up button instead of the (disabled, since busy) Attempt one. */
   var isThisFight=busy&&G.sideBattle.meta.kind==='quest'&&G.sideBattle.meta.uid===uid;
   var btn=isThisFight
    ?'<button class="mini questGiveUp" data-uid="'+uid+'" style="margin-top:6px">Give up</button>'
    :('<button class="mini questAttempt" data-uid="'+uid+'" style="margin-top:6px"'+
      (!fielded?' disabled title="'+name+' must be in your fielded party to attempt their own quest"':
       (busy?' disabled title="A battle is already in progress"':''))+'>Attempt</button>');
   h+='<div class="slot" style="margin-bottom:6px"><div class="uname">'+name+'</div>'+
    '<div class="tiny mono" style="margin-top:2px">Stage '+(stage+1)+' of 5 · +'+
    P.questStageAether(stage)+' Aether on clear</div>'+btn+'</div>';});}
 host.innerHTML=h;
 Array.prototype.forEach.call(host.querySelectorAll('.questEnter'),function(el){
  el.onclick=function(){enterDungeon(el.dataset.id);renderAll();};});
 Array.prototype.forEach.call(host.querySelectorAll('.questAttempt'),function(el){
  el.onclick=function(){attemptQuestStage(el.dataset.uid);renderAll();};});
 Array.prototype.forEach.call(host.querySelectorAll('.questGiveUp'),function(el){
  el.onclick=function(){giveUpQuest();renderAll();};});}
function renderEconomy(){renderPurse();renderAether();renderEquipment();renderLore();renderMarks();renderExpedition();renderQuests();}
function renderAll(){renderHead();renderPowerLevel();renderUnits();renderRail();renderEconomy();renderDropNote();autoSave();}
/* Lighter sibling of renderAll(), for the ordinary per-beat path in
   doStep()/tick() only — see the comment there. Skips renderEconomy()'s
   heavy per-tab rebuilds (AETHER/LORE/MARKS/EXPEDITION) in favor of just
   renderPurse() (cheap textContent updates, no DOM replacement), since
   nothing an ordinary combat beat does changes what those tabs show. */
function renderTick(){renderHead();renderPowerLevel();renderUnits();renderRail();renderPurse();renderDropNote();autoSave();}

/* ------------------------------------------------------------- gambits --- */
/* ===== PARTY ROSTER EDITOR =====
 * Was no way to change who's fielded at all — G.party only ever changed via
 * the boss-milestone auto-join and a pull auto-fielding when there was room
 * (doPull() in this file). v2.9: moved from the top of GAMBITS onto
 * EXPEDITION (see renderExpedition) — fielding/benching and sending an
 * expedition are both "who's doing what right now" decisions, and benched
 * units are exactly the pool an expedition draws from. */
function availableForParty(){
 return Object.keys(G.owned).filter(function(uid){return G.party.indexOf(uid)<0&&!isOnExpedition(uid);});}
function benchUnit(uid){
 if(G.party.length<=1)return false;             /* never allow an empty party */
 var i=G.party.indexOf(uid);if(i<0)return false;
 G.party.splice(i,1);
 return true;}
function fieldUnit(uid){
 if(!G.owned[uid]||G.party.indexOf(uid)>=0)return false;
 if(isOnExpedition(uid))return false;   /* away units aren't available */
 if(G.party.length>=P.PARTY_CAP)return false;
 G.party.push(uid);
 autoEquip();                                    /* same default-rule pass a pull/boss-join gets */
 return true;}
/* ===== PER-CHARACTER SUB-TABS (v2.9) =====
 * GAMBITS/AETHER/LORE each used to stack one box per fielded unit, so a
 * full 5-unit party meant scrolling through 5x the content on every tab —
 * "playing now requires a lot of scrolling", especially on a phone. One
 * shared selectedUnitTab (UI-only, not saved, same treatment as speed/
 * mcExpedPick elsewhere in this file) drives all three: switching units on
 * one tab keeps that same unit selected if you flip to another. */
var selectedUnitTab=null;
/* v2.9: AETHER/LORE went back to this same tab pattern (were briefly a
   compact all-units list) — "let's change the UI for aether and lore to be
   like gambits with the tabs." Both now pass includeBenched=true so the
   "benched units are reachable, not just fielded ones" capability from
   that compact pass isn't lost in the revert; GAMBITS' own call sites are
   unchanged (omit the arg -> fielded-only, exactly as before), since
   configuring gambit slots only matters for units actually in a fight. */
function unitTabPool(includeBenched){return includeBenched?Object.keys(G.owned):G.party;}
function currentSelectedUnit(includeBenched){
 var pool=unitTabPool(includeBenched);
 if(!selectedUnitTab||pool.indexOf(selectedUnitTab)<0)selectedUnitTab=pool[0];
 return selectedUnitTab;}
function renderUnitTabs(host,onChange,includeBenched){
 var pool=unitTabPool(includeBenched);
 var box=document.createElement('div');box.className='row';
 box.style.cssText='flex-wrap:wrap;margin-bottom:8px';
 var cur=currentSelectedUnit(includeBenched),h='';
 pool.forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var benchTag=(includeBenched&&G.party.indexOf(uid)<0)?
   (isOnExpedition(uid)?' <span class="tiny">(expedition)</span>':' <span class="tiny">(bench)</span>'):'';
  h+='<button class="mini utab'+(uid===cur?' on':'')+'" data-u="'+uid+'">'+
   (def?def.name+rarityTag(def.rarity):uid)+benchTag+'</button>';});
 box.innerHTML=h;host.appendChild(box);
 Array.prototype.forEach.call(box.querySelectorAll('.utab'),function(el){
  el.onclick=function(){selectedUnitTab=el.dataset.u;onChange();};});}
/* ===== SELECTED ACTION (LORE) =====
 * v2.16: which action's Lore panel is currently shown. Originally driven
 * by a flat per-action tab row (one button per action, active ones
 * starred) — retired in favor of grouping by unit (renderLore's own
 * equipped-row + unequipped <select>, see unitActiveActions above), since
 * the flat row became an unwieldy scroll once a run had a dozen-plus
 * actions. selectedActionTab itself is unchanged: still independent from
 * selectedUnitTab (LORE's grouping reads the unit tab to decide WHICH
 * action row to show, but the actual open panel is still just one id). */
var selectedActionTab=null;
function currentSelectedAction(actionIds){
 if(!selectedActionTab||actionIds.indexOf(selectedActionTab)<0)selectedActionTab=actionIds[0];
 return selectedActionTab;}
/* "level" = total Lore upgrades an action has, escalating (Swift/Potent/
   etc, via actionBonusTotal — the same count bonusPrice uses to escalate
   cost, and the "this action's upgrade #N" line shows) PLUS Broad, which
   is flat-priced and doesn't feed the escalating counter but is still a
   real Lore upgrade spent on this action — "leveling up broad does not
   level up the action; it should count towards its level." Pricing itself
   is untouched (bonusPrice/actionBonusTotal still exclude broad on
   purpose, for the escalation math) — only this display number changes. */
function actionLevel(aid){var b=G.bonuses[aid]||{};return C.actionBonusTotal(b)+(b.broad||0);}
/* Returns a plain HTML string rather than appending to a host directly —
   renderExpedition() (its one call site) already assembles its own content
   as a single string and sets host.innerHTML once, so this needs to slot
   into that same pattern rather than doing its own DOM manipulation.
   wirePartyRoster(host) below attaches the click handlers afterward, once
   the combined innerHTML is actually in the DOM. */
function partyRosterHTML(){
 var h='<div style="margin-bottom:14px"><div class="tiny" style="margin-bottom:6px"><b>PARTY</b> — '+
  G.party.length+' of '+P.PARTY_CAP+' fielded. Changes take effect on the next wave, not the one in progress.</div>';
 G.party.forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  h+='<div class="slot" style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">'+
   '<span><span class="uname p">'+(def?def.name:uid)+'</span> <span class="tiny">'+(def?capRole(def.role):'')+
   ' · LV '+levelOf(uid)+'</span></span>'+
   '<button class="mini pb-bench" data-u="'+uid+'"'+(G.party.length<=1?' disabled':'')+'>Bench</button></div>';});
 var avail=availableForParty();
 h+='<div class="tiny" style="margin:8px 0 4px;color:var(--dimmer)">BENCHED'+
  (avail.length?'':' — none available')+'</div>';
 avail.forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  h+='<div class="slot" style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">'+
   '<span><span class="uname">'+(def?def.name:uid)+'</span> <span class="tiny">'+(def?capRole(def.role):'')+
   ' · LV '+levelOf(uid)+'</span></span>'+
   '<button class="mini pb-field" data-u="'+uid+'"'+(G.party.length>=P.PARTY_CAP?' disabled':'')+'>Field</button></div>';});
 return h+'</div>';}
function wirePartyRoster(host){
 Array.prototype.forEach.call(host.querySelectorAll('.pb-bench'),function(el){
  el.onclick=function(){if(benchUnit(el.dataset.u)){buildGambits();renderAll();}};});
 Array.prototype.forEach.call(host.querySelectorAll('.pb-field'),function(el){
  el.onclick=function(){var uid=el.dataset.u;
   if(fieldUnit(uid)){buildGambits();renderAll();renderFieldConflicts(uid);}};});}
function buildGambits(){
 var host=$('#gambits');host.innerHTML='';
 /* v2.9: one unit's gambit box at a time, picked by the shared unit-tab
    selector, instead of stacking all of G.party's boxes vertically —
    "playing now requires a lot of scrolling" with a full party. Everything
    below is unchanged from the per-unit render it always was; only the
    outer iteration (G.party.forEach -> a single selected uid) changed.
    v2.9 BUGFIX: now includes benched units — "I still can't update
    gambits for benched units." A benched unit's loadout (G.loadout[uid])
    is real, persistent state regardless of fielded status (ensureLoadout/
    syncLoadout already only key off uid, no G.party dependency — editing
    one was always safe, just unreachable through this tab). This also
    fixes a second, related bug: since selectedUnitTab is shared with
    AETHER/LORE (which already included benched units), this tab's
    fielded-only pool would silently reset the shared selection back to a
    fielded unit (reads as "the tab switches to the MC") the moment
    buildGambits() ran after leveling a benched unit on AETHER — both
    tabs now agree on the same pool, so there's nothing to reset. */
 renderUnitTabs(host,function(){buildGambits();},true);
 /* v2.9: condition dropdown sorted by TYPE (group), not the order each one
    was acquired in — with dozens of conditions now (the 10%-HP-ladder
    addition above especially), acquisition order made a specific one hard
    to find. GROUP_ORDER puts the always-true 'none' entry first, then
    Self/Ally/Foe; within a group, original CONDITIONS array order is kept
    (a stable sort) since that already roughly sub-clusters by theme. */
 var GROUP_ORDER={'':0,Self:1,Ally:2,Foe:3};
 function sortedOwnedConditions(){
  var idx={};C.CONDITIONS.forEach(function(c,i){idx[c.id]=i;});
  return G.conditions.slice().sort(function(a,b){
   var ca=C.condById(a),cb=C.condById(b);
   var ga=GROUP_ORDER[ca.group]!=null?GROUP_ORDER[ca.group]:9;
   var gb=GROUP_ORDER[cb.group]!=null?GROUP_ORDER[cb.group]:9;
   if(ga!==gb)return ga-gb;
   return idx[a]-idx[b];});}
 [currentSelectedUnit(true)].forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var fielded=G.party.indexOf(uid)>=0;
  var sl=ensureLoadout(uid);
  var box=document.createElement('div');box.style.marginBottom='12px';
  box.innerHTML='<div class="spread" style="margin-bottom:4px"><span class="uname'+(fielded?' p':'')+'">'+def.name+
   ' <span class="tiny">'+capRole(def.role)+(fielded?'':(isOnExpedition(uid)?' · on expedition':' · benched'))+
   '</span></span><span class="tiny">'+G.actions.length+' actions</span></div>'+
   (fielded?'':'<div class="tiny" style="color:var(--dimmer);margin-bottom:6px">Changes apply at the start of each combat.</div>');
  var ownedConds=sortedOwnedConditions();
  sl.forEach(function(s,i){
   var w=document.createElement('div');w.className='slot';
   /* reorder controls get their own row so they are not squeezed by the label */
   var co='';
   ownedConds.forEach(function(cid){var c=C.condById(cid);
    co+='<option value="'+cid+'"'+(cid===s.cond?' selected':'')+'>'+c.label+'</option>';});
   var ao='';
   G.actions.forEach(function(aid){
    var holder=(aid!==s.action)?actionHolderInParty(aid,uid):null;
    /* v2.9: "benched units aren't counted towards action allocation, so
       multiple benched units can have the same actions" — a benched-vs-
       benched match isn't an active exploit (only fielded units fight),
       so it's surfaced as a tag/warning here, never disabled — only a
       FIELDED holder blocks the option. */
    var benchHolder=(!holder&&aid!==s.action)?benchedActionHolder(aid,uid):null;
    var dis=holder?' disabled title="'+C.ACTIONS[aid].name+' is equipped by '+holder+' — non-starter actions can only be used by one unit at a time"':'';
    var tag=holder?' (used by '+holder+')':(benchHolder?' (also held by '+benchHolder+', benched)':'');
    ao+='<option value="'+aid+'"'+(aid===s.action?' selected':'')+dis+'>'+actionGlyphText(C.ACTIONS[aid])+C.ACTIONS[aid].name+rarityTagText(C.ACTIONS[aid].rarity)+tag+'</option>';});
   /* v2.16: the passive "also equipped by X from before this rule" notice
      that used to live here is retired — a conflict now surfaces actively,
      at the moment it's created, via the Field-time popup
      (renderFieldConflicts) instead of waiting to be noticed on whichever
      slot happens to have it next time this screen is opened. The <select>
      above still disables/tags a conflicting OPTION (that's prevention —
      it stops a manual edit here from CREATING a new conflict — a
      different job from the retired notice, which was after-the-fact
      disclosure of one that already existed). */
   w.innerHTML='<div class="slotbar"><span class="lbl">SLOT '+(i+1)+' — IF</span>'+
     '<button class="mini mv up" aria-label="move up">▲</button>'+
     '<button class="mini mv dn" aria-label="move down">▼</button></div>'+
    '<select class="cs">'+co+'</select>'+
    '<label style="margin-top:8px">THEN</label><select class="as">'+ao+'</select>'+
    '<div class="tiny" style="margin-top:6px">initiative '+initTag(C.ACTIONS[s.action].rank)+
     ' <span style="color:var(--dimmer)">— higher acts more often</span></div>'+
    '<div class="tiny" style="margin-top:2px;color:var(--dimmer)">scales with <b>'+
     scalesWith(C.ACTIONS[s.action])+'</b>'+(C.ACTIONS[s.action].power?
     ' · power ×'+C.ACTIONS[s.action].power.toFixed(2):'')+'</div>'+
    '<div class="tiny" style="margin-top:2px">'+withMcName(C.ACTIONS[s.action].note||'')+'</div>';
   var up=w.querySelector('.up'),dn=w.querySelector('.dn');
   if(i===0)up.disabled=true;
   if(i===sl.length-1)dn.disabled=true;
   up.onclick=function(){if(i===0)return;var t=sl[i-1];sl[i-1]=sl[i];sl[i]=t;
    G.touched=G.touched||{};G.touched[uid]=true;syncLoadout(uid);buildGambits();renderAll();};
   dn.onclick=function(){if(i===sl.length-1)return;var t=sl[i+1];sl[i+1]=sl[i];sl[i]=t;
    G.touched=G.touched||{};G.touched[uid]=true;syncLoadout(uid);buildGambits();renderAll();};
   w.querySelector('.cs').onchange=function(){s.cond=this.value;
    G.touched=G.touched||{};G.touched[uid]=true;syncLoadout(uid);buildGambits();renderAll();};
   w.querySelector('.as').onchange=function(){s.action=this.value;
    G.touched=G.touched||{};G.touched[uid]=true;syncLoadout(uid);buildGambits();renderAll();};
   box.appendChild(w);});
  /* ITEM 6: the unit's CHARGE ACTION, shown where loadout decisions are made.
     13 charge actions with no comparison surface was worse than 5. */
  /* Swappable — MC only (roadmap item 2). Every other unit stays locked to
     def.chargeAction, same as always; only the player-built 'kesh' has a
     pool to choose from at all. This replaces a dead branch that read
     `G.chargeAction`, a field nothing ever set — the v0.8 file used `cfg`,
     v0.9 renamed the game state to `G` and this line was never updated, so
     it always silently fell through to def.chargeAction. */
  var mcOwns=(uid==='kesh'&&G.mc&&G.mc.acquiredCharges&&G.mc.acquiredCharges.length);
  var ca=mcOwns?G.mc.chargeAction:def.chargeAction;
  if(ca&&C.ACTIONS[ca]){
   var a=C.ACTIONS[ca];
   var chargePerTurn=22;                       /* typical basic-action charge gain */
   var turnsToFill=Math.max(1,Math.ceil(100/chargePerTurn));
   var shape=(a.tk==='allFoes'?'all foes':a.tk==='allAllies'?'whole party':
              a.tk==='ally'?'one ally':a.tk==='self'?'self':
              a.tk==='deadAlly'?'a fallen ally':'one foe');
   var kind=a.heal?'heal':a.revive?'revive':(a.power?'damage':'effect');
   var cbox=document.createElement('div');cbox.className='slot';
   cbox.style.borderColor='var(--charge)';
   var swappable=mcOwns&&G.mc.acquiredCharges.length>1;
   var nameRow=swappable?
    '<select class="mcc-swap mono" style="margin-top:2px;color:var(--charge);border-color:var(--charge)">'+
     G.mc.acquiredCharges.map(function(id){var ai=C.ACTIONS[id];
      return '<option value="'+id+'"'+(id===ca?' selected':'')+'>'+(ai?actionGlyphText(ai)+ai.name+rarityTagText(ai.rarity):id)+'</option>';}).join('')+
     '</select>'
    :'<div class="uname" style="color:var(--charge);margin-top:2px">'+actionGlyph(a)+a.name+rarityTag(a.rarity)+'</div>';
   cbox.innerHTML='<div class="spread"><span class="lbl" style="color:var(--charge)">'+
     '⚡ CHARGE ACTION</span><span class="tiny">'+initTag(a.rank)+'</span></div>'+
    nameRow+
    '<div class="tiny" style="margin-top:4px">hits <b>'+shape+'</b> · '+kind+
     (a.power?' ×'+a.power:'')+(a.applies?' · applies <b>'+a.applies+'</b> '+(a.turns||3)+' turns':'')+
     (a.revive?' at '+Math.round(a.revive*100)+'% HP':'')+
     (a.lifesteal?' · heals you '+Math.round(a.lifesteal*100)+'% of it':'')+
     (a.hits>1?' · '+a.hits+' hits':'')+'</div>'+
    '<div class="tiny" style="margin-top:4px;color:var(--dimmer)">fills in roughly <b>'+
     turnsToFill+'</b> of this unit’s turns · '+withMcName(a.note||'')+'</div>'+
    (swappable?'<div class="tiny" style="margin-top:2px;color:var(--dim)">'+
     G.mc.acquiredCharges.length+' charge actions acquired — swap freely, no cost. Lore '+
     'upgrades are kept per action, so switching back restores any you bought.</div>':'');
   box.appendChild(cbox);
   if(swappable)cbox.querySelector('.mcc-swap').onchange=function(){
    G.mc.chargeAction=this.value;applyCustomMC();
    /* applyCustomMC() only updates the ROSTER TEMPLATE — buildParty() copies
       chargeAction onto the live unit once, at wave start, so a fight already
       in progress would otherwise keep firing the old action until the next
       wave. Patch the live unit directly so a swap takes effect immediately,
       matching "swap freely, no cost" rather than "on your next wave". */
    if(G.units)G.units.forEach(function(u){if(u.id==='kesh')u.chargeAction=G.mc.chargeAction;});
    buildGambits();renderAll();};}
  host.appendChild(box);});}
function syncLoadout(uid){
 if(!G.units)return;
 G.units.forEach(function(u){if(u.id===uid)
  u.slots=G.loadout[uid].map(function(s){return {cond:s.cond,action:s.action};});});}
/* Non-starter actions get shared-across-the-party Lore uplift for free if
   more than one FIELDED unit equips the same id — every unit using it
   benefits from a single escalating-cost purchase. Starters (strike/ember,
   P.STARTER_ACTIONS) are exempt since every unit begins with them anyway;
   restricting those too would leave new/underinvested units with nothing
   usable. Returns the display name of the other fielded unit already
   holding aid, or null if aid is free (or is itself a starter). */
function actionHolderInParty(aid,excludeUid){
 if(P.STARTER_ACTIONS.indexOf(aid)>=0)return null;
 var holder=null;
 G.party.forEach(function(uid){if(uid===excludeUid||holder)return;
  var sl=G.loadout[uid];if(!sl)return;
  sl.forEach(function(s){if(s.action===aid){var def=null;
   C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
   holder=def?def.name:uid;}});});
 return holder;}
/* Companion to actionHolderInParty above, scanning BENCHED owned units
   only — "benched units aren't counted towards action allocation, so
   multiple benched units can have the same actions." Two benched units
   sharing a non-starter action isn't an active Lore-sharing exploit (only
   fielded units fight), so this is surfaced as a warning/tag only,
   everywhere it's checked — never disables an option or blocks a save,
   unlike actionHolderInParty's fielded-vs-fielded case. */
function benchedActionHolder(aid,excludeUid){
 if(P.STARTER_ACTIONS.indexOf(aid)>=0)return null;
 var holder=null;
 Object.keys(G.owned).forEach(function(uid){
  if(uid===excludeUid||holder||G.party.indexOf(uid)>=0)return;
  var sl=G.loadout[uid];if(!sl)return;
  sl.forEach(function(s){if(s.action===aid){var def=null;
   C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
   holder=def?def.name:uid;}});});
 return holder;}
/* ===== FIELD CONFLICT POPUP (v2.16) =====
 * "rather than have a notice that an action is equipped by another unit
 * on the action, have there be a pop-up if you try to put two units in
 * the party with the same actions." GAMBITS' <select> already disables a
 * conflicting option and shows a passive warning if you happen to open
 * that unit's own slot editor — but nothing stopped fielding a unit whose
 * SAVED loadout (or a fresh autoEquip pick that happens to land on the
 * same GATE_FOR action as someone already fielded) collided with a
 * unit already in the party, and nothing surfaced it until you noticed.
 * This is the one deliberate exception to "no blocking modals" — it only
 * ever opens in direct response to a Field click, never on a timer, so
 * it doesn't fight the reason drop notices stay non-blocking. */
function renderFieldConflicts(uid){
 var modal=$('#conflictModal'),host=$('#conflictModalBody');
 var sl=G.loadout[uid]||[];
 var conflicts=[];
 sl.forEach(function(s,i){
  var holder=actionHolderInParty(s.action,uid);
  if(holder)conflicts.push({i:i,action:s.action,holder:holder});});
 if(!conflicts.length){modal.classList.add('hidden');return;}
 var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
 var h='<div class="spread" style="margin-bottom:6px"><b>Action conflict</b></div>'+
  '<div class="tiny" style="margin-bottom:10px">'+(def?def.name:uid)+' shares a non-starter action '+
  'with someone already in your party — only one fielded unit can use it at a time. Leaving it as-is '+
  'is not just a warning: '+(def?def.name:uid)+' will skip that slot in battle rather than fire a '+
  'copy of an action someone else already fields. Pick a different one for each slot below, or leave '+
  'it and sort it out later from GAMBITS.</div>';
 conflicts.forEach(function(c){
  var a=C.ACTIONS[c.action];
  var opts=G.actions.map(function(aid){
   var otherHolder=(aid===c.action)?null:actionHolderInParty(aid,uid);
   var dis=otherHolder?' disabled':'';
   return '<option value="'+aid+'"'+(aid===c.action?' selected':'')+dis+'>'+
    actionGlyphText(C.ACTIONS[aid])+C.ACTIONS[aid].name+rarityTagText(C.ACTIONS[aid].rarity)+
    (otherHolder?' (used by '+otherHolder+')':'')+'</option>';}).join('');
  h+='<div class="slot" style="margin-bottom:8px">'+
   '<div class="tiny" style="margin-bottom:3px">Slot '+(c.i+1)+': <b>'+a.name+'</b> — also used by <b>'+c.holder+'</b></div>'+
   '<select class="cfSel" data-i="'+c.i+'">'+opts+'</select></div>';});
 h+='<button class="mini" id="cfDismiss">Field anyway (conflicting slots won\'t fire)</button>';
 host.innerHTML=h;
 modal.classList.remove('hidden');
 Array.prototype.forEach.call(host.querySelectorAll('.cfSel'),function(el){
  el.onchange=function(){
   var i=parseInt(el.dataset.i,10);
   G.loadout[uid][i].action=this.value;
   G.touched=G.touched||{};G.touched[uid]=true;   /* never let autoEquip silently override this fix */
   syncLoadout(uid);
   buildGambits();renderAll();
   renderFieldConflicts(uid);   /* re-scan: fixing one slot may resolve everything, or leave others */
  };});
 $('#cfDismiss').onclick=function(){modal.classList.add('hidden');};}

/* --------------------------------------------------------------- tests --- */
function tCadence(){
 var held={},bad=[],out=['CURATED CADENCE — every condition must gate something already held',''];
 P.STARTER_ACTIONS.forEach(function(a){held[a]=1;});
 var GATES={foe_lacks_debuff:['sear','hex','cripple','smother','daunt'],
  foe_armoured:['ember','hex','pierce'],ally_lacks_buff:['bulwark','brace'],
  self_hp_lte_50:['mend','bulwark','brace'],foe_fast:['cripple','daunt'],
  ally_hp_lte_60:['mend'],foe_lowest_hp:['strike','ember','sear','hex','execute'],
  foe_highest_hp:['cleave','gale','daunt'],foe_hp_gte_70:['cleave','gale']};
 P.CURATED.forEach(function(d){
  if(d.kind==='action'){held[d.id]=1;out.push('w'+d.w+'  ACTION  '+C.ACTIONS[d.id].name+'  ['+d.cat+']');return;}
  var g=(GATES[d.id]||[]).filter(function(a){return held[a];});
  out.push('w'+d.w+'  cond    '+d.id+'  → gates: '+(g.length?g.join(', '):'*** NOTHING ***'));
  if(!g.length)bad.push('w'+d.w);});
 out.push('');out.push('dead drops: '+(bad.length?bad.join(', '):'NONE'));
 out.push('hand at boss: '+(P.STARTER_ACTIONS.length+P.CURATED.filter(function(d){return d.kind==='action';}).length)+
  ' actions, '+(1+P.CURATED.filter(function(d){return d.kind==='cond';}).length)+' conditions');
 return out;}
function tRamp(){
 var o=['ENEMY-COUNT RAMP (v0.9, retuned)',''];
 for(var w=1;w<=26;w+=1){if(w%2)continue;o.push('  wave '+(w<10?' ':'')+w+' : '+P.enemyCount(w)+
  (w===15?'   <- the 2-enemy step. Solo cannot pass it; this is why the boss is at 20.':''));}
 o.push('');o.push('Measured: 9/10 solo characters reach wave 20 on this ramp with the heal rule');
 o.push('and ~4% compounding stat growth per wave. The OLD ramp (1+floor((w-1)/3)) gave 0/10.');
 return o;}
function tNiche(){
 var K=25,o=['NICHE PRICING — a conditional only pays if the action LOSES outside its niche',''];
 var a=C.ACTIONS.pierce;
 o.push('Pierce: power '+a.power+', defPierce '+a.defPierce+', rank '+a.rank);o.push('');
 Object.keys(C.ARCH).forEach(function(k){var e=C.ARCH[k];
  var st=26*(K/(K+e.def))/1.00, pi=26*a.power*(K/(K+e.def*(1-a.defPierce)))/a.rank;
  o.push('  '+(e.name+'            ').slice(0,16)+' DEF '+(e.def<10?' ':'')+e.def+
   ' | strike '+st.toFixed(2)+'  pierce '+pi.toFixed(2)+'  → '+(pi>st?'PIERCE':'strike'));});
 o.push('');o.push('Pierce should win against the Barrow Knight ONLY. If it wins everywhere the');
 o.push('conditional is pointless - "always Pierce" would beat "Pierce when armoured".');
 return o;}
function tThreshold(){
 var o=['THRESHOLD SCALING — why conditions are relative, not absolute',''];
 o.push('Enemy DEF scales at S^0.98 where S = 1.06^(wave-1).');
 o.push('An ABSOLUTE condition "foe DEF >= 25" degenerates to always-true:');o.push('');
 [1,5,10,15,20,25].forEach(function(w){
  var S=Math.pow(1.06,w-1);
  var wolf=Math.round(C.ARCH.wolf.def*Math.pow(S,0.98));
  o.push('  wave '+(w<10?' ':'')+w+' : Roadwolf DEF '+(wolf<10?' ':'')+wolf+
   (wolf>=25?'   <- a "soft" enemy now passes DEF>=25':''));});
 o.push('');o.push('v0.9 uses "DEF > 1.4x YOURS" instead, which is scale-invariant.');
 return o;}
function show(o){$('#testOut').textContent=Array.isArray(o)?o.join('\n'):o;}
/* ===== SMOKE TEST =====
 * Drives the REAL handlers — the same doStep() the Travel button calls, plus every
 * render pass and tab builder — for a few hundred waves, and reports the first
 * throw with a stack. This is the gap that let a ReferenceError ship: every
 * previous check ran the simulation CORE headlessly, which was fine, while the
 * page that actually renders was dead. The core passing says nothing about the
 * page booting. */
function smokeTest(waves){
 var out=['SMOKE TEST — driving the real UI, not the headless core',''];
 var errs=0;
 function attempt(label,fn){
  try{fn();return true;}
  catch(e){errs++;out.push('✗ '+label+' THREW  '+e.name+': '+e.message);
   if(e.stack)out.push('   '+String(e.stack).split('\n')[1]||'');return false;}}
 attempt('boot()',function(){boot(4242);});
 attempt('buildGambits()',function(){buildGambits();});
 attempt('renderAll()',function(){renderAll();});
 attempt('renderEconomy()',function(){renderEconomy();});
 attempt('renderAether()',function(){renderAether();});
 attempt('renderLore()',function(){renderLore();});
 attempt('renderMarks()',function(){renderMarks();});
 attempt('renderDropNote()',function(){renderDropNote();});
 attempt('describeAction()/pairingHint()',function(){
  C.EQUIPPABLE.forEach(function(id){describeAction(id);pairingHint(id);});});
 attempt('P.partySizeAt/enemyCount across depth',function(){
  [1,20,40,150,500,1500,3000].forEach(function(w){
   if(typeof P.enemyCount(w)!=='number')throw new Error('enemyCount('+w+') not a number');
   if(typeof P.bossAether(w)!=='number')throw new Error('bossAether('+w+') not a number');
   if(typeof P.pullCost(w)!=='number')throw new Error('pullCost('+w+') not a number');});});
 var startWaveNo=G.wave,bosses=0,drops=0,pulls0=G.party.length,lvl0=levelOf('kesh');
 var ok=attempt('doStep() x'+waves+' waves',function(){
  var guard=0,seen=G.wave;
  while(G.wave<startWaveNo+waves&&guard<400000){
   doStep();guard++;
   if(G.wave!==seen){seen=G.wave;if(P.isBossWave(seen-1))bosses++;}}});
 if(ok){
  out.push('✓ boot, all render passes and '+waves+' waves of doStep() completed');
  out.push('');
  out.push('  waves advanced   '+startWaveNo+' → '+G.wave);
  out.push('  bosses cleared   '+G.bossesCleared);
  out.push('  party size       '+pulls0+' → '+G.party.length);
  out.push('  '+mcName()+' level       '+lvl0+' → '+levelOf('kesh'));
  out.push('  actions held     '+G.actions.length);
  out.push('  conditions held  '+G.conditions.length);
  out.push('  aether / lore / marks   '+Math.floor(G.aether)+' / '+
    Math.floor(G.lore)+' / '+Math.floor(G.marks));
  out.push('  highest-ever LV (ratchet R)  '+(G.maxLevelEver||levelOf('kesh')));}
 out.push('');
 out.push(errs?('RESULT: '+errs+' FAILURE(S) — do not ship'):'RESULT: PASS — build is playable');
 return out;}
/* `busy` was a v0.8 helper that v0.9 dropped in favour of show(). Same stale-name
   class as `cfg` and `WAVE_EXP` — and it was in the harness built to catch them. */
$('#tSmoke').onclick=function(){
 $('#testOut').textContent='running…';
 setTimeout(function(){
  try{show(smokeTest(120));}
  catch(e){show('SMOKE TEST ITSELF THREW\n'+e.name+': '+e.message+'\n'+(e.stack||''));}
 },30);};
$('#tCad').onclick=function(){show(tCadence());};
$('#tRamp').onclick=function(){show(tRamp());};
$('#tNiche').onclick=function(){show(tNiche());};
$('#tThr').onclick=function(){show(tThreshold());};

/* --------------------------------------------------------------- wiring --- */
$('#btnPlay').onclick=function(){playing?stop():play();};
$('#btnStep').onclick=function(){stop();doStep();};
/* FULL reset: clears the save and sends the player back through character
   creation, rather than restarting the same character at a new seed. A
   built character represents real investment (name, 50 stat points, a
   charge pick), so this is confirmed rather than firing on a stray tap. */
$('#btnReset').onclick=function(){
 if(!confirm('Reset everything? This deletes your save and your character — you\'ll build a new one.'))return;
 stop();
 try{localStorage.removeItem(SAVE_KEY);}catch(e){}
 showMcCreate();};
$('#btnClear').onclick=function(){$('#log').innerHTML='';};
/* Catch tab close/refresh and backgrounding — the two ways a session ends
   without a combat beat or purchase around to trigger the renderAll() autosave
   hook (e.g. the player quits while merely staring at an idle screen). */
window.addEventListener('beforeunload',function(){doSave();});
document.addEventListener('visibilitychange',function(){if(document.hidden)doSave();});
$('#btnEnrage').onclick=function(){G.enrage=!G.enrage;
 this.textContent='Enrage: '+(G.enrage?'ON':'OFF');this.classList.toggle('on',G.enrage);
 if(G.battle)G.battle.enrage=G.enrage;
 sysLog(G.enrage?'<b>The clock is running.</b> <span class="tiny">Enemies enrage after turn 20 of '+
  'the fight, +5% ATK each turn after. Offence and speed now matter; healing is optional.</span>'
  :'<b style="color:var(--crit)">The clock is off.</b> <span class="tiny">Healing is now unbounded '+
  'sustain and worth +173% — expect every build to collapse onto the heal rule.</span>');};
Array.prototype.forEach.call(document.querySelectorAll('.spd'),function(b){
 b.onclick=function(){speed=+b.dataset.s;
  Array.prototype.forEach.call(document.querySelectorAll('.spd'),function(x){x.classList.remove('on');});
  b.classList.add('on');renderHead();};});
Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(b){
 b.onclick=function(){
  Array.prototype.forEach.call(document.querySelectorAll('#tabs button'),function(x){x.classList.remove('on');});
  b.classList.add('on');
  ['log','gambits','aether','equipment','lore','marks','expedition','quests','tests'].forEach(function(t){
   $('#tab-'+t).classList.toggle('hidden',t!==b.dataset.t);});};});

function boot(seed,mc){
 G=newGame(seed,mc||(G&&G.mc));   /* Reset run keeps the same custom character */
 applyCustomMC();
 C.applyBonuses({});
 $('#log').innerHTML='';
 var openerName=G.mc?G.mc.name:null;
 sysLog('<b>'+(openerName?openerName+' sets out alone.':'You set out alone.')+
  '</b><div class="tiny">One character, Strike and Ember, and no rules yet. '+
  'Tools arrive on a curated schedule to wave 20 — an action every two waves, a gambit condition '+
  'between them. Write rules in the GAMBITS tab; spend what you earn in AETHER, LORE and MARKS.</div>');
 startWave(1);
 buildGambits();renderAll();}

/* ============================================================ character
 * creation (roadmap item 1) — shown only when there is no save to resume,
 * i.e. a genuine first-ever visit. An existing save's Kesh (custom or
 * hardcoded default) is never retroactively replaced. ==================== */
/* Every stat P.MC_STAT_RANGE offers, in creation-screen display order. Kept as
   a single source of truth in progression.js (P.MC_STAT_KEYS) so the pool
   size (P.MC_POINTS_TOTAL) and this list can never drift apart. */
var MC_STAT_LABELS={atk:'ATK',mag:'MAG',def:'DEF',res:'RES',spd:'SPD',hp:'HP'};
var mcPoints=(function(){var o={};P.MC_STAT_KEYS.forEach(function(k){o[k]=P.MC_POINT_MIN;});return o;})();
var mcChargeChoice=null;
function mcSanitizeName(raw){
 return (raw||'').replace(/[<>&"']/g,'').trim().slice(0,20);}
function mcStatDisplay(k,point){
 return Math.round(P.mcLerp(P.MC_STAT_RANGE[k],point));}
function renderMcStats(){
 var host=$('#mcStats');if(!host)return;host.innerHTML='';
 P.MC_STAT_KEYS.forEach(function(k){
  var val=mcStatDisplay(k,mcPoints[k]);
  var hasGrowth=!!P.MC_GROWTH_RANGE[k];
  var grow=hasGrowth?Math.round(P.mcLerp(P.MC_GROWTH_RANGE[k],mcPoints[k])*10)/10:null;
  var row=document.createElement('div');row.className='row';row.style.marginBottom='4px';
  row.innerHTML='<span class="tiny" style="width:56px">'+MC_STAT_LABELS[k]+'</span>'+
   '<button class="mini mcm" data-k="'+k+'" style="min-width:30px">−</button>'+
   '<span class="mono" style="min-width:22px;text-align:center">'+mcPoints[k]+'</span>'+
   '<button class="mini mcp" data-k="'+k+'" style="min-width:30px">+</button>'+
   '<span class="tiny mono" style="flex:1;text-align:right;color:var(--dimmer)">'+val+
   (hasGrowth?' <span style="color:var(--dim)">(+'+grow+'/lvl)</span>':'')+'</span>';
  host.appendChild(row);});
 Array.prototype.forEach.call(host.querySelectorAll('.mcm'),function(b){
  b.onclick=function(){var k=b.dataset.k;
   if(mcPoints[k]>P.MC_POINT_MIN)mcPoints[k]--;renderMcStats();updateMcConfirm();};});
 Array.prototype.forEach.call(host.querySelectorAll('.mcp'),function(b){
  b.onclick=function(){var k=b.dataset.k;
   if(mcPoints[k]<P.MC_POINT_MAX&&P.mcPointsSpent(mcPoints)<P.MC_POINTS_TOTAL)mcPoints[k]++;
   renderMcStats();updateMcConfirm();};});
 var lbl=$('#mcPointsLbl');
 if(lbl)lbl.textContent=(P.MC_POINTS_TOTAL-P.mcPointsSpent(mcPoints))+' points remaining';}
function renderMcCharges(){
 var host=$('#mcCharges');if(!host)return;host.innerHTML='';
 P.MC_STARTER_CHARGES.forEach(function(id){
  var a=C.ACTIONS[id];if(!a)return;
  var info=describeAction(id);
  /* Same "N of M Lore upgrades apply" count renderLore() shows in-game, up
     front at the point of choice — an AoE or heal-shaped action is dead on
     more of the ten bonuses (piercing/keen/broad assume a single target and
     no heal) than a single-target damage one, so even among three plain
     starters the count still varies (6 / 4 / 4) and is worth seeing before
     committing rather than only after. */
  var liveCount=Object.keys(C.BONUSES).filter(function(bid){return C.bonusApplies(a,bid);}).length;
  var card=document.createElement('div');
  card.className='slot mcc'+(mcChargeChoice===id?' on':'');
  card.style.cursor='pointer';card.style.marginBottom='5px';card.dataset.id=id;
  card.innerHTML='<div class="uname" style="color:var(--charge)">⚡ '+info.name+'</div>'+
   '<div class="tiny" style="margin-top:2px">'+info.body+'</div>'+
   (info.note?'<div class="tiny" style="margin-top:2px;color:var(--dimmer)">'+info.note+'</div>':'')+
   '<div class="tiny" style="margin-top:2px;color:var(--dim)">'+liveCount+' of '+
    Object.keys(C.BONUSES).length+' Lore upgrades apply to this action</div>';
  card.onclick=function(){mcChargeChoice=id;renderMcCharges();updateMcConfirm();};
  host.appendChild(card);});}
function updateMcConfirm(){
 var btn=$('#btnMcConfirm');if(!btn)return;
 var nameOk=mcSanitizeName($('#mcName').value).length>0;
 var pointsOk=P.mcPointsSpent(mcPoints)===P.MC_POINTS_TOTAL;
 btn.disabled=!(nameOk&&pointsOk&&mcChargeChoice);}
function showMcCreate(){
 /* Reset the form itself, not just the save — otherwise Reset run would show
    the PREVIOUS character's name and charge pick still sitting there, one
    click away from silently recreating the character it just deleted. */
 mcPoints=(function(){var o={};P.MC_STAT_KEYS.forEach(function(k){o[k]=P.MC_POINT_MIN;});return o;})();
 mcChargeChoice=null;
 $('#mcName').value='';
 $('#app').classList.add('hidden');
 $('#mcCreate').classList.remove('hidden');
 renderMcStats();renderMcCharges();updateMcConfirm();}
$('#mcName').oninput=updateMcConfirm;
$('#btnMcConfirm').onclick=function(){
 var name=mcSanitizeName($('#mcName').value);
 if(!name||P.mcPointsSpent(mcPoints)!==P.MC_POINTS_TOTAL||!mcChargeChoice)return;
 var built=P.mcBuildStats(mcPoints);
 var mc={name:name,stats:built.stats,hp:built.hp,growth:built.growth,chargeAction:mcChargeChoice,
  acquiredCharges:[mcChargeChoice]};
 $('#mcCreate').classList.add('hidden');
 $('#app').classList.remove('hidden');
 boot(7,mc);
 doSave();};

/* Expeditions run on real wall-clock time and must be picked up even if the
   player never reloads the page — there is no other "time has passed"
   poller in this file (tick() only runs during active combat playback), so
   this is new plumbing rather than a reuse of an existing loop. 15s (was
   30s — halved since one pass now covers every concurrent expedition, not
   just one) is frequent enough that a returning party shows up promptly
   without adding any meaningful cost (resolveExpedition() no-ops in under
   5s anyway). Separate from updateExpeditionTimers below: this one does
   real combat resolution and a full renderAll(), so it stays infrequent
   enough not to reintroduce the double-click bug a sub-second full rebuild
   caused during travel (see doStep()/renderTick() above) — the live
   counter's own 1s cadence is cheap precisely because it never rebuilds
   anything. */
setInterval(function(){
 if(G&&G.expeditions&&G.expeditions.length){resolveAllExpeditions();renderAll();}},15000);
setInterval(function(){if(G)updateExpeditionTimers();},1000);

/* "let's have travelling the road begin as soon as the file is opened, so
   long as the player has already made an MC" — a resumed save with a
   custom G.mc starts travelling immediately instead of waiting for a
   manual ▶ Travel click. Gated on G.mc specifically (not just a
   successful resume) since a legacy save from before MC creation existed
   has G.mc===null — that player never "made an MC" in the sense meant
   here, so it's left starting paused like before. A fresh first-ever
   visit (tryResumeSave() returns false) always goes to character
   creation, where there is no travel loop to start yet regardless. */
if(tryResumeSave()){if(G.mc)play();}else showMcCreate();
})();

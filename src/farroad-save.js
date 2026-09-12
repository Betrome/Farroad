
/* =============================================================================
 * FARROAD SAVE — serialises game state G to a plain, JSON-safe snapshot and
 * back again. Headless by design, like core and progression: it never touches
 * localStorage, the DOM, or a live clock — Date.now() is passed in by the
 * caller — so it loads and round-trips inside the smoke test the same way the
 * other two modules do. Storage and the offline-progress grant are the UI
 * layer's job (see MODULES.md — "a farroad-save.js sitting between
 * progression and UI can serialise G plus a timestamp without either layer
 * knowing").
 *
 * WHAT'S IN THE SNAPSHOT: everything G needs to resume progression — wave,
 * currencies, roster, levels, loadouts, one-time-reward history. NOT the live
 * Battle object: loading resumes at the START of the current wave rather than
 * mid-fight, so no tick/HP/status/charge-gauge state is captured. That mirrors
 * how a wipe already returns to a wave boundary, not a fight-interior point —
 * see startWave()/onWipe() in the UI layer, which the load path reuses.
 * ========================================================================== */
window.FarroadSave=(function(){
'use strict';var S={};
S.VERSION=1;

/* Plain fields copied as-is. All of these are already JSON-safe in newGame()
   (farroad-ui.js) — no functions, no DOM handles, no circular refs. */
var FIELDS=['wave','farthest','bossesCleared','aether','lore','marks','wipes',
 'party','actions','conditions','actionCounts','condCounts','bonuses','recovery',
 'loadout','hpCarry','touched','clearedWaves','dropsGranted','lvl','bank','maxLevelEver','owned',
 'enrage','idleAcc','dropQueue','dropHistory','pullsSinceUnit',
 /* v2.11: {lore,aether} running total for the condensed duplicate-drop
    notice (addDropGain(), farroad-ui.js) — same lazy-init/no-explicit-
    default-fill treatment dropQueue/dropHistory already get just above,
    since renderDropNote() already guards a missing value with ||{}. */
 'dropGains',
 /* the player-built starting character (roadmap item 1), or null for the
    hardcoded default — see applyCustomMC() in the UI layer, which is what
    actually turns this back into stats/growth on the 'kesh' roster slot. */
 'mc',
 /* roadmap item 4 — see resolveExpedition()/sendExpedition() in the UI
    layer. 'expeditions' is [] when no party is out, else one entry per
    active expedition: {id,partyIds,startedAt,lastResolvedAt,ew,hpFrac,
    bank,homeAt,log} — log is that expedition's own capped history
    (cap-and-unshift, same shape dropHistory uses), discarded along with
    the rest of the object once settleExpedition() removes it on return.
    v2.9: was a single nullable 'expedition' object plus one shared
    'expeditionLog' array (multi-expedition support) — see the migration
    in deserialize() below for a save written before this field existed. */
 'expeditions',
 /* discoverable content — see MODULES.md. 'dungeons' is [] of fully-baked,
    frozen-difficulty repeatable fights an expedition has found; 'quests'
    is {uid:{stage}} per-companion 5-battle progress, keyed only for owned
    units. Both are brand-new fields with no legacy shape — see the plain
    default-fill below, not a migration. */
 'dungeons','quests',
 /* v2.9: directional expeditions. 'directions' is {dir:{maxDepth,
    dungeonsUnlocked}} for each of the 8 P.DIRECTIONS values — persistent,
    cumulative exploration progress per direction (never reset when one
    expedition returns and another is sent), what the "a new dungeon every
    100 depth" schedule is checked against. Brand-new field, plain
    default-fill below (the 8 ids are hardcoded here rather than read off
    P.DIRECTIONS since this module never loads progression.js — same
    precedent as 'kesh' being a literal below, not derived from C.ROSTER). */
 'directions',
 /* v2.10: elemental affinities. 'affinities' is {uid:{fire,water,earth,air,
    light,dark,body,spirit}} — PURCHASED AETHER-INVESTMENT POINTS ONLY, per
    owned unit, not the unit's own authored baseline (C.ROSTER/C.ARCH,
    CSV-authored — see content-pipeline.js). A unit's effective combat-time
    affinity is baseline + this, computed at party-build time (farroad-ui.js,
    buildParty/buildExpeditionParty). Brand-new field, plain default-fill
    below, no legacy shape. */
 'affinities',
 /* v2.10: Block/Evade/ATK-Crit/MAG-Crit — same shape as 'affinities' one
    line up, PURCHASED STEPS ONLY (P.PCT_STAT, farroad-progression.js) —
    {uid:{block,evade,atkCrit,magCrit}}, each a step count, not a percent.
    The baseline stays the unit's existing atk_crit/mag_crit/block/evade
    CSV columns (unchanged, already the only source before this feature).
    Brand-new field, plain default-fill below, no legacy shape. */
 'statInvest',
 /* v2.14: equipment. 'equipInv' is {itemId:countOwned} — the count itself
    IS the ownership signal, no separate unlock-boolean (unlike actions/
    conditions), since equipment duplicates are genuinely useful (dual-
    wielding a hand item, the same armor on two units). 'equipped' is
    {uid:{head,body,legs,hand1,hand2}} — an item id or absent per position;
    a unit's effective combat-time stats/affinity are baseline+investment+
    whatever's equipped, computed at party-build time (farroad-ui.js,
    buildParty/buildExpeditionParty/refreshLiveStats — see
    applyEquipmentStats/equipmentAffinity). Both brand-new fields, plain
    default-fill below, no legacy shape. */
 'equipInv', 'equipped'];

function clone(v){return v===undefined?v:JSON.parse(JSON.stringify(v));}

/* @param G   live game state (farroad-ui.js's G)
 * @param now caller-supplied Date.now() — kept a parameter, not a call, so this
 *            function stays pure and testable without a Date mock. */
S.serialize=function(G,now){
 var snap={v:S.VERSION,savedAt:now,seed:G.seed,rngCalls:(G.rng&&G.rng.calls)||0};
 FIELDS.forEach(function(k){snap[k]=clone(G[k]);});
 return snap;};

/* @param snap parsed snapshot object (caller does the JSON.parse)
 * @param C    FarroadCore, needed only to rebuild the seeded RNG
 *
 * RNG NOTE: makeRNG's internal state is a closure, not a field, so it cannot be
 * copied directly. It is reseeded and then fast-forwarded by replaying next()
 * rngCalls times, which reaches the identical internal state because the
 * generator is a pure function of (seed, call count). This does not attempt to
 * reproduce the exact in-progress fight the player saved during — see the file
 * header — it only keeps the long-run sequence continuing rather than
 * restarting, so frequent save/load does not visibly shorten-cycle the RNG. */
S.deserialize=function(snap,C){
 if(!snap||typeof snap!=='object')return null;
 var rng=C.makeRNG(snap.seed);
 var calls=snap.rngCalls||0;
 for(var i=0;i<calls;i++)rng.next();
 var G={seed:snap.seed,rng:rng,battle:null,units:null,enemies:null,over:null};
 FIELDS.forEach(function(k){G[k]=clone(snap[k]);});
 /* Defend against a snapshot saved by an older build that predates a field —
    fall back to newGame()'s own defaults rather than crashing on load. */
 if(!G.party||!G.party.length)G.party=['kesh'];
 if(!G.actions||!G.actions.length)G.actions=['strike','ember'];
 if(!G.conditions||!G.conditions.length)G.conditions=['none'];
 ['actionCounts','condCounts','bonuses','recovery','loadout','hpCarry','touched',
  'clearedWaves','lvl','bank','owned'].forEach(function(k){G[k]=G[k]||{};});
 /* v2.11 MIGRATION: Keen (crit) retired from Lore entirely (redundant once
    ATK/MAG Crit became directly Aether-investable) — a save with banked
    keen stacks on some action must not just lose that spent Lore. Refund
    the difference this action's own triangular price (bonusSpend, same
    closed-form every other Lore cost already uses) drops by once keen no
    longer counts toward its stack total, then strip keen so it can never
    be read again — same "don't strand a purchase" rule every other
    removed/changed stat this codebase has followed (Block's own removal,
    two phases back, needed no such migration only because nothing had
    been spent buying it up yet at the time). */
 Object.keys(G.bonuses).forEach(function(aid){
  var b=G.bonuses[aid];
  if(!b||!b.keen)return;
  var without={};Object.keys(b).forEach(function(k){if(k!=='keen')without[k]=b[k];});
  var refund=C.bonusSpend({x:b})-C.bonusSpend({x:without});
  G.lore=(G.lore||0)+refund;
  delete b.keen;});
 /* v2.9: dropsGranted is a NEW, stricter gate than clearedWaves (see
    grantDrops() in the UI layer) — a save from before this field existed
    has no history for it. Defaulting to {} would let every ALREADY-cleared
    wave grant its drop one more time on next visit (a real regression for
    an in-progress save). Seed it from clearedWaves instead: every wave
    already known cleared is correctly treated as already granted too. The
    one wave the player is CURRENTLY sitting on (visited but not yet
    cleared) isn't covered by that seed and gets one extra grant if wiped —
    a minor, one-time edge case, not worth a bigger migration for. */
 if(!G.dropsGranted)G.dropsGranted=clone(G.clearedWaves)||{};
 if(!G.lvl.kesh)G.lvl.kesh=1;
 if(G.bank.kesh==null)G.bank.kesh=0;
 if(!G.owned.kesh)G.owned.kesh=1;
 G.maxLevelEver=G.maxLevelEver||1;
 G.wave=G.wave||0;G.farthest=G.farthest||1;G.bossesCleared=G.bossesCleared||0;
 G.aether=G.aether||0;G.lore=G.lore||0;G.marks=G.marks||0;G.wipes=G.wipes||0;
 G.idleAcc=G.idleAcc||0;G.enrage=(G.enrage!==false);
 /* v2.9 MIGRATION: a save written before multi-expedition support has a
    singular 'expedition' object (possibly a real in-flight one) and a
    shared 'expeditionLog' array, neither of which is in FIELDS above
    anymore, so G.expeditions came out of the generic clone loop as
    undefined for such a save. Wrap the legacy single expedition into the
    new array (assigning it a fresh id) rather than silently dropping a
    party that's actually out exploring; fold the old shared log into it
    best-effort — those entries weren't scoped to one expedition before,
    but there was only ever one active at a time, so nothing is lost. A
    genuinely new/empty save (no legacy 'expedition' field either) just
    gets []. */
 if(!G.expeditions){
  if(snap.expedition){
   var legacy=clone(snap.expedition);
   legacy.id='exp'+(snap.savedAt||Date.now())+'_migrated';
   legacy.log=clone(snap.expeditionLog)||[];
   G.expeditions=[legacy];
  }else{
   G.expeditions=[];}}
 if(!G.dungeons)G.dungeons=[];
 if(!G.quests)G.quests={};
 if(!G.quests.kesh)G.quests.kesh={stage:0,frozen:[]};   /* kesh is owned from newGame(), never through joinCompanion() */
 /* v2.9: directional expeditions. A save from before this existed has
    neither 'directions' nor a 'direction' on any in-flight expedition —
    default-fill both rather than throw. The 8 ids are hardcoded (see the
    FIELDS comment above) since this module doesn't load progression.js. */
 var DIRS=['west','northwest','southwest','north','south','northeast','southeast','east'];
 if(!G.directions)G.directions={};
 DIRS.forEach(function(dir){if(!G.directions[dir])G.directions[dir]={maxDepth:0,dungeonsUnlocked:0};});
 (G.expeditions||[]).forEach(function(exp){if(!exp.direction)exp.direction='west';});
 G.pullsSinceUnit=G.pullsSinceUnit||0;
 if(!G.affinities)G.affinities={};
 if(!G.affinities.kesh)G.affinities.kesh={};   /* kesh is owned from newGame(), never through joinCompanion() */
 if(!G.statInvest)G.statInvest={};
 if(!G.statInvest.kesh)G.statInvest.kesh={};
 if(!G.equipInv)G.equipInv={};
 if(!G.equipped)G.equipped={};
 if(!G.equipped.kesh)G.equipped.kesh={};   /* kesh is owned from newGame(), never through joinCompanion() */
 return G;};

return S;})();

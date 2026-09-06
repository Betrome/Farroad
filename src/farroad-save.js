
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
 'loadout','hpCarry','touched','clearedWaves','lvl','bank','maxLevelEver','owned',
 'enrage','idleAcc','dropQueue','dropHistory',
 /* the player-built starting character (roadmap item 1), or null for the
    hardcoded default — see applyCustomMC() in the UI layer, which is what
    actually turns this back into stats/growth on the 'kesh' roster slot. */
 'mc',
 /* roadmap item 4, phase 1 — see resolveExpedition()/sendExpedition() in the
    UI layer. 'expedition' is null when no party is out, else the live
    {partyIds,startedAt,lastResolvedAt,ew,hpFrac,bank} record; 'expeditionLog'
    is a capped history array, same cap-and-unshift shape as dropHistory. */
 'expedition','expeditionLog'];

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
 if(!G.lvl.kesh)G.lvl.kesh=1;
 if(G.bank.kesh==null)G.bank.kesh=0;
 if(!G.owned.kesh)G.owned.kesh=1;
 G.maxLevelEver=G.maxLevelEver||1;
 G.wave=G.wave||0;G.farthest=G.farthest||1;G.bossesCleared=G.bossesCleared||0;
 G.aether=G.aether||0;G.lore=G.lore||0;G.marks=G.marks||0;G.wipes=G.wipes||0;
 G.idleAcc=G.idleAcc||0;G.enrage=(G.enrage!==false);
 if(G.expedition===undefined)G.expedition=null;
 G.expeditionLog=G.expeditionLog||[];
 return G;};

return S;})();

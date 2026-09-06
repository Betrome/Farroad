
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
  lvl:{kesh:1}, bank:{kesh:0}, maxLevelEver:1, owned:{kesh:1},
  battle:null, units:null, enemies:null, over:null, enrage:true, idleAcc:0,
  mc:mc||null, expedition:null, expeditionLog:[]};}

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
 /* chargeRate is the one field NOT offered at creation (see P.MC_STAT_RANGE's
    comment — the five shipped units never vary it, so there is no already-
    played range to bound a choice against); it stays fixed at 1 same as
    every other unit. */
 keshDef.stats={atk:G.mc.stats.atk,mag:G.mc.stats.mag,def:G.mc.stats.def,res:G.mc.stats.res,spd:G.mc.stats.spd,
  atkCrit:G.mc.stats.atkCrit,magCrit:G.mc.stats.magCrit,chargeRate:1,
  block:G.mc.stats.block,evade:G.mc.stats.evade};
 P.GROWTH.kesh={hp:G.mc.growth.hp,atk:G.mc.growth.atk,mag:G.mc.growth.mag,
  def:G.mc.growth.def,res:G.mc.growth.res,spd:G.mc.growth.spd};}

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
function costNext(uid){return P.costToNext(levelOf(uid),ratchetR());}
function feedUnit(uid,amount){
 G.bank=G.bank||{};G.lvl=G.lvl||{};
 G.bank[uid]=(G.bank[uid]||0)+amount;
 var gained=0,guard=0;
 while(guard++<100000){
  var c=P.costToNext(levelOf(uid),ratchetR());
  if(G.bank[uid]<c)break;
  G.bank[uid]-=c;G.lvl[uid]=levelOf(uid)+1;gained++;
  if(G.lvl[uid]>(G.maxLevelEver||1))G.maxLevelEver=G.lvl[uid];   /* the ratchet */
 }
 return gained;}
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
  var mh=st.hp;
  /* Between-wave rest. Does NOT fix the multi-enemy wall (25/50/100% measured
     identical there) but it stops waves 1-7 compounding before Mend arrives. */
  var carry=G.hpCarry[uid];
  if(carry!=null)carry=Math.min(1,carry+recoveryOf(uid));
  var hp=(carry==null)?mh:Math.max(1,Math.round(mh*carry));
  out.push(C.makeUnit({id:uid,name:def.name,isParty:true,level:1,slotIndex:i,stats:st,
   maxHp:mh,hp:Math.min(hp,mh),row:def.row,chargeAction:def.chargeAction,
   slots:ensureLoadout(uid).map(function(s){return {cond:s.cond,action:s.action};})}));});
 return out;}

/* @param quiet skips the variety-roll sysLog line — used by expedition
   resolution (resolveExpedition() below), which builds enemies against its
   own synthetic wave counter and must not spam the ROAD log with them. */
function buildEnemies(w,quiet){
 var boss=P.isBossWave(w);
 /* post-wave-40: roll the count, then scale each body inversely to it */
 var variety=(!boss&&w>P.VARIETY_FROM);
 var n=boss?1:(variety?P.rollCount(G.rng):P.enemyCount(w));
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
  hpBase*=P.DIFFICULTY*vMul;
  var atkMul=(boss?1.10:1)*P.DIFFICULTY*vMul;
  /* ATK growth exponent 1.02 -> 0.80. At 1.02 enemy damage grew 3.10x by wave 20
     while a solo character grows 2.05x, so enemies outpaced the player by ~50%
     and the game was only survivable behind the 65% crutch. At 0.80 they track. */
  var ATK_EXP=0.80;
  out.push(C.makeUnit({id:'e'+j,name:(boss?'ROADWARDEN':a.name)+(n>1?' '+(j+1):''),
   isParty:false,level:1,slotIndex:10+j,arch:key,thorns:a.thorns||0,isBoss:boss,
   stats:{hp:Math.max(8,Math.round(hpBase)),
    /* v2.0: ONE exponent for every stat, so no ratio can drift over 1000+ waves */
    atk:Math.max(1,Math.round(a.atk*S*atkMul)),
    mag:Math.round((a.mag||8)*S*P.DIFFICULTY),
    def:Math.round(a.def*S),res:Math.round(a.res*S),
    spd:a.spd,
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
    magCrit:Math.min(C.CAP_CRIT,0.04*Math.sqrt(S)),
    chargeRate:(boss?1.15:1),block:a.block,evade:a.evade},
   /* v1.0: enemies now carry EVERY stat the party has except Recovery, which is
      party-only by construction (recoveryOf() is only called in buildParty), so
      enemies never regain HP between waves — Ian's exclusion holds.
      chargeRate was always present but had no sink; these give it one. */
   chargeAction:(boss?'wardensmaul':(key==='ox'?'sunderingroar':(key==='hound'?'quickenedhowl':null))),
   slots:a.slots.map(function(s){return {cond:s.cond,action:s.action};})}));}
 return out;}

function sysLog(html,cls){
 var d=document.createElement('div');d.className='le sys';d.innerHTML=html;
 var L=$('#log');L.insertBefore(d,L.firstChild);}

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
 if(a.defPierce)bits.push('ignores '+Math.round(a.defPierce*100)+'% armour');
 if(a.lifesteal)bits.push('heals you '+Math.round(a.lifesteal*100)+'% of damage');
 if(a.revive)bits.push('revives at '+Math.round(a.revive*100)+'% HP');
 return {name:a.name,
  body:bits.join(' · ')+' · initiative '+initTag(a.rank)+
   ' <span style="color:var(--dimmer)">(higher acts more often)</span>',
  note:a.note||''};}
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
function renderDropNote(){
 var host=$('#dropnote');if(!host)return;
 var q=G.dropQueue||[];
 if(!q.length){host.className='hidden';host.innerHTML='';return;}
 host.className='';
 var h='<div class="dn-h"><span class="dn-t">'+
  (q.length>1?q.length+' NEW THINGS':'SOMETHING NEW')+'</span>'+
  '<button class="mini" id="dnOk">Got it</button></div>';
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
 var ok=$('#dnOk');if(ok)ok.onclick=function(){G.dropQueue=[];renderDropNote();};}
function grantDrops(w){
 var drops=P.isCurated(w)?P.dropsAt(w):randomDrop(w);
 /* FIRST CLEAR ONLY. Auto-battling reached wave 18 unattended, so replaying the
    early waves farmed the curated sequence for Lore indefinitely. Drops are now
    awarded once per wave, ever — which also makes the tutorial the one-time
    sequence it was always meant to be rather than a loop. */
 if(G.clearedWaves[w]){
  if(drops.length)sysLog('<span class="tiny">Wave '+w+' already cleared — no drop. '+
   'Curated rewards are one-time.</span>');
  return;}
 var curated=P.isCurated(w);
 drops.forEach(function(d){
  if(d.kind==='action'){
   G.actionCounts[d.id]=(G.actionCounts[d.id]||0)+1;
   var dup=G.actions.indexOf(d.id)>=0;
   if(!dup)G.actions.push(d.id); else G.lore+=1;
   var info=describeAction(d.id);
   if(dup){
    pushDrop({wave:w,kind:'DUPLICATE ACTION → +1 Lore',name:info.name,
     body:'You already hold this. Duplicates become <b style="color:var(--lore)">Lore</b>, '+
      'which upgrades actions in the LORE tab.'});
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
    pushDrop({wave:w,kind:'DUPLICATE CHARGE ACTION → +1 Lore',name:infoC.name,
     body:'You already hold this. Duplicates become <b style="color:var(--lore)">Lore</b>.'});
   }else{
    pushDrop({wave:w,kind:'NEW CHARGE ACTION',name:infoC.name,
     body:infoC.body+(infoC.note?'<br>'+infoC.note:''),
     pair:'Swap to it any time from the GAMBITS tab — no cost, and Lore upgrades '+
      'are kept per action, so switching back restores what you bought.'});}
   sysLog('<span class="dw">WAVE '+w+' · CHARGE ACTION</span> <b>'+C.ACTIONS[d.id].name+'</b>');
  }else{
   G.condCounts[d.id]=(G.condCounts[d.id]||0)+1;
   var dup2=G.conditions.indexOf(d.id)>=0;
   if(!dup2)G.conditions.push(d.id); else G.lore+=1;
   var lab=C.condById(d.id).label;
   if(dup2){
    pushDrop({wave:w,kind:'DUPLICATE GAMBIT → +1 Lore',name:lab,
     body:'Already held. Converts to <b style="color:var(--lore)">Lore</b>.'});
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
  var chargePool=P.MC_CHARGE_DROP_POOL;
  return [{kind:'charge',id:chargePool[G.rng.nextInt(chargePool.length)],why:'rare charge-action drop'}];}
 var out=[];
 if(w%2===0){var pool=C.EQUIPPABLE;
  out.push({kind:'action',id:pool[G.rng.nextInt(pool.length)],why:'random drop'});}
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
   G.lvl[next]=1;G.bank[next]=0;G.owned[next]=1;   /* joins at LV 1; costs are relative */
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
     pair:ca?('⚡ Charge action: <b>'+ca.name+'</b> — '+(ca.note||'')):''});})();
   G.party.push(next);
   var nm='';C.ROSTER.forEach(function(x){if(x.id===next)nm=x.name;});
   sysLog('<span class="bosstag">BOSS DOWN</span> <b>'+nm+' joins you</b> at LV 1.'+
    '<div class="tiny">Their stats are poor and it does not matter — they act on their own '+
    'clock, so your side now takes roughly twice as many actions per fight. Early levels are '+
    'cheap, so they close the gap fast.</div>');}
  sysLog('<span class="ckpt">✔ CHECKPOINT banked at wave '+(G.bossesCleared*P.BOSS_EVERY)+
   '. A wipe now returns you here, not to wave 1.</span>');
  if(G.wave>=P.BOSS_EVERY)sysLog('<span class="tiny">Curated drops end. Drops are random from here — '+
   'duplicates now appear, which is where <b style="color:var(--lore)">Lore</b> comes from.</span>');}}

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
   dozens of localStorage writes per second at 40x speed. idle-income accrual
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
 var wipeTxt=wipeDelta>0?(' <span style="color:var(--bad)">(wiped '+wipeDelta+' time'+(wipeDelta===1?'':'s')+
   ' — back to checkpoint)</span>'):'';
 sysLog('<b>Welcome back.</b> <span class="tiny">'+awayTxt+' away'+
  (elapsedSec>P.OFFLINE_CAP_SEC?' (capped at '+(P.OFFLINE_CAP_SEC/3600)+'h)':'')+' — '+progressTxt+'.'+wipeTxt+
  ' Earned <b style="color:var(--aether)">+'+aetherGain+' Aether</b> and '+
  '<b style="color:var(--marks)">+'+Math.floor(marksGain)+' Marks</b>.</span>');}

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
var expedTimer=null;
/* Precisely wakes up resolveExpedition() when a party is actually due home,
   instead of leaving a short wait to whenever the 30s background interval
   next happens to fire — without this, a party turning back only a few
   seconds from arriving would still sit "heading home" for up to 30s. */
function scheduleExpeditionCheck(delayMs){
 clearTimeout(expedTimer);
 expedTimer=setTimeout(function(){
  if(G.expedition)resolveExpedition();
  renderAll();},Math.max(0,delayMs));}
function benchedUnits(){
 return Object.keys(G.owned).filter(function(uid){return G.party.indexOf(uid)<0;});}
function pushExpeditionLog(text){
 G.expeditionLog=G.expeditionLog||[];
 G.expeditionLog.unshift({at:Date.now(),text:text});
 while(G.expeditionLog.length>40)G.expeditionLog.pop();}
function buildExpeditionParty(partyIds,hpFrac){
 var out=[];
 partyIds.forEach(function(uid,i){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var st=P.statsAt(uid,def.stats,def.hp,levelOf(uid));
  var mh=st.hp;
  var frac=(hpFrac==null)?1:Math.min(1,hpFrac+recoveryOf(uid));
  var hp=Math.max(1,Math.round(mh*frac));
  out.push(C.makeUnit({id:uid,name:def.name,isParty:true,level:1,slotIndex:i,stats:st,
   maxHp:mh,hp:Math.min(hp,mh),row:def.row,chargeAction:def.chargeAction,
   slots:ensureLoadout(uid).map(function(s){return {cond:s.cond,action:s.action};})}));});
 return out;}
/* Grants whatever the expedition has banked into the real economy and
   clears the live record — reached once a party that has turned back
   (G.expedition.homeAt set, whether by the HP threshold or a recall)
   actually arrives home; see beginReturnTrip() below. */
function settleExpedition(reason){
 var exp=G.expedition;if(!exp)return;
 var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 G.aether+=exp.bank.aether;G.marks+=exp.bank.marks;
 pushExpeditionLog(names+' — '+reason+' Reached wave '+exp.ew+'. Brought back '+
  Math.round(exp.bank.aether)+' Aether, '+Math.floor(exp.bank.marks)+' Marks.');
 sysLog('<b>Expedition returned.</b> <span class="tiny">'+names+' — '+reason+
  ' Earned <b style="color:var(--aether)">+'+Math.round(exp.bank.aether)+' Aether</b> and '+
  '<b style="color:var(--marks)">+'+Math.floor(exp.bank.marks)+' Marks</b> over '+exp.ew+' wave'+
  (exp.ew===1?'':'s')+'.</span>');
 G.expedition=null;}
/* Turning back — whether the HP threshold tripped it or the player recalled
   the party — is not instant: the trip home takes HALF the real time the
   party has been out (measured from G.expedition.startedAt to this decision
   moment), same road, half the ground already covered. Rewards stay in
   G.expedition.bank, not the real economy, until settleExpedition() actually
   fires — recalling doesn't bank anything early, it just decides "turn back
   now" instead of later. A recall placed right after departure still reads
   as instant: awaySec is ~0 there, so the computed trip is ~0 too.
   decisionMoment is a real timestamp rather than "now": a big catch-up pass
   (resolveExpedition below) can cross the turn-back threshold partway
   through a long absence, so the return-trip clock has to start from THAT
   point, not from whenever the player happens to check back in. If enough
   real time has already passed by the time this runs, the party has already
   made it home and this settles immediately; otherwise a precisely-timed
   check is scheduled so a short remaining wait doesn't sit stale until the
   next 30s background poll. */
function beginReturnTrip(decisionMoment,reason){
 var exp=G.expedition;if(!exp||exp.homeAt)return;
 var awaySec=Math.max(0,(decisionMoment-exp.startedAt)/1000);
 exp.homeAt=decisionMoment+(awaySec/2)*1000;
 var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 pushExpeditionLog(names+' — '+reason+' Heading home now.');
 if(Date.now()>=exp.homeAt)settleExpedition('arrived home.');
 else scheduleExpeditionCheck(exp.homeAt-Date.now());}
/* Validates and starts a new expedition — one at a time in phase 1. Every
   unit must be owned and currently benched (not in G.party); duplicates and
   an oversized party are rejected rather than silently truncated. */
function sendExpedition(partyIds){
 if(G.expedition)return false;
 if(!partyIds||!partyIds.length||partyIds.length>P.PARTY_CAP)return false;
 var seen={};
 for(var i=0;i<partyIds.length;i++){
  var uid=partyIds[i];
  if(seen[uid])return false;seen[uid]=1;
  if(!G.owned[uid]||G.party.indexOf(uid)>=0)return false;}
 G.expedition={partyIds:partyIds.slice(),startedAt:Date.now(),lastResolvedAt:Date.now(),
  ew:1,hpFrac:1,bank:{aether:0,marks:0},homeAt:null};
 var names=partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
  return d?d.name:uid;}).join(', ');
 pushExpeditionLog(names+' set out to explore.');
 sysLog('<b>Expedition departs.</b> <span class="tiny">'+names+' head out into the road beyond.</span>');
 return true;}
/* The real-time resolution loop — see simulateOfflineProgress() above for
   the identical shape this mirrors. Called from tryResumeSave() (catch-up
   on load) and from a periodic check while the tab stays open, so it must
   be safe to call often and cheap to no-op when nothing has happened yet.
   Once a party has turned back (homeAt set) there is no more combat to
   resolve — just a real-time wait — so that branch skips the battle loop
   entirely and only checks whether they've arrived yet. */
function resolveExpedition(){
 var exp=G.expedition;if(!exp)return;
 if(exp.homeAt){if(Date.now()>=exp.homeAt)settleExpedition('arrived home.');return;}
 var elapsedSec=Math.max(0,(Date.now()-exp.lastResolvedAt)/1000);
 if(elapsedSec<5)return;
 var resolveStartedAt=exp.lastResolvedAt;
 var capped=Math.min(elapsedSec,P.EXPED_CAP_SEC);
 var remaining=capped,guard=0,savedWave=G.wave,turnedBack=false;
 while(remaining>0&&guard++<200000){
  var cost=20+P.travelSec(exp.ew);
  if(cost>remaining)break;
  var party=buildExpeditionParty(exp.partyIds,exp.hpFrac);
  var enemies=buildEnemies(exp.ew,true);
  var battle=C.makeBattle(party.concat(enemies),{rng:G.rng,enrage:G.enrage});
  var beatGuard=0;
  while(!battle.over&&beatGuard++<4000)C.step(battle);
  if(battle.over==='party'){
   var r=P.killReward(exp.ew,enemies.length);
   exp.bank.aether+=r.aether;exp.bank.marks+=r.marks*P.marksMul(G);
   if(P.isBossWave(exp.ew))exp.bank.aether+=P.bossAether(exp.ew);
   var alive=party.filter(function(u){return u.hp>0;});
   exp.hpFrac=alive.length?
    alive.reduce(function(s,u){return s+u.hp/u.maxHp;},0)/alive.length:0;
   exp.ew++;
  }else{
   exp.hpFrac=0;                  /* wiped outright — same as hitting the floor below */
  }
  remaining-=cost;
  if(exp.hpFrac<P.EXPED_RETURN_HP_FRAC){turnedBack=true;break;}}
 C.setWave(savedWave);            /* restore CURRENT_WAVE for K_of() before returning */
 exp.lastResolvedAt=Date.now();
 if(turnedBack)beginReturnTrip(resolveStartedAt+(capped-remaining)*1000,
  'injuries mounted and the party turned back.');}
/* Player-initiated early return: catch up on whatever real time has passed
   (which may itself trigger and even fully resolve an auto turn-back), then
   decide to turn back right now if the party isn't already doing so — same
   half-time trip an auto turn-back gets (see beginReturnTrip), so rewards
   don't bank until they actually arrive. A no-op if they're already heading
   home (that trip is already running on its own schedule) or already
   settled during the catch-up above. */
function recallExpedition(){
 if(!G.expedition)return;
 resolveExpedition();
 if(G.expedition&&!G.expedition.homeAt)beginReturnTrip(Date.now(),'recalled.');}

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
 if(G.expedition)resolveExpedition();   /* catch up any expedition the same way */
 buildGambits();renderAll();
 return true;}

/* ---------------------------------------------------------------- loop --- */
var playing=false,timer=null,speed=1,lastActor=null;
var mcExpedPick=[];   /* UI-only: units checked in the expedition party picker */
function doStep(){
 if(!G.battle)return;
 if(G.battle.over==='party'){afterWaveCleared();startWave(G.wave+1);renderAll();return;}
 if(G.battle.over==='enemy'){onWipe();renderAll();return;}
 var e=C.step(G.battle);
 if(e){lastActor=e.actorId;logEntry(e);}
 if(G.battle.over==='enemy'){onWipe();}
 renderAll();}
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
function play(){playing=true;$('#btnPlay').textContent='⏸ Rest';$('#btnPlay').classList.add('on');tick();}
function stop(){playing=false;clearTimeout(timer);$('#btnPlay').textContent='▶ Travel';$('#btnPlay').classList.remove('on');}

/* -------------------------------------------------------------- render --- */
/* ===== INITIATIVE MULTIPLIER (v1.0 presentation) =====
 * The player-facing speed number is now 1/rank: "how often this lets me act",
 * where HIGHER IS FASTER. Rank 0.67 -> x1.50, rank 1.00 -> x1.00, rank 1.25 ->
 * x0.80. This is a pure display change - no rank or power value moved. The raw
 * tick cost is kept in the title attribute for debugging. */
function initMul(rank){return (1/rank);}
function initStr(rank){var m=initMul(rank);
 return '×'+(m>=1?m.toFixed(2):m.toFixed(2));}
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
function pct(a,b){return Math.max(0,Math.min(100,100*a/b));}
function pills(u){var h='';for(var i=0;i<C.ST.length;i++){var id=C.ST[i];if(u.st[id]>0){var f=C.STATUS_INFO[id];
 h+='<span class="pill '+(f.k==='d'?'d':'b')+'">'+f.n+' '+u.st[id]+'</span>';}}return h;}
function renderPurse(){
 $('#cAether').textContent=Math.floor(G.aether);
 $('#cLore').textContent=Math.floor(G.lore);
 $('#cMarks').textContent=Math.floor(G.marks);}
function renderUnits(){
 var host=$('#units');host.innerHTML='';
 if(!G.battle)return;
 G.battle.units.forEach(function(u){
  var d=document.createElement('div');
  d.className='unit'+(lastActor===u.id?' act':'')+(u.hp<=0?' down':'');
  var tag=u.isParty?'<span class="rowtag '+(u.row==='front'?'front':'')+'" data-row="'+u.id+'">'+
    (u.row==='front'?'FRONT':'BACK')+'</span>'
   :'<span class="tiny">'+(u.isBoss?'boss':(C.PREF_TEXT[u.arch]||''))+'</span>';
  d.innerHTML='<div class="spread"><span class="uname '+(u.isParty?'p':(u.isBoss?'b':'f'))+'">'+
   u.name+(u.hp<=0?' — DOWN':'')+' '+tag+'</span>'+
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
   (u.isParty?'<div class="tiny mono" style="color:var(--hp)">RECOVERY '+
     Math.round(recoveryOf(u.id)*100)+'%<span style="color:var(--dimmer)"> — HP regained between waves'+
     (recoveryMaxed(u.id)?' · at cap':'')+'</span></div>':'')+
   ((!u.isParty&&G.enrage)?(function(){
     var st=C.enrageStacks(u),to=C.ENRAGE_AFTER-u.turnsTaken;
     return st>0
      ? '<div class="tiny" style="color:var(--bad)">⏱ ENRAGED ×'+st+' — +'+
        Math.round((Math.pow(1+C.ENRAGE_PCT,st)-1)*100)+'% ATK, rising each of its turns</div>'
      : '<div class="tiny" style="color:var(--dimmer)">⏱ calm — enrages in '+to+
        ' of its turns</div>';})():'')+
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
  var rk=(C.ACTIONS[p.actionId]||{}).rank||1;
  el.innerHTML='<div class="cn">'+p.unitName.split(' ')[0]+'</div><div class="ca">'+
   (p.isCharge?'⚡ ':'')+p.actionName+'</div><div class="ct mono">'+initTag(rk,p.cost)+'</div>';
  h.appendChild(el);});}
function renderHead(){
 var boss=P.isBossWave(G.wave);
 $('#waveLbl').innerHTML='Wave '+G.wave+(boss?' <span class="bosstag">BOSS</span>':'');
 $('#encLbl').textContent='· '+(G.enemies?G.enemies.length:0)+' enemy'+((G.enemies&&G.enemies.length>1)?'ies':'')+
  ' · party '+G.party.length;
 $('#secLbl').textContent=(G.battle?(G.battle.elapsedMs/1000).toFixed(1):'0.0')+'s';
 var nb=P.nextBossWave(G.wave)||'—';
 $('#ckptLbl').innerHTML='farthest <b>'+G.farthest+'</b> · checkpoint <b>'+P.checkpoint(G.bossesCleared)+
  '</b> · next boss <b>'+nb+'</b>'+(G.wipes?' · wipes '+G.wipes:'')+
  (P.isCurated(G.wave)?' · <span class="ckpt">curated drops</span>':' · <span class="tiny">random drops</span>');}
function logEntry(e){
 var d=document.createElement('div');d.className='le '+(e.isParty?'p':'f');
 var tags='',calc='';
 if(e.hits.length){var h=e.hits[0];
  if(h.evaded)tags=' <span style="color:var(--bad)">EVADED</span>';
  else{if(h.crit)tags+=' <span style="color:var(--crit)">CRIT</span>';
       if(h.blocked)tags+=' <span style="color:var(--party)">BLOCK</span>';}
  calc=h.evaded
   ?('MISSED — evade '+(Math.round(h.evadeChance*1000)/10)+'% (×'+h.negEvd+' vs '+
     (h.isPhys?'physical':'magic')+')')
   :('base '+(Math.round(h.power*100)/100)+' × '+Math.round(h.off)+' × '+h.K+'/('+h.K+'+'+
     Math.round(h.defEff)+') = '+(Math.round(h.base*10)/10)+
     '\nno variance roll — base damage is deterministic'+
     (h.crit?'\ncrit ×1.75':'')+(h.blocked?'\nblocked ×0.5':'')+
     '\nblock chance '+(Math.round(h.blockChance*1000)/10)+'% (×'+h.negBlk+' vs '+
     (h.isPhys?'physical':'magic')+')'+
     '\n→ floor '+h.damage);}
 var extra='';
 if(e.dot)extra+='<div class="note">🔥 −'+e.dot+'</div>';
 e.heals.forEach(function(x){extra+='<div class="note">✚ '+x.targetName+' +'+x.amount+'</div>';});
 e.notes.forEach(function(x){extra+='<div class="note">· '+x+'</div>';});
 d.innerHTML='<div class="lh"><span><span class="lt mono">b'+e.beat+'</span> <b>'+
  e.actorName.split(' ')[0]+'</b> → '+(e.isCharge?'⚡ ':'')+e.actionName+
  (e.targetName?' <span class="lt">→ '+e.targetName+'</span>':'')+tags+'</span>'+
  '<span class="dmg mono">'+(e.hits.length?e.totalDamage:'—')+'</span></div>'+
  '<div class="via">'+e.via+' · initiative '+initTag(e.rank||1,e.tickCost)+'</div>'+
  (calc?'<div class="tapme">tap for the damage breakdown</div><div class="calc">'+calc+'</div>':'')+extra;
 /* Progressive disclosure: the summary line stays full size and the component
    breakdown expands on tap, rather than shrinking type to fit it all in. */
 if(calc)d.onclick=function(){d.classList.toggle('open');};
 var L=$('#log');L.insertBefore(d,L.firstChild);while(L.childNodes.length>120)L.removeChild(L.lastChild);}

/* ------------------------------------------------------------ economy UI --- */
function renderAether(){
 var host=$('#aetherView');host.innerHTML='';
 var STEP=50;
 G.party.forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var L=levelOf(uid),x=expOf(uid),need=costNext(uid),have=0;
  var st=P.statsAt(uid,def.stats,def.hp,L), g=P.GROWTH[uid];
  var slots=P.slotsAt(L),nxt=P.nextSlotAt(L);
  var box=document.createElement('div');box.style.marginBottom='10px';
  var prog=Math.max(0,Math.min(100,100*(x-have)/Math.max(1,need-have)));
  box.innerHTML='<div class="spread" style="margin-bottom:3px">'+
   '<span class="uname p">'+def.name+' <span class="tiny">'+def.role+'</span></span>'+
   '<span class="nval">LV '+L+'</span></div>'+
   '<div class="bar"><i style="width:'+prog+'%;background:var(--aether)"></i></div>'+
   '<div class="tiny mono" style="margin-top:3px">'+Math.floor(x)+' / '+need+' to LV '+(L+1)+'</div>'+
   '<div class="tiny mono" style="margin-top:3px">hp '+st.hp+'  atk '+st.atk+'  mag '+st.mag+
    '  def '+st.def+'  res '+st.res+'  spd '+st.spd+'</div>'+
   '<div class="tiny" style="margin-top:2px;color:var(--dimmer)">per level: +'+g.hp+' hp, +'+g.atk+
    ' atk, +'+g.mag+' mag, +'+g.def+' def, +'+g.res+' res, +'+g.spd+' spd</div>'+
   '<div class="tiny" style="margin-top:2px">gambit slots <b>'+slots+'</b>'+
    (nxt?' <span style="color:var(--dimmer)">· '+(slots+1)+'th at LV '+nxt+'</span>':' <span class="ckpt">· max</span>')+'</div>'+
   '<div class="node" style="margin-top:6px"><span class="nname">Recovery '+
     '<span class="tiny">'+Math.round(recoveryOf(uid)*100)+'% → '+
     (recoveryMaxed(uid)?'<b style="color:var(--hp)">at cap ('+Math.round(P.REST_CAP*100)+'%)</b>'
      :Math.round(Math.min(P.REST_CAP,recoveryOf(uid)+0.03)*100)+'%')+
     ' · HP regained between waves</span></span>'+
    '<span><button class="mini rec" data-u="'+uid+'"'+
     ((recoveryMaxed(uid)||G.aether<recoveryCost(uid))?' disabled':'')+'>+3% <span class="ncost">'+
     recoveryCost(uid)+'</span></button></span></div>'+
   '<div class="row" style="margin-top:5px">'+
    '<button class="mini feed" data-u="'+uid+'" data-a="'+STEP+'"'+(G.aether>=STEP?'':' disabled')+'>+'+STEP+'</button>'+
    '<button class="mini feed" data-u="'+uid+'" data-a="'+(STEP*5)+'"'+(G.aether>=STEP*5?'':' disabled')+'>+'+(STEP*5)+'</button>'+
    '<button class="mini feed" data-u="'+uid+'" data-a="next"'+(G.aether>=(need-x)?'':' disabled')+'>→ LV '+(L+1)+' ('+Math.max(0,Math.ceil(need-x))+')</button>'+
   '</div>';
  host.appendChild(box);});
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
    sysLog('<b class="dw">LEVEL UP</b> '+nm+' → LV '+L1+
     (P.slotsAt(L1)>P.slotsAt(L0)?'<div class="tiny" style="color:var(--charge)">A third gambit slot opens.</div>':''));}
   refreshLiveStats();renderAll();buildGambits();};});}
function refreshLiveStats(){
 if(!G.units)return;
 G.units.forEach(function(u){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===u.id)def=r;});
  if(!def)return;
  var st=P.statsAt(u.id,def.stats,def.hp,levelOf(u.id));
  u.base.atk=st.atk;u.base.mag=st.mag;u.base.def=st.def;u.base.res=st.res;u.base.spd=st.spd;
  var fr=u.hp/u.maxHp;u.maxHp=st.hp;u.hp=Math.max(1,Math.round(st.hp*fr));
  u.slots=ensureLoadout(u.id).map(function(s){return {cond:s.cond,action:s.action};});});}
function renderLore(){
 var host=$('#loreView');host.innerHTML='';
 var spent=C.bonusSpend(G.bonuses),free=Math.max(0,G.lore-spent);
 if(!G.lore){host.innerHTML='<div class="tiny">No Lore yet. Lore comes from <b>duplicate</b> drops, '+
  'and the curated sequence never repeats itself — so it stays at zero until drops turn random '+
  'after the wave-20 boss. That is by design, not a stall.</div>';return;}
 host.innerHTML='<div class="tiny" style="margin-bottom:6px">'+free+' of '+Math.floor(G.lore)+
  ' Lore free · '+C.BONUS_COST+' per bonus</div>';
 /* v2.8: charge actions now appear here. They never could before — this loop read
    only ensureLoadout(), i.e. the GAMBIT SLOTS, and a unit's charge action lives
    in u.chargeAction and fires as an override, never from a slot. The engine
    always supported upgrading them (snapshot() already covered CHARGE_ACTIONS);
    it was this one line that made them unreachable. */
 var eq={};G.party.forEach(function(uid){ensureLoadout(uid).forEach(function(s){eq[s.action]=1;});
  var rd=null;C.ROSTER.forEach(function(r){if(r.id===uid)rd=r;});
  if(rd&&rd.chargeAction)eq[rd.chargeAction]=1;});
 Object.keys(eq).forEach(function(aid){
  var a=C.ACTIONS[aid];if(!a)return;var b=G.bonuses[aid]||{};
  var box=document.createElement('div');box.className='bon';
  var h='<div class="spread"><b>'+(a.isCharge?'⚡ ':'')+a.name+'</b><span class="tiny">cost '+
   Math.round(a.rank*100)+(a.isCharge?' · <b style="color:var(--charge)">gauge '+
    Math.round(C.costOfCharge(a))+'</b>':'')+'</span></div>'+
   (a.isCharge?'<div class="tiny" style="color:var(--dimmer);margin-bottom:3px">'+
    'Every upgrade here adds +'+C.CHARGE_UP_COST+' to the gauge — it hits harder but '+
    'fires less often. <b>Thrifty</b> buys the cadence back.</div>':'');
  /* v2.4: show ONLY bonuses that can do something to this action. Hiding rather
     than greying — after the merges each action has 3-8 applicable bonuses out of
     9, so the filtered list is short and self-explanatory, whereas greying six
     dead rows on every action is the noise this was meant to remove. */
  var live=Object.keys(C.BONUSES).filter(function(bid){return C.bonusApplies(a,bid);});
  live.forEach(function(bid){
   var inf=C.BONUSES[bid],n=b[bid]||0;
   /* base = what stack #1 costs (swift's speed-tiered 2/4/6, or the flat
      BONUS_COST for everything else); price = what THIS stack (the n+1'th)
      actually costs once BONUS_GROWTH's per-stack escalation is applied.
      Kept separate so the two different reasons a price can be elevated —
      "this action is already quick" (swift only, fixed) vs. "you already
      own several of this" (every bonus, rises every stack) — get their own
      messaging instead of one conflating the other. */
   var base=(bid==='swift')?C.swiftCost(a):(bid==='broad'?C.BONUS_COST_BROAD:C.BONUS_COST);
   var price=C.bonusPrice(a,bid,n);
   var swiftPremium=(bid==='swift'&&base>C.BONUS_COST);
   /* Broad is flat (see bonusPrice) — buying past stack 1 does nothing and
      costs the same as stack 1, so it never counts as "escalated". */
   var escalated=(bid!=='broad'&&n>0);
   /* v2.9 LAYOUT: was a single flex row holding the name, a full sentence of
      description AND three controls. At 375px the description had no min-width:0
      so it refused to shrink, pushing the −/count/+ group off the edge. Now the
      text is its own block and the controls sit on their own right-aligned row,
      which is also what makes the 44px touch targets fit. */
   h+='<div class="bslot">'+
    '<div class="bname">'+inf.n+
     (price!==C.BONUS_COST?' <b style="color:var(--crit)">'+price+' Lore</b>':'')+'</div>'+
    '<div class="bdesc">'+inf.d+
     (swiftPremium?' — costs more because this action is already quick.':'')+
     (escalated?' <span style="color:var(--dimmer)">— stack '+(n+1)+', up from '+base+' base.</span>':'')+
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
  if(!G.bonuses[a][b])delete G.bonuses[a][b];C.applyBonuses(G.bonuses);renderAll();};});}
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
   '% gambit condition · '+Math.round(P.PULL_ODDS.unit*100)+'% companion.</div>'+
   '<div class="tiny" style="margin-top:6px">Duplicate actions and gambits convert to '+
   '<b style="color:var(--lore)">Lore</b>; duplicate units convert to '+
   '<b style="color:var(--aether)">Aether</b>. You OWN every unit you pull — the party is '+
   'the '+P.PARTY_CAP+' you field, and extras stay benched but yours.'+
   (G.party.length>=P.PARTY_CAP?' <b>Party full — new units arrive benched.</b>':'')+
   '</div></div>';
 }
 h+='<div class="tiny">Income scales with your <b>farthest wave ('+G.farthest+')</b>: '+
  Math.round(P.idlePerSec(G.farthest).marks*60)+' Marks/min idle, plus '+
  Math.round(P.killReward(G.wave,1).marks)+' per kill.</div>';
 /* v2.9: removed the wave-28-wall clear-rate history (23% -> 100%) — that was the
    justification for a past change, not something the player acts on. */
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
P.PULL_ODDS={unit:0.10, action:0.45, cond:0.45};
function doPull(){
 var cost=P.pullCost(G.wave);
 if(!P.pullsUnlocked(G))return;      /* locked during the curated run */
 if(G.marks<cost)return;G.marks-=cost;
 var roll=G.rng.next(), O=P.PULL_ODDS;
 var kind=(roll<O.unit)?'unit':((roll<O.unit+O.action)?'action':'cond');
 if(kind==='unit'){
  /* v2.8 BUGFIX kept: filter on OWNED, not party. Collection and party are
     different things — a benched unit is still a real acquisition. */
  var avail=C.ROSTER.filter(function(r){return !G.owned[r.id];});
  if(!avail.length){
   /* Duplicate unit -> Aether. With 5 of a planned 25 units authored this is the
      COMMON case, not an edge case, so it must read as a result. */
   var dup=P.dupUnitAether(G.wave);G.aether+=dup;
   pushDrop({name:'Duplicate companion',kind:'PULL · unit',wave:G.wave,
    body:'You already own every authored companion, so this converted to '+
     '<b style="color:var(--aether)">+'+dup+' Aether</b> — about '+
     P.DUP_UNIT_WAVES+' waves of income.',
    note:'Only '+C.ROSTER.length+' of a planned '+P.POOL_SIZE+' companions are written, '+
     'so unit rolls will keep converting until more exist.'});}
  else{var pick=avail[G.rng.nextInt(avail.length)];
   G.lvl[pick.id]=1;G.bank[pick.id]=0;G.owned[pick.id]=1;
   var fielded=G.party.length<P.PARTY_CAP;
   if(fielded)G.party.push(pick.id);
   var ca=pick.chargeAction?C.ACTIONS[pick.chargeAction]:null;
   var st=pick.stats,lean=(st.mag>st.atk?'magic':'physical')+
    ', '+(st.def>=25?'sturdy':st.hp>=430?'durable':st.spd>=110?'very fast':'balanced');
   pushDrop({name:pick.name,kind:'PULL · NEW COMPANION',wave:G.wave,
    body:pick.role+' · '+pick.row+' row · joins at LV 1 · leans '+lean+
     '<br>ATK '+st.atk+' · MAG '+st.mag+' · DEF '+st.def+' · RES '+st.res+' · SPD '+st.spd+
     (ca?'<br>⚡ Charge action: <b>'+ca.name+'</b> — '+(ca.note||''):''),
    /* why, not note — the "did this actually join my party" question is the
       whole point of the notification, so it gets the same prominent styling
       curated-teaching moments use, not the dim secondary-aside treatment. */
    why:(fielded?'Fielded immediately. The value is the extra actions per fight, not the stat line.'
      :'<b>Benched</b> — your party of '+P.PARTY_CAP+' is full, but this companion is yours and can be swapped in.')});}
 }else if(kind==='action'){
  var id=C.EQUIPPABLE[G.rng.nextInt(C.EQUIPPABLE.length)];
  G.actionCounts[id]=(G.actionCounts[id]||0)+1;
  var d=describeAction(id);
  if(G.actions.indexOf(id)<0){G.actions.push(id);
   pushDrop({name:d.name,kind:'PULL · NEW ACTION',wave:G.wave,
    body:d.body,note:pairingHint(id)});}
  else{G.lore+=1;
   pushDrop({name:'Duplicate '+d.name,kind:'PULL · action',wave:G.wave,
    body:'Already held, so it converted to <b style="color:var(--lore)">+1 Lore</b> '+
     '— spend it in the LORE tab to upgrade an action you already use.',
    note:'You now hold '+G.actionCounts[id]+' copies of '+d.name+'.'});}
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
   pushDrop({name:'Duplicate '+c.label,kind:'PULL · gambit',wave:G.wave,
    body:'Already held, so it converted to <b style="color:var(--lore)">+1 Lore</b>.',
    note:'You now hold '+G.condCounts[c.id]+' copies of this condition.'});}}
 buildGambits();renderAll();}
function renderDrops(){
 var host=$('#dropsView'),h='';
 h+='<div class="tiny" style="margin-bottom:6px">Holding <b>'+G.actions.length+'</b> actions, <b>'+
  G.conditions.length+'</b> conditions.</div>';
 P.CURATED.forEach(function(d){
  var got=d.w<=G.wave;
  h+='<div class="drop" style="'+(got?'':'opacity:.35')+'"><div class="spread">'+
   '<span><span class="dw">w'+d.w+'</span> '+(d.kind==='action'?
     '<b>'+C.ACTIONS[d.id].name+'</b> <span class="tiny">'+(d.cat||'')+'</span>':
     '<b>'+C.condById(d.id).label+'</b> <span class="tiny">condition</span>')+'</span>'+
   '<span class="tiny">'+(got?'✔':'—')+'</span></div>'+
   '<div class="tiny">'+d.why+'</div></div>';});
 h+='<div class="tiny" style="margin-top:6px">After wave 20 drops are random — an action on even '+
  'waves, a condition on odd. Duplicates become Lore.</div>';
 /* HISTORY — so a player back from an idle session can see everything they
    collected while away, rather than watching notices scroll past. */
 var hist=G.dropHistory||[];
 h+='<hr><div class="tiny" style="margin-bottom:6px"><b>COLLECTED</b> — most recent first ('+
  hist.length+')</div>';
 if(!hist.length)h+='<div class="tiny">Nothing yet.</div>';
 hist.forEach(function(d){
  h+='<div class="drop"><div class="spread"><span><span class="dw">w'+(d.wave||'?')+
   '</span> <b>'+d.name+'</b></span><span class="tiny">'+d.kind+'</span></div>'+
   (d.body?'<div class="tiny">'+d.body+'</div>':'')+
   /* why/note were dropped here too — a player checking history after being
      away had no record of whether a pulled companion joined the party or
      the bench, same gap as the live banner. */
   (d.why?'<div class="tiny" style="color:var(--hp)">▸ '+d.why+'</div>':'')+
   (d.note?'<div class="tiny" style="color:var(--dimmer)">'+d.note+'</div>':'')+'</div>';});
 host.innerHTML=h;}
function renderExpedition(){
 var host=$('#expeditionView');if(!host)return;
 var exp=G.expedition,h='';
 if(exp){
  var names=exp.partyIds.map(function(uid){var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
   return d?d.name:uid;}).join(', ');
  if(exp.homeAt){
   var etaSec=Math.max(0,(exp.homeAt-Date.now())/1000);
   var etaTxt=etaSec>=3600?(etaSec/3600).toFixed(1)+' hours':Math.max(1,Math.round(etaSec/60))+' minutes';
   h+='<div class="slot"><div class="uname">'+names+'</div>'+
    '<div class="tiny mono" style="margin-top:2px">Heading home — back in about '+etaTxt+'</div>'+
    '<div class="tiny mono" style="margin-top:2px">Banked '+Math.round(exp.bank.aether)+
    ' Aether, '+Math.floor(exp.bank.marks)+' Marks so far</div></div>';
  }else{
   var awaySec=Math.max(0,(Date.now()-exp.startedAt)/1000);
   var awayTxt=awaySec>=3600?(awaySec/3600).toFixed(1)+' hours':Math.max(1,Math.round(awaySec/60))+' minutes';
   h+='<div class="slot"><div class="uname">'+names+'</div>'+
    '<div class="tiny mono" style="margin-top:2px">Away '+awayTxt+' · reached wave '+exp.ew+'</div>'+
    '<div class="tiny mono" style="margin-top:2px">Banked '+Math.round(exp.bank.aether)+
    ' Aether, '+Math.floor(exp.bank.marks)+' Marks so far</div>'+
    '<button class="mini" id="btnExpedRecall" style="margin-top:6px">Recall party</button></div>';}
 }else{
  var bench=benchedUnits();
  mcExpedPick=mcExpedPick.filter(function(uid){return bench.indexOf(uid)>=0;});
  if(!bench.length){
   h+='<div class="tiny">No benched units — everyone owned is already fielded.</div>';
  }else{
   h+='<div class="tiny" style="margin-bottom:6px">Send up to '+P.PARTY_CAP+' benched units '+
    'exploring in real time — click to pick them. The longer they\'re out, the harder what they '+
    'meet gets, and they turn back on their own if hurt too badly. The trip home takes half as '+
    'long as they were out.</div>';
   bench.forEach(function(uid){
    var d=null;C.ROSTER.forEach(function(r){if(r.id===uid)d=r;});
    var picked=mcExpedPick.indexOf(uid)>=0;
    h+='<div class="slot expick'+(picked?' on':'')+'" data-uid="'+uid+'" style="cursor:pointer">'+
     '<div class="uname">'+(d?d.name:uid)+'</div>'+
     '<div class="tiny">'+(d?d.role:'')+' · LV '+levelOf(uid)+'</div></div>';});
   h+='<button class="mini" id="btnExpedSend" style="margin-top:6px">Send expedition ('+
    mcExpedPick.length+'/'+P.PARTY_CAP+')</button>';}}
 h+='<hr><div class="tiny" style="margin-bottom:6px"><b>EXPEDITION LOG</b> — most recent first ('+
  (G.expeditionLog||[]).length+')</div>';
 var log=G.expeditionLog||[];
 if(!log.length)h+='<div class="tiny">Nothing yet.</div>';
 log.forEach(function(e){h+='<div class="drop"><div class="tiny">'+e.text+'</div></div>';});
 host.innerHTML=h;
 Array.prototype.forEach.call(host.querySelectorAll('.expick'),function(el){
  el.onclick=function(){var uid=el.dataset.uid,i=mcExpedPick.indexOf(uid);
   if(i>=0)mcExpedPick.splice(i,1);
   else if(mcExpedPick.length<P.PARTY_CAP)mcExpedPick.push(uid);
   renderExpedition();};});
 var sendBtn=$('#btnExpedSend');
 if(sendBtn)sendBtn.onclick=function(){
  if(sendExpedition(mcExpedPick)){mcExpedPick=[];renderAll();}};
 var recallBtn=$('#btnExpedRecall');
 if(recallBtn)recallBtn.onclick=function(){recallExpedition();renderAll();};}
function renderEconomy(){renderPurse();renderAether();renderLore();renderMarks();renderDrops();renderExpedition();}
function renderAll(){renderHead();renderUnits();renderRail();renderEconomy();renderDropNote();autoSave();}

/* ------------------------------------------------------------- gambits --- */
function buildGambits(){
 var host=$('#gambits');host.innerHTML='';
 G.party.forEach(function(uid){
  var def=null;C.ROSTER.forEach(function(r){if(r.id===uid)def=r;});
  var sl=ensureLoadout(uid);
  var box=document.createElement('div');box.style.marginBottom='12px';
  box.innerHTML='<div class="spread" style="margin-bottom:4px"><span class="uname p">'+def.name+
   ' <span class="tiny">'+def.role+'</span></span><span class="tiny">'+G.actions.length+' actions</span></div>';
  sl.forEach(function(s,i){
   var w=document.createElement('div');w.className='slot';
   /* reorder controls get their own row so they are not squeezed by the label */
   var co='';
   G.conditions.forEach(function(cid){var c=C.condById(cid);
    co+='<option value="'+cid+'"'+(cid===s.cond?' selected':'')+'>'+c.label+'</option>';});
   var ao='';
   G.actions.forEach(function(aid){
    ao+='<option value="'+aid+'"'+(aid===s.action?' selected':'')+'>'+C.ACTIONS[aid].name+'</option>';});
   w.innerHTML='<div class="slotbar"><span class="lbl">SLOT '+(i+1)+' — IF</span>'+
     '<button class="mini mv up" aria-label="move up">▲</button>'+
     '<button class="mini mv dn" aria-label="move down">▼</button></div>'+
    '<select class="cs">'+co+'</select>'+
    '<label style="margin-top:8px">THEN</label><select class="as">'+ao+'</select>'+
    '<div class="tiny" style="margin-top:6px">initiative '+initTag(C.ACTIONS[s.action].rank)+
     ' <span style="color:var(--dimmer)">— higher acts more often</span></div>'+
    '<div class="tiny" style="margin-top:2px">'+(C.ACTIONS[s.action].note||'')+'</div>';
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
      return '<option value="'+id+'"'+(id===ca?' selected':'')+'>'+(ai?ai.name:id)+'</option>';}).join('')+
     '</select>'
    :'<div class="uname" style="color:var(--charge);margin-top:2px">'+a.name+'</div>';
   cbox.innerHTML='<div class="spread"><span class="lbl" style="color:var(--charge)">'+
     '⚡ CHARGE ACTION</span><span class="tiny">'+initTag(a.rank)+'</span></div>'+
    nameRow+
    '<div class="tiny" style="margin-top:4px">hits <b>'+shape+'</b> · '+kind+
     (a.power?' ×'+a.power:'')+(a.applies?' · applies <b>'+a.applies+'</b> '+(a.turns||3)+' turns':'')+
     (a.revive?' at '+Math.round(a.revive*100)+'% HP':'')+
     (a.lifesteal?' · heals you '+Math.round(a.lifesteal*100)+'% of it':'')+
     (a.hits>1?' · '+a.hits+' hits':'')+'</div>'+
    '<div class="tiny" style="margin-top:4px;color:var(--dimmer)">fills in roughly <b>'+
     turnsToFill+'</b> of this unit’s turns · '+(a.note||'')+'</div>'+
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
 attempt('renderDrops()',function(){renderDrops();});
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
  out.push('  Kesh level       '+lvl0+' → '+levelOf('kesh'));
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
 sysLog(G.enrage?'<b>The clock is running.</b> <span class="tiny">Enemies enrage after 8 of their '+
  'own turns, +5% ATK each turn after. Offence and speed now matter; healing is optional.</span>'
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
  ['log','gambits','aether','lore','marks','expedition','drops','tests'].forEach(function(t){
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
var MC_STAT_LABELS={atk:'ATK',mag:'MAG',def:'DEF',res:'RES',spd:'SPD',hp:'HP',
 atkCrit:'ATK CRIT',magCrit:'MAG CRIT',block:'BLOCK',evade:'EVADE'};
var mcPoints=(function(){var o={};P.MC_STAT_KEYS.forEach(function(k){o[k]=P.MC_POINT_MIN;});return o;})();
var mcChargeChoice=null;
function mcSanitizeName(raw){
 return (raw||'').replace(/[<>&"']/g,'').trim().slice(0,20);}
function mcStatDisplay(k,point){
 var v=P.mcLerp(P.MC_STAT_RANGE[k],point);
 return (P.MC_PCT_STATS.indexOf(k)>=0)?Math.round(v*100)+'%':Math.round(v);}
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
   this is new plumbing rather than a reuse of an existing loop. 30s is
   frequent enough that a returning party shows up promptly without adding
   any meaningful cost (resolveExpedition() no-ops in under 5s anyway). */
setInterval(function(){
 if(G&&G.expedition){resolveExpedition();renderAll();}},30000);

if(!tryResumeSave())showMcCreate();
})();

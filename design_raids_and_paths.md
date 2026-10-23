# Raid bosses and Paths (roguelike): draft 2

Draft 2 after review. Nothing here is built. Both fit the agreed screens: **Arena** gets tabs *Arena | Raids*;
**Quests** has tabs *Dungeons | Quests | Trials* (built), and Trials is where Paths lives.

Items marked **(default)** are my assumptions where you haven't said; change any of them.

---

## 1. Raid bosses (Arena > Raids)

**Version 1: your own team only.** No server needed. Borrowed main characters and the shared community HP bar come
in versions 2 and 3.

**Weekly boss with rotating strengths and weaknesses.**
- A new boss each week, on the same Monday 00:00 UTC clock as seasons. Which boss it is comes from the week number,
  so every player sees the same one without a server.
- Each week the boss is built from a seeded rotation:
  - **2 strong elements** and **2 weak elements** (for example, strong to fire and earth, weak to water and light;
    the other four are neutral). Strong means a large affinity bonus, so that element does little to it; weak means
    a large penalty, so it takes extra damage from that element.
  - **A stat emphasis**: one high stat (for example DEF or RES) and one low stat, plus a matching signature action.
  - The rotation never repeats the same strong or weak elements two weeks running, so teams have to change.
- The Raids tab shows the week's strengths and weaknesses up front so players can build for it. **(default)**

**An attempt (version 1).** Up to 3 a day (resets 00:00 UTC). Your fielded team fights the boss in a normal watched
battle. The fight ends when the team falls or after a turn limit; the damage you dealt is recorded. Your best damage
of the week is your score. Rewards are paid per personal damage tier at the end of the week, in Crystals, Marks
(in hundreds) and Distilled Aether.

**Version 2:** borrowed main characters (free to borrow; the lender gets a small capped assist reward).
**Version 3:** the shared community HP bar with milestones at 25 / 50 / 75 / 100%.

---

## 2. Paths (Quests > Trials)

A true roguelike: it does not use your main game's strength, units or items.

**The run.**
- You start with **your main character at level 1**: only their starting stats and basic actions. Nothing carries in
  from the main game (no levels, gear, actions or gambits).
- **5 levels**, each a map of **10 rows** with a boss at the end. Paths **branch and converge**: each row has 2-3
  nodes, and each node connects to 1-2 nodes in the next row, so you choose a route but routes rejoin.
- You see the type of each node ahead, not its contents.

**Node types.**
- **Fight**, in 3 difficulties, shown on the map: **Easy**, **Medium**, **Hard**. Harder fights have a higher chance
  to drop a rarer action, in addition to what every fight drops.
- **Event**: a short text choice that can be good or bad (a gift, a trade, an ambush, a curse).
- **Boss** at the end of each level.

**What drops (all of it stays in the run).**
- **Every fight:** one action, one gambit and some Aether. The action's rarity (common / rare / legendary) rises with
  the fight's difficulty: Easy mostly common, Medium has a good chance of rare, Hard has the best chance of rare.
- **Every boss:** a **unit** who joins your party (up to 5), a **legendary action**, a gambit and Aether.
- **Aether** is spent during the run to level up your units. **(default: between nodes, on the same cost curve as
  the main game)**

**The run's own state.** Your actions, gambits, units and levels live only for the run. You equip actions and gambits
as you collect them. **(default: you can change them between nodes)**

**Health.** HP carries from fight to fight. **(default: a fallen unit comes back at 1 HP after each fight, so a run
ends only when the whole party falls in one fight; some events heal)** The run also ends if you choose to retreat.

**Enemies.** Scaled by the level of the map (level 1 to 5) and the row, not by your main game's Power, so the run
is self-contained. The level-5 boss is the final boss.

**Rewards outside the mode: per depth cleared.** Paid when the run ends (win, loss or retreat), per row and per level
cleared, in Crystals, Marks and Distilled Aether. **(default numbers, to tune:)**
- each row cleared: 20 Marks
- each level (boss) cleared: 2 Crystals and 100 Marks
- clearing all 5 levels: +10 Crystals and 2 Distilled Aether
Rewards from a depth you've already reached are paid at a reduced rate afterward, so repeating a short run doesn't
pay like a deep one. **(default)**

**Goals.** "Complete a Path level" fits the daily and weekly goal lists.

---

## 3. Build order

1. **Paths version 1:** the run state, the 5-level map generator (branching and converging), fights with the three
   difficulties and their drops, bosses with unit and legendary drops, events, run-level leveling, and the end-of-run
   rewards. No server.
2. **Raid version 1:** the weekly rotation, the Raids tab, personal best damage and the weekly rewards. Adds the
   Arena | Raids tabs.
3. Raid version 2 (borrowed characters), then version 3 (shared HP) once there's a player base.

---

## 4. Questions

Paths:
1. Is Aether spent between nodes on levels (my default), or something else?
2. HP: do fallen units return at 1 HP after each fight (my default), or should units be lost for the run?
3. Can you change actions and gambits between nodes (my default)?
4. Are the reward numbers above in the right range?

Raid:
5. Is the rotation (2 strong and 2 weak elements, plus one high and one low stat) the variety you wanted?
6. Which do you want first, Paths or the Raid?

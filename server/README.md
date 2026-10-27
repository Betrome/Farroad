# Farroad PvP server

The game itself, exported for Linux as a dedicated server and run headless on
Google Cloud Run. Players are kept in Firestore.

## Build

From `godot-project`, export the **Linux Server** preset to
`server/farroad_server.x86_64`.

## Deploy

```
gcloud run deploy farroad-arena --source server --region us-central1 \
  --max-instances 1 --min-instances 0 --memory 512Mi --cpu 1 \
  --no-invoker-iam-check --set-env-vars FARROAD_STORE=firestore
```

`--no-invoker-iam-check` is what makes the service public: it switches Cloud Run's
permission check off. (`--allow-unauthenticated` instead tries to add an "allUsers"
permission, which the account can't set, so it ends with an "IAM policy failed" error
even though the deploy itself succeeds.) After deploying, check the live version:
`curl https://farroad-arena-3poidf5yha-uc.a.run.app/version` should report the new
game version (for example `2.40-...`).

`--max-instances 1` matters: fights update two players' ratings, and one
instance handles requests one at a time.

## Local testing

```
Godot --headless --path godot-project -- --server --port 8910 --data <folder>
```

Then start the game with `-- --arena http://127.0.0.1:8910`.

## Community raid boss (built, switched off)

The Raids tab's shared HP bar (`Raids.gd`, and the raid code in `ArenaServer.gd`) is **off by default**: the
`/raid/*` endpoints answer `raids_off` and the game shows no community bar. To turn it on, start the server with
`FARROAD_RAIDS=1` (on Cloud Run add it to `--set-env-vars`, like `FARROAD_SEASONS`).

- Each raid attempt reports the share of the player's *own* boss it took (their boss is scaled to their own
  strength). The server adds the shares up per week (Monday 00:00 UTC), a player adds at most 1.0 (their own whole boss) per week, and 3 attempts a
  day count per player.
- The community boss has `max(5, 0.25 x players)` shares of HP, fixed when the week's first request arrives.
  Milestones at 25 / 50 / 75 / 100% pay everyone who took a Bronze share or more: 2 / 5 / 10 / 20 Crystal and 0 / 0 / 1 / 2
  Distilled Aether (cumulative), added to their weekly claim. Once the boss is down nobody can fight it until the week resets.
- Endpoints: `/raid/state {id, key, week?}` and `/raid/report {id, key, week, pct}`. Documents: `raid-<week>` in the meta store.
- Cloud-save checks (`SaveCheck`) allow for these rewards in their weekly credit.

## Weekly seasons (built, switched off)

Arena seasons (`godot-project/scripts/Seasons.gd`, and the season code in `ArenaServer.gd`) are
**off by default**: a server started the usual way behaves exactly as before, and the game shows
nothing about seasons because the server doesn't mention them.

To turn them on, start the server with `FARROAD_SEASONS=1` (on Cloud Run: add
`FARROAD_SEASONS=1` to `--set-env-vars`, e.g. `--set-env-vars FARROAD_STORE=firestore,FARROAD_SEASONS=1`).
Remove it to turn them off again.

How a season works:
- A season is Monday 00:00 UTC to the next Monday 00:00 UTC. The first one starts the first time a
  server with seasons on runs; it is "Season 1".
- Every fight you start counts. With at least 5 fights in the season you get a tier from your final
  rating (Bronze, Silver 1050, Gold 1100, Platinum 1200; the top 3 with 1250 or more are Champion).
- When the season ends the server leaves each qualifying player a reward to claim the next time they
  open the Arena, and pulls every real player's rating halfway back to 1000. The seven ready-made
  rival teams are not reset.
- Rewards (Crystals / Marks as pulls' worth / Distilled Aether): Bronze 2 / 1 / 1, Silver 4 / 2 / 1,
  Gold 7 / 3 / 2, Platinum 12 / 5 / 3, Champion 25 / 10 / 5. Change them in `Seasons.gd`.

Local test: `Godot --headless --path godot-project -- --server --port 8910 --seasons --data <folder>`;
`--time-offset=SECONDS` moves the server's clock, to try a season ending.

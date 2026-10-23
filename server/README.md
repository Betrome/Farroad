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
  rating (Bronze, Silver 1050, Gold 1100, Platinum 1200; the top 3 with 1150 or more are Champion).
- When the season ends the server leaves each qualifying player a reward to claim the next time they
  open the Arena, and pulls every real player's rating halfway back to 1000. The seven ready-made
  rival teams are not reset.
- Rewards (Crystals / Marks as pulls' worth / Distilled Aether): Bronze 2 / 1 / 1, Silver 4 / 2 / 1,
  Gold 7 / 3 / 2, Platinum 12 / 5 / 3, Champion 25 / 10 / 5. Change them in `Seasons.gd`.

Local test: `Godot --headless --path godot-project -- --server --port 8910 --seasons --data <folder>`;
`--time-offset=SECONDS` moves the server's clock, to try a season ending.

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
  --allow-unauthenticated --set-env-vars FARROAD_STORE=firestore
```

`--max-instances 1` matters: fights update two players' ratings, and one
instance handles requests one at a time.

## Local testing

```
Godot --headless --path godot-project -- --server --port 8910 --data <folder>
```

Then start the game with `-- --arena http://127.0.0.1:8910`.

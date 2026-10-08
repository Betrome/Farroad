# The Farroad PvP server for Google Cloud Run: the game's Linux
# dedicated-server export, run headless. Build the export first (Godot,
# preset "Linux Server" -> server/farroad_server.x86_64), then deploy this
# folder (see server/README.md).
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY farroad_server.x86_64 ./
RUN chmod +x farroad_server.x86_64
ENV FARROAD_STORE=firestore
# Cloud Run sets PORT; the server reads it.
CMD ["./farroad_server.x86_64", "--headless", "--", "--server"]

class_name CatchupRef
extends Node
## The wave the new-player catch-up bonus fades out at: the average highest-cleared
## boss wave of the player base, reported by the Farroad server (/stats). The last
## answer is kept on the device so it still applies offline; until there is one,
## or while too few players have cleared a boss for an average to mean anything,
## FarroadProgression.CATCHUP_REF_WAVE_DEFAULT stays in force.

const CACHE_FILE := "user://catchup_ref.json"
const REFRESH_EVERY_SEC := 10800.0   # 3 hours
## An average over fewer players than this is just those few people.
const MIN_PLAYERS := 5
const MIN_REF_WAVE := 40.0
const MAX_REF_WAVE := 5000.0

var _client: RankedClient

## Uses the last answer saved on this device. Call early, before any catch-up
## reward is worked out.
static func apply_cached() -> void:
	if not FileAccess.file_exists(CACHE_FILE):
		return
	var f := FileAccess.open(CACHE_FILE, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		apply(float(d.get("bossAvg", 0.0)), int(d.get("players", 0)))

static func apply(boss_avg: float, players: int) -> void:
	if players >= MIN_PLAYERS and boss_avg > 0.0:
		FarroadProgression.catchup_ref_wave = clampf(boss_avg, MIN_REF_WAVE, MAX_REF_WAVE)
	else:
		FarroadProgression.catchup_ref_wave = FarroadProgression.CATCHUP_REF_WAVE_DEFAULT

func setup(client: RankedClient) -> void:
	_client = client
	var t := Timer.new()
	t.wait_time = REFRESH_EVERY_SEC
	t.autostart = true
	t.ignore_time_scale = true
	t.timeout.connect(refresh)
	add_child(t)
	refresh()

## Asks the server for the current average. A failed request changes nothing.
func refresh() -> void:
	if not RankedClient.online():
		return
	var res := await _client.call_api("/stats")
	if res.has("error") or not res.has("bossAvg"):
		return
	var avg := float(res["bossAvg"])
	var players := int(res.get("players", 0))
	var w := FileAccess.open(CACHE_FILE, FileAccess.WRITE)
	if w != null:
		w.store_string(JSON.stringify({"bossAvg": avg, "players": players}))
		w.close()
	apply(avg, players)

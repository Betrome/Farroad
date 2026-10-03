class_name Notifier
extends Node
## Ian: notifications when idle rewards are full or an expedition party is
## back. Android: local notifications scheduled when the game is closed or
## sent to the background (NotificationScheduler plugin, addons/), cancelled
## when it's opened again. Windows: a system notification when a party gets
## home while the game is open but not focused. Players can turn them off
## in Settings; Android asks for permission the first time the game opens.

const CHANNEL_ID := "farroad"
const ID_IDLE := 1
const ID_EXPEDITION_BASE := 10   # one id per expedition slot, 10..10+MAX_EXP-1
const MAX_EXP := 8

var g: Dictionary
var _scheduler: Node = null   # NotificationScheduler (Android only)
var _ready_android := false

static func enabled() -> bool:
	return bool(Analytics.state.get("notify", true)) if not Analytics.state.is_empty() else true

static func set_enabled(on: bool) -> void:
	Analytics.enabled()   # loads the device settings file
	Analytics.state["notify"] = on
	Analytics._dirty = true
	Analytics.save()

func setup(game: Dictionary) -> void:
	g = game
	Analytics.enabled()   # make sure the device settings are loaded
	if OS.get_name() == "Android" and Engine.has_singleton("NotificationSchedulerPlugin"):
		_scheduler = load("res://addons/NotificationSchedulerPlugin/NotificationScheduler.gd").new()
		add_child(_scheduler)
		_scheduler.initialization_completed.connect(_on_android_ready)
		_scheduler.initialize()

func _on_android_ready() -> void:
	_ready_android = true
	var ch = load("res://addons/NotificationSchedulerPlugin/model/NotificationChannel.gd").new()
	ch.set_id(CHANNEL_ID).set_name("Farroad").set_description("Idle rewards and expedition returns") \
		.set_importance(3)
	_scheduler.create_notification_channel(ch)
	cancel_scheduled()   # the game is open: nothing pending should fire
	# Ian: ask the first time the game is opened.
	if not bool(Analytics.state.get("notifyAsked", false)):
		Analytics.state["notifyAsked"] = true
		Analytics._dirty = true
		Analytics.save()
		if not _scheduler.has_post_notifications_permission():
			_scheduler.request_post_notifications_permission()

func cancel_scheduled() -> void:
	if not _ready_android:
		return
	_scheduler.cancel(ID_IDLE)
	for i in MAX_EXP:
		_scheduler.cancel(ID_EXPEDITION_BASE + i)

## Called when the game is closed or backgrounded: schedule what will happen
## while it's away.
func schedule_away() -> void:
	if not _ready_android:
		return
	cancel_scheduled()
	if not enabled() or g.is_empty():
		return
	var now := Time.get_unix_time_from_system()
	var still_out := 0
	var i := 0
	for exp in g.get("expeditions", []):
		if exp.get("arrivedAt") != null:
			continue
		if exp.get("homeAt") != null:
			if i < MAX_EXP:
				_schedule(ID_EXPEDITION_BASE + i, "Expedition back",
					"%s are back from the %s. Collect their haul!" % [FarroadProgression._expedition_names(exp["partyIds"]),
						FarroadProgression.direction_label(exp["direction"]).to_lower()],
					maxi(1, roundi(float(exp["homeAt"]) - now)))
				i += 1
		else:
			still_out += 1
	var body := "Your idle rewards are full."
	if still_out > 0:
		body += " Your expeditions have gone as far as they can while you're away."
	_schedule(ID_IDLE, "Farroad", body + " Come back to collect!", FarroadProgression.OFFLINE_CAP_SEC)

func _schedule(id: int, title: String, text: String, delay_sec: int) -> void:
	var data = load("res://addons/NotificationSchedulerPlugin/model/NotificationData.gd").new()
	data.set_id(id).set_channel_id(CHANNEL_ID).set_title(title).set_content(text).set_delay(delay_sec)
	_scheduler.schedule(data)

## Windows: a party got home while the game was open but not in focus.
func on_expedition_arrived(exp: Dictionary) -> void:
	if not enabled() or OS.get_name() != "Windows" or DisplayServer.window_is_focused():
		return
	toast("Expedition back", "%s are back from the %s. Collect their haul!" % [
		FarroadProgression._expedition_names(exp["partyIds"]),
		FarroadProgression.direction_label(exp["direction"]).to_lower()])

## A Windows notification through the system's own toast service (no extra
## software; shown under PowerShell's name).
static func toast(title: String, text: String) -> void:
	var esc := func(s: String) -> String:
		return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "''")
	var script := """
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$x = New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>%s</text><text>%s</text></binding></visual></toast>')
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))
""" % [esc.call(title), esc.call(text)]
	OS.create_process("powershell.exe", ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script])

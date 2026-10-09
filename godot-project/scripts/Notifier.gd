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

## Ian: each kind of alert has its own switch ("idle" = rewards full,
## "expedition" = a party is home), under the master one.
static func kind_enabled(kind: String) -> bool:
	return enabled() and (bool(Analytics.state.get("notify_" + kind, true)) if not Analytics.state.is_empty() else true)

static func set_kind_enabled(kind: String, on: bool) -> void:
	Analytics.enabled()
	Analytics.state["notify_" + kind] = on
	Analytics._dirty = true
	Analytics.save()

## Which delivery this device uses.
static func platform() -> String:
	if OS.has_feature("web"):
		return "web"
	return OS.get_name().to_lower()   # "android", "windows", ...

func setup(game: Dictionary) -> void:
	g = game
	Analytics.enabled()   # make sure the device settings are loaded
	if OS.get_name() == "Android" and Engine.has_singleton("NotificationSchedulerPlugin"):
		_scheduler = load("res://addons/NotificationSchedulerPlugin/NotificationScheduler.gd").new()
		add_child(_scheduler)
		_scheduler.initialization_completed.connect(_on_android_ready)
		_scheduler.initialize()
	elif platform() == "windows" and bool(Analytics.state.get("winScheduled", false)):
		cancel_scheduled()   # the game is open: nothing should still be waiting

func _on_android_ready() -> void:
	_ready_android = true
	var ch = load("res://addons/NotificationSchedulerPlugin/model/NotificationChannel.gd").new()
	ch.set_id(CHANNEL_ID).set_name("Farroad").set_description("Idle rewards and expedition returns") \
		.set_importance(3)
	_scheduler.create_notification_channel(ch)
	var was_pending := _pending_schedule
	cancel_scheduled()   # the game is open: nothing pending should fire
	if was_pending:
		schedule_away()
		return
	# Ian: ask the first time the game is opened.
	if not bool(Analytics.state.get("notifyAsked", false)):
		Analytics.state["notifyAsked"] = true
		Analytics._dirty = true
		Analytics.save()
		if not _scheduler.has_post_notifications_permission():
			_scheduler.request_post_notifications_permission()
	# Ian: "idle reward notifications trigger ~20 minutes late." Without the
	# "Alarms & reminders" permission Android only lets the alarm go off
	# roughly, and holds it back while the phone is idle. Ask once (opens the
	# system screen), after the notification permission is sorted.
	elif not bool(Analytics.state.get("exactAlarmAsked", false)):
		Analytics.state["exactAlarmAsked"] = true
		Analytics._dirty = true
		Analytics.save()
		if not _scheduler.has_schedule_exact_alarm_permission():
			_scheduler.request_schedule_exact_alarm_permission()

var _pending_schedule := false

func cancel_scheduled() -> void:
	_pending_schedule = false
	match platform():
		"android":
			if not _ready_android:
				return
			_scheduler.cancel(ID_IDLE)
			for i in MAX_EXP:
				_scheduler.cancel(ID_EXPEDITION_BASE + i)
		"windows":
			_win_run(_win_header())
			Analytics.state["winScheduled"] = false
			Analytics._dirty = true
		"web":
			_web_eval("(window.__frTimers||[]).forEach(clearTimeout); window.__frTimers=[];")

## What will happen while the game is away, as alerts to deliver: each
## {slot, title, text, delay} (delay in seconds from now).
func plan() -> Array:
	var out: Array = []
	if not enabled() or g.is_empty():
		return out
	var now := Time.get_unix_time_from_system()
	var still_out := 0
	var i := 0
	var idx := -1
	for exp in g.get("expeditions", []):
		idx += 1
		if exp.get("arrivedAt") != null:
			continue
		# A party that hasn't turned back yet has no known home time (the
		# game only works that out when it is open), so work out when it
		# will turn back by playing the trip forward on a throwaway copy --
		# each expedition has its own fixed random stream, so that is exact.
		var home_at: float = float(exp["homeAt"]) if exp.get("homeAt") != null else _predict_home(idx, now)
		if home_at > 0.0:
			if i < MAX_EXP and kind_enabled("expedition"):
				out.append({"slot": ID_EXPEDITION_BASE + i, "title": "Expedition back", "text": _return_text(exp),
					"delay": maxi(1, roundi(home_at - now))})
			i += 1
		else:
			still_out += 1
	if kind_enabled("idle"):
		var body := "Your idle rewards are full."
		if still_out > 0 and kind_enabled("expedition"):
			body += " Your expeditions have gone as far as they can while you're away."
		out.append({"slot": ID_IDLE, "title": "Farroad", "text": body + " Come back to collect!",
			"delay": int(FarroadProgression.OFFLINE_CAP_SEC)})
	return out

## Called when the game is closed or backgrounded: schedule what will happen
## while it's away. Android: system alarms. Windows: scheduled toasts, which
## the system delivers even though the game is closed. Web: timers in the
## page, which work while the tab stays open in the background (a closed tab
## can't notify).
func schedule_away() -> void:
	match platform():
		"android":
			if not _ready_android:
				# the plugin is still starting (opened and closed again quickly):
				# schedule the moment it is ready, unless the game is reopened first
				_pending_schedule = _scheduler != null
				return
			cancel_scheduled()
			for item in plan():
				_schedule(item["slot"], item["title"], item["text"], item["delay"])
		"windows":
			_win_schedule(plan())
		"web":
			cancel_scheduled()
			_web_schedule(plan())

func _schedule(id: int, title: String, text: String, delay_sec: int) -> void:
	var data = load("res://addons/NotificationSchedulerPlugin/model/NotificationData.gd").new()
	data.set_id(id).set_channel_id(CHANNEL_ID).set_title(title).set_content(text).set_delay(delay_sec)
	_scheduler.schedule(data)

## ===== Windows scheduled toasts =====
const WIN_AUMID := "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"

## Runs a PowerShell script without a window. Passed on the command line,
## Windows strips the double quotes out of it (which breaks the toast XML), so
## it goes through a small file that deletes itself when it has run.
static func _win_run(script: String) -> void:
	var path := ProjectSettings.globalize_path("user://notify_%d.ps1" % Time.get_ticks_usec())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))   # BOM, so PowerShell reads it as UTF-8
	f.store_string(script + "
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
")
	f.close()
	OS.create_process("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", path])

## Loads the toast types and drops every Farroad toast still waiting.
static func _win_header() -> String:
	return """
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ScheduledToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$n = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('%s')
foreach ($s in $n.GetScheduledToastNotifications()) { if ($s.Id -like 'fr-*') { $n.RemoveFromSchedule($s) } }
""" % WIN_AUMID

static func _xml_escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "''")

func _win_schedule(items: Array) -> void:
	var script := _win_header()
	var now := Time.get_unix_time_from_system()
	for item in items:
		script += """
$x = New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>%s</text><text>%s</text></binding></visual></toast>')
$t = [Windows.UI.Notifications.ScheduledToastNotification]::new($x, [DateTimeOffset]::FromUnixTimeSeconds(%d))
$t.Id = 'fr-%d'
$n.AddToSchedule($t)
""" % [_xml_escape(item["title"]), _xml_escape(item["text"]), int(now) + int(item["delay"]), int(item["slot"])]
	Analytics.state["winScheduled"] = not items.is_empty()
	Analytics._dirty = true
	Analytics.save()
	_win_run(script)

## ===== Web notifications (the browser's Notification API) =====
static func _web_eval(js: String) -> Variant:
	if not OS.has_feature("web"):
		return null
	return JavaScriptBridge.eval(js, true)

## "default" (not asked yet), "granted", "denied", or "unsupported".
static func web_permission() -> String:
	if not OS.has_feature("web"):
		return "unsupported"
	var r = JavaScriptBridge.eval("(typeof Notification === 'undefined') ? 'unsupported' : Notification.permission", true)
	return str(r)

## Browsers only allow this straight after a tap or click.
static func web_request_permission() -> void:
	_web_eval("if (typeof Notification !== 'undefined') Notification.requestPermission();")

func _web_schedule(items: Array) -> void:
	if items.is_empty():
		return
	var list: Array = []
	for item in items:
		list.append({"tag": "fr-%d" % int(item["slot"]), "title": item["title"], "text": item["text"], "ms": int(item["delay"]) * 1000})
	_web_eval("""(function(items){
		window.__frTimers = window.__frTimers || [];
		items.forEach(function(i){
			window.__frTimers.push(setTimeout(function(){
				if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
					var n = new Notification(i.title, {body: i.text, tag: i.tag});
					n.onclick = function(){ window.focus(); n.close(); };
				}
			}, i.ms));
		});
	})(%s);""" % JSON.stringify(list))

## A test alert on this device (Settings).
func send_test() -> String:
	match platform():
		"android":
			if not _ready_android:
				return "Notifications aren't ready on this device yet."
			_schedule(98, "Farroad", "This is a test notification.", 3)
			return "Sent. It should arrive in a few seconds (leave the game open or close it)."
		"windows":
			toast("Farroad", "This is a test notification.")
			return "Sent."
		"web":
			var perm := web_permission()
			if perm == "granted":
				_web_eval("var n = new Notification('Farroad', {body: 'This is a test notification.'}); n.onclick = function(){ window.focus(); n.close(); };")
				return "Sent."
			if perm == "denied":
				return "Notifications are blocked for this site. Allow them in your browser's site settings."
			web_request_permission()
			return "Allow notifications in the browser prompt, then press this again."
	return "Notifications aren't available on this device."

## Windows: a party got home while the game was open but not in focus.
func on_expedition_arrived(exp: Dictionary) -> void:
	if not kind_enabled("expedition") or OS.get_name() != "Windows" or DisplayServer.window_is_focused():
		return
	toast("Expedition back", _return_text(exp))

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
	_win_run(script)

## "Ansa's party has returned from exploring to the west." -- the first
## member names the party; no member list.
static func _return_text(exp: Dictionary) -> String:
	var where: String = FarroadProgression.direction_label(exp["direction"]).to_lower()
	# a saved party goes by its own name (Ian)
	var party_nm: String = str(exp.get("partyName", ""))
	if party_nm != "":
		return "%s has returned from exploring to the %s." % [party_nm, where]
	var leader := "Your"
	var ids: Array = exp.get("partyIds", [])
	if not ids.is_empty():
		var def = FarroadCore.roster_by_id(ids[0])
		leader = ("%s's" % def["name"]) if def != null else "Your"
	return "%s party has returned from exploring to the %s." % [leader, where]

## When a party that is still out will turn back, found by playing the trip
## forward on a deep copy of the game (never the real one). -1 if it won't
## turn back within the longest stretch a single catch-up covers.
func _predict_home(idx: int, now: float) -> float:
	var gc: Dictionary = {}
	for k in g.keys():
		if k in ["battle", "units", "enemies", "roadBattle", "sideBattle", "over", "rng"]:
			continue
		var v = g[k]
		gc[k] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	gc["rng"] = FarroadCore.make_rng(0)   # placeholder; the expedition brings its own stream
	gc["_dryRun"] = true
	var exps: Array = gc.get("expeditions", [])
	if idx >= exps.size():
		return -1.0
	var exp: Dictionary = exps[idx]
	FarroadProgression.resolve_expedition(gc, exp, now + FarroadProgression.OFFLINE_CAP_SEC)
	return float(exp["homeAt"]) if exp.get("homeAt") != null else -1.0

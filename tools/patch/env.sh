# Shared settings for the test-patch scripts. Override GODOT / ADB in the environment if needed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GODOT="${GODOT:-$LOCALAPPDATA/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe}"
ADB="${ADB:-/c/Users/Lucas/AndroidSdk/platform-tools/adb.exe}"
OUT="$ROOT/builds/test"
PHONE_DIR="/sdcard/Android/data/com.farroad.game/files"
PRESET="Android Test"
mkdir -p "$OUT"

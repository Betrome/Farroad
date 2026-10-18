#!/usr/bin/env bash
# Builds patch.pck (only the files changed since base.pck) and, if a phone is connected
# over adb, pushes it to the app's files folder. Usage: patch.sh [--no-push]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
[ -f "$OUT/base.pck" ] || { echo "No base.pck: run tools/patch/base.sh first."; exit 1; }
cd "$ROOT/godot-project"
stamp="patch-$(date +%Y%m%d-%H%M%S)"
orig_info="$(cat patch_info.json)"
trap 'printf "%s
" "$orig_info" > patch_info.json' EXIT
printf '{"stamp": "%s"}\n' "$stamp" > patch_info.json
"$GODOT" --headless --path . --import > /dev/null 2>&1 || true
rm -f "$OUT/patch.pck"
"$GODOT" --headless --path . --export-patch "$PRESET" "$OUT/patch.pck" --patches "$OUT/base.pck"
ls -la "$OUT/patch.pck"
if [ "${1:-}" = "--no-push" ]; then echo "Patch built ($stamp). Not pushed."; exit 0; fi
if "$ADB" devices | grep -qw device; then
  "$ADB" shell mkdir -p "$PHONE_DIR"
  "$ADB" push "$OUT/patch.pck" "$PHONE_DIR/patch.pck"
  echo "Patch $stamp pushed. Close the game completely and reopen it."
else
  echo "Patch built ($stamp), but no phone is connected over adb."
  echo "Copy $OUT/patch.pck to $PHONE_DIR/ on the phone."
fi

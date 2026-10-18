#!/usr/bin/env bash
# Builds the TEST base: the APK to install once on the phone (Farroad-test.apk) and
# base.pck, the reference every later patch is measured against. Re-run this (and
# reinstall the APK) when a change can't ship as a patch (see README.md).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ROOT/godot-project"
stamp="base-$(date +%Y%m%d-%H%M%S)"
orig_info="$(cat patch_info.json)"
trap 'printf "%s
" "$orig_info" > patch_info.json' EXIT
printf '{"stamp": "%s"}\n' "$stamp" > patch_info.json
"$GODOT" --headless --path . --import > /dev/null 2>&1 || true
rm -f "$OUT/base.pck" "$OUT/patch.pck" "$OUT/Farroad-test.apk"
"$GODOT" --headless --path . --export-pack "$PRESET" "$OUT/base.pck"
"$GODOT" --headless --path . --export-release "$PRESET" "$OUT/Farroad-test.apk"
echo "$stamp" > "$OUT/base-stamp.txt"
ls -la "$OUT/base.pck" "$OUT/Farroad-test.apk"
echo "Base built ($stamp). Install $OUT/Farroad-test.apk on the phone once."

# Test patches for the phone

Try a code change on the phone without installing a new APK. A **patch** is a Godot `.pck` that holds only the files that changed since a **base** build. A test build loads it at startup.

This is for testing only. A release is always a full APK (normal Android installs can't be delta-patched).

## How it is kept out of releases

- Test builds are exported from the **"Android Test"** preset, which sets the custom feature `patchable`. The normal "Android" preset has no such feature.
- `scripts/PatchLoader.gd` (an autoload) does nothing unless that feature is set. On a desktop it can also be switched on with `-- --patchable`, debug builds only.
- The patch is read from the app's own files folder, which other apps can't write to. There is no network download.
- Crash-loop guard: if the game doesn't run for 8 seconds after loading a patch, the next start sets the patch aside (`patch.pck.bad`) and starts without it.

## Workflow

1. **Once:** `bash tools/patch/base.sh`. This builds `builds/test/Farroad-test.apk` and `builds/test/base.pck`. Install the APK on the phone (it has the same package name and signing key as the real game, so it installs over it and keeps the save).
2. **After each change:** `bash tools/patch/patch.sh`. This builds `builds/test/patch.pck` (only changed files, usually under 1 MB) and, if the phone is connected over adb (USB debugging), pushes it to `/sdcard/Android/data/com.farroad.game/files/patch.pck`. Use `--no-push` to just build it.
3. Close the game completely and reopen it. **Menu** (bottom right) shows "Test build. Patch loaded: patch-<time>", and has a **Remove test patch** button.

Without adb, copy `builds/test/patch.pck` to that folder on the phone any other way.

## What a patch can't carry (needs a new base APK: run `base.sh` and reinstall)

- A new script with a `class_name` (the class list is read before the patch loads).
- Changes to `project.godot` (settings, autoloads) or the export preset.
- Native plugins, the Android build template, the engine version.
- `patch.sh` always compares to the last `base.pck`; run `base.sh` again to reset that reference.

## Files

- `base.sh`, `patch.sh`, `env.sh` (paths; override `GODOT` / `ADB` in the environment).
- `godot-project/patch_info.json`: the stamp shown in the Menu. The scripts overwrite it for the export and restore it afterwards.
- The "Android Test" preset lives in `godot-project/export_presets.cfg` (not in git). Its signing settings are in `godot-project/.godot/export_credentials.cfg`, copied from the "Android" preset.

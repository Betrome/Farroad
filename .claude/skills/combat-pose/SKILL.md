---
name: combat-pose
description: Recreate a combat pose (from a reference photo/description) on the Farroad Blender rig, render its skeleton, re-pose the male/female main-character masters with Qwen-Image-Edit, and score how close each step got. Use when making keyframes, practising poses, or turning a reference into a sprite pose.
---

# Combat pose -> rig -> sprite

The loop: **reference -> keypoints -> fit the rig -> render guide -> Qwen re-pose (male + female) -> pixelize -> measure -> adjust.**
Every step is measurable, so every attempt gets a score and a note on what to change.

## Pieces (all in the repo unless noted)

| Step | Tool |
|---|---|
| Rig and guides | `tools/blender_rig.py` (headless: `blender -b --factory-startup -P tools/blender_rig.py -- pose.json out_dir`) writes `depth.png`, `shaded.png`, `openpose.json` (COCO-18 plus a `sword` hilt->tip line) and `openpose.png`. Hand posing happens in `art_src/mc/rig/farroad_rig.blend` (Farroad sidebar tab). |
| Pose format | `{"root":{"hips":[fwd,left,up],"rotation":[x,y,z]}, "bones":{"spine":[x,y,z],"head":[x,y,z]}, "targets":{"hand.L/R","aim.L/R","elbow.L/R","foot.L/R","knee.L/R"}}`, all in world units (1 = one head). +X = forward (screen right), +Y = the character's left, +Z = up, feet on z=0. The hips rest at z=1.3. A hand or foot reaches at most 97% of the limb length, and elbows/knees bend toward their pole points. |
| Keypoints from an image | The desktop ComfyUI `DWPreprocessor` (http://192.168.50.77:8188; bbox_detector yolox_l for photos, "None" for pixel art; `SavePoseKpsAsJsonFile` saves its POSE_KEYPOINT output). **As of 2026-09-25 its model is not on the desktop** (the auto-download fails: the Windows path under `ckpts\hr16\DWPose-TorchScript-BatchSize5\.cache\...` is too long), so keypoints are annotated by hand: `tools/pose_score.py` `parse_points` format, on a grid overlay. |
| Fit the rig to a reference | `tools/pose_fit.py` (inside Blender): `blender -b --factory-startup -P tools/pose_fit.py -- target.json out_dir [--spec spec.json] [--init pose.json]` -> pose.json (+ `fit_params`), fit.json, guides. |
| Score two poses | `tools/pose_score.py REF.json OTHER.json` (joint / limb-angle / sword error, auto-mirror). |
| One practice round | `tools/pose_practice.py run ROUND.json` (fit, guide, Qwen male+female, pixelize, annotate.png), then write `male_kp.txt`/`female_kp.txt` and `finish ROUND_DIR` (scores, sheet.png, record.json, gallery.html). |
| Re-pose a sprite | `tools/qwen_edit.py SPRITE OUT --pose openpose.png --prompt ...` (image1 = sprite, image2 = skeleton). Skeleton guides work; shaded/depth mannequin renders get copied literally. ~24 s warm. |
| Back to true pixels | `tools/pixelize.py`: `pixelize(img, block=16, palette=shared_palette([master]), keep_largest=True)` |
| Masters | `art_src/mc/v2/male_master_64.png`, `female_master_64.png` (64x64, facing right) |

## Measuring closeness
Compare 2D keypoint sets after normalising: translate the neck to the origin and scale by the neck-to-mid-hip length. Then take:
- **joint error**: mean distance over the body joints (0-13), in torso lengths;
- **limb-angle error**: mean absolute angle difference over the 12 limb segments. This is the more meaningful one;
- **sword angle**: the direction of the grey line vs the reference weapon, when the reference has one.

Score three stages: reference->rig, rig->Qwen male, rig->Qwen female (DWPose on the 1024 Qwen output, with no bbox detector).

## Rules that always apply (Ian's art rules)
- Characters face **right**. The sword is in `hand.R`, the hand nearer the camera.
- Poses must read as a **dynamic, unique silhouette** at ~60 px. Keep the same weapon hand and facing within a move. No hand hidden behind the body; the sword hand stays visible and connected.
- FFBE attack timing: wind-up held ~4 frames, strike held ~4 frames plus a trail, then recovery.
- **Never feed third-party art into AI tools** (Otsoga's especially). Reference photos are only used to extract a skeleton. Only the skeleton goes further; never pass a reference into Qwen/SD.
- Only use references whose licence allows it (e.g. Wikimedia Commons CC/PD). Record source URL, author and licence. Don't commit the photos themselves.

## Lessons (append as you learn)
- The camera sits at the character's front-right three-quarter (azimuth -45, elevation 8, ortho). A stance that is wide along X reads as crossed legs from here, so spread the feet along Y too.
- Qwen picks up the pose from the skeleton and the palette/identity from the master. It may still invent small things (belts, shadows, head tilt): pick the best of 3 seeds.
- Hand-annotating: always check the skeleton overlaid on the source before using it (mkref-style `_check.png`); misreading the grid by one label is easy. Label "R" = the sword arm; read the rig guide's colours before annotating the sprites (R leg = green/cyan, L leg = blue; R arm = orange/yellow, L arm = green) or the legs get swapped.
- pose_fit: set the scene to a square resolution before projecting (Blender's default 1920x1080 stretches the keypoints). Rig axes: `rot.y` + = hips pitch forward, `spine.z` - = lean forward, `spine.x` = lean sideways (toward the camera), `spine.y` = twist.
- A real person is ~7.5 heads, the rig ~4.4: compare joints only after retargeting the reference onto the rig's limb lengths (pose_fit does this), or the fit folds the chibi legs to reach the long-legged feet. Limb angles are unaffected.
- Ground-plane back-projection is ill-conditioned at 8 deg elevation; the first guess puts points on constant-Y (side) planes instead, and multi-start covers crouch depth and lean.
- The sword must stay outside the body silhouette for most of its length. When the guide's blade crosses the face Qwen hides it behind the head, cut off from the hands; when it runs along the arm/torso Qwen may drop it entirely. pose_fit penalises a blade across the face.
- Never foreshorten the sword: a blade pointing at the camera becomes a stub on a 60 px sprite. pose_fit asks for a full-length blade by default. Also annotate the whole blade (don't clip it at a crop edge).
- Pixelize Qwen output with background tolerance ~40 (not 90: the light-grey blade touching the white background gets flood-filled away) and add a few steel greys to the master palette (light blades otherwise snap to skin beige); cap the result at 16 colours.
- Qwen follows the guide's limb directions closely when limbs are clear of each other (the long point came out almost exact); it doesn't copy extreme crouches (thighs stay steeper than the rig's).

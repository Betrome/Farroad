#!/usr/bin/env python3
"""
Farroad art pipeline: animate a character with Stable Diffusion alone
("option 3"), frame by frame, on the desktop's ComfyUI server.

For each pose in a sequence:
  - start from the PREVIOUS frame's image (img2img; frame 1 starts from the
    reference design itself), so details carry over frame to frame -- or,
    with --init-from-reference, from the reference every time,
  - guide the new pose with an OpenPose skeleton (ControlNet),
  - lock identity to the reference design with IP-Adapter (if installed
    on the server; --no-ipadapter to skip),
then run tools/pixelize.py on every frame with one shared palette.

The pose sequence is a JSON file: {"canvas": [W, H], "frames": [kp18, ...]}
where each kp18 is 18 OpenPose keypoints (x, y, conf triples, COCO order;
see tools/pose_render.py).

Usage:
  python tools/sd_animate.py reference.png poses.json out_dir "<prompt>"
      [--denoise 0.55] [--seed 7] [--ip-weight 0.8] [--no-ipadapter]
"""
import argparse
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import comfy_gen as cg  # noqa: E402
import pixelize as px  # noqa: E402
import pose_render  # noqa: E402

NEGATIVE = ("multiple characters, duplicate, blurry, lowres, text, watermark, cropped, out of frame, "
            "extra limbs, extra arms, deformed, bad anatomy, ground shadow, floor, gradient background")


def frame_workflow(prompt, init_name, pose_name, ref_name, seed, denoise, ip_weight, use_ip, prefix):
    wf = cg.workflow(prompt, NEGATIVE, seed, 512, 512, 30, 7.0, 1, 1.0, prefix)
    # img2img: replace the empty latent with the encoded init image.
    wf["30"] = {"class_type": "LoadImage", "inputs": {"image": init_name}}
    wf["31"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["30", 0], "vae": ["1", 2]}}
    wf["7"]["inputs"]["latent_image"] = ["31", 0]
    wf["7"]["inputs"]["denoise"] = denoise
    del wf["6"]
    cg.add_pose_control(wf, pose_name, 1.0)
    if use_ip:
        wf["40"] = {"class_type": "LoadImage", "inputs": {"image": ref_name}}
        wf["41"] = {"class_type": "IPAdapterUnifiedLoader", "inputs": {
            "model": ["2", 0], "preset": "PLUS (high strength)"}}
        wf["42"] = {"class_type": "IPAdapterAdvanced", "inputs": {
            "model": ["41", 0], "ipadapter": ["41", 1], "image": ["40", 0],
            "weight": ip_weight, "weight_type": "linear", "combine_embeds": "concat",
            "start_at": 0.0, "end_at": 1.0, "embeds_scaling": "V only"}}
        wf["7"]["inputs"]["model"] = ["42", 0]
    return wf


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reference")
    ap.add_argument("poses")
    ap.add_argument("out_dir")
    ap.add_argument("prompt")
    ap.add_argument("--denoise", type=float, default=0.55)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--ip-weight", type=float, default=0.8)
    ap.add_argument("--no-ipadapter", action="store_true")
    ap.add_argument("--colors", type=int, default=40)
    ap.add_argument("--init-from-reference", action="store_true",
                    help="start every frame from the reference instead of the previous frame (no error build-up)")
    a = ap.parse_args()

    os.makedirs(a.out_dir, exist_ok=True)
    seq = json.load(open(a.poses))
    W, H = seq["canvas"]
    tag = os.path.basename(os.path.normpath(a.out_dir))
    ref_name = cg.upload(a.reference, tag + "_ref.png")
    init_name = ref_name
    raws = []
    for i, kp in enumerate(seq["frames"]):
        pose_path = os.path.join(a.out_dir, "pose_%d.png" % i)
        pose_render.render(kp, W, H).save(pose_path)
        pose_name = cg.upload(pose_path, "%s_pose_%d.png" % (tag, i))
        wf = frame_workflow(a.prompt, init_name, pose_name, ref_name, a.seed, a.denoise,
                            a.ip_weight, not a.no_ipadapter, "%s_f%d" % (tag, i))
        saved, secs = cg.run(wf, a.out_dir)
        raw = os.path.join(a.out_dir, "raw_%d.png" % i)
        os.replace(saved[0], raw)
        raws.append(raw)
        if not a.init_from_reference:
            init_name = cg.upload(raw, "%s_raw_%d.png" % (tag, i))
        print("frame %d: %.1fs" % (i, secs))

    first = [px.pixelize(Image.open(r), colors=256, keep_largest=True, orphans=False)[0] for r in raws]
    pal = px.shared_palette(first, a.colors)
    for i, r in enumerate(raws):
        s = px.pixelize(Image.open(r), keep_largest=True, palette=pal)[0]
        s.save(os.path.join(a.out_dir, "%d.png" % i))
    print("wrote %d frames to %s" % (len(raws), a.out_dir))


if __name__ == "__main__":
    main()

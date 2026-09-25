"""Re-pose a sprite with Qwen-Image-Edit-2511 on the desktop ComfyUI server.

    python tools/qwen_edit.py SPRITE OUT_DIR --prompt "..." [--pose POSE.png]
        [--seed 1] [--count 1] [--size 1024] [--mirror-pose]

SPRITE is small pixel art (e.g. a 64x64 master); it is nearest-upscaled to
--size so Qwen sees crisp pixels. POSE (optional) is a Blender rig render
passed as image2, so the prompt can say "pose the character from image 1
like the figure in image 2". Results come back at --size; run
tools/pixelize.py on them to get true pixels again.

Graph: the official image_qwen_image_edit_2511 template (native nodes;
Lightning 4-step fp8 model), as set up on the desktop 2026-09-25.
"""
import argparse
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import comfy_gen as cg  # noqa: E402

UNET = "qwen_image_edit_2511_fp8_e4m3fn_scaled_lightning_comfyui_4steps_v1.0.safetensors"
CLIP = "qwen_2.5_vl_7b_nvfp4.safetensors"
VAE = "qwen_image_vae.safetensors"


def prep(path, size, mirror=False, bg=(255, 255, 255)):
    """Nearest-upscale onto an opaque square canvas; returns a temp PNG path."""
    im = Image.open(path).convert("RGBA")
    if mirror:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    k = max(1, size // max(im.size))
    im = im.resize((im.width * k, im.height * k), Image.NEAREST)
    canvas = Image.new("RGBA", (size, size), bg + (255,))
    canvas.alpha_composite(im, ((size - im.width) // 2, (size - im.height) // 2))
    out = os.path.join(os.environ.get("TEMP", "."), "qwen_in_" + os.path.basename(path))
    canvas.convert("RGB").save(out)
    return out


def workflow(image_names, prompt, seed, prefix):
    wf = {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "2": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["1", 0], "shift": 3.1}},
        "3": {"class_type": "CFGNorm", "inputs": {"model": ["2", 0], "strength": 1.0}},
        "4": {"class_type": "CLIPLoader", "inputs": {"clip_name": CLIP, "type": "qwen_image"}},
        "5": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
    }
    refs = {}
    for i, name in enumerate(image_names):
        load, scale = str(10 + 2 * i), str(11 + 2 * i)
        wf[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
        wf[scale] = {"class_type": "FluxKontextImageScale", "inputs": {"image": [load, 0]}}
        refs["image%d" % (i + 1)] = [scale, 0]
    for nid, text in (("20", prompt), ("21", "")):
        wf[nid] = {"class_type": "TextEncodeQwenImageEditPlus",
                   "inputs": dict({"clip": ["4", 0], "prompt": text, "vae": ["5", 0]}, **refs)}
        wf[nid + "m"] = {"class_type": "FluxKontextMultiReferenceLatentMethod",
                         "inputs": {"conditioning": [nid, 0], "reference_latents_method": "index_timestep_zero"}}
    wf["30"] = {"class_type": "VAEEncode", "inputs": {"pixels": refs["image1"], "vae": ["5", 0]}}
    wf["31"] = {"class_type": "KSampler", "inputs": {
        "model": ["3", 0], "positive": ["20m", 0], "negative": ["21m", 0], "latent_image": ["30", 0],
        "seed": seed, "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}}
    wf["32"] = {"class_type": "VAEDecode", "inputs": {"samples": ["31", 0], "vae": ["5", 0]}}
    wf["33"] = {"class_type": "SaveImage", "inputs": {"images": ["32", 0], "filename_prefix": prefix}}
    return wf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sprite")
    ap.add_argument("out_dir")
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--pose")
    ap.add_argument("--mirror-pose", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--prefix", default="farroad_qwen")
    a = ap.parse_args()
    names = [cg.upload(prep(a.sprite, a.size), "qwen_sprite.png")]
    if a.pose:
        names.append(cg.upload(prep(a.pose, a.size, a.mirror_pose, bg=(0, 0, 0)), "qwen_pose.png"))
    for s in range(a.seed, a.seed + a.count):
        saved, secs = cg.run(workflow(names, a.prompt, s, a.prefix), a.out_dir)
        print("seed %d: %.1fs -> %s" % (s, secs, ", ".join(saved)))


if __name__ == "__main__":
    main()

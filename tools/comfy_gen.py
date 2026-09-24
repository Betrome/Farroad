#!/usr/bin/env python3
"""
Farroad art pipeline: generate images on the desktop's ComfyUI server.

Sends a Stable Diffusion 1.5 txt2img job (AnyLoRA checkpoint + 2D Pixel
Toolkit LoRA, clip skip 2) to ComfyUI's HTTP API, waits for it, and saves
the results locally. Only the Python standard library is needed.

Usage:
  python tools/comfy_gen.py "<prompt>" --out art_gen/test [--count 4]
      [--seed 1] [--width 512] [--height 512] [--steps 25] [--cfg 7]
      [--negative "..."] [--lora 1.0] [--server http://192.168.50.77:8188]

Server and model names default to the desktop setup (see the COMFY_*
environment variables to override).

Licences (Civitai, checked when the desktop was set up):
  - AnyLoRA checkpoint: commercial use of generated images allowed, no
    credit required.
  - 2D Pixel Toolkit LoRA (Civitai model 165876): commercial use of images
    allowed, CREDIT REQUIRED (add it to the game's credits), and the LoRA
    itself may not be merged or redistributed.
"""
import argparse
import json
import os
import time
import urllib.parse
import urllib.request

SERVER = os.environ.get("COMFY_SERVER", "http://192.168.50.77:8188")
CHECKPOINT = os.environ.get("COMFY_CHECKPOINT", "anyloraCheckpoint_bakedvaeBlessedFp16.safetensors")
LORA = os.environ.get("COMFY_LORA", "pixel_sprites_2DPixelToolkit.safetensors")
TRIGGER = "pixel, pixel art, pixelart"
DEFAULT_NEGATIVE = ("blurry, lowres, jpeg artifacts, text, watermark, signature, cropped, "
                    "out of frame, multiple characters, extra limbs, deformed, bad anatomy, "
                    "gradient background, shadow on ground")


def workflow(prompt, negative, seed, width, height, steps, cfg, count, lora_strength, prefix):
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": CHECKPOINT}},
        "2": {"class_type": "LoraLoader", "inputs": {
            "model": ["1", 0], "clip": ["1", 1], "lora_name": LORA,
            "strength_model": lora_strength, "strength_clip": lora_strength}},
        "3": {"class_type": "CLIPSetLastLayer", "inputs": {"clip": ["2", 1], "stop_at_clip_layer": -2}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["3", 0], "text": TRIGGER + ", " + prompt}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["3", 0], "text": negative}},
        "6": {"class_type": "EmptyLatentImage", "inputs": {"width": width, "height": height, "batch_size": count}},
        "7": {"class_type": "KSampler", "inputs": {
            "model": ["2", 0], "positive": ["4", 0], "negative": ["5", 0], "latent_image": ["6", 0],
            "seed": seed, "steps": steps, "cfg": cfg, "sampler_name": "euler_ancestral",
            "scheduler": "normal", "denoise": 1.0}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["7", 0], "vae": ["1", 2]}},
        "9": {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": prefix}},
    }


def post(path, body):
    req = urllib.request.Request(SERVER + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def get(path, raw=False):
    with urllib.request.urlopen(SERVER + path, timeout=60) as r:
        data = r.read()
    return data if raw else json.loads(data)


def run(wf, out_dir, timeout=600):
    pid = post("/prompt", {"prompt": wf})["prompt_id"]
    t0 = time.time()
    while True:
        hist = get("/history/" + pid)
        if pid in hist:
            break
        if time.time() - t0 > timeout:
            raise SystemExit("timed out waiting for ComfyUI job " + pid)
        time.sleep(0.5)
    entry = hist[pid]
    if entry.get("status", {}).get("status_str") == "error":
        raise SystemExit("ComfyUI error: " + json.dumps(entry["status"])[:2000])
    os.makedirs(out_dir, exist_ok=True)
    saved = []
    for node in entry["outputs"].values():
        for img in node.get("images", []):
            q = urllib.parse.urlencode({"filename": img["filename"], "subfolder": img.get("subfolder", ""),
                                        "type": img.get("type", "output")})
            path = os.path.join(out_dir, img["filename"])
            with open(path, "wb") as fh:
                fh.write(get("/view?" + q, raw=True))
            saved.append(path)
    return saved, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt")
    ap.add_argument("--out", default="art_gen")
    ap.add_argument("--negative", default=DEFAULT_NEGATIVE)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--width", type=int, default=512)
    ap.add_argument("--height", type=int, default=512)
    ap.add_argument("--steps", type=int, default=25)
    ap.add_argument("--cfg", type=float, default=7.0)
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--lora", type=float, default=1.0)
    ap.add_argument("--prefix", default="farroad")
    a = ap.parse_args()
    wf = workflow(a.prompt, a.negative, a.seed, a.width, a.height, a.steps, a.cfg, a.count, a.lora, a.prefix)
    saved, secs = run(wf, a.out)
    print("%d image(s) in %.1fs" % (len(saved), secs))
    for p in saved:
        print(p)


if __name__ == "__main__":
    main()

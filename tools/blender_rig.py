"""
Farroad keyframe rig: a stylized (~4 heads tall) mannequin with a sword,
posed from a JSON file and rendered as ControlNet guides.

Run with Blender (no UI):
  blender -b --factory-startup -P tools/blender_rig.py -- pose.json out_dir [--size 512]

pose.json:
  {"bones": {"upper_arm.R": [x, y, z], ...},   # euler degrees, bone-local
   "root": {"location": [x, y, z], "rotation": [x, y, z]}}   # optional
Bones: root, spine, head, upper_arm.L/R, forearm.L/R, hand.L/R,
       thigh.L/R, shin.L/R, foot.L/R. The sword is parented to hand.R.

Writes out_dir/depth.png (near = bright, background black) and
out_dir/shaded.png (flat grey shading on black, for a line-art preprocessor).
The character faces +X (screen right); the camera looks at it from the
front-right three-quarter angle the battle sprites use.
"""
import json
import math
import os
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
pose_path, out_dir = argv[0], argv[1]
SIZE = int(argv[argv.index("--size") + 1]) if "--size" in argv else 512
os.makedirs(out_dir, exist_ok=True)

# ---- proportions (1 unit = 1 head height; total ~4 heads) ----
HEAD = 1.0
FOOT_Z, ANKLE_Z = 0.0, 0.12
KNEE_Z, HIP_Z = 0.72, 1.40
NECK_Z = 2.95
HEAD_C = NECK_Z + 0.47
SHOULDER_Z, SHOULDER_X = 2.72, 0.42
UPPER_ARM, FOREARM, HAND = 0.55, 0.50, 0.18
HIP_X = 0.2
SWORD_LEN, SWORD_W = 1.35, 0.09

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---- armature (character faces +X; +Y is the character's left) ----
arm_data = bpy.data.armatures.new("rig")
rig = bpy.data.objects.new("rig", arm_data)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones


def bone(name, head, tail, parent=None):
    b = eb.new(name)
    b.head, b.tail = Vector(head), Vector(tail)
    if parent:
        b.parent = eb[parent]
    return b


bone("root", (0, 0, HIP_Z - 0.1), (0, 0, HIP_Z))
bone("spine", (0, 0, HIP_Z), (0, 0, NECK_Z), "root")
bone("head", (0, 0, NECK_Z), (0, 0, NECK_Z + HEAD * 1.1), "spine")
for side, sy in (("L", 1), ("R", -1)):
    sh = (0, sy * SHOULDER_X, SHOULDER_Z)
    el = (0, sy * SHOULDER_X, SHOULDER_Z - UPPER_ARM)
    wr = (0, sy * SHOULDER_X, SHOULDER_Z - UPPER_ARM - FOREARM)
    bone(f"upper_arm.{side}", sh, el, "spine")
    bone(f"forearm.{side}", el, wr, f"upper_arm.{side}")
    bone(f"hand.{side}", wr, (0, sy * SHOULDER_X, wr[2] - HAND), f"forearm.{side}")
    hp = (0, sy * HIP_X, HIP_Z)
    kn = (0, sy * HIP_X, KNEE_Z)
    an = (0, sy * HIP_X, ANKLE_Z)
    bone(f"thigh.{side}", hp, kn, "root")
    bone(f"shin.{side}", kn, an, f"thigh.{side}")
    bone(f"foot.{side}", an, (0.32, sy * HIP_X, FOOT_Z), f"shin.{side}")
bpy.ops.object.mode_set(mode="OBJECT")

mat = bpy.data.materials.new("body")


def part(name, bone_name, loc, scale, kind="sphere"):
    if kind == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=16, location=loc)
    elif kind == "cyl":
        bpy.ops.mesh.primitive_cylinder_add(vertices=20, location=loc)
    else:
        bpy.ops.mesh.primitive_cube_add(location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    bpy.ops.object.transform_apply(scale=True)
    o.data.materials.append(mat)
    # rigid bone parenting, keeping the world transform
    mw = o.matrix_world.copy()
    o.parent = rig
    o.parent_type = "BONE"
    o.parent_bone = bone_name
    o.matrix_world = mw
    return o


def limb(name, bone_name, a, b, r):
    a, b = Vector(a), Vector(b)
    o = part(name, bone_name, (a + b) / 2, (r, r, (a - b).length / 2 + r * 0.6))
    return o


part("head", "head", (0, 0, HEAD_C), (0.44, 0.41, 0.47))
part("nose", "head", (0.41, 0, HEAD_C - 0.05), (0.09, 0.07, 0.07))   # shows which way the face points
part("torso", "spine", (0, 0, (HIP_Z + NECK_Z) / 2 + 0.05), (0.26, 0.4, 0.78))
part("hips", "root", (0, 0, HIP_Z - 0.02), (0.24, 0.34, 0.2))
for side, sy in (("L", 1), ("R", -1)):
    x = sy * SHOULDER_X
    limb(f"uarm.{side}", f"upper_arm.{side}", (0, x, SHOULDER_Z), (0, x, SHOULDER_Z - UPPER_ARM), 0.12)
    limb(f"farm.{side}", f"forearm.{side}", (0, x, SHOULDER_Z - UPPER_ARM), (0, x, SHOULDER_Z - UPPER_ARM - FOREARM), 0.105)
    part(f"hand.{side}", f"hand.{side}", (0, x, SHOULDER_Z - UPPER_ARM - FOREARM - 0.08), (0.1, 0.09, 0.12))
    limb(f"thigh.{side}", f"thigh.{side}", (0, sy * HIP_X, HIP_Z), (0, sy * HIP_X, KNEE_Z), 0.16)
    limb(f"shin.{side}", f"shin.{side}", (0, sy * HIP_X, KNEE_Z), (0, sy * HIP_X, ANKLE_Z), 0.13)
    part(f"boot.{side}", f"foot.{side}", (0.12, sy * HIP_X, 0.08), (0.24, 0.13, 0.1))

# sword in the right hand, blade pointing forward (+X) out of the fist
hz = SHOULDER_Z - UPPER_ARM - FOREARM - 0.08
grip = part("grip", "hand.R", (0.0, -SHOULDER_X, hz), (0.05, 0.05, 0.16), "cyl")
guard = part("guard", "hand.R", (0.0, -SHOULDER_X, hz - 0.2), (0.04, 0.22, 0.04), "cube")
blade = part("blade", "hand.R", (0.0, -SHOULDER_X, hz - 0.22 - SWORD_LEN / 2), (0.02, SWORD_W, SWORD_LEN / 2), "cube")

# ---- pose ----
with open(pose_path) as fh:
    pose = json.load(fh)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="POSE")
for name, rot in pose.get("bones", {}).items():
    pb = rig.pose.bones[name]
    pb.rotation_mode = "XYZ"
    pb.rotation_euler = [math.radians(v) for v in rot]
r = pose.get("root", {})
if "location" in r:
    rig.pose.bones["root"].location = r["location"]
if "hips" in r:
    # world-space offset [forward(+X), left(+Y), up(+Z)] -> root bone local
    # axes (the root bone points +Z: local X = X, local Y = Z, local Z = -Y)
    dx, dy, dz = r["hips"]
    rig.pose.bones["root"].location = (dx, dz, -dy)
if "rotation" in r:
    rig.pose.bones["root"].rotation_mode = "XYZ"
    rig.pose.bones["root"].rotation_euler = [math.radians(v) for v in r["rotation"]]

# Target-based posing (world coordinates; +X forward, +Y the character's
# left, +Z up, ground at 0). "targets": hand.L/R and foot.L/R positions
# (2-bone IK on forearm/shin); "aim.R"/"aim.L": a point the hand (and so
# the sword) points at. Knees bend forward, elbows bend down/back.
def empty(name, loc):
    e = bpy.data.objects.new(name, None)
    e.location = loc
    scene.collection.objects.link(e)
    return e


targets = pose.get("targets", {})
for side, sy in (("L", 1), ("R", -1)):
    if f"hand.{side}" in targets:
        t = empty(f"t_hand.{side}", targets[f"hand.{side}"])
        pl = empty(f"p_elbow.{side}", targets.get(f"elbow.{side}", (-1.5, sy * 1.2, 1.2)))
        c = rig.pose.bones[f"forearm.{side}"].constraints.new("IK")
        c.target, c.pole_target, c.chain_count = t, pl, 2
        c.pole_angle = math.radians(-90)
    if f"aim.{side}" in targets:
        a = empty(f"t_aim.{side}", targets[f"aim.{side}"])
        c = rig.pose.bones[f"hand.{side}"].constraints.new("DAMPED_TRACK")
        c.target, c.track_axis = a, "TRACK_Y"
    if f"foot.{side}" in targets:
        fx, fy, fz = targets[f"foot.{side}"]
        t = empty(f"t_foot.{side}", (fx, fy, fz + ANKLE_Z))
        pl = empty(f"p_knee.{side}", (fx + 2.0, fy, 1.0))
        c = rig.pose.bones[f"shin.{side}"].constraints.new("IK")
        c.target, c.pole_target, c.chain_count = t, pl, 2
        c.pole_angle = math.radians(-90)
bpy.ops.object.mode_set(mode="OBJECT")
bpy.context.view_layer.update()

# ---- camera: orthographic, front-right 3/4, slightly above ----
cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = float(pose.get("ortho_scale", 4.7))
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
az = math.radians(float(pose.get("camera_azimuth", -45)))   # 0 = side view from the character's right
el = math.radians(float(pose.get("camera_elevation", 8)))
target = Vector((0.2, 0, 2.05))
d = 12
cam.location = target + Vector((d * math.sin(-az) * math.cos(el), -d * math.cos(az) * math.cos(el), d * math.sin(el)))
cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
scene.camera = cam
scene.render.resolution_x = scene.render.resolution_y = SIZE
scene.render.film_transparent = False

world = bpy.data.worlds.new("w")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0, 0, 0, 1)
scene.world = world
scene.render.engine = "CYCLES"
scene.cycles.samples = 8
scene.cycles.device = "CPU"
scene.view_settings.view_transform = "Standard"

# depth: emission = remapped camera distance (near bright)
mat.use_nodes = True
nt = mat.node_tree
nt.nodes.clear()
out = nt.nodes.new("ShaderNodeOutputMaterial")
camd = nt.nodes.new("ShaderNodeCameraData")
mr = nt.nodes.new("ShaderNodeMapRange")
mr.inputs["From Min"].default_value = d - 1.2
mr.inputs["From Max"].default_value = d + 1.2
mr.inputs["To Min"].default_value = 1.0
mr.inputs["To Max"].default_value = 0.25
em = nt.nodes.new("ShaderNodeEmission")
nt.links.new(camd.outputs["View Z Depth"], mr.inputs["Value"])
nt.links.new(mr.outputs["Result"], em.inputs["Color"])
nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
scene.render.filepath = os.path.join(out_dir, "depth.png")
bpy.ops.render.render(write_still=True)

# shaded: plain diffuse under a key light, for a line-art preprocessor
nt.nodes.clear()
out = nt.nodes.new("ShaderNodeOutputMaterial")
bsdf = nt.nodes.new("ShaderNodeBsdfDiffuse")
bsdf.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 4.0
sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-40))
scene.collection.objects.link(sun)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.0
scene.render.filepath = os.path.join(out_dir, "shaded.png")
bpy.ops.render.render(write_still=True)
print("rendered", out_dir)

# openpose.json: COCO-18 keypoints projected into the camera, plus the sword
# (hilt -> tip) so tools/pose_render.py can draw a skeleton guide for
# Qwen-Image-Edit (which reads OpenPose images natively).
from bpy_extras.object_utils import world_to_camera_view  # noqa: E402

bpy.context.view_layer.update()


def px(p):
    v = world_to_camera_view(scene, cam, p)
    return [round(v.x * SIZE, 1), round((1 - v.y) * SIZE, 1)]


pb = rig.pose.bones
mw = rig.matrix_world

def posed(bone_name, rest_point):
    """World position of a rest-pose point carried along by a bone."""
    b = pb[bone_name]
    return mw @ b.matrix @ b.bone.matrix_local.inverted() @ Vector(rest_point)


head_c = posed("head", (0, 0, HEAD_C))
nose = posed("head", (0.41, 0, HEAD_C - 0.05))
fwd = (nose - head_c).normalized()
lat = (posed("head", (0, 1, HEAD_C)) - head_c).normalized()   # character's left
up = (posed("head", (0, 0, HEAD_C + 1)) - head_c).normalized()
pts = {
    0: nose, 1: mw @ pb["spine"].tail,
    2: mw @ pb["upper_arm.R"].head, 3: mw @ pb["forearm.R"].head, 4: mw @ pb["hand.R"].head,
    5: mw @ pb["upper_arm.L"].head, 6: mw @ pb["forearm.L"].head, 7: mw @ pb["hand.L"].head,
    8: mw @ pb["thigh.R"].head, 9: mw @ pb["shin.R"].head, 10: mw @ pb["foot.R"].head,
    11: mw @ pb["thigh.L"].head, 12: mw @ pb["shin.L"].head, 13: mw @ pb["foot.L"].head,
    14: head_c + fwd * 0.36 - lat * 0.16 + up * 0.06, 15: head_c + fwd * 0.36 + lat * 0.16 + up * 0.06,
    16: head_c - lat * 0.4, 17: head_c + lat * 0.4,
}
kp = []
for i in range(18):
    kp += px(pts[i]) + [1.0]
bm = blade.matrix_world
ends = [bm @ Vector((0, 0, SWORD_LEN / 2)), bm @ Vector((0, 0, -SWORD_LEN / 2))]
hand = mw @ pb["hand.R"].tail
tip = max(ends, key=lambda e: (e - hand).length)
with open(os.path.join(out_dir, "openpose.json"), "w") as fh:
    json.dump({"canvas_width": SIZE, "canvas_height": SIZE,
               "people": [{"pose_keypoints_2d": kp}],
               "sword": [px(hand), px(tip)]}, fh)
print("wrote openpose.json")

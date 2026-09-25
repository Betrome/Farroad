"""
Farroad keyframe rig: a stylized (~4 heads tall) mannequin with a sword,
posed with IK controls and rendered as pose guides (depth, shaded,
OpenPose skeleton) for SD ControlNet / Qwen-Image-Edit.

Headless render of a saved pose (what the pipeline uses):
  blender -b --factory-startup -P tools/blender_rig.py -- pose.json out_dir [--size 512]
    -> out_dir/depth.png, shaded.png, openpose.json, openpose.png

Build the hand-posing file (open it in Blender, drag the controls):
  blender -b --factory-startup -P tools/blender_rig.py -- --build art_src/mc/rig/farroad_rig.blend

In the .blend, a "Farroad" tab in the 3D view sidebar (N) loads, saves and
renders poses in art_src/mc/v2/rig_poses/. Controls (empties, drawn in front):
  ctrl.hand.L/R   where each hand goes (arms are 2-bone IK)
  ctrl.aim.L/R    a point the hand points at (the sword is in hand.R)
  ctrl.elbow.L/R  which way each elbow bends (pole)
  ctrl.foot.L/R   where each ankle goes (legs are 2-bone IK)
  ctrl.knee.L/R   which way each knee bends (pole)
  ctrl.hips       moves/rotates the whole body from the hips
Spine and head: rotate the bones directly in Pose Mode.
Hands/feet can only reach 97% of the limb length, so elbows and knees always bend.

pose.json:
  {"root": {"hips": [fwd, left, up], "rotation": [x, y, z]},   # hips offset (world) / degrees
   "bones": {"spine": [x, y, z], "head": [x, y, z]},           # euler degrees, bone-local
   "targets": {"hand.R": [x, y, z], "aim.R": [...], "elbow.R": [...],
               "foot.R": [x, y, 0], "knee.R": [...], ...}}      # world; foot = ground point
The character faces +X (screen right, toward the enemies); +Y is its left.
The camera looks from the front-right three-quarter angle the battle sprites use.
"""
import json
import math
import os
import subprocess
import sys

import bpy
from mathutils import Matrix, Vector

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
REACH = 0.97          # max hand/foot distance as a share of limb length (keeps elbows/knees bent)
CAM_TARGET = Vector((0.2, 0, 2.05))
CAM_DIST = 12

WRIST_Z = SHOULDER_Z - UPPER_ARM - FOREARM
DEFAULTS = {   # rest pose for every control (world coordinates)
    "hand.L": (0.12, 0.5, WRIST_Z + 0.05), "hand.R": (0.12, -0.5, WRIST_Z + 0.05),
    "aim.L": (0.5, 0.55, 0.6), "aim.R": (2.5, -0.5, WRIST_Z),
    "elbow.L": (-1.5, 1.2, 1.2), "elbow.R": (-1.5, -1.2, 1.2),
    "foot.L": (0.0, HIP_X, 0.0), "foot.R": (0.0, -HIP_X, 0.0),
    "knee.L": (2.0, HIP_X, 1.0), "knee.R": (2.0, -HIP_X, 1.0),
}
HIPS_REST = Vector((0, 0, HIP_Z - 0.1))   # root bone head


def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


def poses_dir():
    return os.path.join(repo_root(), "art_src", "mc", "v2", "rig_poses")


# ---------------------------------------------------------------- build
def build(scene):
    arm_data = bpy.data.armatures.new("rig")
    rig = bpy.data.objects.new("rig", arm_data)
    scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm_data.edit_bones

    def bone(name, head, tail, parent=None):
        b = eb.new(name)
        b.head, b.tail = Vector(head), Vector(tail)
        b.roll = 0
        if parent:
            b.parent = eb[parent]
            b.use_connect = (Vector(head) - eb[parent].tail).length < 1e-4
        return b

    bone("root", (0, 0, HIP_Z - 0.1), (0, 0, HIP_Z))
    bone("spine", (0, 0, HIP_Z), (0, 0, NECK_Z), "root")
    bone("head", (0, 0, NECK_Z), (0, 0, NECK_Z + HEAD * 1.1), "spine")
    for side, sy in (("L", 1), ("R", -1)):
        # rest pose is pre-bent (elbows back, knees forward) so IK knows the bend direction
        sh = (0, sy * SHOULDER_X, SHOULDER_Z)
        el = (-0.06, sy * SHOULDER_X, SHOULDER_Z - UPPER_ARM)
        wr = (0, sy * SHOULDER_X, WRIST_Z)
        # shoulder/hip helper bones: fixed joints the reach limits measure from
        bone(f"shoulder.{side}", sh, (0, sy * (SHOULDER_X + 0.15), SHOULDER_Z), "spine")
        bone(f"upper_arm.{side}", sh, el, f"shoulder.{side}")
        bone(f"forearm.{side}", el, wr, f"upper_arm.{side}")
        bone(f"hand.{side}", wr, (0, sy * SHOULDER_X, WRIST_Z - HAND), f"forearm.{side}")
        hp = (0, sy * HIP_X, HIP_Z)
        kn = (0.06, sy * HIP_X, KNEE_Z)
        an = (0, sy * HIP_X, ANKLE_Z)
        bone(f"hip.{side}", hp, (0, sy * (HIP_X + 0.15), HIP_Z), "root")
        bone(f"thigh.{side}", hp, kn, f"hip.{side}")
        bone(f"shin.{side}", kn, an, f"thigh.{side}")
        bone(f"foot.{side}", an, (0.32, sy * HIP_X, FOOT_Z), f"shin.{side}")
    bpy.ops.object.mode_set(mode="OBJECT")

    mat = bpy.data.materials.new("body")

    def part(name, bone_name, loc, scale, kind="sphere", rot=None):
        if kind == "sphere":
            bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=16, location=loc)
        elif kind == "cyl":
            bpy.ops.mesh.primitive_cylinder_add(vertices=20, location=loc)
        else:
            bpy.ops.mesh.primitive_cube_add(location=loc)
        o = bpy.context.active_object
        o.name = name
        o.scale = scale
        if rot is not None:
            o.rotation_mode = "QUATERNION"
            o.rotation_quaternion = rot
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
        o.data.materials.append(mat)
        o.hide_select = True          # clicks go to the controls, not the body
        mw = o.matrix_world.copy()
        o.parent = rig
        o.parent_type = "BONE"
        o.parent_bone = bone_name
        o.matrix_world = mw
        return o

    def limb(name, bone_name, a, b, r):
        """A capsule from a to b (lined up with the pre-bent bone)."""
        a, b = Vector(a), Vector(b)
        d = b - a
        return part(name, bone_name, (a + b) / 2, (r, r, d.length / 2 + r * 0.6),
                    rot=Vector((0, 0, 1)).rotation_difference(d))

    part("head", "head", (0, 0, HEAD_C), (0.44, 0.41, 0.47))
    part("nose", "head", (0.41, 0, HEAD_C - 0.05), (0.09, 0.07, 0.07))   # shows which way the face points
    part("torso", "spine", (0, 0, (HIP_Z + NECK_Z) / 2 + 0.05), (0.26, 0.4, 0.78))
    part("hips", "root", (0, 0, HIP_Z - 0.02), (0.24, 0.34, 0.2))
    for side, sy in (("L", 1), ("R", -1)):
        x = sy * SHOULDER_X
        limb(f"uarm.{side}", f"upper_arm.{side}", (0, x, SHOULDER_Z), (-0.06, x, SHOULDER_Z - UPPER_ARM), 0.12)
        limb(f"farm.{side}", f"forearm.{side}", (-0.06, x, SHOULDER_Z - UPPER_ARM), (0, x, WRIST_Z), 0.105)
        part(f"hand.{side}", f"hand.{side}", (0, x, WRIST_Z - 0.08), (0.1, 0.09, 0.12))
        limb(f"thigh.{side}", f"thigh.{side}", (0, sy * HIP_X, HIP_Z), (0.06, sy * HIP_X, KNEE_Z), 0.16)
        limb(f"shin.{side}", f"shin.{side}", (0.06, sy * HIP_X, KNEE_Z), (0, sy * HIP_X, ANKLE_Z), 0.13)
        part(f"boot.{side}", f"foot.{side}", (0.12, sy * HIP_X, 0.08), (0.24, 0.13, 0.1))

    # sword in the right hand, blade pointing out of the fist along the hand bone
    hz = WRIST_Z - 0.08
    part("grip", "hand.R", (0.0, -SHOULDER_X, hz), (0.05, 0.05, 0.16), "cyl")
    part("guard", "hand.R", (0.0, -SHOULDER_X, hz - 0.2), (0.04, 0.22, 0.04), "cube")
    part("blade", "hand.R", (0.0, -SHOULDER_X, hz - 0.22 - SWORD_LEN / 2), (0.02, SWORD_W, SWORD_LEN / 2), "cube")

    # ---- controls ----
    coll = bpy.data.collections.new("controls")
    scene.collection.children.link(coll)

    def ctrl(name, loc, shape="SPHERE", size=0.12):
        e = bpy.data.objects.new("ctrl." + name, None)
        e.empty_display_type = shape
        e.empty_display_size = size
        e.show_in_front = True
        e.show_name = True
        e.location = loc
        coll.objects.link(e)
        return e

    for name, loc in DEFAULTS.items():
        shape = "CUBE" if name.startswith(("elbow", "knee")) else ("CONE" if name.startswith("aim") else "SPHERE")
        size = 0.09 if shape != "SPHERE" else 0.13
        pos = Vector(loc) + (Vector((0, 0, ANKLE_Z)) if name.startswith("foot") else Vector())
        ctrl(name, pos, shape, size)
    hips = ctrl("hips", HIPS_REST, "CIRCLE", 0.55)
    hips.rotation_mode = "XYZ"

    pb = rig.pose.bones
    c = pb["root"].constraints.new("CHILD_OF")   # the whole body follows the hips control
    c.target = hips
    c.inverse_matrix = Matrix.Translation(-HIPS_REST)
    for side in ("L", "R"):
        for chain, tgt, pole in (("forearm", "hand", "elbow"), ("shin", "foot", "knee")):
            c = pb[f"{chain}.{side}"].constraints.new("IK")
            c.target = bpy.data.objects[f"ctrl.{tgt}.{side}"]
            c.pole_target = bpy.data.objects[f"ctrl.{pole}.{side}"]
            c.chain_count = 2
            c.pole_angle = math.radians(90)
        c = pb[f"hand.{side}"].constraints.new("DAMPED_TRACK")
        c.target = bpy.data.objects[f"ctrl.aim.{side}"]
        c.track_axis = "TRACK_Y"
        # elbows/knees never lock straight: each hand/foot control can reach at most
        # REACH of the limb's length from its shoulder/hip, so IK always keeps a bend
        # (and the elbow/knee pole decides which way it bends)
        for tgt, joint, length in (("hand", "shoulder", UPPER_ARM + FOREARM),
                                   ("foot", "hip", HIP_Z - ANKLE_Z)):
            c = bpy.data.objects[f"ctrl.{tgt}.{side}"].constraints.new("LIMIT_DISTANCE")
            c.target, c.subtarget = rig, f"{joint}.{side}"
            c.distance = REACH * length
            c.limit_mode = "LIMITDIST_INSIDE"
    for n in ("spine", "head"):
        pb[n].rotation_mode = "XYZ"

    # ---- camera + render settings ----
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    set_camera(scene, 4.7, -45, 8)
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0, 0, 0, 1)
    scene.world = world
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 8
    scene.cycles.device = "CPU"
    scene.view_settings.view_transform = "Standard"
    scene.render.film_transparent = False
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4.0
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-40))
    scene.collection.objects.link(sun)
    set_material(mat, "shaded")
    bpy.context.view_layer.update()
    return rig


def set_camera(scene, ortho_scale, azimuth, elevation):
    cam = scene.camera
    cam.data.ortho_scale = float(ortho_scale)
    az, el = math.radians(float(azimuth)), math.radians(float(elevation))   # az 0 = side view from the character's right
    cam.location = CAM_TARGET + Vector((CAM_DIST * math.sin(-az) * math.cos(el),
                                        -CAM_DIST * math.cos(az) * math.cos(el),
                                        CAM_DIST * math.sin(el)))
    cam.rotation_euler = (CAM_TARGET - cam.location).to_track_quat("-Z", "Y").to_euler()


def set_material(mat, mode):
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    if mode == "depth":   # emission = remapped camera distance (near bright)
        camd = nt.nodes.new("ShaderNodeCameraData")
        mr = nt.nodes.new("ShaderNodeMapRange")
        mr.inputs["From Min"].default_value = CAM_DIST - 1.2
        mr.inputs["From Max"].default_value = CAM_DIST + 1.2
        mr.inputs["To Min"].default_value = 1.0
        mr.inputs["To Max"].default_value = 0.25
        em = nt.nodes.new("ShaderNodeEmission")
        nt.links.new(camd.outputs["View Z Depth"], mr.inputs["Value"])
        nt.links.new(mr.outputs["Result"], em.inputs["Color"])
        nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    else:                 # plain diffuse under the sun
        bsdf = nt.nodes.new("ShaderNodeBsdfDiffuse")
        bsdf.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])


# ---------------------------------------------------------------- poses
def ctrl_obj(name):
    return bpy.data.objects["ctrl." + name]


def apply_pose(scene, pose):
    rig = bpy.data.objects["rig"]
    for name, loc in DEFAULTS.items():
        v = Vector(pose.get("targets", {}).get(name, loc))
        if name.startswith("foot"):
            v = v + Vector((0, 0, ANKLE_Z))
        ctrl_obj(name).location = v
    r = pose.get("root", {})
    hips = ctrl_obj("hips")
    hips.location = HIPS_REST + Vector(r.get("hips", (0, 0, 0)))
    hips.rotation_euler = [math.radians(v) for v in r.get("rotation", (0, 0, 0))]
    for n, pbone in rig.pose.bones.items():
        rot = pose.get("bones", {}).get(n)
        pbone.rotation_mode = "XYZ"
        pbone.rotation_euler = [math.radians(v) for v in rot] if rot else (0, 0, 0)
    set_camera(scene, pose.get("ortho_scale", 4.7), pose.get("camera_azimuth", -45),
               pose.get("camera_elevation", 8))
    bpy.context.view_layer.update()


def read_pose(scene):
    """The current control/bone state as a pose dict (inverse of apply_pose)."""
    rig = bpy.data.objects["rig"]
    r3 = lambda v: [round(float(x), 3) for x in v]   # noqa: E731
    targets = {}
    for name in DEFAULTS:
        v = ctrl_obj(name).matrix_world.translation.copy()   # after the reach limit
        if name.startswith("foot"):
            v.z -= ANKLE_Z
        targets[name] = r3(v)
    hips = ctrl_obj("hips")
    pose = {"root": {"hips": r3(hips.location - HIPS_REST),
                     "rotation": r3(math.degrees(a) for a in hips.rotation_euler)},
            "bones": {}, "targets": targets}
    for n in ("spine", "head"):
        e = rig.pose.bones[n].rotation_euler
        if any(abs(a) > 1e-4 for a in e):
            pose["bones"][n] = r3(math.degrees(a) for a in e)
    cam = scene.camera
    pose["ortho_scale"] = round(cam.data.ortho_scale, 3)
    return pose


# ---------------------------------------------------------------- render
def render_guides(scene, out_dir, prefix="", size=512):
    """depth.png, shaded.png, openpose.json (+ openpose.png) into out_dir."""
    os.makedirs(out_dir, exist_ok=True)
    scene.render.resolution_x = scene.render.resolution_y = size
    mat = bpy.data.materials["body"]
    hidden = [o for o in bpy.data.collections["controls"].objects if not o.hide_render]
    for o in hidden:
        o.hide_render = True
    for mode in ("depth", "shaded"):
        set_material(mat, mode)
        scene.world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
        scene.render.filepath = os.path.join(out_dir, prefix + mode + ".png")
        bpy.ops.render.render(write_still=True)
    set_material(mat, "shaded")
    jpath = os.path.join(out_dir, prefix + "openpose.json")
    write_openpose(scene, jpath, size)
    ppath = os.path.join(out_dir, prefix + "openpose.png")
    try:   # Blender's Python has no PIL; draw the skeleton with the system Python
        subprocess.run(["python", os.path.join(repo_root(), "tools", "pose_render.py"), jpath, ppath],
                       check=True, timeout=60)
    except Exception as e:  # noqa: BLE001
        print("openpose.png not drawn:", e)
    return out_dir


def write_openpose(scene, path, size):
    """COCO-18 keypoints projected into the camera, plus the sword (hilt -> tip)."""
    from bpy_extras.object_utils import world_to_camera_view
    bpy.context.view_layer.update()
    rig = bpy.data.objects["rig"]
    cam = scene.camera
    pb = rig.pose.bones
    mw = rig.matrix_world

    def px(p):
        v = world_to_camera_view(scene, cam, p)
        return [round(v.x * size, 1), round((1 - v.y) * size, 1)]

    def posed(bone_name, rest_point):
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
    bm = bpy.data.objects["blade"].matrix_world
    ends = [bm @ Vector((0, 0, SWORD_LEN / 2)), bm @ Vector((0, 0, -SWORD_LEN / 2))]
    hand = mw @ pb["hand.R"].tail
    tip = max(ends, key=lambda e: (e - hand).length)
    with open(path, "w") as fh:
        json.dump({"canvas_width": size, "canvas_height": size,
                   "people": [{"pose_keypoints_2d": kp}],
                   "sword": [px(hand), px(tip)]}, fh)


# ---------------------------------------------------------------- UI (in the .blend)
def pose_items(self, context):
    d = poses_dir()
    names = sorted(f[:-5] for f in os.listdir(d)
                   if f.endswith(".json") and not f.endswith("_openpose.json")) if os.path.isdir(d) else []
    return [(n, n, "") for n in names] or [("", "(no poses)", "")]


class FARROAD_OT_load(bpy.types.Operator):
    bl_idname = "farroad.load_pose"
    bl_label = "Load"
    bl_description = "Load the selected pose from art_src/mc/v2/rig_poses"

    def execute(self, context):
        name = context.scene.farroad_pose
        if not name:
            return {"CANCELLED"}
        with open(os.path.join(poses_dir(), name + ".json")) as fh:
            apply_pose(context.scene, json.load(fh))
        context.scene.farroad_name = name
        self.report({"INFO"}, "Loaded " + name)
        return {"FINISHED"}


class FARROAD_OT_reset(bpy.types.Operator):
    bl_idname = "farroad.reset_pose"
    bl_label = "Reset to rest"
    bl_description = "Put every control back to the neutral standing pose"

    def execute(self, context):
        apply_pose(context.scene, {})
        return {"FINISHED"}


class FARROAD_OT_save(bpy.types.Operator):
    bl_idname = "farroad.save_pose"
    bl_label = "Save pose"
    bl_description = "Write <name>.json into art_src/mc/v2/rig_poses (and render the guides if ticked)"

    def execute(self, context):
        sc = context.scene
        name = sc.farroad_name.strip().replace(" ", "_")
        if not name:
            self.report({"ERROR"}, "Type a pose name first")
            return {"CANCELLED"}
        d = poses_dir()
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".json"), "w") as fh:
            json.dump(read_pose(sc), fh, indent=1)
        if sc.farroad_render:
            render_guides(sc, d, prefix=name + "_")
        self.report({"INFO"}, "Saved " + name + (" and rendered guides" if sc.farroad_render else ""))
        return {"FINISHED"}


class FARROAD_PT_panel(bpy.types.Panel):
    bl_label = "Farroad pose"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Farroad"

    def draw(self, context):
        sc, col = context.scene, self.layout.column()
        col.label(text="Existing poses:")
        row = col.row(align=True)
        row.prop(sc, "farroad_pose", text="")
        row.operator("farroad.load_pose")
        col.operator("farroad.reset_pose")
        col.separator()
        col.prop(sc, "farroad_name", text="Name")
        col.prop(sc, "farroad_render", text="Render guides on save")
        col.operator("farroad.save_pose", icon="FILE_TICK")
        col.separator()
        col.label(text="Drag the ctrl.* empties;")
        col.label(text="rotate spine/head in Pose Mode.")
        col.label(text="Numpad 0 = camera view.")


CLASSES = (FARROAD_OT_load, FARROAD_OT_reset, FARROAD_OT_save, FARROAD_PT_panel)


def register_ui():
    S = bpy.types.Scene
    S.farroad_pose = bpy.props.EnumProperty(name="Pose", items=pose_items)
    S.farroad_name = bpy.props.StringProperty(name="Name", default="my_pose")
    S.farroad_render = bpy.props.BoolProperty(name="Render guides", default=True)
    for c in CLASSES:
        try:
            bpy.utils.unregister_class(c)
        except RuntimeError:
            pass
        bpy.utils.register_class(c)


UI_BOOT = '''# Runs when this file opens (allow it in the yellow bar if Blender asks),
# or press Run Script (Alt+P) here. Adds the "Farroad" tab to the 3D view sidebar (N).
import os, sys, bpy
tools = os.path.normpath(os.path.join(bpy.path.abspath("//"), "..", "..", "..", "tools"))
if tools not in sys.path:
    sys.path.insert(0, tools)
import importlib, blender_rig
importlib.reload(blender_rig)
blender_rig.register_ui()
'''


def build_blend(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    build(scene)
    apply_pose(scene, {})
    txt = bpy.data.texts.new("farroad_rig_ui.py")
    txt.write(UI_BOOT)
    txt.use_module = True    # auto-runs on open when scripts are allowed
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(path))
    print("built", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if argv and argv[0] == "--build":
        build_blend(argv[1])
        return
    pose_path, out_dir = argv[0], argv[1]
    size = int(argv[argv.index("--size") + 1]) if "--size" in argv else 512
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    build(scene)
    with open(pose_path) as fh:
        apply_pose(scene, json.load(fh))
    render_guides(scene, out_dir, size=size)
    print("rendered", out_dir)


if __name__ == "__main__":
    main()

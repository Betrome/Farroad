"""
Farroad hand-posing rig built with Blender's Rigify: the same male/female
bodies as tools/blender_rig.py (proportions measured off the masters), with
standard Rigify controls -- IK and FK arms/legs (switch per limb in the
Rigify panel), foot roll, torso/chest/hips/neck/head controls.

Build the posing files:
  blender -b --factory-startup -P tools/rigify_rig.py -- --build art_src/mc/rig/farroad_rigify_male.blend --body male
  blender -b --factory-startup -P tools/rigify_rig.py -- --build art_src/mc/rig/farroad_rigify_female.blend --body female

Render a saved pose's guides (depth, shaded, openpose.json/png) headless:
  blender -b art_src/mc/rig/farroad_rigify_male.blend -P tools/rigify_rig.py -- --render pose.json out_dir [--size 512]

In the .blend: "Farroad" tab in the 3D view sidebar (N) loads/saves/renders
poses (art_src/mc/v2/rig_poses/<name>.json, "format": "rigify"). The Rigify
tab (same sidebar) has the IK/FK switches and snapping. The character faces
+X (screen right) like every other Farroad rig; the sword is in the right hand.
"""
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_rig as br  # noqa: E402  (body profiles, camera, materials)

RIG = "farroad_rig"
SKIP_PREFIX = ("ORG-", "DEF-", "MCH-", "VIS_")


# ---------------------------------------------------------------- metarig
def fit_metarig(meta):
    """Move the basic-human metarig's bones onto the current br body.
    Rigify's own frame: +X = character's left, -Y = forward, +Z = up."""
    bpy.context.view_layer.objects.active = meta
    bpy.ops.object.mode_set(mode="EDIT")
    eb = meta.data.edit_bones
    for n in ("breast.L", "breast.R", "pelvis.L", "pelvis.R"):
        if n in eb:
            eb.remove(eb[n])

    def put(name, head, tail, roll_vec):
        b = eb[name]
        b.head, b.tail = Vector(head), Vector(tail)
        b.align_roll(Vector(roll_vec))

    fwd = (0, -1, 0)
    back = (0, 1, 0)
    s0, s4 = br.HIP_Z - 0.12, br.SHOULDER_Z - 0.05
    seg = [s0 + (s4 - s0) * k / 4 for k in range(5)]
    for i in range(4):
        put("spine" if i == 0 else f"spine.00{i}", (0, 0, seg[i]), (0, 0, seg[i + 1]), fwd)
    nz = (s4 + br.NECK_Z) / 2
    put("spine.004", (0, 0, s4), (0, 0, nz), fwd)
    put("spine.005", (0, 0, nz), (0, 0, br.NECK_Z), fwd)
    put("spine.006", (0, 0, br.NECK_Z), (0, 0, br.TOTAL_H), fwd)
    out = math.radians(28)      # A-pose: arms 28 degrees out from vertical
    dn = Vector((math.sin(out), 0, -math.cos(out)))
    for side, sx in (("L", 1), ("R", -1)):
        d = Vector((dn.x * sx, 0, dn.z))
        sh = Vector((sx * br.SHOULDER_X, 0, br.SHOULDER_Z))
        el = sh + d * br.UPPER_ARM + Vector((0, 0.05, 0))       # slight bend: elbow back
        wr = el + d * br.FOREARM + Vector((0, -0.05, 0))
        put(f"shoulder.{side}", (sx * 0.05, -0.02, br.SHOULDER_Z - 0.02), sh - Vector((sx * 0.02, 0, 0)), (0, 0, 1))
        put(f"upper_arm.{side}", sh, el, fwd)
        put(f"forearm.{side}", el, wr, fwd)
        put(f"hand.{side}", wr, wr + d * br.HAND, fwd)
        hp = Vector((sx * br.HIP_X, 0, br.HIP_Z))
        kn = Vector((sx * br.HIP_X, -0.06, br.KNEE_Z))                 # slight bend: knee forward
        an = Vector((sx * br.HIP_X, 0, br.ANKLE_Z))
        put(f"thigh.{side}", hp, kn, back)
        put(f"shin.{side}", kn, an, back)
        put(f"foot.{side}", an, (sx * br.HIP_X, -0.26, 0.03), (0, 0.5, -0.85))
        put(f"toe.{side}", (sx * br.HIP_X, -0.26, 0.03), (sx * br.HIP_X, -0.38, 0.03), (0, 0, 1))
        put(f"heel.02.{side}", (sx * (br.HIP_X - 0.07), 0.04, 0), (sx * (br.HIP_X + 0.07), 0.04, 0), (0, 0, 1))
    bpy.ops.object.mode_set(mode="OBJECT")


# ---------------------------------------------------------------- build
def build(scene, body):
    br.set_body(body)
    bpy.ops.preferences.addon_enable(module="rigify")
    bpy.ops.object.armature_basic_human_metarig_add()
    meta = bpy.context.active_object
    meta.name = "metarig"
    fit_metarig(meta)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.objects.active = meta
    meta.select_set(True)
    bpy.ops.pose.rigify_generate()
    rig = bpy.context.active_object
    rig.name = RIG
    # turn Rigify's -Y-forward rig to face +X (screen right, toward the enemies)
    rig.rotation_euler = (0, 0, math.radians(90))
    meta.rotation_euler = (0, 0, math.radians(90))
    meta.hide_set(True)
    meta.hide_render = True
    # IK limbs keep their length (Rigify stretches them by default)
    for n in ("upper_arm_parent.L", "upper_arm_parent.R", "thigh_parent.L", "thigh_parent.R"):
        if n in rig.pose.bones and "IK_Stretch" in rig.pose.bones[n].keys():
            rig.pose.bones[n]["IK_Stretch"] = 0.0
    bpy.context.view_layer.update()

    mat = bpy.data.materials.new("body")
    mw = rig.matrix_world

    def rest(bone, t=0.0):
        b = rig.data.bones[bone]
        return mw @ b.head_local.lerp(b.tail_local, t)

    def part(name, bone, loc, scale, kind="sphere", rot=None):
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
        o.hide_select = True           # clicks go to the rig controls, not the body
        keep = o.matrix_world.copy()
        o.parent, o.parent_type, o.parent_bone = rig, "BONE", bone
        o.matrix_world = keep
        return o

    def limb(name, bone, r):
        a, b = rest(bone), rest(bone, 1.0)
        d = b - a
        return part(name, bone, (a + b) / 2, (r, r, d.length / 2 + r * 0.6),
                    rot=Vector((0, 0, 1)).rotation_difference(d))

    B = br.BODY
    head = "ORG-spine.006"
    part("head", head, (0, 0, br.HEAD_C), br.HEAD_R)
    part("nose", head, (br.HEAD_R[0] - 0.03, 0, br.HEAD_C - 0.05), (0.09, 0.07, 0.07))
    part("torso", "ORG-spine.002", (0, 0, (br.HIP_Z + br.NECK_Z) / 2 + 0.05),
         B["torso_r"] + ((br.NECK_Z - br.HIP_Z) / 2 + 0.08,))
    part("hips", "ORG-spine", (0, 0, br.HIP_Z - 0.02), B["hips_r"])
    for s in ("L", "R"):
        limb(f"uarm.{s}", f"ORG-upper_arm.{s}", B["arm_r"][0])
        limb(f"farm.{s}", f"ORG-forearm.{s}", B["arm_r"][1])
        part(f"handm.{s}", f"ORG-hand.{s}", rest(f"ORG-hand.{s}", 0.5), (0.1, 0.1, 0.1))
        limb(f"thigh.{s}", f"ORG-thigh.{s}", B["leg_r"][0])
        limb(f"shin.{s}", f"ORG-shin.{s}", B["leg_r"][1])
        a, b = rest(f"ORG-foot.{s}"), rest(f"ORG-toe.{s}", 1.0)
        part(f"boot.{s}", f"ORG-foot.{s}", ((a.x + b.x) / 2, (a.y + b.y) / 2, 0.08), (0.24, 0.13, 0.1),
             rot=Vector((1, 0, 0)).rotation_difference(Vector((b.x - a.x, b.y - a.y, 0))))
    # sword in the right fist: grip across the hand, blade continuing past the fingers
    h0, h1 = rest("ORG-hand.R"), rest("ORG-hand.R", 1.0)
    d = (h1 - h0).normalized()
    q = Vector((0, 0, 1)).rotation_difference(d)
    c = (h0 + h1) / 2
    part("grip", "ORG-hand.R", c, (0.05, 0.05, 0.16), "cyl", rot=q)
    part("guard", "ORG-hand.R", c + d * 0.2, (0.22, 0.04, 0.04), "cube", rot=q)
    part("blade", "ORG-hand.R", c + d * (0.22 + br.SWORD_LEN / 2), (br.SWORD_W, 0.02, br.SWORD_LEN / 2), "cube", rot=q)

    # camera, world, light: the same look as blender_rig's guides
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    scene.collection.objects.link(cam)
    scene.camera = cam
    br.set_camera(scene, 4.7, -45, 8)
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0, 0, 0, 1)
    scene.world = world
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 8
    scene.cycles.device = "CPU"
    scene.view_settings.view_transform = "Standard"
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4.0
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-40))
    scene.collection.objects.link(sun)
    br.set_material(mat, "shaded")
    scene["farroad_body"] = body
    bpy.context.view_layer.objects.active = rig
    return rig


# ---------------------------------------------------------------- poses
def _controls(rig):
    return [pb for pb in rig.pose.bones if not pb.name.startswith(SKIP_PREFIX)]


def read_pose(scene):
    rig = bpy.data.objects[RIG]
    r4 = lambda v: [round(float(x), 4) for x in v]   # noqa: E731
    bones = {}
    for pb in _controls(rig):
        e = {}
        if pb.location.length > 1e-5:
            e["loc"] = r4(pb.location)
        rot = pb.rotation_quaternion if pb.rotation_mode == "QUATERNION" else pb.rotation_euler
        if pb.rotation_mode == "QUATERNION":
            if abs(rot.w - 1) > 1e-5:
                e["quat"] = r4(rot)
        elif any(abs(a) > 1e-5 for a in rot):
            e["euler"] = r4(rot)
        if any(abs(s - 1) > 1e-5 for s in pb.scale):
            e["scale"] = r4(pb.scale)
        props = {k: float(pb[k]) for k in pb.keys() if isinstance(pb[k], (int, float)) and not k.startswith("_")}
        if props:
            e["props"] = props
        if e:
            bones[pb.name] = e
    return {"format": "rigify", "body": scene.get("farroad_body", "male"),
            "ortho_scale": round(scene.camera.data.ortho_scale, 3), "bones": bones}


def apply_pose(scene, pose):
    rig = bpy.data.objects[RIG]
    bones = pose.get("bones", {})
    for pb in _controls(rig):
        e = bones.get(pb.name, {})
        pb.location = e.get("loc", (0, 0, 0))
        if pb.rotation_mode == "QUATERNION":
            pb.rotation_quaternion = e.get("quat", (1, 0, 0, 0))
        else:
            pb.rotation_euler = e.get("euler", (0, 0, 0))
        pb.scale = e.get("scale", (1, 1, 1))
        for k, v in e.get("props", {}).items():
            if k in pb.keys():
                pb[k] = type(pb[k])(v)
    br.set_camera(scene, pose.get("ortho_scale", 4.7), -45, 8)
    bpy.context.view_layer.update()


def reset_pose(scene):
    rig = bpy.data.objects[RIG]
    for pb in _controls(rig):
        pb.location, pb.scale = (0, 0, 0), (1, 1, 1)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.rotation_euler = (0, 0, 0)
    bpy.context.view_layer.update()


# ---------------------------------------------------------------- render
def write_openpose(scene, path, size):
    """COCO-18 keypoints from the ORG bones, plus the sword (hilt -> tip)."""
    from bpy_extras.object_utils import world_to_camera_view
    bpy.context.view_layer.update()
    rig = bpy.data.objects[RIG]
    pb, mw, cam = rig.pose.bones, rig.matrix_world, scene.camera

    def px(p):
        v = world_to_camera_view(scene, cam, p)
        return [round(v.x * size, 1), round((1 - v.y) * size, 1)]

    def posed(bone, rest_point):   # rest_point in world rest coordinates
        b = pb[bone]
        local = mw.inverted() @ Vector(rest_point)
        return mw @ b.matrix @ b.bone.matrix_local.inverted() @ local

    head = "ORG-spine.006"
    head_c = posed(head, (0, 0, br.HEAD_C))
    nose = posed(head, (br.HEAD_R[0] - 0.03, 0, br.HEAD_C - 0.05))
    lat = (posed(head, (0, 1, br.HEAD_C)) - head_c).normalized()
    up = (posed(head, (0, 0, br.HEAD_C + 1)) - head_c).normalized()
    fwd = (nose - head_c).normalized()
    H = lambda n: mw @ pb[n].head   # noqa: E731
    pts = {0: nose, 1: mw @ pb["ORG-spine.004"].head,
           2: H("ORG-upper_arm.R"), 3: H("ORG-forearm.R"), 4: H("ORG-hand.R"),
           5: H("ORG-upper_arm.L"), 6: H("ORG-forearm.L"), 7: H("ORG-hand.L"),
           8: H("ORG-thigh.R"), 9: H("ORG-shin.R"), 10: H("ORG-foot.R"),
           11: H("ORG-thigh.L"), 12: H("ORG-shin.L"), 13: H("ORG-foot.L"),
           14: head_c + fwd * br.HEAD_R[0] * 0.8 - lat * 0.16 + up * 0.06,
           15: head_c + fwd * br.HEAD_R[0] * 0.8 + lat * 0.16 + up * 0.06,
           16: head_c - lat * br.HEAD_R[1] * 0.9, 17: head_c + lat * br.HEAD_R[1] * 0.9}
    kp = []
    for i in range(18):
        kp += px(pts[i]) + [1.0]
    # the sword was built along the rest hand bone: grip at its middle, tip past the guard
    hb = rig.data.bones["ORG-hand.R"]
    h0, h1 = mw @ hb.head_local, mw @ hb.tail_local
    d = (h1 - h0).normalized()
    hand = posed("ORG-hand.R", (h0 + h1) / 2)
    tip = posed("ORG-hand.R", (h0 + h1) / 2 + d * (0.22 + br.SWORD_LEN))
    with open(path, "w") as fh:
        json.dump({"canvas_width": size, "canvas_height": size,
                   "people": [{"pose_keypoints_2d": kp}], "sword": [px(hand), px(tip)]}, fh)


def render_guides(scene, out_dir, prefix="", size=512):
    import subprocess
    os.makedirs(out_dir, exist_ok=True)
    scene.render.resolution_x = scene.render.resolution_y = size
    mat = bpy.data.materials["body"]
    for mode in ("depth", "shaded"):
        br.set_material(mat, mode)
        scene.render.filepath = os.path.join(out_dir, prefix + mode + ".png")
        bpy.ops.render.render(write_still=True)
    br.set_material(mat, "shaded")
    jpath = os.path.join(out_dir, prefix + "openpose.json")
    write_openpose(scene, jpath, size)
    try:   # Blender's Python has no PIL; draw the skeleton with the system Python
        subprocess.run(["python", os.path.join(br.repo_root(), "tools", "pose_render.py"), jpath,
                        os.path.join(out_dir, prefix + "openpose.png")], check=True, timeout=60)
    except Exception as e:  # noqa: BLE001
        print("openpose.png not drawn:", e)


# ---------------------------------------------------------------- UI (in the .blend)
def pose_items(self, context):
    d = br.poses_dir()
    names = []
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(".json") and not f.endswith("_openpose.json"):
                try:
                    with open(os.path.join(d, f)) as fh:
                        if json.load(fh).get("format") == "rigify":
                            names.append(f[:-5])
                except (OSError, ValueError):
                    pass
    return [(n, n, "") for n in names] or [("", "(no Rigify poses yet)", "")]


class FARROAD_OT_rload(bpy.types.Operator):
    bl_idname = "farroad.rigify_load"
    bl_label = "Load"
    bl_description = "Load the selected pose from art_src/mc/v2/rig_poses"

    def execute(self, context):
        name = context.scene.farroad_rpose
        if not name:
            return {"CANCELLED"}
        with open(os.path.join(br.poses_dir(), name + ".json")) as fh:
            apply_pose(context.scene, json.load(fh))
        context.scene.farroad_name = name
        return {"FINISHED"}


class FARROAD_OT_rreset(bpy.types.Operator):
    bl_idname = "farroad.rigify_reset"
    bl_label = "Reset to rest"
    bl_description = "Clear every control back to the rest pose"

    def execute(self, context):
        reset_pose(context.scene)
        return {"FINISHED"}


class FARROAD_OT_rsave(bpy.types.Operator):
    bl_idname = "farroad.rigify_save"
    bl_label = "Save pose"
    bl_description = "Write <name>.json into art_src/mc/v2/rig_poses (and render the guides if ticked)"

    def execute(self, context):
        sc = context.scene
        name = sc.farroad_name.strip().replace(" ", "_")
        if not name:
            self.report({"ERROR"}, "Type a pose name first")
            return {"CANCELLED"}
        d = br.poses_dir()
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".json"), "w") as fh:
            json.dump(read_pose(sc), fh, indent=1)
        if sc.farroad_render:
            render_guides(sc, d, prefix=name + "_")
        self.report({"INFO"}, "Saved " + name)
        return {"FINISHED"}


class FARROAD_PT_rpanel(bpy.types.Panel):
    bl_label = "Farroad pose"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Farroad"

    def draw(self, context):
        sc, col = context.scene, self.layout.column()
        col.label(text="Body: " + sc.get("farroad_body", "male"))
        row = col.row(align=True)
        row.prop(sc, "farroad_rpose", text="")
        row.operator("farroad.rigify_load")
        col.operator("farroad.rigify_reset")
        col.separator()
        col.prop(sc, "farroad_name", text="Name")
        col.prop(sc, "farroad_render", text="Render guides on save")
        col.operator("farroad.rigify_save", icon="FILE_TICK")
        col.separator()
        col.label(text="Pose Mode: select a control and G / R.")
        col.label(text="IK/FK switch: Item tab > Rig Main Properties.")
        col.label(text="Numpad 0 = camera view.")


CLASSES = (FARROAD_OT_rload, FARROAD_OT_rreset, FARROAD_OT_rsave, FARROAD_PT_rpanel)


def register_ui():
    S = bpy.types.Scene
    S.farroad_rpose = bpy.props.EnumProperty(name="Pose", items=pose_items)
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
import importlib, blender_rig, rigify_rig
importlib.reload(blender_rig)
importlib.reload(rigify_rig)
blender_rig.set_body(bpy.context.scene.get("farroad_body", "male"))
rigify_rig.register_ui()
'''


def build_blend(path, body):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    rig = build(scene, body)
    txt = bpy.data.texts.new("farroad_rig_ui.py")
    txt.write(UI_BOOT)
    txt.use_module = True
    # open straight into Pose Mode on the rig
    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="POSE")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(path))
    print("built", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    body = argv[argv.index("--body") + 1] if "--body" in argv else "male"
    if argv and argv[0] == "--build":
        build_blend(argv[1], body)
    elif argv and argv[0] == "--render":
        scene = bpy.context.scene
        br.set_body(scene.get("farroad_body", body))
        with open(argv[1]) as fh:
            apply_pose(scene, json.load(fh))
        size = int(argv[argv.index("--size") + 1]) if "--size" in argv else 512
        render_guides(scene, argv[2], size=size)
        print("rendered", argv[2])


if __name__ == "__main__":
    main()

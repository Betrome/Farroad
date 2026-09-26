class_name Appearance
extends RefCounted
## Unit looks: which body (the male or female main-character sprite set)
## and colours for skin, hair, eyes, top, bottoms and shoes. Stored per
## unit in g["appearance"][uid] = {"body": "male"|"female", "colors":
## {part: "#rrggbb"}} -- a missing part keeps the sprite's own colour. The
## MC's body comes from g["mc"]["body"]. Companions without a stored look
## get a steady one picked from their id, so every unit is its own variation
## of the male or female character (Ian, for now, until units get own art).

const PARTS := ["skin", "hair", "eyes", "top", "bottoms", "shoes"]
const PART_ID := {"skin": 1, "hair": 2, "eyes": 3, "top": 4, "bottoms": 5, "shoes": 6}
const PART_LABEL := {"skin": "Skin", "hair": "Hair", "eyes": "Eyes", "top": "Top", "bottoms": "Bottoms", "shoes": "Shoes"}
const SPRITES := {"male": "kesh", "female": "mc_female"}

const PRESETS := {
	"skin": ["#ffe0c0", "#f3c79a", "#dba577", "#b87e52", "#8c5a38", "#613d26", "#fff0e6", "#b8cfe8"],
	"hair": ["#6e4424", "#262022", "#ecc86c", "#bd401f", "#ebebf2", "#3f66d9", "#f082b3", "#4ca659"],
	"eyes": ["#3f78b0", "#3d9950", "#7a5230", "#d09a2a", "#8a55c8", "#c43a3a", "#8a9098", "#2aa3a3"],
	"top": ["#5e8692", "#b53a3a", "#3f8a4a", "#6a4aa8", "#d8b340", "#ededed", "#2d2d33", "#2f9a9a"],
	"bottoms": ["#dcb06b", "#7a5230", "#2a2a30", "#2f3f73", "#8a8a90", "#4d6b3a", "#8f2f2f", "#e8e4da"],
	"shoes": ["#65402a", "#252027", "#7a2626", "#6f6f78", "#27335e", "#c29a62", "#3d5a30", "#e6e2da"],
}

static func look(g: Dictionary, uid: String) -> Dictionary:
	var stored: Dictionary = (g.get("appearance", {}) as Dictionary).get(uid, {})
	var body: String
	if uid == "kesh":
		body = str(g["mc"].get("body", "male")) if g.get("mc") != null else "male"
	else:
		body = str(stored.get("body", _default_body(uid)))
	var colors: Dictionary = stored.get("colors", {} if uid == "kesh" else _default_colors(uid))
	return {"body": body, "colors": colors}

static func set_part(g: Dictionary, uid: String, part: String, hex) -> void:
	var cur := look(g, uid)
	var colors: Dictionary = (cur["colors"] as Dictionary).duplicate()
	if hex == null:
		colors.erase(part)
	else:
		colors[part] = hex
	_store(g, uid, cur["body"], colors)

static func set_body(g: Dictionary, uid: String, body: String) -> void:
	if uid == "kesh" and g.get("mc") != null:
		g["mc"]["body"] = body
	_store(g, uid, body, look(g, uid)["colors"])

static func _store(g: Dictionary, uid: String, body: String, colors: Dictionary) -> void:
	if not g.has("appearance") or g["appearance"] == null:
		g["appearance"] = {}
	g["appearance"][uid] = {"body": body, "colors": colors}

static func sprite_set(g: Dictionary, uid: String) -> String:
	return SPRITES.get(look(g, uid)["body"], "kesh")

## A ShaderMaterial for this unit's look, or null if nothing is recoloured.
static func material_for(g: Dictionary, uid: String, part_ref: Array) -> ShaderMaterial:
	var colors: Dictionary = look(g, uid)["colors"] if not g.is_empty() else {}
	if part_ref.is_empty():
		return null
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/unit_recolor.gdshader")
	var pc := []
	for i in 7:
		pc.append(Vector4(0, 0, 0, 0))
	for part in colors:
		var c := Color(str(colors[part]))
		pc[PART_ID[part]] = Vector4(c.r, c.g, c.b, 1.0)
	mat.set_shader_parameter("part_color", pc)
	mat.set_shader_parameter("part_ref", PackedFloat32Array(part_ref))
	return mat

static func _hash(uid: String, salt: String) -> int:
	return absi(hash(uid + ":" + salt))

static func _default_body(uid: String) -> String:
	return "female" if _hash(uid, "body") % 2 == 1 else "male"

## How many presets (from the start of each list) are everyday choices --
## the automatic companion looks only use those; the rest (pale blue skin,
## pink or blue hair...) are there for players to pick.
const NATURAL := {"skin": 6, "hair": 5, "eyes": 7, "top": 8, "bottoms": 6, "shoes": 6}

static func _default_colors(uid: String) -> Dictionary:
	var out := {}
	for part in PARTS:
		var list: Array = PRESETS[part]
		out[part] = list[_hash(uid, part) % int(NATURAL[part])]
	return out

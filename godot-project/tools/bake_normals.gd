extends SceneTree
## Bakes a normal map (<frame>_n.png) beside every unit-sprite frame under
## res://sprites/units/, for the dynamic lighting (Lighting.gd wraps each frame
## in a CanvasTexture when the matching _n.png exists).
##
## Run after adding or changing unit art:
##   godot --headless --path godot-project --script tools/bake_normals.gd
##   godot --headless --path godot-project --import      (imports the new PNGs)
##
## The maps are derived from the sprite itself: a height field of coverage and
## brightness, blurred twice for a rounder surface, then Sobel. Good enough to give
## the art soft directional shading; hand-made maps can simply replace the files.
## (The recolour pipeline stores a part id in alpha, so "covered" means alpha > 0.5.)

const STRENGTH := 5.0

func _initialize() -> void:
	var n := 0
	for dir_name in DirAccess.get_directories_at("res://sprites/units"):
		var dir := "res://sprites/units/" + dir_name
		for f in DirAccess.get_files_at(dir):
			if not f.ends_with(".png") or f.ends_with("_n.png"):
				continue
			var img := Image.load_from_file(dir + "/" + f)
			if img == null:
				continue
			_bake(img).save_png(dir + "/" + f.replace(".png", "_n.png"))
			n += 1
	print("baked ", n, " normal maps")
	quit()

func _bake(img: Image) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var hf := PackedFloat32Array()
	hf.resize(w * h)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			hf[y * w + x] = (0.55 + 0.45 * c.get_luminance()) if c.a > 0.5 else 0.0
	for pass_i in 2:
		var b := hf.duplicate()
		for y in range(1, h - 1):
			for x in range(1, w - 1):
				var s := 0.0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						s += hf[(y + dy) * w + x + dx]
				b[y * w + x] = s / 9.0
		hf = b
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var xl := hf[y * w + maxi(x - 1, 0)]
			var xr := hf[y * w + mini(x + 1, w - 1)]
			var yu := hf[maxi(y - 1, 0) * w + x]
			var yd := hf[mini(y + 1, h - 1) * w + x]
			var n := Vector3((xl - xr) * STRENGTH, (yu - yd) * STRENGTH, 1.0).normalized()
			out.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, 1.0 if img.get_pixel(x, y).a > 0.5 else 0.0))
	return out

shader_type canvas_item;
// Per-part recolouring for unit sprites (tools/unit_anims.py writes each
// opaque pixel's part into its alpha: 255 - part id; 0 = leave alone).
// Parts: 1 skin, 2 hair, 3 eyes, 4 top, 5 bottoms, 6 shoes.
// A part with an enabled colour keeps its original light and shade: the
// pixel's brightness relative to that part's mid-tone (ref) scales the new
// colour, and anything brighter than the mid-tone blends toward white.

uniform vec4 part_color[7];   // rgb = new mid-tone colour, a > 0.5 = recolour this part
uniform float part_ref[7];    // the part's original mid-tone brightness

varying vec4 vertex_color;

void vertex() {
	vertex_color = COLOR;
}

void fragment() {
	vec4 t = texture(TEXTURE, UV);
	if (t.a < 0.5) {
		COLOR = vec4(t.rgb, 0.0);
	} else {
		int part = int(round((1.0 - t.a) * 255.0));
		vec3 rgb = t.rgb;
		if (part > 0 && part < 7 && part_color[part].a > 0.5) {
			float lum = dot(rgb, vec3(0.299, 0.587, 0.114));
			float ratio = lum / max(part_ref[part], 0.02);
			vec3 base = part_color[part].rgb;
			rgb = ratio <= 1.0 ? base * ratio : mix(base, vec3(1.0), clamp((ratio - 1.0) * 0.8, 0.0, 1.0));
		}
		COLOR = vec4(rgb, 1.0) * vertex_color;
	}
}

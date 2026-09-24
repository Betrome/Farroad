shader_type canvas_item;

// Recolors a layer (hair, eyes, skin...) while keeping its pixel shading.
// Each pixel's brightness is remapped onto a ramp from `shadow` to `light`,
// so any hair drawn in any colour can be shown in any other colour.
// strength 0 = original colours, 1 = fully recoloured.
uniform vec4 shadow : source_color = vec4(0.10, 0.06, 0.05, 1.0);
uniform vec4 light : source_color = vec4(0.85, 0.65, 0.45, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.0;
// Contrast around the layer's own brightness range, so dark-drawn hair
// still spreads across the whole ramp.
uniform float lum_min = 0.0;
uniform float lum_max = 1.0;
// Pixels less saturated than this keep their drawn colour. 0 recolours
// everything (hair); ~0.15 on eyes leaves whites, lashes and pupils alone
// and only recolours the iris.
uniform float sat_min = 0.0;

void fragment() {
	// COLOR already holds texture * modulate here; don't sample TEXTURE again
	// and multiply, or every colour gets squared (darker).
	vec4 c = COLOR;
	float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
	float k = sat >= sat_min ? strength : 0.0;
	float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	float t = clamp((lum - lum_min) / max(0.001, lum_max - lum_min), 0.0, 1.0);
	vec3 ramp = mix(shadow.rgb, light.rgb, t);
	COLOR = vec4(mix(c.rgb, ramp, k), c.a);
}

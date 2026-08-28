$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_tint;
uniform vec4 u_tintMode;
uniform vec4 u_tintFinish;

// A stable float hash of a screen cell: deterministic, no runtime RNG, so a
// shimmer glint lands on the same cells every frame and every run.
float tintHash(vec2 p)
{
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

// A masked color layer: folds u_tint.rgb into the frame scaled by the mask on
// unit 1 and u_tint.w opacity, so a face-part matte reads as soft makeup. mode
// 0 blends toward the color, 1 multiplies it in for a contour shadow, 2 screens
// it for a highlight. Zero mask leaves the frame untouched.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float m = texture2D(s_texDepth, uv).r;
	float amount = m * u_tint.w;
	vec3 base = color.rgb;
	vec3 target = u_tint.xyz;
	if (u_tintMode.x > 1.5) {
		target = 1.0 - (1.0 - base) * (1.0 - u_tint.xyz);
	} else if (u_tintMode.x > 0.5) {
		target = base * u_tint.xyz;
	}
	vec3 tinted = mix(base, target, amount);
	vec3 outc = tinted;

	// The finish reads the frame's own highlight as its light: matte (finish 0)
	// leaves the flat blend byte-identical, the rest add a sheen scaled by the
	// mask amount so it vanishes with the region.
	float finish = u_tintFinish.x;
	float luma = dot(base, vec3(0.299, 0.587, 0.114));
	float hi = smoothstep(0.4, 0.95, luma);
	if (finish > 2.5) {
		// Metallic drives a contrast and chroma boost around the mid so the
		// layer reads harder, plus a specular follow of the real highlight.
		float sheen = hi * 0.7 * amount;
		vec3 boosted = (tinted - 0.5) * 1.4 + 0.5;
		float lum = dot(boosted, vec3(0.299, 0.587, 0.114));
		vec3 chroma = mix(vec3_splat(lum), boosted, 1.0 + 0.4 * amount);
		outc = mix(tinted, chroma, amount) + vec3_splat(sheen);
	} else if (finish > 1.5) {
		// Shimmer sparkles a stable per-cell glint, denser on the highlights,
		// so the region carries a fine micro-glint the flat blend lacks.
		float glint = step(0.7, tintHash(floor(uv * 180.0)));
		float spark = glint * (0.4 + 0.6 * hi) * 0.6 * amount;
		outc = tinted + vec3_splat(spark);
	} else if (finish > 0.5) {
		// Gloss lifts the region's own highlights into a soft specular sheen.
		float sheen = hi * 0.55 * amount;
		outc = tinted + vec3_splat(sheen);
	}

	gl_FragColor = vec4(clamp(outc, 0.0, 1.0), color.a);
}

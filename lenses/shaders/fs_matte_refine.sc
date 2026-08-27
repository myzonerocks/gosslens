$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_matteRefine;

// A guided (joint-bilateral) matte refinement: frame luminance (unit 0) guides,
// the matte rides on unit 1. Each output alpha averages nearby matte samples
// weighted by distance and guide-luma similarity, snapping the matte to real
// image edges and smoothing flats. u_matteRefine = (radius, sensitivity, strength).
void main()
{
	vec2 uv = v_texcoord0;
	vec3 base_rgb = texture2D(s_texColor, uv).rgb;
	float guide0 = dot(base_rgb, vec3(0.299, 0.587, 0.114));
	float matte0 = texture2D(s_texDepth, uv).r;

	float radius = max(u_matteRefine.x, 0.001);
	float sensitivity = u_matteRefine.y;
	float strength = clamp(u_matteRefine.z, 0.0, 1.0);

	float stride_uv = 0.006 * radius;
	float sigma2 = 2.0 * radius * radius + 0.0001;

	float wsum = 0.0;
	float msum = 0.0;
	for (int jy = -2; jy <= 2; jy++) {
		for (int ix = -2; ix <= 2; ix++) {
			vec2 off = vec2(float(ix), float(jy)) * stride_uv;
			vec3 neighbor_rgb = texture2D(s_texColor, uv + off).rgb;
			float guide_n = dot(neighbor_rgb, vec3(0.299, 0.587, 0.114));
			float matte_n = texture2D(s_texDepth, uv + off).r;
			float dist2 = float(ix * ix + jy * jy);
			float w_spatial = exp(-dist2 / sigma2);
			float dg = (guide_n - guide0) * sensitivity;
			float w_range = exp(-dg * dg);
			float w = w_spatial * w_range;
			wsum += w;
			msum += w * matte_n;
		}
	}
	float refined = (wsum > 0.0) ? (msum / wsum) : matte0;
	float outm = mix(matte0, refined, strength);
	gl_FragColor = vec4(vec3(outm), 1.0);
}

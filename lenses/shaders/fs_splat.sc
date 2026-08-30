$input v_billboard, v_color

#include <bgfx_shader.sh>

// One gaussian splat's coverage: v_billboard.xy is the local gaussian coordinate
// in sigma units, so exp(-0.5 * dot) is the anisotropic falloff, weighted by the
// splat opacity in v_color.a. The colour is premultiplied here for the sorted
// over-blend, and a near-zero tail is discarded so the clouds stay cheap.
void main()
{
	vec2 g = v_billboard.xy;
	float a = v_color.a * exp(-0.5 * dot(g, g));
	if (a < 0.004) discard;
	gl_FragColor = vec4(v_color.rgb * a, a);
}

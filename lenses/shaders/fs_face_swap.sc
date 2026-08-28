$input v_backgroundUv, v_swapUv, v_feather

#include <bgfx_shader.sh>

SAMPLER2D(s_texBackground, 0);
SAMPLER2D(s_texMakeup, 1);
SAMPLER2D(s_texMask, 2);
uniform vec4 u_swapParams; // x: opacity, y: feather width

// The face swap warps a donor face, baked in canonical face-mesh UVs, onto the
// live tracked mesh and blends it only inside the face. The seam weight ramps
// from 0 on the silhouette to 1 inside; a smoothstep over the feather width
// turns it into a soft alpha so the donor meets real skin without a hard edge.
void main()
{
	vec4 donor = texture2D(s_texMakeup, v_swapUv);
	vec4 bg = texture2D(s_texBackground, v_backgroundUv);
	float region = texture2D(s_texMask, v_backgroundUv).x;
	float width = max(u_swapParams.y, 0.0001);
	float seam = smoothstep(0.0, width, v_feather.x);
	float coverage = donor.a * u_swapParams.x * region * seam;
	vec3 outc = mix(bg.rgb, donor.rgb, coverage);
	gl_FragColor = vec4(outc, bg.a);
}

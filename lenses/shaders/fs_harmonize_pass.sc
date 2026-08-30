$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_harmonize[4]; // [0] fg mean + strength, [1] fg std + direction, [2] bg mean, [3] bg std

// A harmonize.pass node's statistical color transfer: it matches one region's
// color distribution to the other's by a Reinhard transfer (subtract the source
// mean, scale by the ratio of standard deviations, add the destination mean). The
// mask picks the region, direction picks the way, and strength blends the match.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	float m = texture2D(s_texMask, v_texcoord0).r;
	vec3 fgMean = u_harmonize[0].xyz;
	float strength = u_harmonize[0].w;
	vec3 fgStd = u_harmonize[1].xyz;
	float direction = u_harmonize[1].w;
	vec3 bgMean = u_harmonize[2].xyz;
	vec3 bgStd = u_harmonize[3].xyz;
	vec3 srcMean = direction < 0.5 ? fgMean : bgMean;
	vec3 srcStd = direction < 0.5 ? fgStd : bgStd;
	vec3 dstMean = direction < 0.5 ? bgMean : fgMean;
	vec3 dstStd = direction < 0.5 ? bgStd : fgStd;
	vec3 transferred = (color - srcMean) / max(srcStd, vec3_splat(0.02)) * dstStd + dstMean;
	float region = direction < 0.5 ? m : (1.0 - m);
	gl_FragColor = vec4(clamp(mix(color, transferred, region * strength), 0.0, 1.0), 1.0);
}

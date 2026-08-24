$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_fog;

// A depth fog pass: the frame fades toward u_fog's rgb by how far its
// submitted depth is, u_fog.w the density, so distant geometry sinks into
// haze while near content stays clear. With no depth the pass holds off.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	float depth = texture2D(s_texDepth, v_texcoord0).r;
	float amount = clamp(depth * u_fog.w, 0.0, 1.0);
	gl_FragColor = vec4(mix(color.rgb, u_fog.xyz, amount), color.a);
}

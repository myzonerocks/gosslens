$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_ssr;

// A screen-space planar reflection: below the horizon at u_ssr.y the frame
// mirrors what is above it, so a reflective floor picks up the scene. The
// submitted depth gates it - near surfaces reflect, far ones stay dry -
// scaled by u_ssr.x, so flat far depth leaves the frame untouched.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float plane = u_ssr.y;
	float refl_v = 2.0 * plane - uv.y;
	vec3 refl = texture2D(s_texColor, vec2(uv.x, clamp(refl_v, 0.0, 1.0))).rgb;
	float d = texture2D(s_texDepth, uv).r;
	float k = u_ssr.x * (1.0 - d) * step(plane, uv.y);
	gl_FragColor = vec4(mix(color.rgb, refl, clamp(k, 0.0, 1.0)), color.a);
}

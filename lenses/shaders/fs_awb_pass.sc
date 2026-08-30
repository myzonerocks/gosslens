$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_awb;       // gainR, gainG, gainB, strength
uniform vec4 u_awbLevel;  // black, white, unused, unused

// An awb.pass node's one-tap auto-enhance: per-channel gray-world gains pull the
// frame's average toward neutral, then an auto-levels stretch maps the luma black
// and white points to the full range. u_awb.w blends the correction in, 0
// leaving the frame untouched.
void main()
{
	vec3 rgb = texture2D(s_texColor, v_texcoord0).rgb;
	vec3 wb = rgb * u_awb.xyz;
	float denom = max(u_awbLevel.y - u_awbLevel.x, 0.03);
	vec3 lev = clamp((wb - vec3_splat(u_awbLevel.x)) / denom, 0.0, 1.0);
	gl_FragColor = vec4(clamp(mix(rgb, lev, u_awb.w), 0.0, 1.0), 1.0);
}

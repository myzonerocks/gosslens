$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_undistort;   // k1, k2, strength, aspect (fx/fy)
uniform vec4 u_undistortC;  // cx, cy (normalized), unused

// Inverse radial remap: for each output pixel the sampler reads the distorted
// input at the radius the true point sits at, r_d = r*(1 + k1 r^2 + k2 r^4), so
// a barrel or pincushion frame is straightened. Aspect corrects a non-square
// frame; strength blends toward the corrected sample, 0 leaving it untouched.
void main()
{
	vec2 center = u_undistortC.xy;
	vec2 off = v_texcoord0 - center;
	vec2 da = vec2(off.x * u_undistort.w, off.y);
	float r2 = dot(da, da);
	float f = 1.0 + u_undistort.x * r2 + u_undistort.y * r2 * r2;
	vec2 src = center + off * f;
	vec3 corrected = texture2D(s_texColor, src).rgb;
	vec3 base = texture2D(s_texColor, v_texcoord0).rgb;
	gl_FragColor = vec4(mix(base, corrected, u_undistort.z), 1.0);
}

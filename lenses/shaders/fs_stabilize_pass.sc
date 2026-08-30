$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_stabilize;  // shiftU, shiftV, inset, strength

// A stabilize.pass node's stabilization: the frame is zoomed in by the inset
// margin and shifted by the residual jitter the engine estimated, so content
// holds on a smoothed path. The zoom hides the edge the shift would reveal;
// strength blends the correction in, 0 leaving the frame untouched.
void main()
{
	vec2 center = vec2(0.5, 0.5);
	vec2 uv = center + (v_texcoord0 - center) * (1.0 - u_stabilize.z) - u_stabilize.xy;
	vec3 stabilized = texture2D(s_texColor, clamp(uv, 0.0, 1.0)).rgb;
	vec3 base = texture2D(s_texColor, v_texcoord0).rgb;
	gl_FragColor = vec4(mix(base, stabilized, u_stabilize.w), 1.0);
}

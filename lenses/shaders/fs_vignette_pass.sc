$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_vignette;

// A vignette.pass node's radial luma-gain: distance from the frame centre rolls
// in from the radius u_vignette.y out to the corner, scaling the gain
// u_vignette.x. A positive strength lifts the darkened corners (correcting a lens
// vignette), a negative sinks them (a stylistic one); strength 0 is untouched.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	vec2 d = v_texcoord0 - vec2(0.5, 0.5);
	float dist = length(d) / 0.70710678;
	float falloff = clamp((dist - u_vignette.y) / (1.0 - u_vignette.y), 0.0, 1.0);
	float gain = 1.0 + u_vignette.x * falloff;
	gl_FragColor = vec4(clamp(color * gain, 0.0, 1.0), 1.0);
}

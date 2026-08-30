$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_relight;

// A relight.pass node's parametric directional relight: a soft key light whose
// direction is u_relight.yz brightens the frame on the light side and shades
// the far side, scaled by the strength u_relight.x. Strength 0 is untouched.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	vec2 p = v_texcoord0 - vec2(0.5, 0.5);
	float lit = dot(p, u_relight.yz);
	float gain = 1.0 + u_relight.x * lit;
	gl_FragColor = vec4(clamp(color * gain, 0.0, 1.0), 1.0);
}

$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_dehaze;

// A dehaze.pass node's single-pass dark-channel-prior dehaze: the dark channel
// (darkest of r,g,b over a neighborhood) estimates the atmospheric veil on a
// pixel, and the transmission recovers the scene radiance from under it.
// u_dehaze.x is the strength (0 = untouched), u_dehaze.yz the texel step.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	float dark = 1.0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			vec3 s = texture2D(s_texColor, v_texcoord0 + vec2(float(dx), float(dy)) * u_dehaze.yz).rgb;
			dark = min(dark, min(s.r, min(s.g, s.b)));
		}
	}
	float airlight = 0.95;
	float t = max(1.0 - u_dehaze.x * dark / airlight, 0.1);
	vec3 dehazed = (color - airlight) / t + airlight;
	gl_FragColor = vec4(clamp(dehazed, 0.0, 1.0), 1.0);
}

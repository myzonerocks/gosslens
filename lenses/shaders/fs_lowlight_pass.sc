$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_lowlight;

// A lowlight.pass node's night lift: a shadow-weighted blur of the neighbourhood
// damps the noise that lives in dark regions, then a gamma curve raises the
// shadows while holding the highlights near white. u_lowlight.x is the lift
// strength, .y the denoise amount, .zw the texel step; 0/0 leaves the frame be.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	float luma = dot(color, vec3(0.299, 0.587, 0.114));
	float shadow = 1.0 - smoothstep(0.0, 0.5, luma);
	vec3 avg = vec3_splat(0.0);
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			avg += texture2D(s_texColor, v_texcoord0 + vec2(float(dx), float(dy)) * u_lowlight.zw).rgb;
		}
	}
	avg /= 9.0;
	vec3 cleaned = mix(color, avg, u_lowlight.y * shadow);
	float gamma = 1.0 / (1.0 + u_lowlight.x * 1.5);
	vec3 lifted = pow(max(cleaned, vec3_splat(0.0)), vec3_splat(gamma));
	gl_FragColor = vec4(clamp(lifted, 0.0, 1.0), 1.0);
}

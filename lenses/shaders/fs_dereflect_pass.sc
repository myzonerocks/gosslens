$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_dereflect;  // strength, texel_w, texel_h, 0

// A dereflect.pass node's localized specular attenuation: a glass reflection
// sits as high-frequency detail over the bright regions, so the pass pulls each
// pixel's detail (its difference from the neighbourhood mean) back toward that
// mean, weighted by brightness and the strength u_dereflect.x; dark is untouched.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	vec3 mean = vec3_splat(0.0);
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			mean += texture2D(s_texColor, v_texcoord0 + vec2(float(dx), float(dy)) * u_dereflect.yz).rgb;
		}
	}
	mean /= 9.0;
	vec3 high = color - mean;
	float luma = dot(color, vec3(0.299, 0.587, 0.114));
	float w = smoothstep(0.45, 0.9, luma) * u_dereflect.x;
	gl_FragColor = vec4(clamp(color - high * w, 0.0, 1.0), 1.0);
}

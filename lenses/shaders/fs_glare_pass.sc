$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_glare;

// A glare.pass node's specular-highlight rolloff: a pixel whose luma sits above
// the threshold u_glare.y is pulled back down toward it by the strength
// u_glare.x, so blown-out speculars recover while the rest of the frame holds.
// Strength 0 leaves the frame untouched.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	float luma = dot(color, vec3(0.299, 0.587, 0.114));
	float excess = max(luma - u_glare.y, 0.0);
	vec3 recovered = color - vec3_splat(u_glare.x * excess);
	gl_FragColor = vec4(clamp(recovered, 0.0, 1.0), 1.0);
}

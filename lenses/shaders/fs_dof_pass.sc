$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_dof;

// A depth-of-field pass with a bokeh disc kernel: sharp at the focus plane,
// blurred where the submitted depth is far from it. u_dof packs focus (0..1),
// strength, and disc radius; the out-of-focus image samples two concentric
// rings of taps on a circle, mixed in by the depth's distance from focus.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 sharp = texture2D(s_texColor, uv);

	float focus = u_dof.x;
	float strength = u_dof.y;
	float radius = u_dof.z;

	float depth = texture2D(s_texDepth, uv).r;
	float amount = clamp(abs(depth - focus) * strength, 0.0, 1.0);

	vec3 sum = sharp.rgb;
	float weight = 1.0;
	float r1 = radius * amount;
	for (int i = 0; i < 6; i++)
	{
		float a = 6.2831853 * float(i) / 6.0;
		sum += texture2D(s_texColor, uv + vec2(cos(a), sin(a)) * r1).rgb;
		weight += 1.0;
	}
	float r2 = radius * amount * 2.0;
	for (int j = 0; j < 12; j++)
	{
		float a = 6.2831853 * float(j) / 12.0 + 0.26179;
		sum += texture2D(s_texColor, uv + vec2(cos(a), sin(a)) * r2).rgb;
		weight += 1.0;
	}
	vec3 bokeh = sum / weight;

	gl_FragColor = vec4(mix(sharp.rgb, bokeh, amount), sharp.a);
}

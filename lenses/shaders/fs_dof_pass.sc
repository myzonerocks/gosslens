$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_dof;

// A depth-of-field pass: the frame stays sharp at the focus plane and
// blurs where its submitted depth is far from it. u_dof packs focus (0..1
// over near..far), strength, and the tap offset; a nine-tap box blur is
// the out-of-focus image, mixed by the depth distance from focus.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 sharp = texture2D(s_texColor, uv);

	float focus = u_dof.x;
	float strength = u_dof.y;
	float off = u_dof.z;

	vec3 sum = vec3_splat(0.0);
	for (int i = -4; i <= 4; i++)
	{
		sum += texture2D(s_texColor, uv + vec2(off * float(i), off * float(i))).rgb;
	}
	vec3 blurred = sum / 9.0;

	float depth = texture2D(s_texDepth, uv).r;
	float amount = clamp(abs(depth - focus) * strength, 0.0, 1.0);

	gl_FragColor = vec4(mix(sharp.rgb, blurred, amount), sharp.a);
}

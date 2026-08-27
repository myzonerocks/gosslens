$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_tint;

// A masked color layer: blends u_tint.rgb into the frame scaled by the mask
// on unit 1 and u_tint.w opacity, so a face-part matte reads as soft makeup
// (eyeshadow, lip or brow tint). Zero mask leaves the frame untouched.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float m = texture2D(s_texDepth, uv).r;
	float amount = m * u_tint.w;
	gl_FragColor = vec4(mix(color.rgb, u_tint.xyz, amount), color.a);
}

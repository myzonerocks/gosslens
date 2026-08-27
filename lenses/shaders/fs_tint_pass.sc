$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_tint;
uniform vec4 u_tintMode;

// A masked color layer: folds u_tint.rgb into the frame scaled by the mask on
// unit 1 and u_tint.w opacity, so a face-part matte reads as soft makeup. mode
// 0 blends toward the color, 1 multiplies it in for a contour shadow, 2 screens
// it for a highlight. Zero mask leaves the frame untouched.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float m = texture2D(s_texDepth, uv).r;
	float amount = m * u_tint.w;
	vec3 base = color.rgb;
	vec3 target = u_tint.xyz;
	if (u_tintMode.x > 1.5) {
		target = 1.0 - (1.0 - base) * (1.0 - u_tint.xyz);
	} else if (u_tintMode.x > 0.5) {
		target = base * u_tint.xyz;
	}
	gl_FragColor = vec4(mix(base, target, amount), color.a);
}

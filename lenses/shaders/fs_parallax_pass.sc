$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_parallax; // xy per-frame shift (amount-scaled), z focus plane, w fill mode

// A parallax.pass node's 3D-photo warp: each pixel reads its color from a source
// shifted by the submitted depth's signed distance from the focus plane, so the
// layers nearer and farther than focus sway opposite ways as the device tilts
// while the subject at the focus plane holds. No tilt is an identity.
void main()
{
	vec2 uv = v_texcoord0;
	float d = texture2D(s_texDepth, uv).r;
	float disp = d - u_parallax.z;
	vec2 src = uv + disp * u_parallax.xy;
	if (u_parallax.w > 0.5) {
		// mirror the revealed edges back into gamut so the border does not smear
		src = abs(src);
		src = 1.0 - abs(1.0 - mod(src, vec2_splat(2.0)));
	} else {
		src = clamp(src, vec2_splat(0.0), vec2_splat(1.0));
	}
	gl_FragColor = texture2D(s_texColor, src);
}

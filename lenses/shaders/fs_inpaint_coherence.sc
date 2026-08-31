$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);      // fresh inpaint this frame
SAMPLER2D(s_texBackground, 1); // previous frame's inpaint output
SAMPLER2D(s_texMask, 2);       // the fill region
uniform vec4 u_coherence;      // x: coherence amount 0..1

// Temporal consistency for the inpaint fill: inside the removal mask the fresh
// fill blends toward the previous frame's fill by the coherence amount, so a
// video inpaint holds steady instead of flickering frame to frame. Outside the
// mask the frame is untouched. Coherence 0 is the raw per-frame fill.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 fresh = texture2D(s_texColor, uv);
	vec4 prev = texture2D(s_texBackground, uv);
	float m = texture2D(s_texMask, uv).r;
	float k = clamp(u_coherence.x, 0.0, 1.0) * m;
	gl_FragColor = vec4(mix(fresh.rgb, prev.rgb, k), fresh.a);
}

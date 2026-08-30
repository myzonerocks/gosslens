$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_zoom;  // factor, centerU, centerV, unused

// A zoom.pass node's digital region zoom: the frame is magnified around a centre
// by a factor, so a sub-region fills the output and reads sharper after an
// upscale resharpen downstream. Factor 1 with a centred point is the identity.
void main()
{
	vec2 center = u_zoom.yz;
	vec2 uv = center + (v_texcoord0 - vec2(0.5, 0.5)) / max(u_zoom.x, 1.0);
	gl_FragColor = vec4(texture2D(s_texColor, clamp(uv, 0.0, 1.0)).rgb, 1.0);
}

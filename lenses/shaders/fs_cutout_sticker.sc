$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_cutout;

// Lifts the segmented subject into a transparent-background cutout: the matte on
// unit 1 becomes the alpha so the subject keeps the camera colour and the rest
// goes clear, ready to draw at a rect as a movable sticker. u_cutout.w feathers
// the matte edge so the cut is not jagged. A zero matte yields a clear frame.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 frame = texture2D(s_texColor, uv);
	float m = texture2D(s_texMask, uv).r;
	float soft = clamp(u_cutout.w, 0.001, 0.5);
	float keyed = smoothstep(0.5 - soft, 0.5 + soft, m);
	gl_FragColor = vec4(frame.rgb, keyed);
}

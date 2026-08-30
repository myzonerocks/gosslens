$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texBackground, 1);
SAMPLER2D(s_texMask, 2);

uniform vec4 u_blendParams;

// A blend.pass node's fixed compositing shader: the segmentation mask's
// red channel is the subject's confidence at this pixel (1.0 fully
// foreground, 0.0 fully background), so a plain lerp between the
// background image and the camera frame reproduces the mask's own soft
// edges. u_blendParams.x scales the mask so a masked restyle mixes onto
// its region by a strength (1 is full, a greenscreen key stays 1).
void main()
{
	vec4 frame = texture2D(s_texColor, v_texcoord0);
	vec4 background = texture2D(s_texBackground, v_texcoord0);
	float mask = texture2D(s_texMask, v_texcoord0).r * u_blendParams.x;

	vec3 blended = mix(background.rgb, frame.rgb, mask);
	gl_FragColor = vec4(blended, frame.a);
}

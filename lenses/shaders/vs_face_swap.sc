$input a_position, a_texcoord1, a_texcoord2
$output v_backgroundUv, v_swapUv, v_feather

#include <bgfx_shader.sh>

// The face swap rides the same face mesh vs_makeup drives: a_position is the
// live tracked landmark in 0-1 UV space, both the clip position and the frame
// sample point, a_texcoord1 the donor's canonical face UV, and a_texcoord2.x
// the per-vertex seam feather that fades the donor into the surrounding skin.
void main()
{
	vec2 ndc = vec2(a_position.x * 2.0 - 1.0, 1.0 - a_position.y * 2.0);
	gl_Position = vec4(ndc, 0.0, 1.0);
	v_backgroundUv = a_position;
	v_swapUv = a_texcoord1;
	v_feather = a_texcoord2;
}

$input a_position, a_texcoord0, i_data0, i_data1, i_data2, i_data3
$output v_texcoord0

#include <bgfx_shader.sh>

// The lens vertex stage, instanced: each instance carries its own model matrix
// as four vec4 columns, so a cloud of the same mesh draws in one call. The
// world position is the same one the per-draw path computes, so the two match.
void main()
{
	mat4 model = mtxFromCols(i_data0, i_data1, i_data2, i_data3);
	vec4 worldPos = mul(model, vec4(a_position, 1.0));
	gl_Position = mul(u_viewProj, worldPos);
	v_texcoord0 = a_texcoord0;
}

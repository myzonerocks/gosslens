$input a_position, a_normal, a_texcoord0
$output v_normal, v_worldpos, v_texcoord0

#include <bgfx_shader.sh>

// A lit model.gltf vertex stage: the clip transform plus the world-space
// normal and position (the model matrix's upper 3x3 rotates the normal, the
// full matrix places the position) for the fragment stage to shade a
// directional light and a view-dependent specular highlight against.
void main()
{
	gl_Position = mul(u_modelViewProj, vec4(a_position, 1.0));
	v_normal = mul(u_model[0], vec4(a_normal, 0.0)).xyz;
	v_worldpos = mul(u_model[0], vec4(a_position, 1.0)).xyz;
	v_texcoord0 = a_texcoord0;
}

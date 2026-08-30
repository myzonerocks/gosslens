$input a_position, a_normal, a_texcoord0
$output v_normal, v_texcoord0

#include <bgfx_shader.sh>

// A lit model.gltf vertex stage: the same clip transform as the flat model,
// plus the world-space normal (the model matrix's upper 3x3 rotates it) for
// the fragment stage to shade a directional light against.
void main()
{
	gl_Position = mul(u_modelViewProj, vec4(a_position, 1.0));
	v_normal = mul(u_model[0], vec4(a_normal, 0.0)).xyz;
	v_texcoord0 = a_texcoord0;
}

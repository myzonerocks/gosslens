$input a_position, a_texcoord0, a_texcoord1, a_color0
$output v_billboard, v_color

#include <bgfx_shader.sh>

// Expands one anisotropic gaussian splat: a_position is the splat centre,
// a_texcoord0.xy this corner's offset in the camera-facing plane (the projected
// 3D covariance's oriented ellipse, baked per frame), a_texcoord1.xy the local
// gaussian coordinate the fragment evaluates, a_color0 the colour and opacity.
void main()
{
	vec3 centre = a_position;
	vec3 offset = vec3(a_texcoord0.xy, 0.0);
	gl_Position = mul(u_modelViewProj, vec4(centre + offset, 1.0));
	v_billboard = vec4(a_texcoord1, 0.0, 0.0);
	v_color = a_color0;
}

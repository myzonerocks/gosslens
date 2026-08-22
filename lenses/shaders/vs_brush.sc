$input a_position, a_color0
$output v_color0

#include <bgfx_shader.sh>

// The brush ribbon vertex stage. a_position is a normalized screen point
// (0-1, y down), remapped to clip space the same way the makeup mesh does,
// since the ribbon is already in screen space with no model to transform.
// The per-stroke color rides through to the fragment stage.
void main()
{
	vec2 ndc = vec2(a_position.x * 2.0 - 1.0, 1.0 - a_position.y * 2.0);
	gl_Position = vec4(ndc, 0.0, 1.0);
	v_color0 = a_color0;
}

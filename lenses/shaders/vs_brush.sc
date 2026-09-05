$input a_position, a_color0
$output v_color0

#include <bgfx_shader.sh>

uniform vec4 u_meshTile;

// The brush ribbon vertex stage. a_position is a normalized screen point
// (0-1, y down), remapped to clip space the same way the makeup mesh does,
// since the ribbon is already in screen space with no model to transform.
// The per-stroke color rides through to the fragment stage.
// u_meshTile is the sub-rect a tiled capture is rendering (origin, span; whole frame is
// 0,0,1,1). Only the clip position is tiled - the frame sample point stays in whole-frame
// space, so the mesh reads the same pixels whatever tile it lands in.
void main()
{
	vec2 tiled = (a_position.xy - u_meshTile.xy) / u_meshTile.zw;
	vec2 ndc = vec2(tiled.x * 2.0 - 1.0, 1.0 - tiled.y * 2.0);
	gl_Position = vec4(ndc, 0.0, 1.0);
	v_color0 = a_color0;
}

$input a_position, a_texcoord1
$output v_backgroundUv, v_makeupUv

#include <bgfx_shader.sh>

uniform vec4 u_meshTile;

// beauty.lipstick/beauty.blusher's own mesh vertex stage: a_position is
// the live tracked landmark in 0-1 UV space, doubling as both the
// clip-space position (after the same manual NDC remap sdk/ts's own
// proven WebGL2 version uses, not bgfx's usual MVP uniform - there is
// no model to transform, only a flat mesh already in UV space) and the
// background sample point, so the mesh reads the frame at exactly the
// screen position it draws over. a_texcoord1 is the mesh's own fixed
// UV into the makeup source image (bgfx's vertex attribute names are a
// closed set - a_texcoord1 rather than a more descriptive name).
// u_meshTile is the sub-rect a tiled capture is rendering (origin, span; whole frame is
// 0,0,1,1). Only the clip position is tiled - the frame sample point stays in whole-frame
// space, so the mesh reads the same pixels whatever tile it lands in.
void main()
{
	vec2 tiled = (a_position.xy - u_meshTile.xy) / u_meshTile.zw;
	vec2 ndc = vec2(tiled.x * 2.0 - 1.0, 1.0 - tiled.y * 2.0);
	gl_Position = vec4(ndc, 0.0, 1.0);
	v_backgroundUv = a_position;
	v_makeupUv = a_texcoord1;
}

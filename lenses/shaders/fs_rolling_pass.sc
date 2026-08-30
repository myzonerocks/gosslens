$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_rolling; // xy per-row skew (image uv), z,w unused

// A rolling.pass node's rolling-shutter correction: a sensor reads its rows
// top-to-bottom over the frame readout, so camera rotation during that readout
// skews each scanline. The engine derives the motion from the orientation stream
// and this pass counter-shifts each row by its readout offset from the centre.
void main()
{
	vec2 skew = u_rolling.xy;
	vec2 srcuv = v_texcoord0 - skew * (v_texcoord0.y - 0.5);
	gl_FragColor = vec4(texture2D(s_texColor, srcuv).rgb, 1.0);
}

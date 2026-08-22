$input v_color0

#include <bgfx_shader.sh>

// Flat per-vertex brush color. The caller's blend state does the rest: a
// straight alpha blend for pen, highlighter, and marker, an additive blend
// for the neon glow.
void main()
{
	gl_FragColor = v_color0;
}

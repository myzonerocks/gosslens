$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texPrev, 1);
uniform vec4 u_trail;

// A motion-trail pass: the current frame on unit 0 blended with the
// previous frame's output on unit 1 by u_trail.x, so moving content leaves
// an echo. The engine copies the current frame into the previous buffer
// after this pass, so next frame trails against this one.
void main()
{
	vec4 cur = texture2D(s_texColor, v_texcoord0);
	vec4 old = texture2D(s_texPrev, v_texcoord0);
	gl_FragColor = mix(cur, old, u_trail.x);
}

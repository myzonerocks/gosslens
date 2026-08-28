$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_cutout;

// Isolates the face: the matte on unit 1 keys the camera frame through, and
// where the matte is off the chosen flat colour replaces it, so the face reads
// on a plain background. u_cutout.rgb is that colour, u_cutout.w feathers the
// matte edge so the cut is not jagged. A zero matte leaves a flat colour field.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 frame = texture2D(s_texColor, uv);
	float m = texture2D(s_texMask, uv).r;
	float soft = clamp(u_cutout.w, 0.001, 0.5);
	float keyed = smoothstep(0.5 - soft, 0.5 + soft, m);
	vec3 outc = mix(u_cutout.xyz, frame.rgb, keyed);
	gl_FragColor = vec4(outc, frame.a);
}

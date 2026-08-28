$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texBackground, 1);
SAMPLER2D(s_texMask, 2);
uniform vec4 u_occluder;

// A head occluder: the head matte on unit 2 keys the preserved camera frame
// on unit 1 back over the composited frame on unit 0, so 3D content drawn
// behind the head is hidden by it. u_occluder.xy grows the silhouette,
// u_occluder.z softens the edge; the pass adds no colour of its own.
void main()
{
	vec2 uv = v_texcoord0;
	float ex = u_occluder.x;
	float ey = u_occluder.y;
	float m = texture2D(s_texMask, uv).r;
	m = max(m, texture2D(s_texMask, uv + vec2(ex, 0.0)).r);
	m = max(m, texture2D(s_texMask, uv + vec2(-ex, 0.0)).r);
	m = max(m, texture2D(s_texMask, uv + vec2(0.0, ey)).r);
	m = max(m, texture2D(s_texMask, uv + vec2(0.0, -ey)).r);
	float soft = clamp(u_occluder.z, 0.001, 0.5);
	float keyed = smoothstep(0.5 - soft, 0.5 + soft, m);
	vec4 content = texture2D(s_texColor, uv);
	vec4 head = texture2D(s_texBackground, uv);
	gl_FragColor = vec4(mix(content.rgb, head.rgb, keyed), content.a);
}

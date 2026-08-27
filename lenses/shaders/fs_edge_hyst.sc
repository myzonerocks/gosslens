$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_edge;
uniform vec4 u_edgeTexel;

// Canny weak-pixel hysteresis: a suppressed pixel survives only if it is lit
// and enough of its 3x3 neighbours are too, bridging strong edges across the
// gaps suppression left. u_edge.x inverts to dark edges on a light field.
void main()
{
	vec2 uv = v_texcoord0;
	vec2 t = u_edgeTexel.xy;
	float center = texture2D(s_texColor, uv).r;
	float sum = center;
	sum += texture2D(s_texColor, uv + vec2(-t.x, -t.y)).r;
	sum += texture2D(s_texColor, uv + vec2(0.0, -t.y)).r;
	sum += texture2D(s_texColor, uv + vec2(t.x, -t.y)).r;
	sum += texture2D(s_texColor, uv + vec2(-t.x, 0.0)).r;
	sum += texture2D(s_texColor, uv + vec2(t.x, 0.0)).r;
	sum += texture2D(s_texColor, uv + vec2(-t.x, t.y)).r;
	sum += texture2D(s_texColor, uv + vec2(0.0, t.y)).r;
	sum += texture2D(s_texColor, uv + vec2(t.x, t.y)).r;
	float lit = step(1.5, sum) * step(0.01, center);
	lit = mix(lit, 1.0 - lit, u_edge.x);
	gl_FragColor = vec4(vec3(lit), 1.0);
}

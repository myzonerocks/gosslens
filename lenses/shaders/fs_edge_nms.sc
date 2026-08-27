$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_edge;
uniform vec4 u_edgeTexel;

// Canny non-maximum suppression: the sobel stage packed magnitude in .r and
// the snapped gradient direction in .gb. Sample the magnitude one texel each
// way along that direction and keep this pixel only where it is the local
// maximum, faded in over u_edge.x (low) to u_edge.y (high) thresholds.
void main()
{
	vec2 uv = v_texcoord0;
	vec3 cur = texture2D(s_texColor, uv).rgb;
	vec2 dir = ((cur.gb * 2.0) - 1.0) * u_edgeTexel.xy;
	float ahead = texture2D(s_texColor, uv + dir).r;
	float behind = texture2D(s_texColor, uv - dir).r;
	float keep = step(ahead, cur.r) * step(behind, cur.r);
	keep = keep * smoothstep(u_edge.x, u_edge.y, cur.r);
	gl_FragColor = vec4(vec3(keep), 1.0);
}

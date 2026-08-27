$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_edge;
uniform vec4 u_edgeTexel;

// Grayscale then a 3x3 Sobel over luma, one texel per tap (u_edgeTexel.xy).
// u_edge.x picks the output: 0 packs the edge magnitude as monochrome for
// the single-pass sobel (gain u_edge.y, invert u_edge.z), 1 packs magnitude
// plus a snapped gradient direction canny's suppression stage reads.
void main()
{
	vec2 uv = v_texcoord0;
	vec2 t = u_edgeTexel.xy;
	vec3 lw = vec3(0.2125, 0.7154, 0.0721);
	float tl = dot(texture2D(s_texColor, uv + vec2(-t.x, -t.y)).rgb, lw);
	float tc = dot(texture2D(s_texColor, uv + vec2(0.0, -t.y)).rgb, lw);
	float tr = dot(texture2D(s_texColor, uv + vec2(t.x, -t.y)).rgb, lw);
	float ml = dot(texture2D(s_texColor, uv + vec2(-t.x, 0.0)).rgb, lw);
	float mr = dot(texture2D(s_texColor, uv + vec2(t.x, 0.0)).rgb, lw);
	float bl = dot(texture2D(s_texColor, uv + vec2(-t.x, t.y)).rgb, lw);
	float bc = dot(texture2D(s_texColor, uv + vec2(0.0, t.y)).rgb, lw);
	float br = dot(texture2D(s_texColor, uv + vec2(t.x, t.y)).rgb, lw);
	float gh = -bl - 2.0 * ml - tl + br + 2.0 * mr + tr;
	float gv = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
	vec2 grad = vec2(gh, gv);
	float mag = length(grad);
	if (u_edge.x < 0.5) {
		float edge = clamp(mag * u_edge.y, 0.0, 1.0);
		edge = mix(edge, 1.0 - edge, u_edge.z);
		gl_FragColor = vec4(vec3(edge), 1.0);
	} else {
		// Snap the unit direction toward the nearest axis or diagonal, then
		// fold -1..1 into 0..1 so it survives an 8-bit target for suppression.
		vec2 dir = grad * inversesqrt(max(dot(grad, grad), 1e-8));
		dir = sign(dir) * floor(abs(dir) + 0.617316);
		dir = (dir + 1.0) * 0.5;
		gl_FragColor = vec4(mag, dir.x, dir.y, 1.0);
	}
}

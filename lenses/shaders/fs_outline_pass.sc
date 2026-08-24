$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_outline;

// A depth-edge outline pass: where the submitted depth jumps between
// neighboring pixels by more than u_outline.w, it draws u_outline's rgb
// over the frame, so silhouettes and creases get a toon outline. Flat
// depth leaves the frame untouched; with no depth the pass holds off.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float off = 0.006;
	float d = texture2D(s_texDepth, uv).r;
	float dl = texture2D(s_texDepth, uv + vec2(-off, 0.0)).r;
	float dr = texture2D(s_texDepth, uv + vec2(off, 0.0)).r;
	float du = texture2D(s_texDepth, uv + vec2(0.0, -off)).r;
	float dd = texture2D(s_texDepth, uv + vec2(0.0, off)).r;
	float edge = max(max(abs(d - dl), abs(d - dr)), max(abs(d - du), abs(d - dd)));
	float amount = step(u_outline.w, edge);
	gl_FragColor = vec4(mix(color.rgb, u_outline.xyz, amount), color.a);
}

$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_retouch; // mode, amount, unused, unused

// One color tap weighted by how close its luma is to the center's, so a wide
// average evens flat skin while a real edge (a lid, a brow) keeps its own tone.
// Returns the weighted color in rgb and the weight in w, summed by the caller.
vec4 skinTap(vec2 uv, float clum)
{
	vec3 s = texture2D(s_texColor, uv).rgb;
	float dl = dot(s, vec3(0.299, 0.587, 0.114)) - clum;
	float w = exp(-dl * dl * 48.0);
	return vec4(s * w, w);
}

// A selective skin retouch on unit 0 masked by unit 1. mode 0 (blemish) is a
// wider edge-aware average that evens small spots yet keeps texture and edges;
// mode 1 (shine) pulls pixels brighter than the local mean back toward it, a
// T-zone matte. amount and the mask scale it, so a zero mask leaves the frame.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float m = texture2D(s_texDepth, uv).r;
	float amount = m * u_retouch.y;
	vec3 lw = vec3(0.299, 0.587, 0.114);
	float off = 0.005;

	if (u_retouch.x < 0.5) {
		float clum = dot(color.rgb, lw);
		vec4 acc = vec4(color.rgb, 1.0);
		acc += skinTap(uv + vec2(off, 0.0), clum);
		acc += skinTap(uv + vec2(-off, 0.0), clum);
		acc += skinTap(uv + vec2(0.0, off), clum);
		acc += skinTap(uv + vec2(0.0, -off), clum);
		acc += skinTap(uv + vec2(off, off), clum);
		acc += skinTap(uv + vec2(-off, off), clum);
		acc += skinTap(uv + vec2(off, -off), clum);
		acc += skinTap(uv + vec2(-off, -off), clum);
		acc += skinTap(uv + vec2(2.0 * off, 0.0), clum);
		acc += skinTap(uv + vec2(-2.0 * off, 0.0), clum);
		acc += skinTap(uv + vec2(0.0, 2.0 * off), clum);
		acc += skinTap(uv + vec2(0.0, -2.0 * off), clum);
		vec3 evened = acc.rgb / acc.w;
		gl_FragColor = vec4(mix(color.rgb, evened, amount), color.a);
	} else {
		vec3 sum = color.rgb;
		sum += texture2D(s_texColor, uv + vec2(off, 0.0)).rgb;
		sum += texture2D(s_texColor, uv + vec2(-off, 0.0)).rgb;
		sum += texture2D(s_texColor, uv + vec2(0.0, off)).rgb;
		sum += texture2D(s_texColor, uv + vec2(0.0, -off)).rgb;
		sum += texture2D(s_texColor, uv + vec2(off, off)).rgb;
		sum += texture2D(s_texColor, uv + vec2(-off, off)).rgb;
		sum += texture2D(s_texColor, uv + vec2(off, -off)).rgb;
		sum += texture2D(s_texColor, uv + vec2(-off, -off)).rgb;
		vec3 mean = sum / 9.0;
		float lum = dot(color.rgb, lw);
		float mlum = dot(mean, lw);
		float excess = max(lum - mlum, 0.0);
		vec3 outc = color.rgb - vec3_splat(excess * amount);
		gl_FragColor = vec4(clamp(outc, 0.0, 1.0), color.a);
	}
}

$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);
uniform vec4 u_smooth;

// A masked skin-smoothing pass: averages a small cross of neighbors and
// blends the frame toward that average, scaled by the mask on unit 1 and
// u_smooth.x amount. Zero mask leaves the frame untouched, so retouch stays
// on the named region.
void main()
{
	vec2 uv = v_texcoord0;
	vec4 color = texture2D(s_texColor, uv);
	float m = texture2D(s_texDepth, uv).r;
	float off = 0.004;
	vec3 sum = color.rgb;
	sum += texture2D(s_texColor, uv + vec2(off, 0.0)).rgb;
	sum += texture2D(s_texColor, uv + vec2(-off, 0.0)).rgb;
	sum += texture2D(s_texColor, uv + vec2(0.0, off)).rgb;
	sum += texture2D(s_texColor, uv + vec2(0.0, -off)).rgb;
	vec3 avg = sum / 5.0;
	float amount = m * u_smooth.x;
	gl_FragColor = vec4(mix(color.rgb, avg, amount), color.a);
}

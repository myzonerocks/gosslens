$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_inpaint; // x radius (uv), y aspect (w/h), z,w unused

#define INPAINT_RAYS 16
#define INPAINT_STEPS 20

// An inpaint.pass node's content-aware fill: each pixel the mask marks (the
// removed object, blemish or passerby) is replaced by the color of the nearest
// unmasked boundary, gathered along rays cast outward and weighted by inverse
// distance, so the hole takes on the surrounding content. Unmasked pixels hold.
void main()
{
	vec3 color = texture2D(s_texColor, v_texcoord0).rgb;
	float m = texture2D(s_texMask, v_texcoord0).r;
	float radius = u_inpaint.x;
	float aspect = u_inpaint.y;
	vec3 acc = vec3_splat(0.0);
	float wsum = 0.0;
	for (int i = 0; i < INPAINT_RAYS; i++) {
		float ang = (float(i) / float(INPAINT_RAYS)) * 6.28318530718;
		vec2 dir = vec2(cos(ang), sin(ang) * aspect);
		float found = 0.0;
		for (int s = 1; s <= INPAINT_STEPS; s++) {
			float t = (float(s) / float(INPAINT_STEPS)) * radius;
			vec2 suv = v_texcoord0 + dir * t;
			float mv = texture2D(s_texMask, suv).r;
			if (found < 0.5 && mv < 0.5) {
				float w = 1.0 / t;
				acc += texture2D(s_texColor, suv).rgb * w;
				wsum += w;
				found = 1.0;
			}
		}
	}
	vec3 filled = wsum > 0.0 ? acc / wsum : color;
	gl_FragColor = vec4(mix(color, filled, step(0.5, m)), 1.0);
}

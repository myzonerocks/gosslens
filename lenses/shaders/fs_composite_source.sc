$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 2);
uniform vec4 u_composite; // opacity, key mode, similarity, softness
uniform vec4 u_chroma;    // key rgb, unused

// One source composited over the frame below it. Key mode 0 is a flat opacity
// fade; 1 cuts alpha from the source's own alpha channel (the matte a guest
// supplies); 2 chroma-keys against u_chroma by color distance; 3 keys by a
// separate per-source mask (s_texMask), so an opaque source is cut to a matte
// without touching its own alpha. Straight-alpha out; the caller blends it.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	float a = u_composite.x;
	float mode = u_composite.y;
	if (mode > 2.5) {
		a *= texture2D(s_texMask, v_texcoord0).r;
	} else if (mode > 1.5) {
		float d = distance(color.rgb, u_chroma.rgb);
		a *= smoothstep(u_composite.z, u_composite.z + u_composite.w, d);
		// Despill: pull the key-hue excess above the pixel's neutral gray back
		// off, so green/blue-screen spill on the kept subject is removed.
		vec3 kdir = normalize(u_chroma.rgb + vec3(0.0001, 0.0001, 0.0001));
		float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
		float excess = max(0.0, dot(color.rgb, kdir) - dot(vec3(luma, luma, luma), kdir));
		color.rgb = color.rgb - kdir * excess;
	} else if (mode > 0.5) {
		a *= color.a;
	}
	gl_FragColor = vec4(color.rgb, a);
}

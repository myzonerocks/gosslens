$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_composite; // opacity, key mode, similarity, softness
uniform vec4 u_chroma;    // key rgb, unused

// One source composited over the frame below it. Key mode 0 is a flat opacity
// fade; 1 cuts alpha from the source's own alpha channel (the matte a guest
// supplies); 2 chroma-keys against u_chroma by color distance. Straight-alpha
// out, so the caller blends it over the target.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	float a = u_composite.x;
	float mode = u_composite.y;
	if (mode > 1.5) {
		float d = distance(color.rgb, u_chroma.rgb);
		a *= smoothstep(u_composite.z, u_composite.z + u_composite.w, d);
	} else if (mode > 0.5) {
		a *= color.a;
	}
	gl_FragColor = vec4(color.rgb, a);
}

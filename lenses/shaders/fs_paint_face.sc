$input v_backgroundUv, v_makeupUv

#include <bgfx_shader.sh>

SAMPLER2D(s_texBackground, 0);
SAMPLER2D(s_texMakeup, 1);
SAMPLER2D(s_texMask, 2);
uniform vec4 u_paintParams; // x: opacity, y: blend mode

// paint.face lays the lens texture onto the tracked face through the face
// mesh UVs, keyed to a mask channel sampled at the screen position each
// triangle draws over. mode 0 lays it straight over the skin, 1 multiplies
// ink into it for a tattoo, 2 screens it for a lightening projection.
void main()
{
	vec4 paint = texture2D(s_texMakeup, v_makeupUv);
	vec4 bg = texture2D(s_texBackground, v_backgroundUv);
	float region = texture2D(s_texMask, v_backgroundUv).x;
	float coverage = paint.a * u_paintParams.x * region;
	vec3 folded = paint.rgb;
	if (u_paintParams.y > 1.5)
	{
		folded = 1.0 - (1.0 - bg.rgb) * (1.0 - paint.rgb);
	}
	else if (u_paintParams.y > 0.5)
	{
		folded = bg.rgb * paint.rgb;
	}
	vec3 outc = mix(bg.rgb, folded, coverage);
	gl_FragColor = vec4(outc, bg.a);
}

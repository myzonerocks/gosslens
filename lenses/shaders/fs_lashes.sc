$input v_backgroundUv, v_makeupUv

#include <bgfx_shader.sh>

SAMPLER2D(s_texBackground, 0);
uniform vec4 u_lashColor; // rgb tint, w opacity
uniform vec4 u_lashShape; // x strands across the strip, y edge softness

// mesh.lashes' own fragment stage: the strip's u splits into repeated
// strands, each narrowing to a point toward the tip (v near one) and
// fading at the very tip, alpha-blended over the frame in the tint so the
// lashes read as strands rising off the lid.
void main()
{
	vec4 bgColor = texture2D(s_texBackground, v_backgroundUv);
	float across = v_makeupUv.x;
	float along = v_makeupUv.y;
	float strand = fract(across * u_lashShape.x);
	float centerDist = abs(strand - 0.5) * 2.0;
	float taper = clamp(1.0 - along, 0.0, 1.0);
	float core = 1.0 - smoothstep(taper - u_lashShape.y, taper, centerDist);
	float tipFade = 1.0 - smoothstep(0.8, 1.0, along);
	float a = core * tipFade * u_lashColor.w;
	gl_FragColor = vec4(bgColor.rgb * (1.0 - a) + u_lashColor.rgb * a, 1.0);
}

$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_stylize;

// A single-pass artistic filter over the frame on unit 0. u_stylize.x picks
// the mode (0 sketch, 1 toon, 2 emboss, 3 crosshatch); .y is edge/emboss
// strength, .z the toon edge threshold, .w its colour quantization levels.
void main()
{
	vec2 uv = v_texcoord0;
	float mode = u_stylize.x;
	float strength = u_stylize.y;
	float threshold = u_stylize.z;
	float levels = u_stylize.w;
	vec4 base = texture2D(s_texColor, uv);
	vec3 lw = vec3(0.2125, 0.7154, 0.0721);

	if (mode < 2.5) {
		// Sketch, toon and emboss all read a 3x3 neighbourhood.
		float o = 0.003;
		vec3 tl = texture2D(s_texColor, uv + vec2(-o, -o)).rgb;
		vec3 tc = texture2D(s_texColor, uv + vec2(0.0, -o)).rgb;
		vec3 tr = texture2D(s_texColor, uv + vec2(o, -o)).rgb;
		vec3 ml = texture2D(s_texColor, uv + vec2(-o, 0.0)).rgb;
		vec3 mr = texture2D(s_texColor, uv + vec2(o, 0.0)).rgb;
		vec3 bl = texture2D(s_texColor, uv + vec2(-o, o)).rgb;
		vec3 bc = texture2D(s_texColor, uv + vec2(0.0, o)).rgb;
		vec3 br = texture2D(s_texColor, uv + vec2(o, o)).rgb;
		if (mode < 1.5) {
			// Sketch and toon share a Sobel magnitude over luma.
			float ltl = dot(tl, lw);
			float ltc = dot(tc, lw);
			float ltr = dot(tr, lw);
			float lml = dot(ml, lw);
			float lmr = dot(mr, lw);
			float lbl = dot(bl, lw);
			float lbc = dot(bc, lw);
			float lbr = dot(br, lw);
			float gx = -ltl - 2.0 * ltc - ltr + lbl + 2.0 * lbc + lbr;
			float gy = -lbl - 2.0 * lml - ltl + lbr + 2.0 * lmr + ltr;
			float mag = length(vec2(gx, gy));
			if (mode < 0.5) {
				// Sketch: pale paper darkened along edges, monochrome.
				float pencil = 1.0 - mag * strength;
				gl_FragColor = vec4(vec3(pencil), base.a);
			} else {
				// Toon: quantize the colour, knock edges to black.
				vec3 quant = (floor(base.rgb * levels) + 0.5) / levels;
				float edge = 1.0 - step(threshold, mag);
				gl_FragColor = vec4(quant * edge, base.a);
			}
		} else {
			// Emboss: a directional relief biased to mid-grey.
			vec3 relief = -2.0 * strength * tl - strength * tc - strength * ml + strength * mr + strength * bc + 2.0 * strength * br;
			gl_FragColor = vec4(relief + vec3(0.5), base.a);
		}
	} else {
		// Crosshatch: black diagonal strokes layered by darkness on white.
		float luma = dot(base.rgb, lw);
		float spacing = 0.03;
		float weight = 0.003 * strength;
		vec3 ink = vec3(1.0);
		if (luma < 1.00) {
			if (mod(uv.x + uv.y, spacing) <= weight) ink = vec3(0.0);
		}
		if (luma < 0.75) {
			if (mod(uv.x - uv.y, spacing) <= weight) ink = vec3(0.0);
		}
		if (luma < 0.50) {
			if (mod(uv.x + uv.y - spacing * 0.5, spacing) <= weight) ink = vec3(0.0);
		}
		if (luma < 0.30) {
			if (mod(uv.x - uv.y - spacing * 0.5, spacing) <= weight) ink = vec3(0.0);
		}
		gl_FragColor = vec4(ink, base.a);
	}
}

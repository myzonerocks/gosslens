$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_grade[3];

// A grade.pass node's color adjustment: tone (exposure, brightness,
// contrast), white balance (temperature, tint), then hue, saturation,
// grayscale, posterize and invert applied in that order. Every term
// defaults to the identity, so an empty grade leaves the frame untouched.
// u_grade[2].z gates a masked grade: on, the graded result blends over the
// original only inside the named channel; off, the whole frame is graded.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	vec3 orig = color.rgb;
	vec3 rgb = color.rgb;

	float exposure = u_grade[0].x;
	float contrast = u_grade[0].y;
	float saturation = u_grade[0].z;
	float temperature = u_grade[0].w;
	float brightness = u_grade[1].x;
	float hueRad = u_grade[1].y;
	float tint = u_grade[1].z;
	float grayscale = u_grade[1].w;
	float invertAmount = u_grade[2].x;
	float levels = u_grade[2].y;

	rgb *= exp2(exposure);
	rgb += vec3_splat(brightness);
	rgb = (rgb - 0.5) * contrast + 0.5;
	rgb += vec3(temperature, 0.0, -temperature);
	rgb += vec3(tint, -tint, tint);
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	rgb = mix(vec3_splat(luma), rgb, saturation);

	// Hue rotates the IQ chroma plane by hueRad, guarded so the default
	// zero angle is a bit-exact no-op rather than a YIQ round trip.
	if (hueRad != 0.0) {
		vec4 c4 = vec4(rgb, 0.0);
		float yp = dot(c4, vec4(0.299, 0.587, 0.114, 0.0));
		float ci = dot(c4, vec4(0.595716, -0.274453, -0.321263, 0.0));
		float cq = dot(c4, vec4(0.211456, -0.522591, 0.31135, 0.0));
		float ca = cos(hueRad);
		float sa = sin(hueRad);
		float ni = ci * ca + cq * sa;
		float nq = cq * ca - ci * sa;
		vec4 yiq = vec4(yp, ni, nq, 0.0);
		rgb = vec3(dot(yiq, vec4(1.0, 0.9563, 0.621, 0.0)),
		           dot(yiq, vec4(1.0, -0.2721, -0.6474, 0.0)),
		           dot(yiq, vec4(1.0, -1.107, 1.7046, 0.0)));
	}

	rgb = mix(rgb, vec3_splat(dot(rgb, vec3(0.2125, 0.7154, 0.0721))), grayscale);

	if (levels >= 1.0) {
		rgb = floor(rgb * levels + 0.5) / levels;
	}

	rgb = mix(rgb, vec3_splat(1.0) - rgb, invertAmount);

	// A masked grade keeps the original outside the channel; unmasked grades all.
	if (u_grade[2].z > 0.5) {
		float m = texture2D(s_texMask, v_texcoord0).r;
		rgb = mix(orig, rgb, m);
	}

	// u_grade[2].w is the HDR flag: 0 clamps to the display range as always,
	// 1 keeps values past 1.0 so a bright pass survives an HDR (half-float)
	// intermediate target and only the final present clamps.
	gl_FragColor = vec4(mix(clamp(rgb, 0.0, 1.0), rgb, u_grade[2].w), color.a);
}

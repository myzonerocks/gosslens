$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_warp;        // mode, center.x, center.y, radius
uniform vec4 u_warpParams;  // strength, refractive index, aspect, unused

// One geometric distortion over the frame on unit 0, radial around a center
// within a radius. u_warp.x picks the mode: 0 glass_sphere, 1 sphere_refraction,
// 2 bulge, 3 pinch, 4 swirl. Beyond the radius the frame passes through, or for
// sphere_refraction goes black.
void main()
{
	float mode = u_warp.x;
	vec2 cen = u_warp.yz;
	float rad = u_warp.w;
	float amount = u_warpParams.x;
	float idx = u_warpParams.y;
	float aspect = u_warpParams.z;

	vec2 uv = v_texcoord0;
	vec4 base = texture2D(s_texColor, uv);

	// Reshape y by the frame aspect so the region is a circle on screen, the
	// way gpupixel's sphere filters correct textureCoordinate.y.
	vec2 tc = vec2(uv.x, uv.y * aspect + 0.5 - 0.5 * aspect);
	float dist = distance(cen, tc);
	float presence = step(dist, rad);

	if (mode < 1.5) {
		// Build the sphere surface normal at this point and refract the view
		// ray through it, exactly as gpupixel does.
		float dn = dist / rad;
		float zdepth = rad * sqrt(max(1.0 - dn * dn, 0.0));
		vec3 nrm = normalize(vec3(tc - cen, zdepth));
		if (mode < 0.5) {
			// glass_sphere: doubled and negated refraction, sampled recentred
			// on the lens, plus gpupixel's grazing-angle rim light. The
			// surround passes through so the lens reads as glass over the scene.
			vec3 refr = 2.0 * refract(vec3(0.0, 0.0, -1.0), nrm, idx);
			refr.xy = -refr.xy;
			vec3 col = texture2D(s_texColor, (refr.xy + 1.0) * 0.5 + cen - vec2(0.5, 0.5)).rgb;
			vec3 ambient = vec3(0.0, 0.0, 1.0);
			float lit = 2.5 * (1.0 - pow(clamp(dot(ambient, nrm), 0.0, 1.0), 0.25));
			col += lit;
			vec3 outc = mix(base.rgb, col, amount * presence);
			gl_FragColor = vec4(outc, base.a);
		} else {
			// sphere_refraction: the raw refraction sampled from screen center,
			// the classic crystal ball, with everything outside the sphere black.
			vec3 refr = refract(vec3(0.0, 0.0, -1.0), nrm, idx);
			vec3 col = texture2D(s_texColor, (refr.xy + 1.0) * 0.5).rgb;
			vec3 inside = mix(base.rgb, col, amount);
			gl_FragColor = vec4(inside * presence, base.a);
		}
	} else {
		// Radial UV displacement inside the region, identity outside. pct is 1
		// at the center and eases to 0 at the rim.
		float pct = (rad - dist) / rad;
		vec2 warpuv = uv;
		if (mode < 2.5) {
			// bulge: shrink the sampling offset toward the center to magnify.
			float sc = 1.0 - pct * amount * 0.5;
			warpuv = (uv - cen) * (sc * sc) + cen;
		} else if (mode < 3.5) {
			// pinch: grow the offset to pull the image in toward the center.
			float sc = 1.0 + pct * amount * 0.5;
			warpuv = (uv - cen) * sc + cen;
		} else {
			// swirl: rotate about the center by an angle that grows inward.
			float theta = pct * pct * amount * 3.14159265;
			float sn = sin(theta);
			float cs = cos(theta);
			vec2 d = uv - cen;
			warpuv = vec2(dot(d, vec2(cs, -sn)), dot(d, vec2(sn, cs))) + cen;
		}
		vec2 finaluv = mix(uv, warpuv, presence);
		gl_FragColor = texture2D(s_texColor, finaluv);
	}
}

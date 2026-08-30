$input v_texcoord0

#include <bgfx_shader.sh>

#define WARP_POINTS 8

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texDepth, 1);   // confine mask: 1 warps the pixel, 0 leaves it put
uniform vec4 u_warp;        // mode, center.x, center.y, radius
uniform vec4 u_warpParams;  // strength, refractive index, aspect, unused
uniform vec4 u_warpExtra;   // point count, symmetry, symmetry axis x, unused
uniform vec4 u_warpPoints[WARP_POINTS]; // liquify points: px, py, dx, dy
uniform vec4 u_warpFall[WARP_POINTS];   // liquify falloff radius in x

// The displaced sample coord for one point p in the radial bulge, pinch and
// swirl modes. Recomputed per point so the symmetric side can mirror it.
vec2 radialWarpUv(vec2 p, float mode, vec2 cen, float rad, float amount, float aspect)
{
	vec2 tc = vec2(p.x, p.y * aspect + 0.5 - 0.5 * aspect);
	float dist = distance(cen, tc);
	float pct = (rad - dist) / rad;
	vec2 warpuv = p;
	if (mode < 2.5) {
		float sc = 1.0 - pct * amount * 0.5;
		warpuv = (p - cen) * (sc * sc) + cen;
	} else if (mode < 3.5) {
		float sc = 1.0 + pct * amount * 0.5;
		warpuv = (p - cen) * sc + cen;
	} else {
		float theta = pct * pct * amount * 3.14159265;
		float sn = sin(theta);
		float cs = cos(theta);
		vec2 d = p - cen;
		warpuv = vec2(dot(d, vec2(cs, -sn)), dot(d, vec2(sn, cs))) + cen;
	}
	return warpuv;
}

// Freeform liquify: the summed push/pull at point p from every active point,
// each pulling p along its direction with a smooth falloff to its radius.
// Inactive slots carry a zero push, so they add nothing.
vec2 liquifyDisp(vec2 p, float aspect)
{
	vec2 tp = vec2(p.x, p.y * aspect + 0.5 - 0.5 * aspect);
	vec2 acc = vec2(0.0, 0.0);
	for (int i = 0; i < WARP_POINTS; i++) {
		vec4 pt = u_warpPoints[i];
		float fr = max(u_warpFall[i].x, 0.000001);
		vec2 pc = vec2(pt.x, pt.y * aspect + 0.5 - 0.5 * aspect);
		float t = clamp(distance(tp, pc) / fr, 0.0, 1.0);
		float w = 1.0 - t * t * (3.0 - 2.0 * t);
		acc += pt.zw * w;
	}
	return acc * u_warpParams.x;
}

// One geometric distortion over the frame on unit 0, radial around a center
// within a radius. u_warp.x picks the mode: 0 glass_sphere, 1 sphere_refraction,
// 2 bulge, 3 pinch, 4 swirl, 5 liquify. u_warpExtra can mirror the displacement.
// The mask on unit 1 confines it: 1 warps, 0 leaves the pixel identity.
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
	// The confine mask. A full mask (1) leaves every path identity to the
	// unmasked warp; below 1 it eases the displacement toward none.
	float gate = texture2D(s_texDepth, uv).r;

	if (mode > 6.5) {
		// roll_lock: counter-rotate the frame about the center to level the
		// horizon. u_warpParams.x carries the signed angle the engine derived
		// from the device roll; the y term is aspect-corrected so the turn is
		// round on screen and the sample stays in gamut by clamping.
		float ca = cos(amount);
		float sa = sin(amount);
		vec2 d = uv - cen;
		d.y *= aspect;
		vec2 rd = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
		rd.y /= aspect;
		vec2 srcuv = cen + rd;
		if (gate < 1.0) srcuv = mix(uv, srcuv, gate);
		gl_FragColor = texture2D(s_texColor, clamp(srcuv, 0.0, 1.0));
		return;
	}

	if (mode > 5.5) {
		// face_scale: scale the frame about the face center within its radius.
		// A positive amount enlarges the face, negative shrinks it; the region
		// eases to identity by the rim and the mask on unit 1 gates it further.
		float du = distance(vec2(uv.x, uv.y * aspect), vec2(cen.x, cen.y * aspect)) / rad;
		float ease = clamp(1.0 - du * du, 0.0, 1.0);
		float k = clamp(1.0 - amount * ease, 0.05, 4.0);
		vec2 srcuv = cen + (uv - cen) * k;
		if (gate < 1.0) srcuv = mix(uv, srcuv, gate);
		gl_FragColor = texture2D(s_texColor, srcuv);
		return;
	}

	if (mode > 4.5) {
		// liquify: sum the multi-point push, optionally mirrored, then
		// sample where the pushed content comes from.
		vec2 disp = liquifyDisp(uv, aspect);
		if (u_warpExtra.y > 0.5) {
			float ax = u_warpExtra.z;
			vec2 dm = liquifyDisp(vec2(2.0 * ax - uv.x, uv.y), aspect);
			disp += vec2(-dm.x, dm.y);
		}
		vec2 srcuv = uv - disp;
		if (gate < 1.0) srcuv = mix(uv, srcuv, gate);
		gl_FragColor = texture2D(s_texColor, srcuv);
		return;
	}

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
			float glassAmt = amount * presence;
			if (gate < 1.0) glassAmt *= gate;
			vec3 outc = mix(base.rgb, col, glassAmt);
			gl_FragColor = vec4(outc, base.a);
		} else {
			// sphere_refraction: the raw refraction sampled from screen center,
			// the classic crystal ball, with everything outside the sphere black.
			vec3 refr = refract(vec3(0.0, 0.0, -1.0), nrm, idx);
			vec3 col = texture2D(s_texColor, (refr.xy + 1.0) * 0.5).rgb;
			vec3 inside = mix(base.rgb, col, amount);
			vec3 outc = inside * presence;
			if (gate < 1.0) outc = mix(base.rgb, outc, gate);
			gl_FragColor = vec4(outc, base.a);
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
		if (u_warpExtra.y > 0.5) {
			// symmetry: add the same warp taken across the mirror axis, so an
			// off-center reshape reappears on the opposite side.
			float ax = u_warpExtra.z;
			vec2 uvm = vec2(2.0 * ax - uv.x, uv.y);
			vec2 tcm = vec2(uvm.x, uvm.y * aspect + 0.5 - 0.5 * aspect);
			float presm = step(distance(cen, tcm), rad);
			vec2 dispm = (radialWarpUv(uvm, mode, cen, rad, amount, aspect) - uvm) * presm;
			finaluv += vec2(-dispm.x, dispm.y);
		}
		if (gate < 1.0) finaluv = mix(uv, finaluv, gate);
		gl_FragColor = texture2D(s_texColor, finaluv);
	}
}

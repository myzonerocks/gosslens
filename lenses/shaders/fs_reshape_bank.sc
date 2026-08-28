$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_reshapeParams;   // x aspect ratio, y presence, z falloff softness
uniform vec4 u_facePoints[53];  // 106 tracked contour points, two per vec4
uniform vec4 u_reshapeBank[17]; // 66 per-region sculpt amounts, four per vec4
uniform vec4 u_reshapeHubs;     // forehead center xy, nose-bridge midpoint zw

// pushRegion slides samples near a center along a direction, faded to zero at
// its radius so a sculpt stays anchored to one region. scaleRegion enlarges or
// shrinks around a center the way enlargeEye does. Both divide y by the frame
// aspect so each falloff region reads as a circle on screen.
vec2 pushRegion(vec2 coord, vec2 center, vec2 dir, float amt, float rad, float aspect)
{
	float d = distance(vec2(coord.x, coord.y / aspect), vec2(center.x, center.y / aspect)) / rad;
	float w = clamp(1.0 - d, 0.0, 1.0);
	return coord - dir * amt * w;
}

vec2 scaleRegion(vec2 coord, vec2 center, float rad, float amt, float aspect)
{
	float w = distance(vec2(coord.x, coord.y / aspect), vec2(center.x, center.y / aspect)) / rad;
	w = 1.0 - (1.0 - w * w) * amt;
	w = clamp(w, 0.0, 1.0);
	return center + (coord - center) * w;
}

// Pulls an anchor toward a target (positive amt) or away from it (negative),
// with an explicit radius rather than the origin-to-target coupling curveWarp
// uses, so a local slim never reaches across the face.
vec2 pullTo(vec2 coord, vec2 anchor, vec2 target, float amt, float rad, float aspect)
{
	vec2 dir = anchor - target;
	float len = max(length(dir), 1e-4);
	dir = dir / len * (rad * 0.5);
	return pushRegion(coord, anchor, dir, amt, rad, aspect);
}

void main()
{
	float aspect = u_reshapeParams.x;

	// Region anchors from the tracked contour and the two derived hubs.
	vec2 chin = u_facePoints[8].xy;
	vec2 noseTip = u_facePoints[23].xy;
	vec2 browGap = u_facePoints[21].zw;
	vec2 noseMid = u_facePoints[22].zw;
	vec2 noseUpper = u_facePoints[22].xy;
	vec2 leftNostril = u_facePoints[23].zw;
	vec2 rightNostril = u_facePoints[25].zw;
	vec2 philtrum = u_facePoints[24].zw;
	vec2 leftJaw = u_facePoints[3].zw;
	vec2 rightJaw = u_facePoints[12].zw;
	vec2 leftJawLow = u_facePoints[7].xy;
	vec2 rightJawLow = u_facePoints[9].xy;
	vec2 leftJawMid = u_facePoints[5].xy;
	vec2 rightJawMid = u_facePoints[11].xy;
	vec2 leftEye = u_facePoints[37].xy;
	vec2 leftEyeOuter = u_facePoints[36].xy;
	vec2 rightEye = u_facePoints[38].zw;
	vec2 rightEyeOuter = u_facePoints[37].zw;
	vec2 leftEyeInner = u_facePoints[39].xy;
	vec2 rightEyeInner = u_facePoints[39].zw;
	vec2 leftBrow = u_facePoints[17].zw;
	vec2 leftBrowInner = u_facePoints[18].zw;
	vec2 leftBrowOuter = u_facePoints[16].zw;
	vec2 rightBrow = u_facePoints[20].xy;
	vec2 rightBrowInner = u_facePoints[19].xy;
	vec2 rightBrowOuter = u_facePoints[21].xy;
	vec2 leftCheek = u_facePoints[41].xy;
	vec2 rightCheek = u_facePoints[41].zw;
	vec2 leftCheekbone = u_facePoints[2].xy;
	vec2 rightCheekbone = u_facePoints[14].xy;
	vec2 upperLip = u_facePoints[43].zw;
	vec2 lowerLip = u_facePoints[51].xy;
	vec2 leftMouth = u_facePoints[42].xy;
	vec2 rightMouth = u_facePoints[45].xy;
	vec2 forehead = u_reshapeHubs.xy;
	vec2 bridge = u_reshapeHubs.zw;
	vec2 lipCenter = (upperLip + lowerLip) * 0.5;

	// A face frame: axisY runs down the nose, axisX is its perpendicular, and
	// faceH scales every region radius and push so the sculpt tracks head size.
	vec2 down = chin - browGap;
	float faceH = max(length(down), 1e-4);
	vec2 axisY = down / faceH;
	vec2 axisX = vec2(axisY.y, -axisY.x);
	vec2 faceMid = (browGap + chin) * 0.5;
	vec2 pX = axisX * (faceH * 0.12);
	vec2 pY = axisY * (faceH * 0.12);

	float noseRad = faceH * 0.22;
	float jawRad = faceH * 0.30;
	float chinRad = faceH * 0.22;
	float lipRad = faceH * 0.18;
	float cheekRad = faceH * 0.28;
	float browRad = faceH * 0.22;
	float eyeRad = faceH * 0.20;
	float foreRad = faceH * 0.32;
	float faceRad = faceH * 1.0;

	vec2 uv = v_texcoord0;

	// Global face banks first, broad radius, so per-feature banks layer on top.
	uv = pullTo(uv, leftJawMid, faceMid, u_reshapeBank[14].z, faceRad, aspect);
	uv = pullTo(uv, rightJawMid, faceMid, u_reshapeBank[14].z, faceRad, aspect);
	uv = pushRegion(uv, leftCheek, pX, u_reshapeBank[14].w, faceRad, aspect);
	uv = pushRegion(uv, rightCheek, -pX, u_reshapeBank[14].w, faceRad, aspect);
	uv = pushRegion(uv, forehead, -pY, u_reshapeBank[15].x, faceRad, aspect);
	uv = pushRegion(uv, chin, pY, u_reshapeBank[15].x, faceRad, aspect);
	uv = pullTo(uv, leftJawLow, chin, u_reshapeBank[15].y, jawRad, aspect);
	uv = pullTo(uv, rightJawLow, chin, u_reshapeBank[15].y, jawRad, aspect);
	uv = pushRegion(uv, leftBrowOuter, pX, u_reshapeBank[15].z, foreRad, aspect);
	uv = pushRegion(uv, rightBrowOuter, -pX, u_reshapeBank[15].z, foreRad, aspect);
	uv = scaleRegion(uv, faceMid, faceRad, u_reshapeBank[15].w * 0.4, aspect);
	uv = pullTo(uv, leftJawMid, faceMid, u_reshapeBank[16].x * 0.5, faceRad, aspect);
	uv = pullTo(uv, rightJawMid, faceMid, u_reshapeBank[16].x * 0.5, faceRad, aspect);
	uv = scaleRegion(uv, faceMid, faceRad, u_reshapeBank[16].y * 0.3, aspect);

	// Nose.
	uv = pushRegion(uv, leftNostril, pX * 0.8, u_reshapeBank[0].x, noseRad * 0.7, aspect);
	uv = pushRegion(uv, rightNostril, -pX * 0.8, u_reshapeBank[0].x, noseRad * 0.7, aspect);
	uv = pushRegion(uv, bridge, pX, u_reshapeBank[0].y, noseRad, aspect);
	uv = pushRegion(uv, bridge, -pY, u_reshapeBank[0].z, noseRad, aspect);
	uv = scaleRegion(uv, noseTip, noseRad * 0.7, u_reshapeBank[0].w * 0.5, aspect);
	uv = pushRegion(uv, noseTip, -pY, u_reshapeBank[1].x, noseRad * 0.8, aspect);
	uv = pullTo(uv, noseTip, bridge, u_reshapeBank[1].y, noseRad, aspect);
	uv = scaleRegion(uv, leftNostril, noseRad * 0.5, u_reshapeBank[1].z * 0.5, aspect);
	uv = scaleRegion(uv, rightNostril, noseRad * 0.5, u_reshapeBank[1].z * 0.5, aspect);
	uv = scaleRegion(uv, noseMid, noseRad, u_reshapeBank[1].w * 0.5, aspect);

	// Jaw.
	uv = pushRegion(uv, leftJawMid, pX, u_reshapeBank[2].x, jawRad, aspect);
	uv = pushRegion(uv, rightJawMid, -pX, u_reshapeBank[2].x, jawRad, aspect);
	uv = pullTo(uv, leftJawMid, faceMid, u_reshapeBank[2].y, jawRad, aspect);
	uv = pullTo(uv, rightJawMid, faceMid, u_reshapeBank[2].y, jawRad, aspect);
	uv = pushRegion(uv, leftJawMid, pX, u_reshapeBank[2].z, jawRad, aspect);
	uv = pushRegion(uv, rightJawMid, -pX, u_reshapeBank[2].w, jawRad, aspect);
	uv = pushRegion(uv, leftJaw, pY, u_reshapeBank[3].x, jawRad, aspect);
	uv = pushRegion(uv, rightJaw, pY, u_reshapeBank[3].x, jawRad, aspect);
	uv = pushRegion(uv, leftJawLow, pY, u_reshapeBank[3].y, jawRad, aspect);
	uv = pushRegion(uv, rightJawLow, pY, u_reshapeBank[3].y, jawRad, aspect);
	uv = pullTo(uv, leftJawLow, chin, u_reshapeBank[3].z, jawRad, aspect);
	uv = pullTo(uv, rightJawLow, chin, u_reshapeBank[3].z, jawRad, aspect);

	// Chin.
	uv = pushRegion(uv, chin, pY, u_reshapeBank[3].w, chinRad, aspect);
	uv = pushRegion(uv, chin, pX, u_reshapeBank[4].x, chinRad, aspect);
	uv = pullTo(uv, chin, faceMid, u_reshapeBank[4].y, chinRad, aspect);
	uv = pushRegion(uv, chin, -pY, u_reshapeBank[4].z, chinRad, aspect);
	uv = pushRegion(uv, chin, pY * 0.5, u_reshapeBank[4].w, chinRad, aspect);
	uv = scaleRegion(uv, chin, chinRad, u_reshapeBank[5].x * 0.5, aspect);

	// Lip.
	uv = scaleRegion(uv, lipCenter, lipRad, u_reshapeBank[5].y * 0.5, aspect);
	uv = pushRegion(uv, leftMouth, pX, u_reshapeBank[5].z, lipRad, aspect);
	uv = pushRegion(uv, rightMouth, -pX, u_reshapeBank[5].z, lipRad, aspect);
	uv = pushRegion(uv, upperLip, -pY * 0.5, u_reshapeBank[5].w, lipRad, aspect);
	uv = pushRegion(uv, lowerLip, pY * 0.5, u_reshapeBank[5].w, lipRad, aspect);
	uv = scaleRegion(uv, upperLip, lipRad * 0.7, u_reshapeBank[6].x * 0.4, aspect);
	uv = scaleRegion(uv, lowerLip, lipRad * 0.7, u_reshapeBank[6].y * 0.4, aspect);
	uv = pushRegion(uv, lipCenter, pY, u_reshapeBank[6].z, lipRad, aspect);
	uv = pushRegion(uv, leftMouth, -pY, u_reshapeBank[6].w, lipRad, aspect);
	uv = pushRegion(uv, rightMouth, -pY, u_reshapeBank[6].w, lipRad, aspect);
	uv = pushRegion(uv, upperLip, -pY, u_reshapeBank[7].x * 0.5, lipRad * 0.6, aspect);
	uv = pushRegion(uv, philtrum, pY, u_reshapeBank[7].y, lipRad, aspect);

	// Cheek.
	uv = scaleRegion(uv, leftCheek, cheekRad, u_reshapeBank[7].z * 0.5, aspect);
	uv = scaleRegion(uv, rightCheek, cheekRad, u_reshapeBank[7].w * 0.5, aspect);
	uv = pullTo(uv, leftCheek, faceMid, u_reshapeBank[8].x, cheekRad, aspect);
	uv = pullTo(uv, rightCheek, faceMid, u_reshapeBank[8].y, cheekRad, aspect);
	uv = pushRegion(uv, leftCheekbone, -pY, u_reshapeBank[8].z, cheekRad, aspect);
	uv = pushRegion(uv, rightCheekbone, -pY, u_reshapeBank[8].z, cheekRad, aspect);
	uv = pushRegion(uv, leftCheekbone, pX, u_reshapeBank[8].w, cheekRad, aspect);
	uv = pushRegion(uv, rightCheekbone, -pX, u_reshapeBank[8].w, cheekRad, aspect);
	uv = pullTo(uv, leftJawMid, faceMid, u_reshapeBank[9].x, cheekRad, aspect);
	uv = pullTo(uv, rightJawMid, faceMid, u_reshapeBank[9].x, cheekRad, aspect);
	uv = scaleRegion(uv, leftCheek, cheekRad, u_reshapeBank[9].y * 0.4, aspect);
	uv = scaleRegion(uv, rightCheek, cheekRad, u_reshapeBank[9].y * 0.4, aspect);

	// Brow.
	uv = pushRegion(uv, leftBrow, -pY, u_reshapeBank[9].z, browRad, aspect);
	uv = pushRegion(uv, rightBrow, -pY, u_reshapeBank[9].w, browRad, aspect);
	uv = pushRegion(uv, leftBrowOuter, pY, u_reshapeBank[10].x, browRad, aspect);
	uv = pushRegion(uv, rightBrowOuter, -pY, u_reshapeBank[10].x, browRad, aspect);
	uv = scaleRegion(uv, leftBrow, browRad * 0.6, u_reshapeBank[10].y * 0.4, aspect);
	uv = scaleRegion(uv, rightBrow, browRad * 0.6, u_reshapeBank[10].y * 0.4, aspect);
	uv = pushRegion(uv, leftBrowInner, pX, u_reshapeBank[10].z, browRad, aspect);
	uv = pushRegion(uv, rightBrowInner, -pX, u_reshapeBank[10].z, browRad, aspect);
	uv = pushRegion(uv, leftBrow, -pY, u_reshapeBank[10].w * 0.7, browRad * 0.6, aspect);
	uv = pushRegion(uv, rightBrow, -pY, u_reshapeBank[10].w * 0.7, browRad * 0.6, aspect);

	// Forehead.
	uv = pushRegion(uv, forehead, -pY, u_reshapeBank[11].x, foreRad, aspect);
	uv = pushRegion(uv, forehead, pX, u_reshapeBank[11].y, foreRad, aspect);
	uv = scaleRegion(uv, forehead, foreRad, u_reshapeBank[11].z * 0.4, aspect);
	uv = scaleRegion(uv, forehead, foreRad, u_reshapeBank[11].w * 0.5, aspect);

	// Eye.
	uv = scaleRegion(uv, leftEye, eyeRad, u_reshapeBank[12].x * 0.6, aspect);
	uv = scaleRegion(uv, rightEye, eyeRad, u_reshapeBank[12].y * 0.6, aspect);
	uv = pushRegion(uv, leftEyeOuter, pX, u_reshapeBank[12].z, eyeRad, aspect);
	uv = pushRegion(uv, rightEyeOuter, -pX, u_reshapeBank[12].z, eyeRad, aspect);
	uv = pushRegion(uv, leftEye, -pY * 0.5, u_reshapeBank[12].w, eyeRad, aspect);
	uv = pushRegion(uv, rightEye, -pY * 0.5, u_reshapeBank[12].w, eyeRad, aspect);
	uv = pushRegion(uv, leftEye, pX, u_reshapeBank[13].x, eyeRad, aspect);
	uv = pushRegion(uv, rightEye, -pX, u_reshapeBank[13].x, eyeRad, aspect);
	uv = pushRegion(uv, leftEyeOuter, pY, u_reshapeBank[13].y, eyeRad, aspect);
	uv = pushRegion(uv, rightEyeOuter, pY, u_reshapeBank[13].y, eyeRad, aspect);
	uv = pushRegion(uv, leftEyeInner, pX, u_reshapeBank[13].z, eyeRad, aspect);
	uv = pushRegion(uv, rightEyeInner, -pX, u_reshapeBank[13].z, eyeRad, aspect);
	uv = pushRegion(uv, leftEyeOuter, -pX, u_reshapeBank[13].w, eyeRad, aspect);
	uv = pushRegion(uv, rightEyeOuter, pX, u_reshapeBank[13].w, eyeRad, aspect);
	uv = pushRegion(uv, leftEye, pY * 0.5, u_reshapeBank[14].x, eyeRad, aspect);
	uv = pushRegion(uv, rightEye, pY * 0.5, u_reshapeBank[14].x, eyeRad, aspect);
	uv = scaleRegion(uv, leftEye, eyeRad, u_reshapeBank[14].y * 0.4, aspect);
	uv = scaleRegion(uv, rightEye, eyeRad, u_reshapeBank[14].y * 0.4, aspect);

	gl_FragColor = texture2D(s_texColor, uv);
}

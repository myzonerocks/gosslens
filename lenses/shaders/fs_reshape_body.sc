$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_bodyParams;    // x aspect ratio
uniform vec4 u_bodyPoints[3]; // shoulderL/R, hipL/R, ankleMid, head - two per vec4
uniform vec4 u_bodyBank[3];   // eleven body sculpt amounts, four per vec4

// The x of the shoulder-to-hip axis line at height y, so a horizontal squeeze
// pulls toward the body's own centre line rather than the frame centre.
float axisXAt(float y, vec2 shoulderMid, vec2 hipMid)
{
	float span = hipMid.y - shoulderMid.y;
	float t = clamp((y - shoulderMid.y) / (abs(span) < 1e-4 ? 1e-4 : span), -1.0, 2.0);
	return shoulderMid.x + (hipMid.x - shoulderMid.x) * t;
}

// Pull x toward the axis within a vertical band of radius rad around centreY.
// amt > 0 slims (toward the axis), amt < 0 widens.
vec2 squeezeBand(vec2 coord, vec2 shoulderMid, vec2 hipMid, float centreY, float rad, float amt)
{
	float dy = abs(coord.y - centreY) / max(rad, 1e-4);
	float w = clamp(1.0 - dy, 0.0, 1.0);
	float ax = axisXAt(coord.y, shoulderMid, hipMid);
	return vec2(coord.x + (ax - coord.x) * amt * w * 0.6, coord.y);
}

// Lengthen (amt > 0) or shorten the part of the body below pivotY: the source y
// for an output row is pulled toward the pivot, so the region stretches.
vec2 stretchBelow(vec2 coord, float pivotY, float amt)
{
	if (coord.y > pivotY) {
		coord.y = pivotY + (coord.y - pivotY) / (1.0 + amt * 0.5);
	}
	return coord;
}

// Scale a circular region around a centre, dividing y by the aspect so the
// falloff reads round on screen.
vec2 scaleRegion(vec2 coord, vec2 center, float rad, float amt, float aspect)
{
	float w = distance(vec2(coord.x, coord.y / aspect), vec2(center.x, center.y / aspect)) / max(rad, 1e-4);
	w = 1.0 - (1.0 - w * w) * amt;
	w = clamp(w, 0.0, 1.0);
	return center + (coord - center) * w;
}

void main()
{
	float aspect = u_bodyParams.x;
	vec2 shoulderL = u_bodyPoints[0].xy;
	vec2 shoulderR = u_bodyPoints[0].zw;
	vec2 hipL = u_bodyPoints[1].xy;
	vec2 hipR = u_bodyPoints[1].zw;
	vec2 ankleMid = u_bodyPoints[2].xy;
	vec2 head = u_bodyPoints[2].zw;

	vec2 shoulderMid = (shoulderL + shoulderR) * 0.5;
	vec2 hipMid = (hipL + hipR) * 0.5;
	float torsoH = max(distance(shoulderMid, hipMid), 1e-4);
	float shoulderY = shoulderMid.y;
	float hipY = hipMid.y;
	float waistY = (shoulderY + hipY) * 0.5;
	float chestY = shoulderY + (hipY - shoulderY) * 0.3;
	float legY = hipY + (ankleMid.y - hipY) * 0.5;

	float height = u_bodyBank[0].x;
	float head_size = u_bodyBank[0].y;
	float neck_length = u_bodyBank[0].z;
	float shoulder_width = u_bodyBank[0].w;
	float chest_size = u_bodyBank[1].x;
	float torso_slim = u_bodyBank[1].y;
	float waist_slim = u_bodyBank[1].z;
	float hip_width = u_bodyBank[1].w;
	float arm_slim = u_bodyBank[2].x;
	float leg_length = u_bodyBank[2].y;
	float leg_slim = u_bodyBank[2].z;

	vec2 uv = v_texcoord0;

	// Horizontal sculpts, each pulling toward the body axis in its band.
	uv = squeezeBand(uv, shoulderMid, hipMid, waistY, torsoH * 0.8, torso_slim);
	uv = squeezeBand(uv, shoulderMid, hipMid, waistY, torsoH * 0.35, waist_slim);
	uv = squeezeBand(uv, shoulderMid, hipMid, hipY, torsoH * 0.4, -hip_width);
	uv = squeezeBand(uv, shoulderMid, hipMid, shoulderY, torsoH * 0.3, -shoulder_width);
	uv = squeezeBand(uv, shoulderMid, hipMid, chestY, torsoH * 0.3, -chest_size);
	uv = squeezeBand(uv, shoulderMid, hipMid, chestY, torsoH * 0.9, arm_slim);
	uv = squeezeBand(uv, shoulderMid, hipMid, legY, torsoH * 0.9, leg_slim);

	// Vertical sculpts: lengthen the legs below the hips, the whole body below
	// the shoulders, and the neck between the head and the shoulders.
	uv = stretchBelow(uv, hipY, leg_length);
	uv = stretchBelow(uv, shoulderY, height * 0.5);
	uv = stretchBelow(uv, head.y, neck_length * 0.4);
	uv = scaleRegion(uv, head, torsoH * 0.45, head_size * 0.4, aspect);

	// Only displace where the body mask says body, so the background stays put.
	float m = texture2D(s_texMask, v_texcoord0).r;
	uv = mix(v_texcoord0, uv, m);
	gl_FragColor = texture2D(s_texColor, uv);
}

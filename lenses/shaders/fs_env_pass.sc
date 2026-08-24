$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 1);
uniform vec4 u_envParams;
uniform vec4 u_envTop;
uniform vec4 u_envBottom;

// A procedural sky dome behind the segmented foreground: the sky shows where
// the mask reads background. The gradient shifts with the camera pitch in
// u_envParams.x and a sun glow slides with the yaw in .y, so it pans as the
// device turns; u_envParams.z scales the whole sky.
void main()
{
	vec2 uv = v_texcoord0;
	float h = clamp((1.0 - uv.y) + u_envParams.x, 0.0, 1.0);
	vec3 sky = mix(u_envBottom.xyz, u_envTop.xyz, h);
	float sun = smoothstep(0.16, 0.0, distance(vec2(fract(uv.x + u_envParams.y), uv.y), vec2(0.5, 0.28)));
	sky = clamp(sky + sun * 0.6, 0.0, 1.0) * u_envParams.z;
	vec4 frame = texture2D(s_texColor, uv);
	float mask = texture2D(s_texMask, uv).r;
	gl_FragColor = vec4(mix(sky, frame.rgb, mask), frame.a);
}

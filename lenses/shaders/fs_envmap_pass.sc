$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texBackground, 1);
SAMPLER2D(s_texMask, 2);
uniform vec4 u_envParams;
uniform vec4 u_envRot[3];

#define ENV_PI 3.14159265

// env.pass's image variant: each pixel's view ray, turned by the camera
// rotation in u_envRot, samples an equirect environment on unit 1 behind the
// masked foreground. u_envParams.x scales it, .y is the ray's aspect, so the
// environment pans as the device turns.
void main()
{
	vec2 uv = v_texcoord0;
	float t = 0.5773;
	vec3 ray = normalize(vec3((uv.x - 0.5) * 2.0 * t * u_envParams.y, (0.5 - uv.y) * 2.0 * t, -1.0));
	vec3 dir = vec3(dot(u_envRot[0].xyz, ray), dot(u_envRot[1].xyz, ray), dot(u_envRot[2].xyz, ray));
	float lon = atan2(dir.x, -dir.z) / (2.0 * ENV_PI) + 0.5;
	float lat = acos(clamp(dir.y, -1.0, 1.0)) / ENV_PI;
	vec3 env = texture2D(s_texBackground, vec2(lon, lat)).rgb * u_envParams.x;
	vec4 frame = texture2D(s_texColor, uv);
	float mask = texture2D(s_texMask, uv).r;
	gl_FragColor = vec4(mix(env, frame.rgb, mask), frame.a);
}

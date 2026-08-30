$input v_normal, v_texcoord0

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;
// A single directional light: u_light[0].xyz is the world direction it travels,
// u_light[0].w its intensity; u_light[1].rgb its color and u_light[1].w a flat
// ambient term so surfaces facing away are lifted off pure black.
uniform vec4 u_light[2];

void main()
{
	vec3 n = normalize(v_normal);
	vec3 l = normalize(-u_light[0].xyz);
	float ndl = max(dot(n, l), 0.0);
	vec3 shade = vec3_splat(u_light[1].w) + u_light[1].rgb * (u_light[0].w * ndl);
	gl_FragColor = vec4(u_modelColor.rgb * shade, u_modelColor.a);
}

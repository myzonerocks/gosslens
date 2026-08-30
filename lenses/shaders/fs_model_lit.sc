$input v_normal, v_worldpos, v_texcoord0

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;
// A single directional light: u_light[0].xyz is the world direction it travels,
// u_light[0].w its intensity; u_light[1].rgb its color and u_light[1].w a flat
// ambient term so surfaces facing away are lifted off pure black.
uniform vec4 u_light[2];
// The glTF material's PBR factors: u_material[0].rgb is the emissive color
// (self-illumination), u_material[0].w the metallic factor, u_material[1].x the
// roughness. Metallic scales a Blinn-Phong highlight whose tightness follows
// roughness and whose tint runs from white (dielectric) to the base color.
uniform vec4 u_material[2];

void main()
{
	vec3 n = normalize(v_normal);
	vec3 l = normalize(-u_light[0].xyz);
	float ndl = max(dot(n, l), 0.0);
	vec3 diffuse = u_modelColor.rgb * (vec3_splat(u_light[1].w) + u_light[1].rgb * (u_light[0].w * ndl));

	vec3 eye = mul(u_invView, vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 v = normalize(eye - v_worldpos);
	vec3 h = normalize(l + v);
	float ndh = max(dot(n, h), 0.0);
	float shininess = mix(8.0, 128.0, 1.0 - u_material[1].x);
	float spec = pow(ndh, shininess) * u_material[0].w * u_light[0].w * ndl;
	vec3 specColor = mix(vec3_splat(1.0), u_modelColor.rgb, u_material[0].w) * u_light[1].rgb;

	vec3 color = diffuse + specColor * spec + u_material[0].rgb;
	gl_FragColor = vec4(color, u_modelColor.a);
}

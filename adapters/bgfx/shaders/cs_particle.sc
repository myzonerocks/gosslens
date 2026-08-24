#include "bgfx_compute.sh"

// Particle state, three vec4 per particle: [pos.xyz, life], [vel.xyz, maxlife],
// [seed, -, -, -]. The compute shader integrates it in place, so the sim lives
// entirely on the GPU.
BUFFER_RW(state, vec4, 0);
// The billboards it draws: six vertices per particle, two vec4 each (pos.xyz +
// corner, then life fraction + seed + velocity xy) matching the CPU layout.
BUFFER_WO(billboards, vec4, 1);

// x: dt, y: gravity, z: particle count, w: 1 on the first frame to seed state.
uniform vec4 u_simParams;
// x: launch speed, y: lifetime.
uniform vec4 u_simParams2;

float hash01(float i) {
	float x = i * 0.6180339887;
	float s = sin(x * 127.1 + 311.7) * 43758.5453;
	return s - floor(s);
}

NUM_THREADS(64, 1, 1)
void main()
{
	uint i = gl_GlobalInvocationID.x;
	float count = u_simParams.z;
	if (float(i) >= count) {
		return;
	}
	float dt = u_simParams.x;
	float gravity = u_simParams.y;
	float speed = u_simParams2.x;
	float lifetime = u_simParams2.y;
	float init = u_simParams.w;

	vec4 s0 = state[i * 3u + 0u];
	vec4 s1 = state[i * 3u + 1u];
	vec4 s2 = state[i * 3u + 2u];
	vec3 pos = s0.xyz;
	float life = s0.w;
	vec3 vel = s1.xyz;
	float maxlife = s1.w;
	float seed = s2.x;

	if (init > 0.5) {
		life = 0.0; // force an emit below
	} else {
		life -= dt;
	}

	if (life <= 0.0) {
		// Fountain emit, matching the CPU emitOne with no spread.
		float t = float(i) / max(count, 1.0);
		float a = t * 6.2831853;
		seed = hash01(float(i));
		pos = vec3(0.0, 0.0, 0.0);
		vel = vec3(cos(a) * speed, speed * 1.5 + mod(float(i), 8.0) * 0.1, sin(a) * speed);
		life = lifetime;
		maxlife = lifetime;
	} else {
		vel.y -= gravity * dt;
		pos += vel * dt;
	}

	state[i * 3u + 0u] = vec4(pos, life);
	state[i * 3u + 1u] = vec4(vel, maxlife);
	state[i * 3u + 2u] = vec4(seed, 0.0, 0.0, 0.0);

	float frac = clamp(life / max(maxlife, 1e-6), 0.0, 1.0);
	for (uint k = 0u; k < 6u; k++) {
		float corner = (k == 1u) ? 1.0 : ((k == 2u || k == 4u) ? 2.0 : ((k == 5u) ? 3.0 : 0.0));
		uint b = (i * 6u + k) * 2u;
		billboards[b + 0u] = vec4(pos.x, pos.y, pos.z, corner);
		billboards[b + 1u] = vec4(frac, seed, vel.x, vel.y);
	}
}

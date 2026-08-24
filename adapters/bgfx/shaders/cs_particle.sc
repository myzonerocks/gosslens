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
// x: launch speed, y: lifetime, z: drag, w: turbulence.
uniform vec4 u_simParams2;
// xyz: wind, w: curl amplitude.
uniform vec4 u_simParams3;
// xyz: attract target, w: attract strength.
uniform vec4 u_simParams4;
// x: vortex amplitude.
uniform vec4 u_simParams5;

float hash01(float i) {
	float x = i * 0.6180339887;
	float s = sin(x * 127.1 + 311.7) * 43758.5453;
	return s - floor(s);
}

// A smooth vector potential; its curl (below) is divergence-free, so the field
// swirls and folds without sources or sinks - matching the CPU curl noise.
vec3 potential(vec3 p) {
	return vec3(
		sin(p.y * 1.7 + p.z * 1.3),
		sin(p.z * 1.9 + p.x * 1.1),
		sin(p.x * 1.5 + p.y * 2.1));
}

vec3 curlNoise(vec3 p) {
	float e = 0.15;
	vec3 px1 = potential(vec3(p.x + e, p.y, p.z));
	vec3 px0 = potential(vec3(p.x - e, p.y, p.z));
	vec3 py1 = potential(vec3(p.x, p.y + e, p.z));
	vec3 py0 = potential(vec3(p.x, p.y - e, p.z));
	vec3 pz1 = potential(vec3(p.x, p.y, p.z + e));
	vec3 pz0 = potential(vec3(p.x, p.y, p.z - e));
	float inv = 1.0 / (2.0 * e);
	return vec3(
		((py1.z - py0.z) - (pz1.y - pz0.y)) * inv,
		((pz1.x - pz0.x) - (px1.z - px0.z)) * inv,
		((px1.y - px0.y) - (py1.x - py0.x)) * inv);
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

	bool emitted = false;
	if (life <= 0.0) {
		// Fountain emit, matching the CPU emitOne with no spread.
		float t = float(i) / max(count, 1.0);
		float a = t * 6.2831853;
		seed = hash01(float(i));
		pos = vec3(0.0, 0.0, 0.0);
		vel = vec3(cos(a) * speed, speed * 1.5 + mod(float(i), 8.0) * 0.1, sin(a) * speed);
		life = lifetime;
		maxlife = lifetime;
		emitted = true;
		// On the first frame the CPU has already aged this constructor-emitted
		// particle by one step, so match that age here.
		if (init > 0.5) life -= dt;
	}
	// The CPU emits in its constructor and integrates every frame after, so a
	// mid-run respawn integrates on its next frame (not this one), but the
	// first frame - where init seeds this same emit - does integrate now. So
	// integrate unless we just respawned mid-run.
	if (!emitted || init > 0.5) {
		float drag = u_simParams2.z;
		float turbulence = u_simParams2.w;
		vec3 wind = u_simParams3.xyz;
		float curl = u_simParams3.w;
		vec3 attractTarget = u_simParams4.xyz;
		float attractStrength = u_simParams4.w;
		float vortex = u_simParams5.x;
		vel.y -= gravity * dt;
		if (drag > 0.0) {
			float damp = max(0.0, 1.0 - drag * dt);
			vel *= damp;
		}
		vel += wind * dt;
		if (turbulence > 0.0) {
			vel.x += sin(pos.y * 7.0 + seed * 13.0) * turbulence * dt;
			vel.z += cos(pos.x * 7.0 + seed * 17.0) * turbulence * dt;
		}
		if (curl != 0.0) {
			vel += curlNoise(pos) * curl * dt;
		}
		if (attractStrength != 0.0) {
			vec3 d = attractTarget - pos;
			float dist = max(length(d), 1e-3);
			vel += d * (attractStrength * dt / dist);
		}
		if (vortex != 0.0) {
			vel.x += -pos.z * vortex * dt;
			vel.z += pos.x * vortex * dt;
		}
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

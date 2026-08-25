//! A deterministic CPU particle sim for lens VFX: every particle's start and
//! motion is a pure function of its index and elapsed steps, so the same field
//! and step count give the same picture, conformance bit-stable. The face
//! pattern spawns off tracked landmarks, an AR effect the engine unlocks.
const std = @import("std");

/// How the emitter seeds a particle's start position and velocity - the shape
/// of the effect. Every shape is a deterministic function of the index; face
/// spawns from the live emitter points the host feeds in each frame.
pub const Pattern = enum { fountain, rain, burst, ring, cone, sphere, box, disc, hemisphere, face };

pub const Field = struct {
    count: u32,
    /// Emission shape.
    pattern: Pattern = .fountain,
    /// Constant downward acceleration.
    gravity: f32 = 9.8,
    /// Launch speed, and a 0..1 fraction to vary it per particle.
    speed: f32 = 2.0,
    speed_spread: f32 = 0,
    /// Seconds a particle lives, and a 0..1 fraction to vary it per particle.
    lifetime: f32 = 2.0,
    lifetime_spread: f32 = 0,
    /// Velocity damping per second (air resistance).
    drag: f32 = 0,
    /// Constant directional force (wind).
    wind: [3]f32 = .{ 0, 0, 0 },
    /// Deterministic swirl amplitude added to velocity from position.
    turbulence: f32 = 0,
    /// Curl-noise amplitude: a divergence-free swirl sampled from a smooth
    /// vector potential, the organic churn smoke and fire ride. Zero is off.
    curl: f32 = 0,
    /// A point every particle is pulled toward, and how strongly - a gravity
    /// well or magnet. Null is no attractor.
    attract: ?[3]f32 = null,
    attract_strength: f32 = 0,
    /// Swirl strength around the vertical axis - an orbital vortex.
    vortex: f32 = 0,
    /// A floor height particles bounce off. Null lets them fall through.
    floor: ?f32 = null,
    /// How much speed a particle keeps when it bounces off the floor or a
    /// collider (0 stops dead, 1 a perfect bounce). Default keeps half.
    bounce: f32 = 0.5,
    /// Sphere colliders particles bounce off, each center xyz plus radius. A
    /// particle driven inside one is pushed back to its surface and its
    /// velocity reflected (half speed kept), so particles skate over invisible
    /// obstacles. Borrowed for the system's lifetime; empty is no colliders.
    colliders: []const [4]f32 = &.{},
    /// Axis-aligned box colliders particles bounce off, each center xyz plus
    /// half-extents xyz. A particle driven inside is pushed out along its
    /// least-penetrated face and that velocity component reflected (half speed
    /// kept). Borrowed for the system's lifetime; empty is no box colliders.
    box_colliders: []const [6]f32 = &.{},
    /// Infinite plane colliders particles bounce off, each a unit normal xyz
    /// plus offset d (the plane is normal·p = d); a particle on the negative
    /// side is pushed onto the plane and its inward velocity reflected. Walls,
    /// ramps and slides. Borrowed for the system's lifetime; empty is none.
    plane_colliders: []const [4]f32 = &.{},
    /// Emit everything once and let it die, rather than respawning forever.
    oneshot: bool = false,
    // Rendering hints the sim itself ignores, carried for the host.
    /// Draw a 3D-mesh particle cloud with one instanced call instead of one
    /// draw per particle.
    instanced: bool = false,
    /// The rgb a particle draws at; null uses the engine's warm default.
    color: ?[3]f32 = null,
    /// The rgb a particle cools toward as it dies; null holds the draw colour.
    cool: ?[3]f32 = null,
    /// Fade each particle out over its life (alpha-blended sprite).
    fade: bool = false,
    /// Sprite size in pixels at birth, and an optional size at death.
    size: u32 = 0,
    size_end: ?u32 = null,
    /// Turns a sprite spins over its life.
    spin: f32 = 0,
    /// How far a sprite stretches along its screen-space velocity (streaks,
    /// sparks, rain lines); 0 is a round sprite.
    stretch: f32 = 0,
    /// Frames in a square sprite sheet the sprite flip-books through over its
    /// life; 1 (or 0) is a still image.
    frames: u32 = 1,
    /// Trail length: how many of each particle's recent positions draw behind
    /// it as a fading ribbon of billboards (a comet tail). 0 or 1 is no trail.
    trail: u32 = 0,
    /// Blend additively so overlaps brighten (a fire glow).
    glow: bool = false,
    /// Sprite image stem (assets/<stem>.png); null is the soft round default.
    sprite: ?[]const u8 = null,
    /// Sub-emitter: children each parent spawns in an outward burst when it
    /// dies - a firework's shell bursting into sparks. Zero is no sub-emitter.
    sub_count: u32 = 0,
    /// Launch speed and lifetime of a burst child.
    sub_speed: f32 = 3.0,
    sub_lifetime: f32 = 0.8,
};

/// A deterministic per-index value in [0, 1), salted so several independent
/// draws share no correlation - the sim's only source of "randomness".
fn hash01(i: usize, salt: f32) f32 {
    const x = @as(f32, @floatFromInt(i)) * 0.6180339887 + salt * 1.324717957;
    const s = @sin(x * 127.1 + salt * 311.7) * 43758.5453;
    return s - @floor(s);
}

/// A smooth vector potential sampled at a world position. Its curl (below) is
/// divergence-free by construction, so particles driven by it swirl and fold
/// without sources or sinks - the hallmark of curl-noise motion.
fn potential(p: [3]f32) [3]f32 {
    return .{
        @sin(p[1] * 1.7 + p[2] * 1.3),
        @sin(p[2] * 1.9 + p[0] * 1.1),
        @sin(p[0] * 1.5 + p[1] * 2.1),
    };
}

/// The curl of `potential` at p, by central differences - the velocity a
/// curl-noise field imparts, divergence-free so nothing piles up or thins out.
fn curlNoise(p: [3]f32) [3]f32 {
    const e: f32 = 0.15;
    const px1 = potential(.{ p[0] + e, p[1], p[2] });
    const px0 = potential(.{ p[0] - e, p[1], p[2] });
    const py1 = potential(.{ p[0], p[1] + e, p[2] });
    const py0 = potential(.{ p[0], p[1] - e, p[2] });
    const pz1 = potential(.{ p[0], p[1], p[2] + e });
    const pz0 = potential(.{ p[0], p[1], p[2] - e });
    const inv = 1.0 / (2.0 * e);
    return .{
        ((py1[2] - py0[2]) - (pz1[1] - pz0[1])) * inv,
        ((pz1[0] - pz0[0]) - (px1[2] - px0[2])) * inv,
        ((px1[1] - px0[1]) - (py1[0] - py0[0])) * inv,
    };
}

pub const Particle = struct {
    pos: [3]f32,
    vel: [3]f32,
    life: f32,
    /// This particle's own total lifetime (with spread applied).
    max_life: f32,
    /// A per-particle constant in [0,1), the sprite's spin phase.
    seed: f32,
};

pub const System = struct {
    field: Field,
    particles: []Particle,
    gpa: std.mem.Allocator,
    /// Live spawn points (world space) the host feeds each frame for the face
    /// pattern - tracked landmarks. Empty means no tracked subject.
    emitters: []const [3]f32 = &.{},
    /// A ring of each particle's recent positions (count * trail * 3 floats),
    /// only when a trail is on; the newest slot per particle is `head`.
    history: []f32 = &.{},
    head: u32 = 0,
    /// Burst children, `sub_count` per parent, laid out parent-major and dead
    /// until their parent dies and spawns them. Empty with no sub-emitter.
    children: []Particle = &.{},

    /// Trail slots per particle, at least one, so the trail math never divides
    /// by zero when a trail is off.
    fn trailLen(self: *const System) u32 {
        return @max(self.field.trail, 1);
    }

    pub fn init(gpa: std.mem.Allocator, field: Field) !System {
        const particles = try gpa.alloc(Particle, field.count);
        errdefer gpa.free(particles);
        var sys = System{ .field = field, .particles = particles, .gpa = gpa };
        if (field.trail > 1) {
            sys.history = try gpa.alloc(f32, @as(usize, field.count) * field.trail * 3);
        }
        if (field.sub_count > 0) {
            sys.children = try gpa.alloc(Particle, @as(usize, field.count) * field.sub_count);
            for (sys.children) |*ch| ch.* = .{ .pos = .{ 0, 0, 0 }, .vel = .{ 0, 0, 0 }, .life = -1, .max_life = field.sub_lifetime, .seed = 0 };
        }
        sys.emitAll();
        return sys;
    }

    pub fn deinit(self: *System) void {
        self.gpa.free(self.particles);
        if (self.history.len > 0) self.gpa.free(self.history);
        if (self.children.len > 0) self.gpa.free(self.children);
    }

    /// Total particles the host draws: the emitters plus any burst children.
    pub fn renderCount(self: *const System) usize {
        return self.particles.len + self.children.len;
    }

    /// Spawns parent i's burst children at `origin`, each on a deterministic
    /// outward ray so the shell opens into an even sphere of sparks.
    fn burstChildren(self: *System, i: usize, origin: [3]f32) void {
        const c = self.field.sub_count;
        if (c == 0) return;
        var k: u32 = 0;
        while (k < c) : (k += 1) {
            const t = (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(c));
            const z = 1.0 - 2.0 * t;
            const r = @sqrt(@max(0.0, 1.0 - z * z));
            const a = t * std.math.tau * @as(f32, @floatFromInt(c));
            const speed = self.field.sub_speed;
            self.children[i * c + k] = .{
                .pos = origin,
                .vel = .{ @cos(a) * r * speed, z * speed, @sin(a) * r * speed },
                .life = self.field.sub_lifetime,
                .max_life = self.field.sub_lifetime,
                .seed = hash01(i * c + k, 7.0),
            };
        }
    }

    /// Fills every trail slot of particle i with pos, so a fresh or respawned
    /// particle's trail starts collapsed at its birthplace rather than
    /// streaking from wherever it last died.
    fn seedHistory(self: *System, i: usize, pos: [3]f32) void {
        if (self.history.len == 0) return;
        const n = self.trailLen();
        var s: u32 = 0;
        while (s < n) : (s += 1) {
            const b = (i * n + s) * 3;
            self.history[b + 0] = pos[0];
            self.history[b + 1] = pos[1];
            self.history[b + 2] = pos[2];
        }
    }

    /// Points the face pattern spawns from this frame. The slice is borrowed,
    /// valid only until the next call; the sim copies nothing.
    pub fn setEmitters(self: *System, points: []const [3]f32) void {
        self.emitters = points;
    }

    fn emitOne(field: Field, emitters: []const [3]f32, i: usize) Particle {
        const denom: f32 = @floatFromInt(@max(field.count, 1));
        const t = @as(f32, @floatFromInt(i)) / denom;
        const a = t * std.math.tau;
        const seed = hash01(i, 0.0);
        const speed = field.speed * (1.0 - field.speed_spread * hash01(i, 1.0));
        const life = field.lifetime * (1.0 - field.lifetime_spread * hash01(i, 2.0));
        var pos: [3]f32 = .{ 0, 0, 0 };
        var vel: [3]f32 = .{ 0, 0, 0 };
        switch (field.pattern) {
            // A cone rising from the origin and spreading outward.
            .fountain => vel = .{ @cos(a) * speed, speed * 1.5 + @as(f32, @floatFromInt(i % 8)) * 0.1, @sin(a) * speed },
            // Seeded across the top of the frame, drifting straight down.
            .rain => {
                pos = .{ (t - 0.5) * 2.0, 1.0, (seed - 0.5) * 0.6 };
                vel = .{ 0, -speed, 0 };
            },
            // Radial explosion: velocities point out across a sphere by index.
            .burst => {
                const z = 1.0 - 2.0 * t;
                const r = @sqrt(@max(0.0, 1.0 - z * z));
                vel = .{ @cos(a) * r * speed, z * speed, @sin(a) * r * speed };
            },
            // A flat ring expanding outward in the xz plane.
            .ring => {
                pos = .{ @cos(a) * 0.5, 0, @sin(a) * 0.5 };
                vel = .{ @cos(a) * speed, 0, @sin(a) * speed };
            },
            // A tight upward cone, narrower than the fountain.
            .cone => {
                const rr = seed * 0.4;
                vel = .{ @cos(a) * rr * speed, speed, @sin(a) * rr * speed };
            },
            // Emitted from a sphere's surface, moving out along the normal.
            .sphere => {
                const z = 1.0 - 2.0 * seed;
                const r = @sqrt(@max(0.0, 1.0 - z * z));
                const b = hash01(i, 3.0) * std.math.tau;
                pos = .{ @cos(b) * r * 0.5, z * 0.5, @sin(b) * r * 0.5 };
                vel = .{ @cos(b) * r * speed, z * speed, @sin(b) * r * speed };
            },
            // Seeded through a box volume, drifting up gently.
            .box => {
                pos = .{ (hash01(i, 4.0) - 0.5) * 1.4, (hash01(i, 5.0) - 0.5) * 1.4, (hash01(i, 6.0) - 0.5) * 1.4 };
                vel = .{ 0, speed, 0 };
            },
            // A flat disc on the ground, rising.
            .disc => {
                const rr = @sqrt(seed) * 0.6;
                pos = .{ @cos(a) * rr, 0, @sin(a) * rr };
                vel = .{ 0, speed, 0 };
            },
            // The upper half of a sphere's surface.
            .hemisphere => {
                const z = seed;
                const r = @sqrt(@max(0.0, 1.0 - z * z));
                const b = hash01(i, 3.0) * std.math.tau;
                pos = .{ @cos(b) * r * 0.5, z * 0.5, @sin(b) * r * 0.5 };
                vel = .{ @cos(b) * r * speed, z * speed, @sin(b) * r * speed };
            },
            // Spawn from a live tracked landmark - the AR signature. Without a
            // tracked subject the emitter is empty and particles hold at rest.
            .face => {
                if (emitters.len > 0) {
                    const e = emitters[i % emitters.len];
                    pos = .{ e[0], e[1], e[2] };
                    vel = .{ (seed - 0.5) * speed, speed * (0.5 + seed), (hash01(i, 7.0) - 0.5) * speed };
                }
            },
        }
        return .{ .pos = pos, .vel = vel, .life = life, .max_life = @max(life, 1e-6), .seed = seed };
    }

    fn emitAll(self: *System) void {
        for (self.particles, 0..) |*p, i| {
            p.* = emitOne(self.field, self.emitters, i);
            self.seedHistory(i, p.pos);
        }
        self.head = 0;
    }

    /// Advances every particle by dt under gravity, drag, wind, turbulence, an
    /// attractor and a vortex, bouncing off the floor; an expired particle
    /// respawns from the emitter unless the field is a one-shot burst.
    pub fn step(self: *System, dt: f32) void {
        const f = self.field;
        for (self.particles, 0..) |*p, i| {
            p.life -= dt;
            if (p.life <= 0) {
                // The step it crosses from alive to dead, the shell bursts.
                if (f.sub_count > 0 and p.life + dt > 0) self.burstChildren(i, p.pos);
                if (f.oneshot) {
                    p.life = 0;
                    continue;
                }
                p.* = emitOne(f, self.emitters, i);
                self.seedHistory(i, p.pos);
                continue;
            }
            p.vel[1] -= f.gravity * dt;
            if (f.drag > 0) {
                const damp = @max(0.0, 1.0 - f.drag * dt);
                p.vel[0] *= damp;
                p.vel[1] *= damp;
                p.vel[2] *= damp;
            }
            p.vel[0] += f.wind[0] * dt;
            p.vel[1] += f.wind[1] * dt;
            p.vel[2] += f.wind[2] * dt;
            if (f.turbulence > 0) {
                p.vel[0] += @sin(p.pos[1] * 7.0 + p.seed * 13.0) * f.turbulence * dt;
                p.vel[2] += @cos(p.pos[0] * 7.0 + p.seed * 17.0) * f.turbulence * dt;
            }
            if (f.curl != 0) {
                const cn = curlNoise(p.pos);
                p.vel[0] += cn[0] * f.curl * dt;
                p.vel[1] += cn[1] * f.curl * dt;
                p.vel[2] += cn[2] * f.curl * dt;
            }
            if (f.attract) |target| {
                const dx = target[0] - p.pos[0];
                const dy = target[1] - p.pos[1];
                const dz = target[2] - p.pos[2];
                const dist = @max(@sqrt(dx * dx + dy * dy + dz * dz), 1e-3);
                const g = f.attract_strength * dt / dist;
                p.vel[0] += dx * g;
                p.vel[1] += dy * g;
                p.vel[2] += dz * g;
            }
            if (f.vortex != 0) {
                p.vel[0] += -p.pos[2] * f.vortex * dt;
                p.vel[2] += p.pos[0] * f.vortex * dt;
            }
            p.pos[0] += p.vel[0] * dt;
            p.pos[1] += p.vel[1] * dt;
            p.pos[2] += p.vel[2] * dt;
            if (f.floor) |y| {
                if (p.pos[1] < y) {
                    p.pos[1] = y;
                    p.vel[1] = -p.vel[1] * f.bounce;
                }
            }
            for (f.colliders) |sphere| {
                const dx = p.pos[0] - sphere[0];
                const dy = p.pos[1] - sphere[1];
                const dz = p.pos[2] - sphere[2];
                const d2 = dx * dx + dy * dy + dz * dz;
                const rr = sphere[3];
                if (d2 < rr * rr and d2 > 1e-12) {
                    const d = @sqrt(d2);
                    const nx = dx / d;
                    const ny = dy / d;
                    const nz = dz / d;
                    // Push out to the surface along the normal.
                    p.pos[0] = sphere[0] + nx * rr;
                    p.pos[1] = sphere[1] + ny * rr;
                    p.pos[2] = sphere[2] + nz * rr;
                    // Reflect the inward velocity, keeping half its speed.
                    const vn = p.vel[0] * nx + p.vel[1] * ny + p.vel[2] * nz;
                    if (vn < 0) {
                        p.vel[0] = (p.vel[0] - 2.0 * vn * nx) * f.bounce;
                        p.vel[1] = (p.vel[1] - 2.0 * vn * ny) * f.bounce;
                        p.vel[2] = (p.vel[2] - 2.0 * vn * nz) * f.bounce;
                    }
                }
            }
            for (f.box_colliders) |box| {
                const lx = box[3] - @abs(p.pos[0] - box[0]);
                const ly = box[4] - @abs(p.pos[1] - box[1]);
                const lz = box[5] - @abs(p.pos[2] - box[2]);
                // Inside on every axis means penetrating; push out along the
                // face with the least penetration and reflect that component.
                if (lx > 0 and ly > 0 and lz > 0) {
                    if (lx <= ly and lx <= lz) {
                        const s: f32 = if (p.pos[0] < box[0]) -1.0 else 1.0;
                        p.pos[0] = box[0] + s * box[3];
                        if (p.vel[0] * s < 0) p.vel[0] = -p.vel[0] * f.bounce;
                    } else if (ly <= lz) {
                        const s: f32 = if (p.pos[1] < box[1]) -1.0 else 1.0;
                        p.pos[1] = box[1] + s * box[4];
                        if (p.vel[1] * s < 0) p.vel[1] = -p.vel[1] * f.bounce;
                    } else {
                        const s: f32 = if (p.pos[2] < box[2]) -1.0 else 1.0;
                        p.pos[2] = box[2] + s * box[5];
                        if (p.vel[2] * s < 0) p.vel[2] = -p.vel[2] * f.bounce;
                    }
                }
            }
            for (f.plane_colliders) |plane| {
                const nx = plane[0];
                const ny = plane[1];
                const nz = plane[2];
                const sd = p.pos[0] * nx + p.pos[1] * ny + p.pos[2] * nz - plane[3];
                if (sd < 0) {
                    // Push onto the plane along the normal.
                    p.pos[0] -= nx * sd;
                    p.pos[1] -= ny * sd;
                    p.pos[2] -= nz * sd;
                    const vn = p.vel[0] * nx + p.vel[1] * ny + p.vel[2] * nz;
                    if (vn < 0) {
                        p.vel[0] = (p.vel[0] - 2.0 * vn * nx) * f.bounce;
                        p.vel[1] = (p.vel[1] - 2.0 * vn * ny) * f.bounce;
                        p.vel[2] = (p.vel[2] - 2.0 * vn * nz) * f.bounce;
                    }
                }
            }
        }
        // Advance the burst children: a plain oneshot fall, no respawn.
        for (self.children) |*ch| {
            if (ch.life <= 0) continue;
            ch.life -= dt;
            if (ch.life <= 0) continue;
            ch.vel[1] -= f.gravity * dt;
            if (f.drag > 0) {
                const damp = @max(0.0, 1.0 - f.drag * dt);
                ch.vel[0] *= damp;
                ch.vel[1] *= damp;
                ch.vel[2] *= damp;
            }
            ch.pos[0] += ch.vel[0] * dt;
            ch.pos[1] += ch.vel[1] * dt;
            ch.pos[2] += ch.vel[2] * dt;
        }
        // Record this frame's positions into the trail ring, one slot on.
        if (self.history.len > 0) {
            const n = self.trailLen();
            self.head = (self.head + 1) % n;
            for (self.particles, 0..) |p, i| {
                const b = (i * n + self.head) * 3;
                self.history[b + 0] = p.pos[0];
                self.history[b + 1] = p.pos[1];
                self.history[b + 2] = p.pos[2];
            }
        }
    }

    /// Billboard vertices a trail draw needs: six per particle per trail slot.
    pub fn trailVertexCount(self: *const System) usize {
        return @as(usize, self.field.count) * self.trailLen() * 6;
    }

    /// Writes the trail as fading billboards (trailVertexCount() * 8 floats):
    /// each particle's recent positions, oldest faintest, so the ribbon tapers
    /// off behind it. Same vertex shape as writeBillboards, so the one fading
    /// billboard program draws it with no new shader.
    pub fn writeTrailBillboards(self: *const System, out: []f32) void {
        const corners = [6]f32{ 0, 1, 2, 0, 2, 3 };
        const n = self.trailLen();
        for (self.particles, 0..) |p, i| {
            const life_frac = std.math.clamp(p.life / p.max_life, 0.0, 1.0);
            var slot: u32 = 0;
            while (slot < n) : (slot += 1) {
                // slot 0 is the oldest sample, n-1 the newest; the newest sits
                // at `head`, so walk forward from just past it.
                const ring = (self.head + 1 + slot) % n;
                const hb = (i * n + ring) * 3;
                const age = @as(f32, @floatFromInt(slot + 1)) / @as(f32, @floatFromInt(n));
                const frac = life_frac * age;
                for (corners, 0..) |corner, k| {
                    const base = ((i * n + slot) * 6 + k) * 8;
                    out[base + 0] = self.history[hb + 0];
                    out[base + 1] = self.history[hb + 1];
                    out[base + 2] = self.history[hb + 2];
                    out[base + 3] = corner;
                    out[base + 4] = frac;
                    out[base + 5] = p.seed;
                    out[base + 6] = p.vel[0];
                    out[base + 7] = p.vel[1];
                }
            }
        }
    }

    /// Triangle vertices a ribbon draw needs: six per particle per trail
    /// segment (one connecting quad between consecutive history points).
    pub fn ribbonVertexCount(self: *const System) usize {
        const n = self.trailLen();
        const segs = if (n > 1) n - 1 else 0;
        return @as(usize, self.field.count) * segs * 6;
    }

    /// Writes the trail history as a solid connected ribbon (ribbonVertexCount()
    /// * 3 floats): each pair of consecutive positions becomes a camera-facing
    /// quad `width` wide, tapering toward the tail, so a particle draws one
    /// continuous strip instead of a row of separate billboards.
    pub fn writeRibbons(self: *const System, out: []f32, width: f32) void {
        const n = self.trailLen();
        if (n < 2) return;
        const denom: f32 = @floatFromInt(n - 1);
        for (self.particles, 0..) |_, i| {
            var seg: u32 = 0;
            while (seg < n - 1) : (seg += 1) {
                const r0 = (self.head + 1 + seg) % n;
                const r1 = (self.head + 1 + seg + 1) % n;
                const b0 = (i * n + r0) * 3;
                const b1 = (i * n + r1) * 3;
                const p0 = [3]f32{ self.history[b0], self.history[b0 + 1], self.history[b0 + 2] };
                const p1 = [3]f32{ self.history[b1], self.history[b1 + 1], self.history[b1 + 2] };
                // Offset perpendicular to the segment and to the view (+z), so
                // the ribbon faces the fixed content camera; a still segment
                // falls back to a horizontal offset rather than collapsing.
                var sx = p1[1] - p0[1];
                var sy = -(p1[0] - p0[0]);
                var sl = @sqrt(sx * sx + sy * sy);
                if (sl < 1e-5) {
                    sx = 1;
                    sy = 0;
                    sl = 1;
                }
                sx /= sl;
                sy /= sl;
                const w0 = width * (@as(f32, @floatFromInt(seg)) / denom);
                const w1 = width * (@as(f32, @floatFromInt(seg + 1)) / denom);
                const verts = [6][3]f32{
                    .{ p0[0] - sx * w0, p0[1] - sy * w0, p0[2] },
                    .{ p0[0] + sx * w0, p0[1] + sy * w0, p0[2] },
                    .{ p1[0] + sx * w1, p1[1] + sy * w1, p1[2] },
                    .{ p0[0] - sx * w0, p0[1] - sy * w0, p0[2] },
                    .{ p1[0] + sx * w1, p1[1] + sy * w1, p1[2] },
                    .{ p1[0] - sx * w1, p1[1] - sy * w1, p1[2] },
                };
                for (verts, 0..) |v, k| {
                    const base = ((i * (n - 1) + seg) * 6 + k) * 3;
                    out[base + 0] = v[0];
                    out[base + 1] = v[1];
                    out[base + 2] = v[2];
                }
            }
        }
    }

    /// Writes xyz of every particle into out (count * 3 floats) for the plain
    /// non-fading point mesh.
    pub fn writePositions(self: *const System, out: []f32) void {
        for (self.particles, 0..) |p, i| {
            out[i * 3 + 0] = p.pos[0];
            out[i * 3 + 1] = p.pos[1];
            out[i * 3 + 2] = p.pos[2];
        }
        const base = self.particles.len;
        for (self.children, 0..) |ch, j| {
            out[(base + j) * 3 + 0] = ch.pos[0];
            out[(base + j) * 3 + 1] = ch.pos[1];
            out[(base + j) * 3 + 2] = ch.pos[2];
        }
    }

    /// Writes six vertices per particle (a camera-facing quad) into out (count
    /// * 6 * 8 floats): the centre, a corner index, remaining-life fraction,
    /// spin seed, and world velocity xy - which the billboard shader expands
    /// into a rotated, sized, faded, stretched, flip-booked sprite.
    pub fn writeBillboards(self: *const System, out: []f32) void {
        const corners = [6]f32{ 0, 1, 2, 0, 2, 3 };
        writeParticleBillboards(self.particles, out, 0, corners);
        writeParticleBillboards(self.children, out, self.particles.len, corners);
    }

    fn writeParticleBillboards(list: []const Particle, out: []f32, offset: usize, corners: [6]f32) void {
        for (list, 0..) |p, i| {
            const frac = std.math.clamp(p.life / p.max_life, 0.0, 1.0);
            for (corners, 0..) |corner, k| {
                const base = ((offset + i) * 6 + k) * 8;
                out[base + 0] = p.pos[0];
                out[base + 1] = p.pos[1];
                out[base + 2] = p.pos[2];
                out[base + 3] = corner;
                out[base + 4] = frac;
                out[base + 5] = p.seed;
                out[base + 6] = p.vel[0];
                out[base + 7] = p.vel[1];
            }
        }
    }
};

test "the particle system is deterministic and moves under gravity" {
    const field = Field{ .count = 128, .gravity = 9.8, .speed = 2.0, .lifetime = 2.0 };
    var a = try System.init(std.testing.allocator, field);
    defer a.deinit();
    var b = try System.init(std.testing.allocator, field);
    defer b.deinit();
    for (0..90) |_| {
        a.step(1.0 / 60.0);
        b.step(1.0 / 60.0);
    }
    for (a.particles, b.particles) |pa, pb| {
        try std.testing.expectEqual(pa.pos[0], pb.pos[0]);
        try std.testing.expectEqual(pa.pos[1], pb.pos[1]);
        try std.testing.expectEqual(pa.pos[2], pb.pos[2]);
    }
    try std.testing.expect(a.particles[0].pos[1] != 0);
}

test "a sub-emitter bursts children when its parents die, deterministically" {
    const field = Field{ .count = 4, .gravity = 2.0, .speed = 1.0, .lifetime = 0.5, .oneshot = true, .sub_count = 8, .sub_speed = 2.0, .sub_lifetime = 1.0 };
    var sys = try System.init(std.testing.allocator, field);
    defer sys.deinit();
    try std.testing.expectEqual(@as(usize, 32), sys.children.len);
    // Before the parents' half-second life is up, no child has spawned.
    for (0..8) |_| sys.step(1.0 / 60.0);
    var alive_early: usize = 0;
    for (sys.children) |ch| {
        if (ch.life > 0) alive_early += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), alive_early);
    // Past the parents' lifetime the shells have burst into live sparks.
    for (0..40) |_| sys.step(1.0 / 60.0);
    var alive_after: usize = 0;
    for (sys.children) |ch| {
        if (ch.life > 0) alive_after += 1;
    }
    try std.testing.expect(alive_after > 0);
    // A second identical run lands every child in the same place.
    var sys2 = try System.init(std.testing.allocator, field);
    defer sys2.deinit();
    for (0..48) |_| sys2.step(1.0 / 60.0);
    for (sys.children, sys2.children) |a, b| {
        try std.testing.expectEqual(a.pos[0], b.pos[0]);
        try std.testing.expectEqual(a.pos[1], b.pos[1]);
    }
}

test "every emission pattern and force is deterministic and non-degenerate" {
    const points = [_][3]f32{ .{ 0.1, 0.2, 0 }, .{ -0.1, 0.15, 0 } };
    for ([_]Pattern{ .fountain, .rain, .burst, .ring, .cone, .sphere, .box, .disc, .hemisphere, .face }) |pattern| {
        const field = Field{ .count = 64, .speed = 2.0, .lifetime = 2.0, .pattern = pattern, .drag = 0.5, .turbulence = 1.0, .curl = 2.0, .wind = .{ 0.2, 0, 0 }, .vortex = 1.5, .attract = .{ 0, 0.5, 0 }, .attract_strength = 1.0, .floor = -0.8 };
        var s = try System.init(std.testing.allocator, field);
        defer s.deinit();
        s.setEmitters(&points);
        s.emitAll();
        for (0..30) |_| s.step(1.0 / 60.0);
        var moved = false;
        for (s.particles) |p| {
            if (p.pos[0] != 0 or p.pos[1] != 0 or p.pos[2] != 0) moved = true;
            try std.testing.expect(p.pos[1] >= -0.8001);
        }
        try std.testing.expect(moved);
    }
}

test "curl noise is divergence-free and swirls particles off the plain path" {
    // The curl of a smooth potential has (near) zero divergence: the sum of
    // its diagonal derivatives cancels, so a curl-noise field neither sources
    // nor sinks particles.
    const p = [3]f32{ 0.3, -0.2, 0.5 };
    const e: f32 = 0.15;
    const dxx = curlNoise(.{ p[0] + e, p[1], p[2] })[0] - curlNoise(.{ p[0] - e, p[1], p[2] })[0];
    const dyy = curlNoise(.{ p[0], p[1] + e, p[2] })[1] - curlNoise(.{ p[0], p[1] - e, p[2] })[1];
    const dzz = curlNoise(.{ p[0], p[1], p[2] + e })[2] - curlNoise(.{ p[0], p[1], p[2] - e })[2];
    try std.testing.expect(@abs(dxx + dyy + dzz) < 1e-2);

    // Curl on visibly bends the path away from curl off, deterministically.
    const base = Field{ .count = 96, .speed = 1.5, .lifetime = 3.0, .pattern = .fountain };
    var off = try System.init(std.testing.allocator, base);
    defer off.deinit();
    var on = try System.init(std.testing.allocator, .{ .count = 96, .speed = 1.5, .lifetime = 3.0, .pattern = .fountain, .curl = 3.0 });
    defer on.deinit();
    for (0..60) |_| {
        off.step(1.0 / 60.0);
        on.step(1.0 / 60.0);
    }
    var diverged = false;
    for (off.particles, on.particles) |a, b| {
        if (a.pos[0] != b.pos[0] or a.pos[2] != b.pos[2]) diverged = true;
    }
    try std.testing.expect(diverged);
}

test "particles bounce off a sphere collider and never enter it" {
    // A rain of particles falls straight onto a sphere sitting below them; none
    // may end up inside it, and the collision must be deterministic.
    const sphere = [_][4]f32{.{ 0.0, 0.0, 0.0, 0.5 }};
    const field = Field{ .count = 64, .pattern = .rain, .speed = 3.0, .lifetime = 6.0, .gravity = 4.0, .colliders = &sphere };
    var a = try System.init(std.testing.allocator, field);
    defer a.deinit();
    var b = try System.init(std.testing.allocator, field);
    defer b.deinit();
    for (0..180) |_| {
        a.step(1.0 / 60.0);
        b.step(1.0 / 60.0);
    }
    for (a.particles, b.particles) |pa, pb| {
        const d2 = pa.pos[0] * pa.pos[0] + pa.pos[1] * pa.pos[1] + pa.pos[2] * pa.pos[2];
        try std.testing.expect(d2 >= 0.5 * 0.5 - 1e-4); // outside the sphere
        try std.testing.expectEqual(pa.pos[1], pb.pos[1]); // deterministic
    }
}

test "bounce controls how much speed a floor bounce keeps" {
    // Two particles dropped onto a floor: a perfect bounce keeps more upward
    // speed after impact than a dead-stop one, deterministically.
    const drop = Field{ .count = 4, .pattern = .rain, .speed = 0.0, .lifetime = 6.0, .gravity = 9.8, .floor = -0.5 };
    var bouncy = try System.init(std.testing.allocator, .{ .count = 4, .pattern = .rain, .speed = 0.0, .lifetime = 6.0, .gravity = 9.8, .floor = -0.5, .bounce = 1.0 });
    defer bouncy.deinit();
    var dead = try System.init(std.testing.allocator, .{ .count = 4, .pattern = .rain, .speed = 0.0, .lifetime = 6.0, .gravity = 9.8, .floor = -0.5, .bounce = 0.0 });
    defer dead.deinit();
    _ = drop;
    for (0..80) |_| {
        bouncy.step(1.0 / 60.0);
        dead.step(1.0 / 60.0);
    }
    // The perfect bounce keeps the particle livelier (higher) than the dead one.
    try std.testing.expect(bouncy.particles[0].pos[1] > dead.particles[0].pos[1]);
    // A dead bounce keeps no upward speed the frame it lands.
    var sticky = try System.init(std.testing.allocator, .{ .count = 1, .pattern = .rain, .speed = 0.0, .lifetime = 6.0, .gravity = 9.8, .floor = -0.5, .bounce = 0.0 });
    defer sticky.deinit();
    for (0..80) |_| sticky.step(1.0 / 60.0);
    try std.testing.expect(sticky.particles[0].vel[1] <= 0.001);
}

test "particles bounce off a box collider and never enter it" {
    const box = [_][6]f32{.{ 0.0, 0.0, 0.0, 0.4, 0.4, 0.4 }};
    const field = Field{ .count = 64, .pattern = .rain, .speed = 3.0, .lifetime = 6.0, .gravity = 4.0, .box_colliders = &box };
    var a = try System.init(std.testing.allocator, field);
    defer a.deinit();
    var b = try System.init(std.testing.allocator, field);
    defer b.deinit();
    for (0..180) |_| {
        a.step(1.0 / 60.0);
        b.step(1.0 / 60.0);
    }
    for (a.particles, b.particles) |pa, pb| {
        // Never strictly inside the box (allow the exact surface).
        const inside = @abs(pa.pos[0]) < 0.4 - 1e-3 and @abs(pa.pos[1]) < 0.4 - 1e-3 and @abs(pa.pos[2]) < 0.4 - 1e-3;
        try std.testing.expect(!inside);
        try std.testing.expectEqual(pa.pos[1], pb.pos[1]); // deterministic
    }
}

test "particles bounce off a tilted plane collider and never cross it" {
    // A plane tilted 45 degrees (normal pointing up and to +x): particles must
    // stay on its positive side, deterministically.
    const inv = 1.0 / @sqrt(2.0);
    const plane = [_][4]f32{.{ inv, inv, 0.0, -0.3 }};
    const field = Field{ .count = 64, .pattern = .rain, .speed = 2.0, .lifetime = 6.0, .gravity = 5.0, .plane_colliders = &plane };
    var a = try System.init(std.testing.allocator, field);
    defer a.deinit();
    var b = try System.init(std.testing.allocator, field);
    defer b.deinit();
    for (0..180) |_| {
        a.step(1.0 / 60.0);
        b.step(1.0 / 60.0);
    }
    for (a.particles, b.particles) |pa, pb| {
        const sd = pa.pos[0] * inv + pa.pos[1] * inv - (-0.3);
        try std.testing.expect(sd >= -1e-3); // on the positive side of the plane
        try std.testing.expectEqual(pa.pos[0], pb.pos[0]); // deterministic
    }
}

test "a ribbon bakes a connecting quad per trail segment" {
    const field = Field{ .count = 16, .speed = 1.0, .lifetime = 5.0, .pattern = .fountain, .trail = 8 };
    var s = try System.init(std.testing.allocator, field);
    defer s.deinit();
    for (0..40) |_| s.step(1.0 / 60.0);
    // One quad (six verts) per particle per segment (trail - 1 segments).
    try std.testing.expectEqual(@as(usize, 16 * 7 * 6), s.ribbonVertexCount());
    const out = try std.testing.allocator.alloc(f32, s.ribbonVertexCount() * 3);
    defer std.testing.allocator.free(out);
    s.writeRibbons(out, 0.05);
    // The strip has real width: some vertices are offset off the centre line.
    var spread = false;
    for (out) |v| {
        if (v != 0 and @abs(v) > 1e-4) spread = true;
    }
    try std.testing.expect(spread);
    // No NaNs from a degenerate (still) segment.
    for (out) |v| try std.testing.expect(v == v);
}

test "a trail records recent positions and fades from head to tail" {
    const field = Field{ .count = 32, .speed = 1.0, .lifetime = 5.0, .pattern = .fountain, .trail = 6, .fade = true };
    var s = try System.init(std.testing.allocator, field);
    defer s.deinit();
    // Every trail slot starts collapsed at the birthplace, so no garbage streak.
    for (0..s.trailVertexCount()) |_| {}
    try std.testing.expectEqual(@as(usize, 32 * 6 * 6), s.trailVertexCount());
    for (0..40) |_| s.step(1.0 / 60.0);

    // The ring now holds distinct recent positions for a moving particle.
    const n = s.trailLen();
    const p0 = s.particles[0];
    _ = p0;
    var distinct = false;
    const newest = (s.head) % n;
    const oldest = (s.head + 1) % n;
    const bn = (0 * n + newest) * 3;
    const bo = (0 * n + oldest) * 3;
    if (s.history[bn + 1] != s.history[bo + 1]) distinct = true;
    try std.testing.expect(distinct);

    // Billboards write, oldest slot fainter than newest for the same particle.
    const out = try std.testing.allocator.alloc(f32, s.trailVertexCount() * 8);
    defer std.testing.allocator.free(out);
    s.writeTrailBillboards(out);
    const oldest_frac = out[((0 * n + 0) * 6 + 0) * 8 + 4];
    const newest_frac = out[((0 * n + (n - 1)) * 6 + 0) * 8 + 4];
    try std.testing.expect(newest_frac > oldest_frac);
}

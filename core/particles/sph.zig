//! A deterministic 2D smoothed-particle-hydrodynamics fluid. Particles carry
//! density and pressure sampled from their neighbours and pool under gravity
//! in a box - a pure function of the count and parameters, so runs are
//! bit-identical. The neighbour search is the naive O(n^2) sweep.

const std = @import("std");

/// Fluid parameters. The kernels are the 2D normalisations of the usual poly6
/// (density) and spiky-gradient (pressure) smoothing functions.
pub const Params = struct {
    /// Smoothing radius: a particle only feels neighbours within it.
    h: f32 = 0.12,
    mass: f32 = 1.0,
    /// The density the fluid relaxes toward; pressure pushes back above it.
    rest_density: f32 = 140.0,
    /// Pressure stiffness (how hard the fluid resists compression).
    stiffness: f32 = 6.0,
    /// Viscosity damps relative motion, keeping the sim stable.
    viscosity: f32 = 3.0,
    gravity: f32 = 9.8,
    /// Box the fluid is confined to: xmin, xmax, ymin, ymax.
    bounds: [4]f32 = .{ -0.4, 0.4, -0.5, 0.6 },
    /// Speed kept when a particle bounces off a wall (0 dead, 1 perfect).
    wall_bounce: f32 = 0.3,
    /// Internal substeps per step: SPH stays stable at a smaller step.
    substeps: u32 = 4,
};

pub const Fluid = struct {
    const Particle = struct {
        pos: [2]f32,
        vel: [2]f32,
        density: f32 = 0,
        pressure: f32 = 0,
    };

    particles: []Particle,
    params: Params,
    gpa: std.mem.Allocator,

    /// Seeds `count` particles in a square block near the top of the box, so
    /// they fall and pool. The block is a deterministic grid.
    pub fn init(gpa: std.mem.Allocator, count: u32, params: Params) !Fluid {
        const particles = try gpa.alloc(Particle, count);
        const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(count)))));
        const spacing = params.h * 0.6;
        const start_x = -@as(f32, @floatFromInt(cols)) * spacing * 0.5;
        const top_y = params.bounds[3] - params.h;
        for (particles, 0..) |*p, i| {
            const col = @as(u32, @intCast(i)) % cols;
            const row = @as(u32, @intCast(i)) / cols;
            p.* = .{
                .pos = .{ start_x + @as(f32, @floatFromInt(col)) * spacing, top_y - @as(f32, @floatFromInt(row)) * spacing },
                .vel = .{ 0, 0 },
            };
        }
        return .{ .particles = particles, .params = params, .gpa = gpa };
    }

    pub fn deinit(self: *Fluid) void {
        self.gpa.free(self.particles);
    }

    fn poly6(r2: f32, h: f32) f32 {
        const h2 = h * h;
        if (r2 >= h2) return 0;
        const d = h2 - r2;
        return 4.0 / (std.math.pi * std.math.pow(f32, h, 8.0)) * d * d * d;
    }

    fn spikyGrad(r: f32, h: f32) f32 {
        if (r >= h or r <= 1e-6) return 0;
        const d = h - r;
        return -30.0 / (std.math.pi * std.math.pow(f32, h, 5.0)) * d * d;
    }

    fn viscLap(r: f32, h: f32) f32 {
        if (r >= h) return 0;
        return 40.0 / (std.math.pi * std.math.pow(f32, h, 5.0)) * (h - r);
    }

    /// Advances the fluid by dt, in `substeps` internal steps for stability.
    pub fn step(self: *Fluid, dt: f32) void {
        const sub = dt / @as(f32, @floatFromInt(self.params.substeps));
        var s: u32 = 0;
        while (s < self.params.substeps) : (s += 1) self.substep(sub);
    }

    fn substep(self: *Fluid, dt: f32) void {
        const p = self.params;
        // Density and pressure from neighbours.
        for (self.particles) |*a| {
            var density: f32 = 0;
            for (self.particles) |b| {
                const dx = a.pos[0] - b.pos[0];
                const dy = a.pos[1] - b.pos[1];
                density += p.mass * poly6(dx * dx + dy * dy, p.h);
            }
            a.density = @max(density, p.rest_density * 0.1);
            a.pressure = p.stiffness * (a.density - p.rest_density);
        }
        // Pressure + viscosity forces, then integrate.
        for (self.particles) |*a| {
            var fx: f32 = 0;
            var fy: f32 = 0;
            for (self.particles) |b| {
                if (&b == a) continue;
                const dx = a.pos[0] - b.pos[0];
                const dy = a.pos[1] - b.pos[1];
                const r = @sqrt(dx * dx + dy * dy);
                if (r >= p.h or r <= 1e-6) continue;
                const grad = spikyGrad(r, p.h);
                const shared = -p.mass * (a.pressure + b.pressure) / (2.0 * b.density) * grad;
                fx += shared * (dx / r);
                fy += shared * (dy / r);
                const lap = viscLap(r, p.h);
                const vf = p.viscosity * p.mass / b.density * lap;
                fx += vf * (b.vel[0] - a.vel[0]);
                fy += vf * (b.vel[1] - a.vel[1]);
            }
            fy -= p.gravity * a.density;
            const inv = 1.0 / a.density;
            a.vel[0] += dt * fx * inv;
            a.vel[1] += dt * fy * inv;
            a.pos[0] += dt * a.vel[0];
            a.pos[1] += dt * a.vel[1];
            // Box walls: clamp and reflect the inward velocity, damped.
            if (a.pos[0] < p.bounds[0]) {
                a.pos[0] = p.bounds[0];
                a.vel[0] = -a.vel[0] * p.wall_bounce;
            } else if (a.pos[0] > p.bounds[1]) {
                a.pos[0] = p.bounds[1];
                a.vel[0] = -a.vel[0] * p.wall_bounce;
            }
            if (a.pos[1] < p.bounds[2]) {
                a.pos[1] = p.bounds[2];
                a.vel[1] = -a.vel[1] * p.wall_bounce;
            } else if (a.pos[1] > p.bounds[3]) {
                a.pos[1] = p.bounds[3];
                a.vel[1] = -a.vel[1] * p.wall_bounce;
            }
        }
    }

    /// Writes x, y, 0 per particle (the fluid lives in the z = 0 plane).
    pub fn writePositions(self: *const Fluid, out: []f32) void {
        for (self.particles, 0..) |part, i| {
            out[i * 3 + 0] = part.pos[0];
            out[i * 3 + 1] = part.pos[1];
            out[i * 3 + 2] = 0;
        }
    }

    /// The mean height of the fluid, for tests and settling checks.
    pub fn meanHeight(self: *const Fluid) f32 {
        var sum: f32 = 0;
        for (self.particles) |part| sum += part.pos[1];
        return sum / @as(f32, @floatFromInt(self.particles.len));
    }
};

const t = std.testing;

test "an sph fluid pools at the bottom of its box, deterministically" {
    var runs: [2]f32 = undefined;
    var spread: [2]f32 = undefined;
    for (0..2) |run| {
        var fluid = try Fluid.init(t.allocator, 100, .{});
        defer fluid.deinit();
        const start_height = fluid.meanHeight();
        for (0..120) |_| fluid.step(1.0 / 60.0);
        runs[run] = fluid.meanHeight();
        // Measure how wide the settled fluid spreads in x - it should flatten
        // into a pool, not stay a narrow column.
        var min_x: f32 = 1e9;
        var max_x: f32 = -1e9;
        for (fluid.particles) |part| {
            min_x = @min(min_x, part.pos[0]);
            max_x = @max(max_x, part.pos[1] * 0 + part.pos[0]);
        }
        spread[run] = max_x - min_x;
        // The fluid fell from where it started and stays inside the box.
        try t.expect(runs[run] < start_height - 0.05);
        for (fluid.particles) |part| {
            try t.expect(part.pos[1] >= fluid.params.bounds[2] - 1e-3);
            try t.expect(part.pos[0] >= fluid.params.bounds[0] - 1e-3);
            try t.expect(part.pos[0] <= fluid.params.bounds[1] + 1e-3);
        }
    }
    // Deterministic: two runs land the same, and the fluid spread into a pool.
    try t.expectEqual(runs[0], runs[1]);
    try t.expect(spread[0] > 0.3);
}

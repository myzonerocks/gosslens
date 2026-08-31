//! Trigger `when` expressions: a closed grammar, compiled once at lens
//! load into a typed tree and evaluated every frame
//! against the session's live signals. compile() is the only allocating
//! pass; evaluate() walks the already-typed tree and allocates nothing,
//! so a lens with up to the format's 256-trigger ceiling costs a bounded,
//! predictable amount of frame time with no GC-style pressure behind it.

const std = @import("std");
const face = @import("face");
const hand = @import("hand");
const pose = @import("pose");

pub const max_depth = 8;

pub const SignalKind = enum {
    face_blendshape,
    face_present,
    audio_beat,
    hands_present,
    world_tracking_state,
    audio_level,
    audio_beat_count,
    flash_risk,
    voice_command,
    timer,
    tap,
    param,
    event,
    geo_in_region,
    geo_named_region,
    camera_zoom,
    camera_focus,
    camera_exposure,
    gaze_x,
    gaze_y,
    looking_at_camera,
    head_nod,
    head_shake,
    head_tilt,
    hand_gesture,
    hand_custom_gesture,
    hand_pinch,
    body_present,
    foot_present,
    pet_present,
    pet_expression,
    bone_angle,
    body_jump,
    body_wave,
    body_dance,
    device_in_volume,
    hand_in_region,
    touch_double_tap,
    touch_long_press,
    touch_swipe,
    touch_drag,
    touch_pinch,
    touch_rotate,
    pointer_x,
    pointer_y,
    counter,
};

fn signalIsBoolean(kind: SignalKind) bool {
    return switch (kind) {
        .face_present, .hands_present, .tap, .audio_beat, .event, .voice_command, .geo_in_region, .geo_named_region, .camera_focus, .camera_exposure, .looking_at_camera, .head_nod, .head_shake, .hand_gesture, .hand_custom_gesture, .hand_pinch, .body_present, .foot_present, .pet_present, .body_jump, .body_wave, .body_dance, .device_in_volume, .hand_in_region, .touch_double_tap, .touch_long_press, .touch_swipe, .touch_drag => true,
        .face_blendshape, .world_tracking_state, .audio_level, .audio_beat_count, .flash_risk, .pet_expression, .timer, .param, .camera_zoom, .gaze_x, .gaze_y, .head_tilt, .bone_angle, .touch_pinch, .touch_rotate, .pointer_x, .pointer_y, .counter => false,
    };
}

/// The swipe direction classes a lens names, matching the recognizer's own
/// order so touch.swipe('left') reads the value the engine feeds. Zero is no
/// swipe, the resting value most ticks carry.
fn swipeDirIndex(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "left")) return 1;
    if (std.mem.eql(u8, name, "right")) return 2;
    if (std.mem.eql(u8, name, "up")) return 3;
    if (std.mem.eql(u8, name, "down")) return 4;
    return null;
}

pub const Signal = struct {
    kind: SignalKind,
    blendshape_index: u8 = 0,
    gesture_index: u8 = 0,
    bone_index: u8 = 0,
    swipe_dir: u8 = 0,
    param_index: u16 = 0,
    timer_name: []const u8 = "",
    event_name: []const u8 = "",
    counter_name: []const u8 = "",
};

pub const CompareOp = enum { gt, lt, ge, le, eq, ne };

pub const Literal = union(enum) {
    number: f64,
    boolean: bool,
};

pub const Compare = struct { signal: Signal, op: CompareOp, literal: Literal };
pub const Combine = struct { lhs: *const Node, rhs: *const Node };

pub const Node = union(enum) {
    signal_bool: Signal,
    compare: Compare,
    not: *const Node,
    and_: Combine,
    or_: Combine,
};

pub const Expression = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Node,

    pub fn deinit(self: *Expression) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const TimerValue = struct { name: []const u8, seconds: f32 };
pub const CounterValue = struct { name: []const u8, value: f64 };

/// The live values a compiled expression reads at evaluation time. params
/// mirrors the manifest's parameter list by index, numeric-cast (a bool
/// param reads as 0/1; color params are not readable from an expression
/// and read as 0, since the grammar has no vector comparison).
pub const Signals = struct {
    face_present: bool = false,
    hands_present: bool = false,
    world_tracking_state: f64 = 0,
    audio_level: f64 = 0,
    audio_beat: bool = false,
    audio_beat_count: f64 = 0,
    /// The engine's photosensitivity risk (0..1) from the frame's flashing rate,
    /// engine-fed at tick, so a lens softens or gates a strobing effect when
    /// `safety.flash_risk > 0.5`. Zero when the frame is steady.
    flash_risk: f64 = 0,
    tap: bool = false,
    blendshapes: ?*const [face.blendshape_count]f32 = null,
    params: []const f64 = &.{},
    timers: []const TimerValue = &.{},
    /// The lens's counters, each a value that persists across ticks and changes
    /// only when a trigger increments, resets, or sets it. Read as counter('name').
    counters: []const CounterValue = &.{},
    /// The event names the host fired this tick (goss_session_fire_event). An
    /// event is present only for the tick it is fired, so an edge-triggered
    /// action fires exactly once.
    events: []const []const u8 = &.{},
    /// Whether the submitted location is inside the session's geofence, computed
    /// on-device from goss_session_submit_location; the location never crosses
    /// the ABI, only this boolean.
    geo_in_region: bool = false,
    /// The names of the host's named geofences the current fix is inside, so
    /// geo.in_region('name') fires for its own place. Empty with no fix or no
    /// named region matched; borrows the session's store for the tick.
    geo_regions: []const []const u8 = &.{},
    /// The latest speech the on-device captioner decoded, lowercased, so
    /// voice.command('phrase') fires when its phrase is spoken. Engine-fed at
    /// tick from the captioning audio.infer worker; empty with no speech. Only
    /// the recognized text crosses, never the audio.
    voice_command_text: []const u8 = &.{},
    /// Whether the tracked device is inside the lens's trigger volume, computed
    /// on-device each tick from the submitted world pose and the manifest's
    /// volume region. False with no world tracking or no volume declared.
    device_in_volume: bool = false,
    /// Whether a tracked hand's index fingertip is inside the lens's 2D trigger
    /// rectangle, computed on-device each tick from the hand landmarks and the
    /// manifest's region2d. False with no hand tracking or no region declared.
    hand_in_region: bool = false,
    /// The camera's current zoom factor, engine-fed at tick from the session's
    /// camera controls, so a lens fires an effect on zoom (`camera.zoom > 2`).
    /// One means no zoom, the resting value before any control is set.
    camera_zoom: f64 = 1,
    /// True for exactly the tick after the app changed focus or exposure through
    /// the camera controls, a one-tick pulse an edge-triggered action reads once.
    camera_focus: bool = false,
    camera_exposure: bool = false,
    /// One-tick pulses set the tick a nod (pitch oscillation) or shake (yaw
    /// oscillation) completes, detected on-device from the head-pose history;
    /// the raw pose never crosses the ABI, only these edges do. A refractory
    /// window makes each completed gesture fire exactly once.
    head_nod: bool = false,
    head_shake: bool = false,
    /// Current head roll (radians, positive tipping to the person's left), a
    /// sustained level a lens compares (`head.tilt > 0.3`). Zero is upright.
    head_tilt: f64 = 0,
    /// The gesture a tracked hand is showing, an index into the canned
    /// gesture classes, engine-fed at tick from the hand worker. Zero is the
    /// no-gesture class, the resting value with no hand or no gesture.
    hand_gesture: u32 = 0,
    /// A bit per lens-declared custom gesture that a tracked hand currently
    /// matches (bit i for the i-th gesture in the manifest), engine-fed at tick
    /// from the hand landmarks. Zero with no hand or no match.
    hand_custom_gestures: u32 = 0,
    /// True while a tracked hand's thumb and index tips are pinched together,
    /// engine-fed at tick from the hand landmarks. False with no hand.
    hand_pinch: bool = false,
    /// True while a body is tracked, engine-fed at tick from the pose worker.
    body_present: bool = false,
    /// True while a foot is tracked, engine-fed at tick from the pose worker's
    /// ankle and foot landmark visibility, so a lens reacts to feet in frame.
    foot_present: bool = false,
    /// True while a pet is tracked and the pet's expression strength (0..1),
    /// engine-fed at tick from a bring-your-own pet model's ml.infer outputs
    /// (the reserved `pet_present`/`pet_expression` parameters).
    pet_present: bool = false,
    pet_expression: f64 = 0,
    /// Each tracked bone's current bend angle in radians, engine-fed at tick
    /// from the pose landmarks, or null with no body. A lens compares one by
    /// name (`body.bone_angle('left_elbow') < 1.5`).
    bone_angles: ?*const [pose.bone_count]f32 = null,
    /// One-tick pulses set the tick a jump (a hop up and back) or a wave (a
    /// raised hand swinging sideways) completes; body_dance stays true while
    /// rhythmic whole-body motion lasts. Detected on-device from the pose ring.
    body_jump: bool = false,
    body_wave: bool = false,
    body_dance: bool = false,
    /// Screen gestures the on-device recognizer completed this tick, fed from
    /// the host touch stream. The tap edge rides the existing tap signal; these
    /// carry the richer ones. touch_swipe is a direction class (0 none, 1 left,
    /// 2 right, 3 up, 4 down) a lens matches with touch.swipe('left').
    touch_double_tap: bool = false,
    touch_long_press: bool = false,
    touch_swipe: u8 = 0,
    touch_drag: bool = false,
    /// Live two-finger levels: pinch is the current spread over the spread at
    /// gesture start (one at rest), rotate is signed radians since it started.
    touch_pinch: f64 = 1,
    touch_rotate: f64 = 0,
    /// The primary finger's last position, normalized 0..1 over the frame, so a
    /// lens reads where a tap or drag landed with pointer.x and pointer.y.
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
};

pub fn evaluate(node: *const Node, signals: Signals) bool {
    return switch (node.*) {
        .signal_bool => |s| readBool(s, signals),
        .compare => |c| compareValue(c, signals),
        .not => |inner| !evaluate(inner, signals),
        .and_ => |b| evaluate(b.lhs, signals) and evaluate(b.rhs, signals),
        .or_ => |b| evaluate(b.lhs, signals) or evaluate(b.rhs, signals),
    };
}

// The eye-gaze signals ride the eyeLook blendshapes the face model already
// produces, so gaze needs no new tracker output and never crosses the ABI.
const bs_look_in_left = face.blendshapeIndex("eyeLookInLeft").?;
const bs_look_in_right = face.blendshapeIndex("eyeLookInRight").?;
const bs_look_out_left = face.blendshapeIndex("eyeLookOutLeft").?;
const bs_look_out_right = face.blendshapeIndex("eyeLookOutRight").?;
const bs_look_up_left = face.blendshapeIndex("eyeLookUpLeft").?;
const bs_look_up_right = face.blendshapeIndex("eyeLookUpRight").?;
const bs_look_down_left = face.blendshapeIndex("eyeLookDownLeft").?;
const bs_look_down_right = face.blendshapeIndex("eyeLookDownRight").?;

/// How near centre gaze must be to count as looking at the camera.
const gaze_center_threshold = 0.2;

/// Horizontal (x, positive toward the subject's left) and vertical (y,
/// positive up) eye gaze in roughly [-1, 1], averaged over both eyes from
/// the eyeLook blendshapes. No face reads as centred (zero).
fn gazeXY(signals: Signals) [2]f64 {
    const bs = signals.blendshapes orelse return .{ 0, 0 };
    const x = 0.5 * ((bs[bs_look_out_left] + bs[bs_look_in_right]) - (bs[bs_look_in_left] + bs[bs_look_out_right]));
    const y = 0.5 * ((bs[bs_look_up_left] + bs[bs_look_up_right]) - (bs[bs_look_down_left] + bs[bs_look_down_right]));
    return .{ x, y };
}

fn readBool(s: Signal, signals: Signals) bool {
    return switch (s.kind) {
        .face_present => signals.face_present,
        .hands_present => signals.hands_present,
        .tap => signals.tap,
        .audio_beat => signals.audio_beat,
        .event => {
            for (signals.events) |name| {
                if (std.mem.eql(u8, name, s.event_name)) return true;
            }
            return false;
        },
        .voice_command => signals.voice_command_text.len > 0 and s.event_name.len > 0 and
            std.mem.indexOf(u8, signals.voice_command_text, s.event_name) != null,
        .geo_in_region => signals.geo_in_region,
        .geo_named_region => {
            for (signals.geo_regions) |name| {
                if (std.mem.eql(u8, name, s.event_name)) return true;
            }
            return false;
        },
        .device_in_volume => signals.device_in_volume,
        .hand_in_region => signals.hand_in_region,
        .camera_focus => signals.camera_focus,
        .camera_exposure => signals.camera_exposure,
        .looking_at_camera => {
            if (signals.blendshapes == null) return false;
            const g = gazeXY(signals);
            return @abs(g[0]) < gaze_center_threshold and @abs(g[1]) < gaze_center_threshold;
        },
        .head_nod => signals.head_nod,
        .head_shake => signals.head_shake,
        .hand_gesture => signals.hand_gesture == s.gesture_index,
        .hand_custom_gesture => (signals.hand_custom_gestures >> @intCast(s.gesture_index)) & 1 != 0,
        .hand_pinch => signals.hand_pinch,
        .body_present => signals.body_present,
        .foot_present => signals.foot_present,
        .pet_present => signals.pet_present,
        .body_jump => signals.body_jump,
        .body_wave => signals.body_wave,
        .body_dance => signals.body_dance,
        .touch_double_tap => signals.touch_double_tap,
        .touch_long_press => signals.touch_long_press,
        .touch_swipe => signals.touch_swipe == s.swipe_dir,
        .touch_drag => signals.touch_drag,
        else => unreachable,
    };
}

fn readNumber(s: Signal, signals: Signals) f64 {
    return switch (s.kind) {
        .face_blendshape => if (signals.blendshapes) |bs| bs[s.blendshape_index] else 0,
        .world_tracking_state => signals.world_tracking_state,
        .audio_level => signals.audio_level,
        .audio_beat_count => signals.audio_beat_count,
        .flash_risk => signals.flash_risk,
        .pet_expression => signals.pet_expression,
        .timer => blk: {
            for (signals.timers) |tv| {
                if (std.mem.eql(u8, tv.name, s.timer_name)) break :blk tv.seconds;
            }
            break :blk 0;
        },
        .counter => blk: {
            for (signals.counters) |cv| {
                if (std.mem.eql(u8, cv.name, s.counter_name)) break :blk cv.value;
            }
            break :blk 0;
        },
        .param => if (s.param_index < signals.params.len) signals.params[s.param_index] else 0,
        .camera_zoom => signals.camera_zoom,
        .gaze_x => gazeXY(signals)[0],
        .gaze_y => gazeXY(signals)[1],
        .head_tilt => signals.head_tilt,
        .bone_angle => if (signals.bone_angles) |a| a[s.bone_index] else 0,
        .touch_pinch => signals.touch_pinch,
        .touch_rotate => signals.touch_rotate,
        .pointer_x => signals.pointer_x,
        .pointer_y => signals.pointer_y,
        else => unreachable,
    };
}

fn compareValue(c: Compare, signals: Signals) bool {
    switch (c.literal) {
        .boolean => |lit| {
            const value = readBool(c.signal, signals);
            return switch (c.op) {
                .eq => value == lit,
                .ne => value != lit,
                .gt, .lt, .ge, .le => false,
            };
        },
        .number => |lit| {
            const value = readNumber(c.signal, signals);
            return switch (c.op) {
                .gt => value > lit,
                .lt => value < lit,
                .ge => value >= lit,
                .le => value <= lit,
                .eq => value == lit,
                .ne => value != lit,
            };
        },
    }
}

pub const CompileError = struct {
    message: []const u8,
    offset: usize,
};

const Token = union(enum) {
    ident: []const u8,
    string: []const u8,
    number: f64,
    dot,
    lparen,
    rparen,
    op_and,
    op_or,
    op_not,
    op_gt,
    op_lt,
    op_ge,
    op_le,
    op_eq,
    op_ne,
    end,
};

const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Tokenizer) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) self.pos += 1;
    }

    fn next(self: *Tokenizer) !Token {
        self.skipSpace();
        if (self.pos >= self.source.len) return .end;
        const c = self.source[self.pos];
        switch (c) {
            '.' => {
                self.pos += 1;
                return .dot;
            },
            '(' => {
                self.pos += 1;
                return .lparen;
            },
            ')' => {
                self.pos += 1;
                return .rparen;
            },
            '\'' => {
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.source.len and self.source[self.pos] != '\'') self.pos += 1;
                if (self.pos >= self.source.len) return error.UnterminatedString;
                const s = self.source[start..self.pos];
                self.pos += 1;
                return .{ .string = s };
            },
            '&' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '&') {
                    self.pos += 2;
                    return .op_and;
                }
                return error.UnexpectedCharacter;
            },
            '|' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '|') {
                    self.pos += 2;
                    return .op_or;
                }
                return error.UnexpectedCharacter;
            },
            '!' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_ne;
                }
                self.pos += 1;
                return .op_not;
            },
            '=' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_eq;
                }
                return error.UnexpectedCharacter;
            },
            '>' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_ge;
                }
                self.pos += 1;
                return .op_gt;
            },
            '<' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_le;
                }
                self.pos += 1;
                return .op_lt;
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    const start = self.pos;
                    while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) self.pos += 1;
                    return .{ .ident = self.source[start..self.pos] };
                }
                if (std.ascii.isDigit(c) or c == '-') {
                    const start = self.pos;
                    self.pos += 1;
                    while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '.')) self.pos += 1;
                    const n = std.fmt.parseFloat(f64, self.source[start..self.pos]) catch return error.InvalidNumber;
                    return .{ .number = n };
                }
                return error.UnexpectedCharacter;
            },
        }
    }
};

const Parser = struct {
    tok: Tokenizer,
    current: Token,
    arena: std.mem.Allocator,
    diag_arena: std.mem.Allocator,
    param_names: []const []const u8,
    gesture_names: []const []const u8 = &.{},
    depth: u32 = 0,
    err: ?CompileError = null,

    // Diagnostic messages allocate from diag_arena, never from arena: on a
    // failed compile the caller frees arena (the would-be Expression's own
    // tree) but keeps the diagnostic, so the two must be independent.
    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, Compile } {
        if (self.err == null) {
            self.err = .{
                .message = std.fmt.allocPrint(self.diag_arena, fmt, args) catch return error.OutOfMemory,
                .offset = self.tok.pos,
            };
        }
        return error.Compile;
    }

    fn advance(self: *Parser) !void {
        self.current = self.tok.next() catch |e| return self.fail("bad token: {t}", .{e});
    }

    fn expect(self: *Parser, comptime tag: std.meta.Tag(Token)) !void {
        if (self.current != tag) {
            return self.fail("expected {s}", .{@tagName(tag)});
        }
        try self.advance();
    }

    fn enterNesting(self: *Parser) !void {
        self.depth += 1;
        if (self.depth > max_depth) {
            return self.fail("nests past a depth of {d}", .{max_depth});
        }
    }

    fn newNode(self: *Parser, node: Node) error{OutOfMemory}!*const Node {
        const ptr = try self.arena.create(Node);
        ptr.* = node;
        return ptr;
    }

    fn parseExpr(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        var lhs = try self.parseAnd();
        while (self.current == .op_or) {
            try self.enterNesting();
            try self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.newNode(.{ .or_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        var lhs = try self.parseUnary();
        while (self.current == .op_and) {
            try self.enterNesting();
            try self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.newNode(.{ .and_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        if (self.current == .op_not) {
            try self.enterNesting();
            try self.advance();
            const inner = try self.parseUnary();
            return self.newNode(.{ .not = inner });
        }
        return self.parseAtom();
    }

    fn parseAtom(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        if (self.current == .lparen) {
            try self.enterNesting();
            try self.advance();
            const inner = try self.parseExpr();
            try self.expect(.rparen);
            self.depth -= 1;
            return inner;
        }
        const signal = try self.parseSignal();
        switch (self.current) {
            .op_gt, .op_lt, .op_ge, .op_le, .op_eq, .op_ne => {
                const op: CompareOp = switch (self.current) {
                    .op_gt => .gt,
                    .op_lt => .lt,
                    .op_ge => .ge,
                    .op_le => .le,
                    .op_eq => .eq,
                    .op_ne => .ne,
                    else => unreachable,
                };
                try self.advance();
                const literal = try self.parseLiteral();
                if (signalIsBoolean(signal.kind) and literal == .number) {
                    return self.fail("boolean signal compared to a number", .{});
                }
                if (!signalIsBoolean(signal.kind) and literal == .boolean) {
                    return self.fail("numeric signal compared to a bool", .{});
                }
                if ((op == .gt or op == .lt or op == .ge or op == .le) and literal == .boolean) {
                    return self.fail("ordering operators do not apply to bool", .{});
                }
                return self.newNode(.{ .compare = .{ .signal = signal, .op = op, .literal = literal } });
            },
            else => {
                if (!signalIsBoolean(signal.kind)) {
                    return self.fail("a numeric signal needs a comparison", .{});
                }
                return self.newNode(.{ .signal_bool = signal });
            },
        }
    }

    fn parseLiteral(self: *Parser) error{ OutOfMemory, Compile }!Literal {
        switch (self.current) {
            .number => |n| {
                try self.advance();
                return .{ .number = n };
            },
            .ident => |name| {
                if (std.mem.eql(u8, name, "true")) {
                    try self.advance();
                    return .{ .boolean = true };
                }
                if (std.mem.eql(u8, name, "false")) {
                    try self.advance();
                    return .{ .boolean = false };
                }
                return self.fail("expected a number, true, or false", .{});
            },
            else => {
                return self.fail("expected a literal", .{});
            },
        }
    }

    fn parseCall(self: *Parser) error{ OutOfMemory, Compile }![]const u8 {
        try self.expect(.lparen);
        const s = switch (self.current) {
            .string => |s| s,
            else => {
                return self.fail("expected a string argument", .{});
            },
        };
        try self.advance();
        try self.expect(.rparen);
        return s;
    }

    fn parseSignal(self: *Parser) error{ OutOfMemory, Compile }!Signal {
        const head = switch (self.current) {
            .ident => |name| name,
            else => {
                return self.fail("expected a signal", .{});
            },
        };
        try self.advance();

        if (std.mem.eql(u8, head, "tap")) return .{ .kind = .tap };
        if (std.mem.eql(u8, head, "timer")) {
            const name = try self.parseCall();
            return .{ .kind = .timer, .timer_name = try self.arena.dupe(u8, name) };
        }
        if (std.mem.eql(u8, head, "counter")) {
            const name = try self.parseCall();
            return .{ .kind = .counter, .counter_name = try self.arena.dupe(u8, name) };
        }
        if (std.mem.eql(u8, head, "param")) {
            const name = try self.parseCall();
            for (self.param_names, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, name)) return .{ .kind = .param, .param_index = @intCast(i) };
            }
            return self.fail("unknown parameter '{s}'", .{name});
        }
        if (std.mem.eql(u8, head, "event")) {
            const name = try self.parseCall();
            return .{ .kind = .event, .event_name = try self.arena.dupe(u8, name) };
        }

        try self.expect(.dot);
        const tail = switch (self.current) {
            .ident => |name| name,
            else => {
                return self.fail("expected a field after '{s}.'", .{head});
            },
        };
        try self.advance();

        if (std.mem.eql(u8, head, "face")) {
            if (std.mem.eql(u8, tail, "present")) return .{ .kind = .face_present };
            if (std.mem.eql(u8, tail, "blendshape")) {
                const name = try self.parseCall();
                const index = face.blendshapeIndex(name) orelse {
                    return self.fail("unknown blendshape '{s}'", .{name});
                };
                return .{ .kind = .face_blendshape, .blendshape_index = index };
            }
            return self.fail("unknown face signal '{s}'", .{tail});
        }
        if (std.mem.eql(u8, head, "hands") and std.mem.eql(u8, tail, "present")) {
            return .{ .kind = .hands_present };
        }
        if (std.mem.eql(u8, head, "hands") and std.mem.eql(u8, tail, "gesture")) {
            const name = try self.parseCall();
            if (hand.gestureIndex(name)) |index| {
                return .{ .kind = .hand_gesture, .gesture_index = index };
            }
            // Not a canned class: resolve it against the lens's own declared
            // custom gestures, matched from finger poses at tick.
            for (self.gesture_names, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, name)) {
                    return .{ .kind = .hand_custom_gesture, .gesture_index = @intCast(i) };
                }
            }
            return self.fail("unknown gesture '{s}'", .{name});
        }
        if (std.mem.eql(u8, head, "hands") and std.mem.eql(u8, tail, "pinch")) {
            return .{ .kind = .hand_pinch };
        }
        if (std.mem.eql(u8, head, "world") and std.mem.eql(u8, tail, "tracking_state")) {
            return .{ .kind = .world_tracking_state };
        }
        if (std.mem.eql(u8, head, "geo") and std.mem.eql(u8, tail, "in_region")) {
            // Bare geo.in_region reads the single default geofence; with a name
            // it reads one of the host's named regions matched at tick.
            if (self.current == .lparen) {
                const name = try self.parseCall();
                return .{ .kind = .geo_named_region, .event_name = try self.arena.dupe(u8, name) };
            }
            return .{ .kind = .geo_in_region };
        }
        if (std.mem.eql(u8, head, "device") and std.mem.eql(u8, tail, "in_volume")) {
            return .{ .kind = .device_in_volume };
        }
        if (std.mem.eql(u8, head, "hand") and std.mem.eql(u8, tail, "in_region")) {
            return .{ .kind = .hand_in_region };
        }
        if (std.mem.eql(u8, head, "audio") and std.mem.eql(u8, tail, "level")) {
            return .{ .kind = .audio_level };
        }
        if (std.mem.eql(u8, head, "audio") and std.mem.eql(u8, tail, "beat")) {
            return .{ .kind = .audio_beat };
        }
        if (std.mem.eql(u8, head, "audio") and std.mem.eql(u8, tail, "beat_count")) {
            return .{ .kind = .audio_beat_count };
        }
        if (std.mem.eql(u8, head, "safety") and std.mem.eql(u8, tail, "flash_risk")) {
            return .{ .kind = .flash_risk };
        }
        if (std.mem.eql(u8, head, "voice") and std.mem.eql(u8, tail, "command")) {
            // The phrase is lowered once here so the tick match is case-insensitive.
            const phrase = try self.parseCall();
            const lowered = try self.arena.alloc(u8, phrase.len);
            for (phrase, 0..) |ch, i| lowered[i] = std.ascii.toLower(ch);
            return .{ .kind = .voice_command, .event_name = lowered };
        }
        if (std.mem.eql(u8, head, "camera") and std.mem.eql(u8, tail, "zoom")) {
            return .{ .kind = .camera_zoom };
        }
        if (std.mem.eql(u8, head, "camera") and std.mem.eql(u8, tail, "focus")) {
            return .{ .kind = .camera_focus };
        }
        if (std.mem.eql(u8, head, "camera") and std.mem.eql(u8, tail, "exposure")) {
            return .{ .kind = .camera_exposure };
        }
        if (std.mem.eql(u8, head, "gaze") and std.mem.eql(u8, tail, "x")) {
            return .{ .kind = .gaze_x };
        }
        if (std.mem.eql(u8, head, "gaze") and std.mem.eql(u8, tail, "y")) {
            return .{ .kind = .gaze_y };
        }
        if (std.mem.eql(u8, head, "gaze") and std.mem.eql(u8, tail, "at_camera")) {
            return .{ .kind = .looking_at_camera };
        }
        if (std.mem.eql(u8, head, "head") and std.mem.eql(u8, tail, "nod")) {
            return .{ .kind = .head_nod };
        }
        if (std.mem.eql(u8, head, "head") and std.mem.eql(u8, tail, "shake")) {
            return .{ .kind = .head_shake };
        }
        if (std.mem.eql(u8, head, "body") and std.mem.eql(u8, tail, "present")) {
            return .{ .kind = .body_present };
        }
        if (std.mem.eql(u8, head, "foot") and std.mem.eql(u8, tail, "present")) {
            return .{ .kind = .foot_present };
        }
        if (std.mem.eql(u8, head, "pet") and std.mem.eql(u8, tail, "present")) {
            return .{ .kind = .pet_present };
        }
        if (std.mem.eql(u8, head, "pet") and std.mem.eql(u8, tail, "expression")) {
            return .{ .kind = .pet_expression };
        }
        if (std.mem.eql(u8, head, "body") and std.mem.eql(u8, tail, "bone_angle")) {
            const name = try self.parseCall();
            const index = pose.boneIndex(name) orelse {
                return self.fail("unknown bone '{s}'", .{name});
            };
            return .{ .kind = .bone_angle, .bone_index = index };
        }
        if (std.mem.eql(u8, head, "body") and std.mem.eql(u8, tail, "jump")) {
            return .{ .kind = .body_jump };
        }
        if (std.mem.eql(u8, head, "body") and std.mem.eql(u8, tail, "wave")) {
            return .{ .kind = .body_wave };
        }
        if (std.mem.eql(u8, head, "body") and std.mem.eql(u8, tail, "dance")) {
            return .{ .kind = .body_dance };
        }
        if (std.mem.eql(u8, head, "head") and std.mem.eql(u8, tail, "tilt")) {
            return .{ .kind = .head_tilt };
        }
        if (std.mem.eql(u8, head, "touch")) {
            if (std.mem.eql(u8, tail, "doubleTap")) return .{ .kind = .touch_double_tap };
            if (std.mem.eql(u8, tail, "longPress")) return .{ .kind = .touch_long_press };
            if (std.mem.eql(u8, tail, "drag")) return .{ .kind = .touch_drag };
            if (std.mem.eql(u8, tail, "pinch")) return .{ .kind = .touch_pinch };
            if (std.mem.eql(u8, tail, "rotate")) return .{ .kind = .touch_rotate };
            if (std.mem.eql(u8, tail, "swipe")) {
                const name = try self.parseCall();
                const dir = swipeDirIndex(name) orelse {
                    return self.fail("unknown swipe direction '{s}'", .{name});
                };
                return .{ .kind = .touch_swipe, .swipe_dir = dir };
            }
            return self.fail("unknown touch signal '{s}'", .{tail});
        }
        if (std.mem.eql(u8, head, "pointer")) {
            if (std.mem.eql(u8, tail, "x")) return .{ .kind = .pointer_x };
            if (std.mem.eql(u8, tail, "y")) return .{ .kind = .pointer_y };
            return self.fail("unknown pointer signal '{s}'", .{tail});
        }
        return self.fail("unknown signal '{s}.{s}'", .{ head, tail });
    }
};

/// Reads one signal's numeric value, a boolean as 0 or 1, the value a logic
/// graph's signal leaf feeds. Shares the trigger evaluator's own readers.
pub fn signalValue(s: Signal, signals: Signals) f64 {
    return if (signalIsBoolean(s.kind)) (if (readBool(s, signals)) @as(f64, 1) else 0) else readNumber(s, signals);
}

/// Compiles one bare signal expression (pointer.x, counter('score'), a
/// blendshape name) to a Signal a logic graph reads with signalValue: no
/// comparison or combinator, just the one signal. Name slices dupe into arena;
/// returns null with err set on a parse failure.
pub fn compileSignal(arena: std.mem.Allocator, diag_arena: std.mem.Allocator, source: []const u8, param_names: []const []const u8, gesture_names: []const []const u8, err: *?CompileError) error{OutOfMemory}!?Signal {
    var parser = Parser{
        .tok = .{ .source = source },
        .current = undefined,
        .arena = arena,
        .diag_arena = diag_arena,
        .param_names = param_names,
        .gesture_names = gesture_names,
    };
    parser.advance() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => {
            err.* = parser.err;
            return null;
        },
    };
    const s = parser.parseSignal() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => {
            err.* = parser.err;
            return null;
        },
    };
    if (parser.current != .end) {
        err.* = .{ .message = try std.fmt.allocPrint(diag_arena, "unexpected trailing input", .{}), .offset = parser.tok.pos };
        return null;
    }
    return s;
}

/// Compiles one `when` expression source string against the spec grammar.
/// param_names resolves `param('name')` reads the same way the manifest
/// cross-references parameter targets - an unresolvable name is a compile
/// failure, not a runtime one. Returns null with err populated on failure;
/// err's message allocates from diag_arena (independent of the Expression's
/// own arena, which is freed before returning on any failure path).
pub fn compile(gpa: std.mem.Allocator, diag_arena: std.mem.Allocator, source: []const u8, param_names: []const []const u8, gesture_names: []const []const u8, err: *?CompileError) error{OutOfMemory}!?Expression {
    var expr = Expression{ .arena = std.heap.ArenaAllocator.init(gpa), .root = undefined };
    errdefer expr.arena.deinit();
    const arena = expr.arena.allocator();

    var parser = Parser{
        .tok = .{ .source = source },
        .current = undefined,
        .arena = arena,
        .diag_arena = diag_arena,
        .param_names = param_names,
        .gesture_names = gesture_names,
    };
    parser.advance() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => {
            err.* = parser.err;
            expr.arena.deinit();
            return null;
        },
    };

    const root = parser.parseExpr() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => {
            err.* = parser.err;
            expr.arena.deinit();
            return null;
        },
    };
    if (parser.current != .end) {
        err.* = .{ .message = try std.fmt.allocPrint(diag_arena, "unexpected trailing input", .{}), .offset = parser.tok.pos };
        expr.arena.deinit();
        return null;
    }

    expr.root = root;
    return expr;
}

const t = std.testing;

fn compileOk(source: []const u8) !Expression {
    var err: ?CompileError = null;
    const result = try compile(t.allocator, t.allocator, source, &.{"smooth_amount"}, &.{"rock"}, &err);
    if (result == null) std.debug.print("compile error: {s} at {d}\n", .{ err.?.message, err.?.offset });
    return result orelse error.TestUnexpectedResult;
}

/// The message is allocated from t.allocator; the caller frees it with
/// t.allocator.free(err.message) once done reading it.
fn compileFails(source: []const u8) !CompileError {
    var err: ?CompileError = null;
    var result = try compile(t.allocator, t.allocator, source, &.{"smooth_amount"}, &.{"rock"}, &err);
    if (result) |*e| {
        e.deinit();
        return error.TestUnexpectedResult;
    }
    return err.?;
}

test "a bare boolean signal compiles and evaluates" {
    var expr = try compileOk("tap");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .tap = true }));
    try t.expect(!evaluate(expr.root, .{ .tap = false }));
}

test "a blendshape comparison resolves the real model index" {
    var expr = try compileOk("face.blendshape('jawOpen') > 0.6");
    defer expr.deinit();
    var shapes: [face.blendshape_count]f32 = @splat(0);
    shapes[face.blendshapeIndex("jawOpen").?] = 0.9;
    try t.expect(evaluate(expr.root, .{ .blendshapes = &shapes }));
    shapes[face.blendshapeIndex("jawOpen").?] = 0.1;
    try t.expect(!evaluate(expr.root, .{ .blendshapes = &shapes }));
}

test "an absent face reads every blendshape as zero, never crashes" {
    var expr = try compileOk("face.blendshape('jawOpen') > 0.6");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
}

test "combinators and parens nest correctly" {
    var expr = try compileOk("face.present && (tap || audio.level > 0.5)");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .face_present = true, .tap = true }));
    try t.expect(!evaluate(expr.root, .{ .face_present = false, .tap = true }));
    try t.expect(evaluate(expr.root, .{ .face_present = true, .audio_level = 0.9 }));
    try t.expect(!evaluate(expr.root, .{ .face_present = true, .tap = false, .audio_level = 0.1 }));
}

test "negation flips a boolean signal" {
    var expr = try compileOk("!face.present");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .face_present = false }));
    try t.expect(!evaluate(expr.root, .{ .face_present = true }));
}

test "timer reads by name from the caller-supplied live values" {
    var expr = try compileOk("timer('intro') > 2.0");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .timers = &.{.{ .name = "intro", .seconds = 3.0 }} }));
    try t.expect(!evaluate(expr.root, .{ .timers = &.{.{ .name = "intro", .seconds = 1.0 }} }));
    try t.expect(!evaluate(expr.root, .{ .timers = &.{} }));
}

test "param reads the caller-supplied numeric view by resolved index" {
    var expr = try compileOk("param('smooth_amount') >= 0.5");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .params = &.{0.7} }));
    try t.expect(!evaluate(expr.root, .{ .params = &.{0.2} }));
}

test "an unknown blendshape name fails to compile" {
    const err = try compileFails("face.blendshape('not_real') > 0.5");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown blendshape") != null);
}

test "hands.gesture matches the tracked gesture class by name" {
    var expr = try compileOk("hands.gesture('Thumb_Up')");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{})); // resting None gesture
    try t.expect(!evaluate(expr.root, .{ .hand_gesture = hand.gestureIndex("Open_Palm").? }));
    try t.expect(evaluate(expr.root, .{ .hand_gesture = hand.gestureIndex("Thumb_Up").? }));

    const err = try compileFails("hands.gesture('Nope')");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown gesture") != null);
}

test "hands.gesture resolves a lens-declared custom gesture off its match bit" {
    // compileOk declares one custom gesture, "rock", at index 0.
    var expr = try compileOk("hands.gesture('rock')");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .hand_custom_gestures = 0b1 }));
    // A different custom gesture's bit does not fire this one.
    try t.expect(!evaluate(expr.root, .{ .hand_custom_gestures = 0b10 }));
}

test "hands.pinch reads the fed pinch state" {
    var expr = try compileOk("hands.pinch");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .hand_pinch = true }));
}

test "body.present reads the fed pose presence" {
    var expr = try compileOk("body.present");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .body_present = true }));
}

test "foot.present reads the fed foot presence" {
    var expr = try compileOk("foot.present");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .foot_present = true }));
}

test "pet.present and pet.expression read the fed pet signals" {
    var present = try compileOk("pet.present");
    defer present.deinit();
    try t.expect(!evaluate(present.root, .{}));
    try t.expect(evaluate(present.root, .{ .pet_present = true }));

    var happy = try compileOk("pet.expression > 0.6");
    defer happy.deinit();
    try t.expect(!evaluate(happy.root, .{ .pet_expression = 0.3 }));
    try t.expect(evaluate(happy.root, .{ .pet_expression = 0.8 }));
}

test "touch double tap and long press read the fed edges" {
    var dbl = try compileOk("touch.doubleTap");
    defer dbl.deinit();
    try t.expect(!evaluate(dbl.root, .{}));
    try t.expect(evaluate(dbl.root, .{ .touch_double_tap = true }));
    var long = try compileOk("touch.longPress");
    defer long.deinit();
    try t.expect(evaluate(long.root, .{ .touch_long_press = true }));
}

test "touch.swipe matches only the fed direction" {
    var left = try compileOk("touch.swipe('left')");
    defer left.deinit();
    try t.expect(!evaluate(left.root, .{}));
    try t.expect(evaluate(left.root, .{ .touch_swipe = 1 }));
    try t.expect(!evaluate(left.root, .{ .touch_swipe = 2 }));
    const err = try compileFails("touch.swipe('nowhere')");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown swipe") != null);
}

test "touch pinch, rotate and pointer read as levels" {
    var pinch = try compileOk("touch.pinch > 1.4");
    defer pinch.deinit();
    try t.expect(!evaluate(pinch.root, .{ .touch_pinch = 1 }));
    try t.expect(evaluate(pinch.root, .{ .touch_pinch = 1.6 }));
    var px = try compileOk("pointer.x > 0.5");
    defer px.deinit();
    try t.expect(evaluate(px.root, .{ .pointer_x = 0.7 }));
    try t.expect(!evaluate(px.root, .{ .pointer_x = 0.2 }));
}

test "counter reads the fed counter value by name" {
    var expr = try compileOk("counter('score') >= 3");
    defer expr.deinit();
    const low = [_]CounterValue{.{ .name = "score", .value = 2 }};
    try t.expect(!evaluate(expr.root, .{ .counters = &low }));
    const hi = [_]CounterValue{.{ .name = "score", .value = 3 }};
    try t.expect(evaluate(expr.root, .{ .counters = &hi }));
    // An unknown counter reads zero.
    try t.expect(!evaluate(expr.root, .{}));
}

test "body.bone_angle compares the fed bend of a named bone" {
    var expr = try compileOk("body.bone_angle('right_knee') > 2.0");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{})); // no body reads zero, not straight
    var angles: [pose.bone_count]f32 = @splat(0);
    angles[pose.boneIndex("right_knee").?] = 2.8; // a nearly straight knee
    try t.expect(evaluate(expr.root, .{ .bone_angles = &angles }));
    angles[pose.boneIndex("right_knee").?] = 1.0; // deeply bent
    try t.expect(!evaluate(expr.root, .{ .bone_angles = &angles }));

    const err = try compileFails("body.bone_angle('nope')");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown bone") != null);
}

test "body.jump, wave, and dance read the fed action pulses" {
    var expr = try compileOk("body.jump || body.wave || body.dance");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .body_jump = true }));
    try t.expect(evaluate(expr.root, .{ .body_wave = true }));
    try t.expect(evaluate(expr.root, .{ .body_dance = true }));
}

test "an unknown parameter name fails to compile" {
    const err = try compileFails("param('not_declared') > 0.5");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown parameter") != null);
}

test "a boolean signal cannot compare against a number" {
    const err = try compileFails("tap > 0.5");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "boolean signal") != null);
}

test "a numeric signal used bare needs a comparison" {
    const err = try compileFails("audio.level");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "needs a comparison") != null);
}

test "nesting past the depth limit is rejected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    for (0..max_depth + 2) |_| try buf.appendSlice(t.allocator, "(");
    try buf.appendSlice(t.allocator, "tap");
    for (0..max_depth + 2) |_| try buf.appendSlice(t.allocator, ")");
    const err = try compileFails(buf.items);
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "depth") != null);
}

test "trailing garbage after a valid expression is rejected" {
    const err = try compileFails("tap tap");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "trailing") != null);
}

test "audio.beat compiles as a boolean signal and reads live" {
    var expr = try compileOk("audio.beat");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .audio_beat = true }));
}

test "event fires only when its name is in the tick's fired set" {
    var expr = try compileOk("event('celebrate')");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(!evaluate(expr.root, .{ .events = &.{"other"} }));
    try t.expect(evaluate(expr.root, .{ .events = &.{"celebrate"} }));
    try t.expect(evaluate(expr.root, .{ .events = &.{ "other", "celebrate" } }));
}

test "voice.command fires when its phrase appears in the recognized speech" {
    var expr = try compileOk("voice.command('next slide')");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    // A case-insensitive substring match, so it fires inside a longer utterance.
    try t.expect(!evaluate(expr.root, .{ .voice_command_text = "go back please" }));
    try t.expect(evaluate(expr.root, .{ .voice_command_text = "next slide" }));
    try t.expect(evaluate(expr.root, .{ .voice_command_text = "okay, next slide now" }));
}

test "device.in_volume reads the on-device volume-membership boolean" {
    var expr = try compileOk("device.in_volume");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .device_in_volume = true }));
}

test "geo.in_region reads the on-device membership boolean" {
    var expr = try compileOk("geo.in_region");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .geo_in_region = true }));
}

test "geo.in_region('name') reads its own named region among the matched set" {
    var expr = try compileOk("geo.in_region('downtown')");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    // The default region boolean does not fire a named check.
    try t.expect(!evaluate(expr.root, .{ .geo_in_region = true }));
    try t.expect(!evaluate(expr.root, .{ .geo_regions = &.{"harbor"} }));
    try t.expect(evaluate(expr.root, .{ .geo_regions = &.{ "harbor", "downtown" } }));
}

test "hand.in_region reads the on-device fingertip-membership boolean" {
    var expr = try compileOk("hand.in_region");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
    try t.expect(evaluate(expr.root, .{ .hand_in_region = true }));
}

test "camera.zoom compiles as a numeric signal and compares live" {
    var expr = try compileOk("camera.zoom > 2");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{})); // resting zoom of 1 is not past 2
    try t.expect(!evaluate(expr.root, .{ .camera_zoom = 2 })); // exactly 2 is not past it
    try t.expect(evaluate(expr.root, .{ .camera_zoom = 3 })); // zoomed in past 2
}

test "camera.focus and camera.exposure read the one-tick change pulses" {
    var f = try compileOk("camera.focus");
    defer f.deinit();
    try t.expect(!evaluate(f.root, .{}));
    try t.expect(evaluate(f.root, .{ .camera_focus = true }));
    var e = try compileOk("camera.exposure");
    defer e.deinit();
    try t.expect(!evaluate(e.root, .{}));
    try t.expect(evaluate(e.root, .{ .camera_exposure = true }));
}

test "gaze reads from the eyeLook blendshapes and centres with no face" {
    var shapes = [_]f32{0} ** face.blendshape_count;
    // Both eyes turned to the subject's left: left eye out, right eye in.
    shapes[face.blendshapeIndex("eyeLookOutLeft").?] = 0.8;
    shapes[face.blendshapeIndex("eyeLookInRight").?] = 0.8;

    var gx = try compileOk("gaze.x > 0.3");
    defer gx.deinit();
    try t.expect(!evaluate(gx.root, .{})); // no face reads centred, not past 0.3
    try t.expect(evaluate(gx.root, .{ .blendshapes = &shapes }));

    var at = try compileOk("gaze.at_camera");
    defer at.deinit();
    try t.expect(!evaluate(at.root, .{})); // no face is not looking at the camera
    var centred = [_]f32{0} ** face.blendshape_count;
    try t.expect(evaluate(at.root, .{ .blendshapes = &centred })); // neutral eyes
    try t.expect(!evaluate(at.root, .{ .blendshapes = &shapes })); // gaze off to the side
}

test "head nod, shake, and tilt read the fed pose gestures" {
    var nod = try compileOk("head.nod");
    defer nod.deinit();
    try t.expect(!evaluate(nod.root, .{}));
    try t.expect(evaluate(nod.root, .{ .head_nod = true }));

    var shake = try compileOk("head.shake");
    defer shake.deinit();
    try t.expect(!evaluate(shake.root, .{}));
    try t.expect(evaluate(shake.root, .{ .head_shake = true }));

    var tilt = try compileOk("head.tilt > 0.3");
    defer tilt.deinit();
    try t.expect(!evaluate(tilt.root, .{})); // upright is not past 0.3
    try t.expect(evaluate(tilt.root, .{ .head_tilt = 0.5 }));
}

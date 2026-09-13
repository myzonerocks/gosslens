//! Walks the analyzer through every declaration of a cross-compiled backend, methods
//! included. std's refAllDecls returns at once outside a test build, so an object built
//! with it proved nothing and passed over a type error a Linux runner caught at once.
const std = @import("std");
const backend = @import("screen_capture");

comptime {
    refAll(backend, 2);
}

/// Two deep: the module and the methods of the types it declares. Deeper walks into
/// std itself and fails on platforms this backend never asked about.
fn refAll(comptime T: type, comptime depth: u8) void {
    if (depth == 0) return;
    inline for (std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        if (@TypeOf(field) == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAll(field, depth - 1),
                else => {},
            }
        } else {
            _ = &field;
        }
    }
}

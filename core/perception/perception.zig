//! The perception rail's own contracts: one versioned record of what the engine
//! sees, and the JSON projection of it. Both live behind one module root because
//! the projection reads the record, and two modules over one file collide the
//! moment a compile pulls in both.

pub const snapshot = @import("snapshot.zig");
pub const json = @import("json.zig");
pub const events = @import("events.zig");

pub const schema_version = snapshot.schema_version;
pub const Tag = snapshot.Tag;
pub const Select = snapshot.Select;
pub const Writer = snapshot.Writer;
pub const Reader = snapshot.Reader;
pub const Section = snapshot.Section;

pub const Event = events.Event;
pub const EventKind = events.Kind;
pub const EventRing = events.Ring;

test {
    @import("std").testing.refAllDecls(@This());
}

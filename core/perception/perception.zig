//! The perception rail's own contracts: one versioned record of what the engine
//! sees, and the JSON projection of it. Both live behind one module root because
//! the projection reads the record, and two modules over one file collide the
//! moment a compile pulls in both.

pub const snapshot = @import("snapshot.zig");
pub const json = @import("json.zig");
pub const schema = @import("schema.zig");
pub const scope = @import("scope.zig");
pub const events = @import("events.zig");
pub const replay = @import("replay.zig");
pub const egress = @import("egress.zig");
pub const actions = @import("actions.zig");

pub const schema_version = snapshot.schema_version;
pub const Tag = snapshot.Tag;
pub const Select = snapshot.Select;
pub const Writer = snapshot.Writer;
pub const Reader = snapshot.Reader;
pub const Section = snapshot.Section;

pub const Event = events.Event;
pub const EventKind = events.Kind;
pub const EventRing = events.Ring;

pub const ReplayLog = replay.Log;
pub const ReplayEntry = replay.Entry;
pub const ReplayKind = replay.Kind;
pub const replayDiverges = replay.diverges;
pub const hashFrame = replay.hashFrame;

pub const EgressConfig = egress.Config;
pub const EgressPolicy = egress.Policy;
pub const EgressDecision = egress.Decision;
pub const EgressReason = egress.Reason;
pub const changeScore = egress.changeScore;
pub const redactRect = egress.redactRect;
pub const RedactMode = egress.RedactMode;
pub const Rect = egress.Rect;

pub const Annotation = actions.Annotation;
pub const AnnotationKind = actions.Kind;
pub const AnchorSpace = actions.AnchorSpace;
pub const OnLost = actions.OnLost;
pub const AnnotationStore = actions.Store;

test {
    @import("std").testing.refAllDecls(@This());
}

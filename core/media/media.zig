//! The media module root. Only Gosslens-owned contracts leave here: an adapter
//! implements them, and no platform type appears in any signature below.

pub const types = @import("types.zig");
pub const packet = @import("packet.zig");
pub const codec = @import("codec.zig");
pub const container = @import("container.zig");
pub const sync = @import("sync.zig");
pub const capabilities = @import("capabilities.zig");
pub const demux = @import("demux.zig");
pub const color_reference = @import("color_reference.zig");

pub const VideoCodec = types.VideoCodec;
pub const AudioCodec = types.AudioCodec;
pub const Container = types.Container;
pub const PixelFormat = types.PixelFormat;
pub const ColorInfo = types.ColorInfo;
pub const Orientation = types.Orientation;
pub const RawVideoDesc = types.RawVideoDesc;
pub const EncodedVideoDesc = types.EncodedVideoDesc;
pub const EncodedAudioDesc = types.EncodedAudioDesc;

pub const Timebase = packet.Timebase;
pub const Packet = packet.Packet;

pub const CodecState = codec.State;
pub const CodecMachine = codec.Machine;
pub const EncoderConfig = codec.EncoderConfig;
pub const DecoderConfig = codec.DecoderConfig;

pub const Track = container.Track;
pub const TrackKind = container.TrackKind;
pub const Discontinuity = container.Discontinuity;
pub const Muxer = container.Muxer;
pub const MuxState = container.MuxState;

pub const Clock = sync.Clock;

pub const Demuxer = demux.Demuxer;
pub const DemuxState = demux.State;
pub const SeekMode = demux.SeekMode;
pub const FrameCache = demux.FrameCache;

pub const MatrixStandard = types.MatrixStandard;
pub const matrixStandard = types.matrixStandard;
pub const isFullRange = types.isFullRange;
pub const yuvToRgb8 = color_reference.yuvToRgb8;
pub const maxChannelDelta = color_reference.maxChannelDelta;

pub const Backend = capabilities.Backend;
pub const Request = capabilities.Request;
pub const selectBackend = capabilities.select;

test {
    @import("std").testing.refAllDecls(@This());
}

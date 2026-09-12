import Testing
@testable import Gosslens

/// The Swift SDK's own unit suite, at the TypeScript suite's scope: the values
/// the C ABI freezes and the pure packing that carries them across. None of
/// these calls an engine function, so they check the wrapper rather than the
/// engine, and a wrong shift fails here instead of as an upside-down preview.
@Suite("Frame descriptor packing")
struct FrameDescTests {
    @Test("an upright unmirrored frame carries no flags")
    func uprightCarriesNoFlags() {
        let desc = GossFrameDesc(width: 1280, height: 720, pixelFormat: .nv12)
        #expect(desc.raw.flags == 0)
        #expect(desc.raw.width == 1280)
        #expect(desc.raw.height == 720)
    }

    @Test("a rotation packs as quarter turns above the shift")
    func rotationPacksAsQuarterTurns() {
        for (degrees, turns) in [(UInt32(90), UInt32(1)), (180, 2), (270, 3)] {
            let desc = GossFrameDesc(width: 2, height: 2, pixelFormat: .nv12, rotationDegrees: degrees)
            #expect(desc.raw.flags == turns << GOSS_FRAME_ROTATION_SHIFT)
        }
    }

    @Test("a mirror rides beside the rotation rather than over it")
    func mirrorRidesBesideRotation() {
        let desc = GossFrameDesc(width: 2, height: 2, pixelFormat: .nv12, rotationDegrees: 90, mirrored: true)
        #expect(desc.raw.flags & GOSS_FRAME_FLAG_MIRROR != 0)
        #expect((desc.raw.flags >> GOSS_FRAME_ROTATION_SHIFT) & 0x3 == 1)
    }

    @Test("the colour metadata crosses as the header numbers it")
    func colourMetadataCrosses() {
        let desc = GossFrameDesc(
            width: 4, height: 4, pixelFormat: .bgra8,
            colorStandard: .bt2020, colorRange: .full, timestampUs: 1234
        )
        #expect(desc.raw.color_standard == GossColorStandard.bt2020.rawValue)
        #expect(desc.raw.color_range == GossColorRange.full.rawValue)
        #expect(desc.raw.timestamp_us == 1234)
    }
}

/// The node diagnostics a host reads after activating a lens it did not author.
@Suite("Node diagnostics")
struct NodeDiagnosticsTests {
    @Test("a node state decodes in the order the ABI numbers it")
    func nodeStateOrder() {
        #expect(GossSession.GossNodeState(rawValue: 0) == .ready)
        #expect(GossSession.GossNodeState(rawValue: 1) == .degraded)
        #expect(GossSession.GossNodeState(rawValue: 2) == .failed)
    }

    @Test("a node reason decodes in the order the ABI numbers it")
    func nodeReasonOrder() {
        #expect(GossSession.GossNodeReason(rawValue: 0) == GossSession.GossNodeReason.none)
        #expect(GossSession.GossNodeReason(rawValue: 1) == .outOfMemory)
        #expect(GossSession.GossNodeReason(rawValue: 9) == .capabilityUnavailable)
    }

    @Test("a reason the engine has not learned to report yet decodes to nothing")
    func unknownReasonDecodesToNothing() {
        #expect(GossSession.GossNodeReason(rawValue: 99) == nil)
        #expect(GossSession.GossNodeState(rawValue: 99) == nil)
    }
}

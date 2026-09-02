import CGosslens

/// ABI bootstrap and pure math - callable before any handle exists.
public enum Gosslens {
    /// Any-thread. Must be the first call this SDK makes; compare the
    /// high 16 bits against the header's own GOSS_ABI_MAJOR before
    /// creating anything.
    public static func abiVersion() -> UInt32 {
        goss_abi_version()
    }

    /// The capabilities this build compiled real. A stub library shares the
    /// full one's filename and abi version, so check the rail you need here
    /// before feeding real bytes to an enable call.
    public struct Capabilities: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let tracking = Capabilities(rawValue: 1 << 0)
        public static let segmentation = Capabilities(rawValue: 1 << 1)
        public static let mlInference = Capabilities(rawValue: 1 << 2)
        public static let diffusion = Capabilities(rawValue: 1 << 3)
        public static let beauty = Capabilities(rawValue: 1 << 4)
        public static let physics = Capabilities(rawValue: 1 << 5)
        public static let videoTextures = Capabilities(rawValue: 1 << 6)
        public static let photoCapture = Capabilities(rawValue: 1 << 7)
        public static let recording = Capabilities(rawValue: 1 << 8)
        public static let fileIo = Capabilities(rawValue: 1 << 9)
    }

    /// Any-thread. Which capabilities this build compiled real.
    public static func capabilities() -> Capabilities {
        Capabilities(rawValue: goss_capabilities())
    }

    /// Any-thread, pure. The YCbCr to RGB conversion for a standard and
    /// range as one column-major homogeneous matrix.
    public static func yuvToRgb(colorStandard: GossColorStandard, colorRange: GossColorRange) throws -> [Float] {
        var matrix = [Float](repeating: 0, count: 16)
        try matrix.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_color_yuv_to_rgb(colorStandard.rawValue, colorRange.rawValue, buffer.baseAddress))
        }
        return matrix
    }

    /// Analytic two-bone inverse kinematics for a limb. root, target, and pole
    /// are (x, y, z); returns the mid joint and end positions. An out-of-reach
    /// target extends the limb straight at it.
    public static func solveTwoBoneIk(root: [Float], upperLen: Float, lowerLen: Float, target: [Float], pole: [Float]) throws -> (mid: [Float], end: [Float]) {
        var mid = [Float](repeating: 0, count: 3)
        var end = [Float](repeating: 0, count: 3)
        try mid.withUnsafeMutableBufferPointer { m in
            try end.withUnsafeMutableBufferPointer { e in
                try checked(goss_solve_two_bone_ik(root, upperLen, lowerLen, target, pole, m.baseAddress, e.baseAddress))
            }
        }
        return (mid, end)
    }
}

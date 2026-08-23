import CGosslens

/// ABI bootstrap and pure math - callable before any handle exists.
public enum Gosslens {
    /// Any-thread. Must be the first call this SDK makes; compare the
    /// high 16 bits against the header's own GOSS_ABI_MAJOR before
    /// creating anything.
    public static func abiVersion() -> UInt32 {
        goss_abi_version()
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

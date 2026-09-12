import CGosslens

/// Mirrors goss_status - thrown by every wrapper method whose C call can
/// fail, carrying the real status code rather than collapsing it to Bool.
public enum GossStatus: Error {
    case invalidArgument
    case outOfMemory
    case poolExhausted
    case abiMismatch
    case rendererUnavailable
    case unsupported
    case again
    /// The lens is live and a node the manifest did not mark optional could not
    /// do what it asked. Thrown only where a caller asked for all-or-nothing;
    /// activateLens answers it as a Bool instead, since the lens is drawing.
    case lensNodeFailed

    init?(_ raw: goss_status) {
        switch raw {
        case GOSS_OK: return nil
        case GOSS_ERROR_INVALID_ARGUMENT: self = .invalidArgument
        case GOSS_ERROR_OUT_OF_MEMORY: self = .outOfMemory
        case GOSS_ERROR_POOL_EXHAUSTED: self = .poolExhausted
        case GOSS_ERROR_ABI_MISMATCH: self = .abiMismatch
        case GOSS_ERROR_RENDERER_UNAVAILABLE: self = .rendererUnavailable
        case GOSS_ERROR_UNSUPPORTED: self = .unsupported
        case GOSS_AGAIN: self = .again
        case GOSS_LENS_NODE_FAILED: self = .lensNodeFailed
        default: self = .invalidArgument
        }
    }
}

func checked(_ raw: goss_status) throws {
    if let status = GossStatus(raw) { throw status }
}

/// An activation's result: true when every node is ready, false when the lens is
/// live with a failed node, and a throw when it did not activate at all.
func activated(_ raw: goss_status) throws -> Bool {
    if raw == GOSS_LENS_NODE_FAILED { return false }
    try checked(raw)
    return true
}

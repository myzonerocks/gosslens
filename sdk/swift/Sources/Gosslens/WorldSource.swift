#if canImport(ARKit) && os(iOS)
import ARKit
import CGosslens

/// Feeds ARKit's world understanding into the engine: camera pose and
/// projection, plane anchors, world anchors, and the light estimate,
/// one submit per rendered AR frame.
public final class GossWorldSource: NSObject, ARSessionDelegate {
    private let arSession = ARSession()
    private weak var engineSession: GossSession?
    private var planes: [goss_world_plane] = []
    private var anchors: [goss_world_anchor] = []
    private var depth: [Float] = []
    private var meshVertices: [Float] = []
    private var meshIndices: [UInt32] = []
    private var meshVersion = 0
    private let viewport: CGSize

    /// ARKit owns the camera while this runs, so its frames are the picture: each one is handed
    /// here as the NV12 buffer ARKit captured, with its timestamp in microseconds, for the host
    /// to submit as the camera frame.
    public var onFrame: ((CVPixelBuffer, Int64) -> Void)?

    /// Whether this phone measures scene depth (LiDAR) and can reconstruct a mesh.
    public static var supportsSceneDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    public static var supportsMesh: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    /// viewport is the size the picture is drawn at, which the projection is computed for.
    public init(session: GossSession, viewport: CGSize) {
        self.engineSession = session
        self.viewport = viewport
        super.init()
        arSession.delegate = self
    }

    /// Starts world tracking with plane detection, scene depth and mesh reconstruction where
    /// the phone has them. ARKit takes the camera; the host pauses its own capture first.
    public func start() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isLightEstimationEnabled = true
        if Self.supportsSceneDepth { configuration.frameSemantics.insert(.sceneDepth) }
        if Self.supportsMesh { configuration.sceneReconstruction = .mesh }
        arSession.run(configuration)
    }

    public func pause() {
        arSession.pause()
        if let engine = engineSession {
            _ = goss_session_submit_depth(engine.handle, nil, 0, 0, 0, 0)
            _ = goss_session_submit_world_mesh(engine.handle, nil, 0, nil, 0)
        }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let engine = engineSession else { return }

        var state = goss_world_state()
        state.tracking_state = trackingState(frame.camera.trackingState)
        state.timestamp_us = Int64(frame.timestamp * 1_000_000)
        copyColumns(frame.camera.transform, into: &state.world_from_camera)
        copyColumns(frame.camera.projectionMatrix(for: .portrait, viewportSize: viewport, zNear: 0.1, zFar: 100), into: &state.projection)

        planes.removeAll(keepingCapacity: true)
        anchors.removeAll(keepingCapacity: true)
        for anchor in frame.anchors {
            if let plane = anchor as? ARPlaneAnchor {
                var out = goss_world_plane()
                out.id = UInt64(bitPattern: Int64(anchor.identifier.hashValue))
                copyColumns(plane.transform, into: &out.pose)
                out.extent_x = plane.planeExtent.width
                out.extent_z = plane.planeExtent.height
                out.classification = planeClass(plane.classification)
                planes.append(out)
            } else {
                var out = goss_world_anchor()
                out.id = UInt64(bitPattern: Int64(anchor.identifier.hashValue))
                copyColumns(anchor.transform, into: &out.pose)
                anchors.append(out)
            }
        }

        var light = goss_world_light()
        if let estimate = frame.lightEstimate {
            light.ambient_intensity = Float(estimate.ambientIntensity / 1000.0)
            light.color_temperature_kelvin = Float(estimate.ambientColorTemperature)
        }

        planes.withUnsafeBufferPointer { planeBuffer in
            anchors.withUnsafeBufferPointer { anchorBuffer in
                _ = goss_session_submit_world(engine.handle, &state, planeBuffer.baseAddress, planeBuffer.count, anchorBuffer.baseAddress, anchorBuffer.count, &light)
            }
        }
        submitDepth(of: frame, to: engine)
        submitMesh(of: frame, to: engine)
        onFrame?(frame.capturedImage, state.timestamp_us)
    }

    /// The LiDAR depth map as metres per pixel, into one reused array. ARKit's map is
    /// Float32 already, so the copy is a row walk and nothing else.
    private func submitDepth(of frame: ARFrame, to engine: GossSession) {
        guard let map = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float>.size
        if depth.count != width * height { depth = [Float](repeating: 0, count: width * height) }
        depth.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                let src = base.advanced(by: row * stride * MemoryLayout<Float>.size).assumingMemoryBound(to: Float.self)
                (out.baseAddress! + row * width).update(from: src, count: width)
            }
        }
        depth.withUnsafeBufferPointer { buffer in
            _ = goss_session_submit_depth(engine.handle, buffer.baseAddress, UInt32(width), UInt32(height), 0.1, 100)
        }
    }

    /// The reconstructed mesh, resubmitted only when a mesh anchor changed. Every anchor's
    /// vertices are moved into world space once, so the engine's raycast meets one mesh.
    private func submitMesh(of frame: ARFrame, to engine: GossSession) {
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        let version = meshes.reduce(0) { $0 &+ $1.geometry.vertices.count &+ Int($1.transform.columns.3.x * 1000) }
        guard version != meshVersion else { return }
        meshVersion = version
        meshVertices.removeAll(keepingCapacity: true)
        meshIndices.removeAll(keepingCapacity: true)
        for mesh in meshes {
            let base = UInt32(meshVertices.count / 3)
            let vertices = mesh.geometry.vertices
            let transform = mesh.transform
            for index in 0..<vertices.count {
                let raw = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * index)
                let local = raw.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world = transform * SIMD4<Float>(local, 1)
                meshVertices.append(world.x)
                meshVertices.append(world.y)
                meshVertices.append(world.z)
            }
            let faces = mesh.geometry.faces
            let bytes = faces.bytesPerIndex
            for face in 0..<faces.count {
                for corner in 0..<faces.indexCountPerPrimitive {
                    let raw = faces.buffer.contents().advanced(by: (face * faces.indexCountPerPrimitive + corner) * bytes)
                    let value = bytes == 4 ? raw.assumingMemoryBound(to: UInt32.self).pointee : UInt32(raw.assumingMemoryBound(to: UInt16.self).pointee)
                    meshIndices.append(base + value)
                }
            }
        }
        meshVertices.withUnsafeBufferPointer { v in
            meshIndices.withUnsafeBufferPointer { i in
                _ = goss_session_submit_world_mesh(engine.handle, v.baseAddress, v.count / 3, i.baseAddress, i.count)
            }
        }
    }

    private func trackingState(_ state: ARCamera.TrackingState) -> UInt32 {
        switch state {
        case .normal: return 2
        case .limited: return 3
        case .notAvailable: return 0
        }
    }

    private func planeClass(_ classification: ARPlaneAnchor.Classification) -> UInt32 {
        switch classification {
        case .floor: return 1
        case .wall: return 2
        case .ceiling: return 3
        case .table: return 4
        default: return 0
        }
    }

    /// simd_float4x4 already stores its columns contiguously in the same
    /// column-major order the C matrix wants, so the copy is a byte move with
    /// no per-frame scratch array.
    private func copyColumns<T>(_ matrix: simd_float4x4, into out: inout T) {
        var source = matrix
        withUnsafeMutableBytes(of: &out) { raw in
            withUnsafeBytes(of: &source) { src in
                raw.copyBytes(from: src)
            }
        }
    }
}

#endif

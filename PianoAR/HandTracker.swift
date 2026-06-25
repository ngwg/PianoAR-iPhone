import ARKit
import Vision
import simd

final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    struct HandResult {
        let isLeft: Bool
        var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>]
    }

    static let allJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP,  .ringPIP,  .ringDIP,  .ringTip,
        .littleMCP,.littlePIP,.littleDIP,.littleTip,
    ]

    static let boneConnections: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,4),
        (0,5),(5,6),(6,7),(7,8),
        (0,9),(9,10),(10,11),(11,12),
        (0,13),(13,14),(14,15),(15,16),
        (0,17),(17,18),(18,19),(19,20),
        (5,9),(9,13),(13,17),
    ]

    // Palm-adjacent bones get thicker strokes in the overlay
    static let isPalmBone: Set<Int> = [4, 8, 12, 16, 20, 21, 22]

    private var _hands: [HandResult] = []
    private let lock         = NSLock()
    private var isProcessing = false
    private var frameCount   = 0
    private let visionQueue  = DispatchQueue(label: "com.piano.vision", qos: .userInteractive)
    private var smoothed:    [String: SIMD3<Float>] = [:]

    // MARK: - Public

    func maybeProcess(_ frame: ARFrame) {
        frameCount += 1
        guard frameCount % 2 == 0, !isProcessing else { return }
        isProcessing = true

        let pixelBuffer = frame.capturedImage
        let camera      = frame.camera
        // Prefer smoothed depth (fewer holes); fall back to raw sceneDepth.
        let depthMap    = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap

        visionQueue.async { [weak self] in
            self?.run(pixelBuffer: pixelBuffer, camera: camera, depthMap: depthMap)
        }
    }

    func snapshot() -> [HandResult] {
        lock.lock(); defer { lock.unlock() }
        return _hands
    }

    // MARK: - Vision + LiDAR

    private func run(pixelBuffer: CVPixelBuffer, camera: ARCamera, depthMap: CVPixelBuffer?) {
        defer { isProcessing = false }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        // .up = no rotation: Vision returns raw landscape image coords (y-up, bottom-left).
        // We convert to camera pixel space ourselves so we can sample the LiDAR depth map
        // at the exact pixel, then unproject via camera intrinsics for a correct 3D position.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else { commit([], count: 0); return }

        let imgW = Float(camera.imageResolution.width)
        let imgH = Float(camera.imageResolution.height)
        var results: [HandResult] = []

        for obs in observations {
            let side  = obs.chirality == .left ? "L" : "R"
            var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]

            for name in HandTracker.allJoints {
                guard let pt = try? obs.recognizedPoint(name), pt.confidence > 0.2 else { continue }

                // Vision (y-up, bottom-left) → camera image pixel (y-down, top-left).
                let px = Float(pt.location.x) * imgW
                let py = (1.0 - Float(pt.location.y)) * imgH

                // Sample LiDAR depth at this pixel; fall back to 0.4 m if unavailable.
                let depth = depthMap.flatMap {
                    sampleDepth(from: $0, px: px, py: py, imgW: imgW, imgH: imgH)
                } ?? 0.4

                // Compute world-space position via camera intrinsics (no plane assumption).
                let world = cameraPixelToWorld(px: px, py: py, depth: depth, camera: camera)

                // EMA smoothing (α = 0.4).
                let key = "\(side)_\(name.rawValue)"
                let s   = smoothed[key].map { $0 + 0.4 * (world - $0) } ?? world
                smoothed[key] = s
                joints[name]  = s
            }

            if !joints.isEmpty {
                results.append(HandResult(isLeft: obs.chirality == .left, joints: joints))
            }
        }

        commit(results, count: observations.count)
    }

    // MARK: - Helpers

    private func sampleDepth(from map: CVPixelBuffer,
                               px: Float, py: Float,
                               imgW: Float, imgH: Float) -> Float? {
        let dW = CVPixelBufferGetWidth(map)
        let dH = CVPixelBufferGetHeight(map)
        let dx = max(0, min(dW - 1, Int((px / imgW * Float(dW)).rounded())))
        let dy = max(0, min(dH - 1, Int((py / imgH * Float(dH)).rounded())))

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(map)
        let val  = base.assumingMemoryBound(to: Float32.self)[dy * (bpr / 4) + dx]
        return (val > 0.05 && val < 5.0 && val.isFinite) ? val : nil
    }

    /// Converts a camera-image pixel + LiDAR depth to an ARKit world-space position.
    /// ARKit camera: right-handed, looks along -Z, Y is up.
    /// Image coords: x-right, y-down (top-left origin).
    private func cameraPixelToWorld(px: Float, py: Float,
                                     depth: Float, camera: ARCamera) -> SIMD3<Float> {
        let fx = camera.intrinsics[0][0]
        let fy = camera.intrinsics[1][1]
        let cx = camera.intrinsics[2][0]
        let cy = camera.intrinsics[2][1]

        let xc =  (px - cx) / fx * depth   // camera x (right)
        let yc = -(py - cy) / fy * depth   // flip: image y-down → camera y-up
        let zc = -depth                    // scene is at negative z in camera space

        let w = camera.transform * SIMD4<Float>(xc, yc, zc, 1.0)
        return SIMD3<Float>(w.x, w.y, w.z)
    }

    private func commit(_ hands: [HandResult], count: Int) {
        lock.lock(); _hands = hands; lock.unlock()
        DispatchQueue.main.async { self.detectedHandCount = count }
    }
}

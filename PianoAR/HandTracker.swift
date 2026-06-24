import ARKit
import Vision
import simd

/// Runs VNDetectHumanHandPoseRequest on camera frames (~20 fps),
/// projects each fingertip onto the keyboard surface plane using
/// ARCamera.unprojectPoint + LiDAR-anchored plane, and applies
/// per-finger exponential smoothing.
final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    struct FingertipResult {
        let label: String          // e.g. "L_index", "R_thumb"
        let worldPosition: simd_float3
        let confidence: Float
    }

    // Snapshot accessed from the render thread — protected by lock
    private var _fingertips: [FingertipResult] = []
    private let lock = NSLock()

    private var isProcessing = false
    private var frameCount   = 0
    private let visionQueue  = DispatchQueue(label: "com.piano.vision", qos: .userInteractive)
    private var smoothed: [String: simd_float3] = [:]

    // MARK: - Public

    /// Call from renderer(_:updateAtTime:) on the render thread.
    func maybeProcess(_ frame: ARFrame, viewportSize: CGSize) {
        frameCount += 1
        guard frameCount % 3 == 0, !isProcessing else { return }
        isProcessing = true

        let pixelBuffer = frame.capturedImage
        let camera      = frame.camera
        let planeY: Float = frame.anchors
            .first { $0.name == "keyboard" || $0.name == "keyboard_calibrated" }
            .map { $0.transform.columns.3.y } ?? -0.3

        visionQueue.async { [weak self] in
            self?.run(pixelBuffer: pixelBuffer, camera: camera,
                      planeY: planeY, viewportSize: viewportSize)
        }
    }

    /// Thread-safe snapshot for the render loop.
    func snapshot() -> [FingertipResult] {
        lock.lock(); defer { lock.unlock() }
        return _fingertips
    }

    // MARK: - Vision

    private func run(pixelBuffer: CVPixelBuffer, camera: ARCamera,
                     planeY: Float, viewportSize: CGSize) {
        defer { isProcessing = false }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else {
            commit([], count: 0); return
        }

        var planeTransform = matrix_identity_float4x4
        planeTransform.columns.3 = SIMD4<Float>(0, planeY, 0, 1)

        let tips: [(VNHumanHandPoseObservation.JointName, String)] = [
            (.thumbTip, "thumb"), (.indexTip, "index"), (.middleTip, "middle"),
            (.ringTip,  "ring"),  (.littleTip, "little"),
        ]

        var results: [FingertipResult] = []

        for obs in observations {
            let side = obs.chirality == .left ? "L" : "R"
            for (joint, name) in tips {
                guard let pt = try? obs.recognizedPoint(joint),
                      pt.confidence > 0.3
                else { continue }

                // Vision with .right orientation: (0,0) = bottom-left of portrait view
                let vp = CGPoint(
                    x: CGFloat(pt.location.x) * viewportSize.width,
                    y: (1 - CGFloat(pt.location.y)) * viewportSize.height
                )

                guard let world = camera.unprojectPoint(
                    vp, ontoPlane: planeTransform,
                    orientation: .portrait, viewportSize: viewportSize
                ) else { continue }

                // Exponential smoothing (α = 0.35)
                let key = "\(side)_\(name)"
                let alpha: Float = 0.35
                let s: simd_float3
                if let prev = smoothed[key] {
                    s = prev + alpha * (world - prev)
                } else {
                    s = world
                }
                smoothed[key] = s

                results.append(FingertipResult(
                    label: key, worldPosition: s,
                    confidence: Float(pt.confidence)
                ))
            }
        }

        commit(results, count: observations.count)
    }

    private func commit(_ tips: [FingertipResult], count: Int) {
        lock.lock()
        _fingertips = tips
        lock.unlock()
        DispatchQueue.main.async { self.detectedHandCount = count }
    }
}

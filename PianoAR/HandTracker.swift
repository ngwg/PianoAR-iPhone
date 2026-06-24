import ARKit
import Vision
import simd

final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    struct HandResult {
        let isLeft: Bool
        var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>]
    }

    // All 21 joints in a fixed order (indices used by boneConnections below)
    static let allJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP,  .ringPIP,  .ringDIP,  .ringTip,
        .littleMCP,.littlePIP,.littleDIP,.littleTip,
    ]

    // (from, to) index pairs into allJoints
    static let boneConnections: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,4),          // thumb
        (0,5),(5,6),(6,7),(7,8),          // index
        (0,9),(9,10),(10,11),(11,12),     // middle
        (0,13),(13,14),(14,15),(15,16),   // ring
        (0,17),(17,18),(18,19),(19,20),   // little
        (5,9),(9,13),(13,17),            // palm knuckle bar
    ]

    private var _hands: [HandResult] = []
    private let lock        = NSLock()
    private var isProcessing = false
    private var frameCount   = 0
    private let visionQueue  = DispatchQueue(label: "com.piano.vision", qos: .userInteractive)
    private var smoothed: [String: SIMD3<Float>] = [:]

    weak var sceneView: ARSCNView?

    // MARK: - Public

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

    func snapshot() -> [HandResult] {
        lock.lock(); defer { lock.unlock() }
        return _hands
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
        else { commit([], count: 0); return }

        var planeTransform = matrix_identity_float4x4
        planeTransform.columns.3 = SIMD4<Float>(0, planeY, 0, 1)

        var results: [HandResult] = []

        for obs in observations {
            let side = obs.chirality == .left ? "L" : "R"
            var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]

            for name in HandTracker.allJoints {
                guard let pt = try? obs.recognizedPoint(name), pt.confidence > 0.2 else { continue }

                let vp = CGPoint(
                    x: CGFloat(pt.location.x) * viewportSize.width,
                    y: (1 - CGFloat(pt.location.y)) * viewportSize.height
                )
                guard let world = camera.unprojectPoint(
                    vp, ontoPlane: planeTransform,
                    orientation: .portrait, viewportSize: viewportSize
                ) else { continue }

                // Exponential smoothing per joint
                let key = "\(side)_\(name.rawValue)"
                let s: SIMD3<Float>
                if let prev = smoothed[key] {
                    s = prev + 0.35 * (world - prev)
                } else {
                    s = world
                }
                smoothed[key] = s
                joints[name] = s
            }

            if !joints.isEmpty {
                results.append(HandResult(isLeft: obs.chirality == .left, joints: joints))
            }
        }

        commit(results, count: observations.count)
    }

    private func commit(_ hands: [HandResult], count: Int) {
        lock.lock(); _hands = hands; lock.unlock()
        DispatchQueue.main.async { self.detectedHandCount = count }
    }
}

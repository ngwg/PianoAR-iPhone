import ARKit
import Vision
import simd

final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    struct HandResult {
        let isLeft: Bool
        var joints:   [VNHumanHandPoseObservation.JointName: SIMD3<Float>]
        var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint]
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

    private var _hands: [HandResult] = []
    private let lock         = NSLock()
    private var isProcessing = false
    private var frameCount   = 0
    private let visionQueue  = DispatchQueue(label: "com.piano.vision", qos: .userInteractive)
    private var smoothed3D:  [String: SIMD3<Float>] = [:]
    private var smoothed2D:  [String: CGPoint]      = [:]

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
            var joints3D: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]
            var joints2D: [VNHumanHandPoseObservation.JointName: CGPoint]      = [:]

            for name in HandTracker.allJoints {
                guard let pt = try? obs.recognizedPoint(name), pt.confidence > 0.2 else { continue }

                // Vision normalized → viewport pixels
                let vp = CGPoint(
                    x: CGFloat(pt.location.x) * viewportSize.width,
                    y: (1 - CGFloat(pt.location.y)) * viewportSize.height
                )

                // Smooth 2D position (EMA α=0.4)
                let key2 = "\(side)_2d_\(name.rawValue)"
                let s2: CGPoint
                if let prev = smoothed2D[key2] {
                    s2 = CGPoint(x: prev.x + 0.4 * (vp.x - prev.x),
                                 y: prev.y + 0.4 * (vp.y - prev.y))
                } else {
                    s2 = vp
                }
                smoothed2D[key2] = s2
                joints2D[name] = s2

                // 3D projection onto keyboard plane (for press detection later)
                if let world = camera.unprojectPoint(
                    vp, ontoPlane: planeTransform,
                    orientation: .portrait, viewportSize: viewportSize
                ) {
                    let key3 = "\(side)_3d_\(name.rawValue)"
                    let s3: SIMD3<Float>
                    if let prev = smoothed3D[key3] {
                        s3 = prev + 0.35 * (world - prev)
                    } else {
                        s3 = world
                    }
                    smoothed3D[key3] = s3
                    joints3D[name] = s3
                }
            }

            if !joints2D.isEmpty {
                results.append(HandResult(isLeft: obs.chirality == .left,
                                          joints: joints3D, joints2D: joints2D))
            }
        }

        commit(results, count: observations.count)
    }

    private func commit(_ hands: [HandResult], count: Int) {
        lock.lock(); _hands = hands; lock.unlock()
        DispatchQueue.main.async { self.detectedHandCount = count }
    }
}

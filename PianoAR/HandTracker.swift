import ARKit
import Vision
import CoreImage
import ImageIO
import simd

final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    /// Orientation to feed Vision so hands appear upright in the ML input.
    /// Set on the main thread from the live interface orientation. The app is
    /// locked to landscape, so only `.up` (landscapeRight) and `.down`
    /// (landscapeLeft) ever occur. Wrong orientation degrades detection and —
    /// worse — flips left/right chirality, so this must track the real mounting.
    var imageOrientation: CGImagePropertyOrientation = .up

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

    static let isPalmBone: Set<Int> = [4, 8, 12, 16, 20, 21, 22]

    private var _hands: [HandResult] = []
    private let lock         = NSLock()
    private var isProcessing = false
    // No frame-count gate — process as fast as Vision allows; isProcessing prevents queuing.
    private let visionQueue  = DispatchQueue(label: "com.piano.vision", qos: .userInteractive)
    private var smoothed:     [String: SIMD3<Float>]        = [:]
    private var smoothedAge:  [String: TimeInterval]        = [:]
    private var lastDepthByKey: [String: Float]             = [:]
    private static let smoothedStaleTimeout: TimeInterval   = 0.5

    // Reusable downscale buffer — allocated once, reused every frame to avoid heap churn.
    private var scaledBuf:  CVPixelBuffer?
    private var scaledSize: CGSize = .zero
    // GPU-backed CIContext for fast rescaling. Only ever touched on visionQueue (serial).
    private lazy var ciCtx = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: NSNull(),
    ])

    // MARK: - Public

    func maybeProcess(_ frame: ARFrame) {
        guard !isProcessing else { return }
        isProcessing = true

        let pixelBuffer = frame.capturedImage
        let camera      = frame.camera
        let depthMap    = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        let orient      = imageOrientation

        visionQueue.async { [weak self] in
            self?.run(pixelBuffer: pixelBuffer, camera: camera, depthMap: depthMap,
                      orientation: orient)
        }
    }

    func snapshot() -> [HandResult] {
        lock.lock(); defer { lock.unlock() }
        return _hands
    }

    // MARK: - Vision + LiDAR

    private func run(pixelBuffer: CVPixelBuffer, camera: ARCamera, depthMap: CVPixelBuffer?,
                     orientation: CGImagePropertyOrientation) {
        defer { isProcessing = false }

        // Downscale to ≤640 px on the long side before Vision.
        // At 1920×1440 input that's ~3× linear = ~9× fewer pixels → dramatically faster ML.
        // Vision's normalized [0,1] output is resolution-independent, so depth/3D math
        // below still uses the original camera.imageResolution.
        let visionInput = downscaled(pixelBuffer, maxSide: 640)

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        let handler = VNImageRequestHandler(cvPixelBuffer: visionInput,
                                            orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else { commit([], count: 0); return }

        let imgW = Float(camera.imageResolution.width)
        let imgH = Float(camera.imageResolution.height)
        var results: [HandResult] = []

        for obs in observations {
            let side = obs.chirality == .left ? "L" : "R"
            var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]

            for name in HandTracker.allJoints {
                guard let pt = try? obs.recognizedPoint(name),
                      pt.confidence > 0.30 else { continue }

                // Vision normalized (oriented, y-up bottom-left) → native captured-image
                // pixel (y-down top-left). The native buffer is landscape; only .up
                // (landscapeRight) and .down (landscapeLeft) occur, and both keep the
                // landscape dimensions, so width/height never swap.
                let nx: Float, ny: Float
                if orientation == .down {
                    nx = (1.0 - Float(pt.location.x)) * imgW
                    ny =        Float(pt.location.y)  * imgH
                } else {
                    nx =        Float(pt.location.x)  * imgW
                    ny = (1.0 - Float(pt.location.y)) * imgH
                }

                let key    = "\(side)_\(name.rawValue)"
                let now    = CACurrentMediaTime()
                let recent = (smoothedAge[key].map { now - $0 < Self.smoothedStaleTimeout }) ?? false

                // Nearest-biased LiDAR depth: a head-mounted camera looks DOWN at the
                // keys, so the finger is always the closest surface along its pixel ray.
                // A per-joint outlier clamp stops a single bad LiDAR reading (a depth-map
                // hole that falls through to the background) from teleporting the joint.
                var depth = depthMap.flatMap {
                    sampleDepthNear(from: $0, px: nx, py: ny, imgW: imgW, imgH: imgH)
                } ?? (lastDepthByKey[key] ?? 0.4)
                if recent, let ld = lastDepthByKey[key] {
                    depth = simd_clamp(depth, ld - 0.05, ld + 0.05)
                }
                lastDepthByKey[key] = depth

                let world = cameraPixelToWorld(px: nx, py: ny, depth: depth, camera: camera)

                // Adaptive EMA: fast-follow when the hand moves, heavy-smooth when still.
                // Eliminates lag on fast gestures while suppressing jitter at rest.
                let s: SIMD3<Float>
                if recent, let prev = smoothed[key] {
                    let dist  = simd_length(world - prev)
                    // α ≈ 0.2 for < 3 mm/frame movement, ramps to 0.95 at > 4 cm/frame
                    let alpha = simd_clamp(dist / 0.04, 0.2, 0.95)
                    s = prev + alpha * (world - prev)
                } else {
                    // Stale or first appearance — jump directly to avoid "snap" from old position.
                    s = world
                }
                smoothed[key]    = s
                smoothedAge[key] = now
                joints[name]     = s
            }

            if !joints.isEmpty {
                results.append(HandResult(isLeft: obs.chirality == .left, joints: joints))
            }
        }

        commit(results, count: observations.count)
    }

    // MARK: - Downscaling

    private func downscaled(_ src: CVPixelBuffer, maxSide: Int) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard max(w, h) > maxSide else { return src }

        let scale = CGFloat(maxSide) / CGFloat(max(w, h))
        let dw    = max(1, Int(CGFloat(w) * scale))
        let dh    = max(1, Int(CGFloat(h) * scale))
        let sz    = CGSize(width: dw, height: dh)

        if scaledBuf == nil || scaledSize != sz {
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey:  true,
            ]
            scaledBuf  = nil
            CVPixelBufferCreate(kCFAllocatorDefault, dw, dh,
                                kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &scaledBuf)
            scaledSize = sz
        }
        guard let dst = scaledBuf else { return src }

        let ci     = CIImage(cvPixelBuffer: src)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciCtx.render(scaled, to: dst,
                     bounds: CGRect(origin: .zero, size: sz),
                     colorSpace: nil)
        return dst
    }

    // MARK: - Helpers

    /// Sample LiDAR depth over a 5×5 neighbourhood and return a *near-biased* reading.
    ///
    /// A 3×3 median blends the finger with the key/desk a centimetre behind it, so a
    /// hovering fingertip reads too far and its world Z drifts toward the surface —
    /// exactly the jitter that wrecks both the hand model and press detection. Since
    /// the head-mounted camera looks down at the keys, the finger is the nearest
    /// surface along its ray, so we bias toward the near end. We take the 2nd-smallest
    /// valid sample rather than the absolute minimum, which rejects a single spurious
    /// near pixel while staying firmly on the finger. The wider 5×5 window tolerates a
    /// pixel or two of joint-localization error.
    private func sampleDepthNear(from map: CVPixelBuffer,
                                 px: Float, py: Float,
                                 imgW: Float, imgH: Float) -> Float? {
        let dW     = CVPixelBufferGetWidth(map)
        let dH     = CVPixelBufferGetHeight(map)
        let cxD    = Int((px / imgW * Float(dW)).rounded())
        let cyD    = Int((py / imgH * Float(dH)).rounded())
        let stride = CVPixelBufferGetBytesPerRow(map) / 4

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let data = base.assumingMemoryBound(to: Float32.self)

        var samples: [Float] = []
        samples.reserveCapacity(25)
        for dy in -2...2 {
            for dx in -2...2 {
                let col = max(0, min(dW - 1, cxD + dx))
                let row = max(0, min(dH - 1, cyD + dy))
                let v   = data[row * stride + col]
                if v > 0.05 && v < 5.0 && v.isFinite { samples.append(v) }
            }
        }
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[min(1, sorted.count - 1)]   // 2nd-nearest: near-biased, noise-robust
    }

    // ARKit camera: right-hand coords, looks along -Z, Y up. Image: x-right, y-down.
    private func cameraPixelToWorld(px: Float, py: Float,
                                     depth: Float, camera: ARCamera) -> SIMD3<Float> {
        let fx = camera.intrinsics[0][0];  let fy = camera.intrinsics[1][1]
        let cx = camera.intrinsics[2][0];  let cy = camera.intrinsics[2][1]
        let w  = camera.transform * SIMD4<Float>( (px-cx)/fx*depth,
                                                 -(py-cy)/fy*depth,
                                                  -depth, 1)
        return SIMD3<Float>(w.x, w.y, w.z)
    }

    private func commit(_ hands: [HandResult], count: Int) {
        lock.lock(); _hands = hands; lock.unlock()
        DispatchQueue.main.async { self.detectedHandCount = count }
    }
}

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
        // Joints that were occluded and reconstructed (guessed) rather than
        // directly detected. Used for the hand model + UI cursor, but press
        // detection ignores these so a guessed fingertip can't fire a note.
        var estimated: Set<VNHumanHandPoseObservation.JointName> = []
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
    // Per-hand canonical skeleton: each joint's position in the palm-local frame,
    // learned whenever that joint is visible. Drives occlusion reconstruction.
    private var localPose:    [String: [Int: SIMD3<Float>]] = [:]
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
                    // Heavier floor than before (α 0.10 vs 0.20): sub-5 mm/frame
                    // deltas are almost entirely sensor noise, so smooth them
                    // hard; real motion still ramps to α 0.9 by ~4.5 cm/frame.
                    let alpha = simd_clamp(dist / 0.05, 0.10, 0.90)
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
                let estimated = completeHand(side: side, joints: &joints)
                results.append(HandResult(isLeft: obs.chirality == .left,
                                          joints: joints, estimated: estimated))
            }
        }

        // Chirality-flap dedupe: with one physical hand in frame, Vision
        // sometimes reports it TWICE (as left and right on top of each other),
        // which drew two skeletons on one hand. Two opposite-handed detections
        // whose centroids are within ~11 cm are the same hand — keep the one
        // with more genuinely-detected joints.
        if results.count == 2, results[0].isLeft != results[1].isLeft,
           simd_length(Self.centroid(results[0]) - Self.centroid(results[1])) < 0.11 {
            let q0 = results[0].joints.count - results[0].estimated.count
            let q1 = results[1].joints.count - results[1].estimated.count
            results = [q0 >= q1 ? results[0] : results[1]]
        }

        commit(results, count: observations.count)
    }

    private static func centroid(_ h: HandResult) -> SIMD3<Float> {
        var s = SIMD3<Float>(repeating: 0)
        for (_, p) in h.joints { s += p }
        return h.joints.isEmpty ? s : s / Float(h.joints.count)
    }

    // MARK: - Occlusion reconstruction

    /// Fills in joints Vision couldn't see this frame, using a palm-local model of
    /// the hand learned from frames where they *were* visible. The palm (wrist +
    /// knuckles) is close to rigid, so a joint's position relative to a palm frame
    /// is stable; transforming that learned local position into the current palm
    /// orientation gives a natural guess for an occluded finger that still rotates
    /// correctly as the hand turns. Returns the set of joints that were guessed.
    @discardableResult
    private func completeHand(side: String,
                              joints: inout [VNHumanHandPoseObservation.JointName: SIMD3<Float>])
        -> Set<VNHumanHandPoseObservation.JointName> {

        var pos: [Int: SIMD3<Float>] = [:]
        for (i, name) in HandTracker.allJoints.enumerated() {
            if let p = joints[name] { pos[i] = p }
        }
        let detected = Set(pos.keys)

        guard let frame = palmFrame(pos) else { return [] }
        let rInv = frame.r.transpose   // orthonormal → inverse is transpose

        // Learn / refresh local coords for every visible joint.
        var store = localPose[side] ?? [:]
        for (i, p) in pos { store[i] = rInv * (p - frame.origin) }
        localPose[side] = store

        var estimated = Set<VNHumanHandPoseObservation.JointName>()

        // Reconstruct any joint we have a learned pose for but didn't see this frame.
        for i in 0..<HandTracker.allJoints.count where !detected.contains(i) {
            guard let local = store[i] else { continue }
            let world = frame.origin + frame.r * local
            pos[i] = world
            joints[HandTracker.allJoints[i]] = world
            estimated.insert(HandTracker.allJoints[i])
        }

        // Fingertip refinement: when a tip is occluded but its two parent joints are
        // *actually* detected, extrapolate along the live finger so the tip follows
        // the current curl instead of the stale palm-relative guess.
        for tip in [4, 8, 12, 16, 20] where !detected.contains(tip) {
            guard detected.contains(tip - 1), detected.contains(tip - 2),
                  let a = pos[tip - 1], let b = pos[tip - 2] else { continue }
            let world = a + (a - b) * 0.7
            pos[tip] = world
            joints[HandTracker.allJoints[tip]] = world
            estimated.insert(HandTracker.allJoints[tip])
        }

        return estimated
    }

    /// Builds an orthonormal palm frame (origin at the wrist) from whatever palm
    /// joints are visible. Needs the wrist + at least two knuckles.
    private func palmFrame(_ pos: [Int: SIMD3<Float>])
        -> (origin: SIMD3<Float>, r: simd_float3x3)? {

        guard let wrist = pos[0] else { return nil }
        let mcps = [pos[5], pos[9], pos[13], pos[17]].compactMap { $0 }
        guard mcps.count >= 2 else { return nil }

        let centroid = mcps.reduce(SIMD3<Float>(repeating: 0), +) / Float(mcps.count)
        var forward  = centroid - wrist
        guard simd_length(forward) > 1e-4 else { return nil }
        forward = simd_normalize(forward)

        // "Across" the palm: index knuckle → little knuckle if both present.
        let across0 = (pos[5] != nil && pos[17] != nil)
            ? pos[17]! - pos[5]!
            : mcps.last! - mcps.first!
        var across = across0 - forward * simd_dot(across0, forward)   // orthogonalize
        guard simd_length(across) > 1e-4 else { return nil }
        across = simd_normalize(across)

        let up      = simd_normalize(simd_cross(forward, across))     // palm normal
        let across2 = simd_cross(up, forward)                          // re-orthonormalize
        return (wrist, simd_float3x3(columns: (across2, up, forward)))
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

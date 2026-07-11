import ARKit
import Vision
import CoreImage
import ImageIO
import simd

final class HandTracker: ObservableObject {
    @Published var detectedHandCount: Int = 0

    struct HandResult {
        /// Stable 0/1 spatial track ID. Vision result order and chirality may
        /// change frame-to-frame; this ID does not.
        let id: Int
        let isLeft: Bool
        var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>]
        /// Joints reconstructed from anatomy/time or lacking direct LiDAR.
        /// Rendering may use them, but press and gesture actions must not.
        var estimated: Set<VNHumanHandPoseObservation.JointName> = []
        var visibility: Float = 1
        let sampleTime: TimeInterval
    }

    static let allJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
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

    // MARK: - Cross-thread state

    private var _hands: [HandResult] = []
    private let resultLock = NSLock()

    private let processingLock = NSLock()
    private var isProcessing = false
    private var lastScheduledTime: TimeInterval = 0
    private var _imageOrientation: CGImagePropertyOrientation = .up

    /// Orientation to feed Vision so hands appear upright in its ML input.
    /// This is read from both the render and Vision queues, so access is locked.
    var imageOrientation: CGImagePropertyOrientation {
        get {
            processingLock.lock(); defer { processingLock.unlock() }
            return _imageOrientation
        }
        set {
            processingLock.lock(); _imageOrientation = newValue; processingLock.unlock()
        }
    }

    private let visionQueue = DispatchQueue(label: "com.piano.vision",
                                             qos: .userInteractive)
    private let stabilizer = HandPoseStabilizer()

    private lazy var handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    // Reusable downscale buffer, confined to visionQueue.
    private var scaledBuf: CVPixelBuffer?
    private var scaledSize: CGSize = .zero
    private lazy var ciCtx = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: NSNull(),
    ])

    private struct PixelJoint {
        let px: Float
        let py: Float
        let visionConfidence: Float
        let depth: DepthSample?
    }

    private struct DepthSample {
        let depth: Float
        let confidence: Float
    }

    // MARK: - Public

    func maybeProcess(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        // Zero artificial throttle: process every frame Vision can keep up
        // with (isProcessing already prevents queue buildup). Back off only
        // under real thermal pressure.
        let interval: TimeInterval
        switch ProcessInfo.processInfo.thermalState {
        case .serious:  interval = 1.0 / 20.0
        case .critical: interval = 1.0 / 15.0
        default:        interval = 0
        }

        processingLock.lock()
        guard !isProcessing, now - lastScheduledTime >= interval else {
            processingLock.unlock()
            return
        }
        isProcessing = true
        lastScheduledTime = now
        let orientation = _imageOrientation
        processingLock.unlock()

        let pixelBuffer = frame.capturedImage
        let camera = frame.camera
        // Raw depth first: smoothedSceneDepth is temporally filtered by ARKit
        // and lags fast vertical finger motion — exactly what press detection
        // and the hand model must not do.
        let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth

        visionQueue.async { [weak self] in
            self?.run(pixelBuffer: pixelBuffer, camera: camera,
                      depthData: depthData, orientation: orientation)
        }
    }

    func snapshot() -> [HandResult] {
        resultLock.lock(); defer { resultLock.unlock() }
        return _hands
    }

    // MARK: - Vision + LiDAR

    private func run(pixelBuffer: CVPixelBuffer,
                     camera: ARCamera,
                     depthData: ARDepthData?,
                     orientation: CGImagePropertyOrientation) {
        defer {
            processingLock.lock(); isProcessing = false; processingLock.unlock()
        }

        let now = CACurrentMediaTime()
        let visionInput = downscaled(pixelBuffer, maxSide: 640)
        let handler = VNImageRequestHandler(cvPixelBuffer: visionInput,
                                            orientation: orientation,
                                            options: [:])

        do {
            try handler.perform([handPoseRequest])
        } catch {
            publish(stabilizer.update(observations: [], at: now), detectedCount: 0)
            return
        }

        let imgW = Float(camera.imageResolution.width)
        let imgH = Float(camera.imageResolution.height)
        var measurements: [HandPoseObservation] = []

        for observation in handPoseRequest.results ?? [] {
            var pixels: [Int: PixelJoint] = [:]

            for (index, name) in Self.allJoints.enumerated() {
                guard let point = try? observation.recognizedPoint(name),
                      point.confidence > 0.30 else { continue }

                // Vision normalized (oriented, y-up) -> native captured-image
                // pixel (y-down). Landscape .up/.down keep width and height.
                let px: Float
                let py: Float
                if orientation == .down {
                    px = (1.0 - Float(point.location.x)) * imgW
                    py = Float(point.location.y) * imgH
                } else {
                    px = Float(point.location.x) * imgW
                    py = (1.0 - Float(point.location.y)) * imgH
                }

                pixels[index] = PixelJoint(
                    px: px, py: py,
                    visionConfidence: point.confidence,
                    depth: depthData.flatMap {
                        sampleDepth(from: $0, px: px, py: py,
                                    imgW: imgW, imgH: imgH)
                    }
                )
            }

            guard !pixels.isEmpty else { continue }

            // A LiDAR hole at one landmark borrows the same hand's median depth
            // instead of jumping to an arbitrary 0.4m. It remains estimated.
            let depths = pixels.values.compactMap { $0.depth?.depth }.sorted()
            let fallbackDepth = depths.isEmpty ? 0.45 : depths[depths.count / 2]
            var joints: [Int: HandJointObservation] = [:]

            for (index, pixel) in pixels {
                let depth = pixel.depth?.depth ?? fallbackDepth
                let depthConfidence = pixel.depth?.confidence ?? (depths.isEmpty ? 0.25 : 0.48)
                let world = cameraPixelToWorld(px: pixel.px, py: pixel.py,
                                               depth: depth, camera: camera)
                joints[index] = HandJointObservation(
                    position: world,
                    confidence: pixel.visionConfidence * depthConfidence,
                    isDepthMeasured: pixel.depth != nil
                )
            }

            measurements.append(HandPoseObservation(
                isLeft: observation.chirality == .left,
                joints: joints
            ))
        }

        measurements = deduplicated(measurements)
        let stabilized = stabilizer.update(observations: measurements, at: now)
        publish(stabilized, detectedCount: measurements.count)
    }

    /// Removes only true stacked duplicate observations. The old centroid-only
    /// 11cm rule could merge two real piano hands; this requires opposite
    /// chirality plus at least five corresponding joints nearly on top of one
    /// another.
    private func deduplicated(_ hands: [HandPoseObservation]) -> [HandPoseObservation] {
        guard hands.count == 2, hands[0].isLeft != hands[1].isLeft,
              simd_length(hands[0].centroid - hands[1].centroid) < 0.030 else {
            return hands
        }

        let common = Set(hands[0].joints.keys).intersection(hands[1].joints.keys)
        guard common.count >= 5 else { return hands }
        let meanDistance = common.reduce(Float(0)) { total, index in
            guard let a = hands[0].joints[index]?.position,
                  let b = hands[1].joints[index]?.position else { return total }
            return total + simd_length(a - b)
        } / Float(common.count)
        guard meanDistance < 0.015 else { return hands }

        func quality(_ hand: HandPoseObservation) -> Float {
            hand.joints.values.reduce(Float(0)) { total, joint in
                total + joint.confidence + (joint.isDepthMeasured ? 0.20 : 0)
            }
        }
        return [quality(hands[0]) >= quality(hands[1]) ? hands[0] : hands[1]]
    }

    private func publish(_ poses: [StabilizedHandPose], detectedCount: Int) {
        let hands = poses.map { pose -> HandResult in
            var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]
            var estimated = Set<VNHumanHandPoseObservation.JointName>()

            for (index, position) in pose.joints
            where Self.allJoints.indices.contains(index) {
                joints[Self.allJoints[index]] = position
            }
            for index in pose.estimated where Self.allJoints.indices.contains(index) {
                estimated.insert(Self.allJoints[index])
            }

            return HandResult(id: pose.trackID, isLeft: pose.isLeft,
                              joints: joints, estimated: estimated,
                              visibility: pose.visibility,
                              sampleTime: pose.sampleTime)
        }

        resultLock.lock(); _hands = hands; resultLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.detectedHandCount = detectedCount
        }
    }

    // MARK: - Confidence-aware LiDAR sampling

    /// Samples a 5x5 neighborhood, rejects low-confidence LiDAR pixels, and
    /// selects the nearest *dense* depth cluster rather than a single minimum.
    /// This keeps the finger (normally the nearest surface) while rejecting
    /// isolated near speckles.
    private func sampleDepth(from data: ARDepthData,
                             px: Float, py: Float,
                             imgW: Float, imgH: Float) -> DepthSample? {
        let depthMap = data.depthMap
        let confidenceMap = data.confidenceMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let centerX = Int((px / imgW * Float(depthWidth)).rounded())
        let centerY = Int((py / imgH * Float(depthHeight)).rounded())
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthValues = depthBase.assumingMemoryBound(to: Float32.self)

        let confidenceWidth = confidenceMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let confidenceHeight = confidenceMap.map { CVPixelBufferGetHeight($0) } ?? 0
        let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let confidenceValues: UnsafeMutablePointer<UInt8>? = {
            guard let confidenceMap,
                  let base = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }
            return base.assumingMemoryBound(to: UInt8.self)
        }()

        var samples: [DepthSample] = []
        samples.reserveCapacity(25)

        for dy in -2...2 {
            for dx in -2...2 {
                let column = max(0, min(depthWidth - 1, centerX + dx))
                let row = max(0, min(depthHeight - 1, centerY + dy))
                let value = depthValues[row * depthStride + column]
                guard value > 0.05, value < 5.0, value.isFinite else { continue }

                let confidence: Float
                if let confidenceValues, confidenceWidth > 0, confidenceHeight > 0 {
                    let confidenceColumn = min(confidenceWidth - 1,
                        max(0, column * confidenceWidth / max(1, depthWidth)))
                    let confidenceRow = min(confidenceHeight - 1,
                        max(0, row * confidenceHeight / max(1, depthHeight)))
                    let level = confidenceValues[confidenceRow * confidenceStride
                                                 + confidenceColumn]
                    guard level >= 1 else { continue }
                    confidence = level >= 2 ? 1.0 : 0.72
                } else {
                    confidence = 0.68
                }
                samples.append(DepthSample(depth: value, confidence: confidence))
            }
        }

        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.depth < $1.depth }

        // Find the nearest cluster with at least two corroborating pixels in a
        // 12mm band. If there is none, use the overall median rather than a
        // lone near outlier.
        for start in sorted.indices {
            let cluster = sorted[start...].prefix {
                $0.depth - sorted[start].depth <= 0.012
            }
            if cluster.count >= 2 {
                let values = Array(cluster)
                let middle = values[values.count / 2]
                let averageConfidence = values.reduce(Float(0)) { $0 + $1.confidence }
                    / Float(values.count)
                return DepthSample(depth: middle.depth,
                                   confidence: averageConfidence)
            }
        }
        return sorted[sorted.count / 2]
    }

    // MARK: - Image and camera helpers

    private func downscaled(_ source: CVPixelBuffer,
                            maxSide: Int) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard max(width, height) > maxSide else { return source }

        let scale = CGFloat(maxSide) / CGFloat(max(width, height))
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        let size = CGSize(width: targetWidth, height: targetHeight)

        if scaledBuf == nil || scaledSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            scaledBuf = nil
            CVPixelBufferCreate(kCFAllocatorDefault,
                                targetWidth, targetHeight,
                                kCVPixelFormatType_32BGRA,
                                attributes as CFDictionary,
                                &scaledBuf)
            scaledSize = size
        }
        guard let destination = scaledBuf else { return source }

        let image = CIImage(cvPixelBuffer: source)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciCtx.render(scaled, to: destination,
                     bounds: CGRect(origin: .zero, size: size),
                     colorSpace: nil)
        return destination
    }

    // ARKit camera looks along -Z. Captured image is x-right, y-down.
    private func cameraPixelToWorld(px: Float, py: Float,
                                    depth: Float,
                                    camera: ARCamera) -> SIMD3<Float> {
        let fx = camera.intrinsics[0][0]
        let fy = camera.intrinsics[1][1]
        let cx = camera.intrinsics[2][0]
        let cy = camera.intrinsics[2][1]
        let world = camera.transform * SIMD4<Float>(
            (px - cx) / fx * depth,
            -(py - cy) / fy * depth,
            -depth,
            1
        )
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}

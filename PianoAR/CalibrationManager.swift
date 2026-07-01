import ARKit
import simd
import Combine
import Vision
import UIKit

struct CalibrationData {
    let anchorTransform: simd_float4x4
    let widthScale: Float   // measured width / standard keyboard width
    let depthScale: Float   // measured depth / standard keyboard depth
}

enum CalibrationState: Equatable {
    case idle
    case collecting(count: Int)  // 0–3 corners confirmed
    case done

    static func == (lhs: CalibrationState, rhs: CalibrationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.collecting(let a), .collecting(let b)): return a == b
        case (.done, .done): return true
        default: return false
        }
    }

    var isCollecting: Bool {
        if case .collecting = self { return true }
        return false
    }
}

final class CalibrationManager: ObservableObject {
    @Published var state: CalibrationState = .idle

    // Set before the "keyboard_calibrated" anchor is added so the Coordinator
    // can read it synchronously from renderer(_:nodeFor:).
    private(set) var calibrationData: CalibrationData?

    private var corners: [simd_float3] = []
    private var cornerAnchorIDs: [UUID] = []

    weak var sceneView: ARSCNView?

    // ── Auto-detection state ──────────────────────────────────────────────
    private let autoQueue = DispatchQueue(label: "com.piano.autodetect", qos: .userInitiated)
    private var autoBusy = false
    private var lastAutoAttempt: TimeInterval = 0
    private var pendingAutoCorners: [SIMD3<Float>]? = nil   // last validated set

    func startCalibration() {
        reset()
        state = .collecting(count: 0)
    }

    /// Called on the main thread from the screen-tap gesture. The tapped 2D
    /// point is raycast against detected horizontal surfaces (LiDAR-backed) to
    /// get the corner's true 3D world position.
    func handleTap(at screenPoint: CGPoint) {
        guard case .collecting(let count) = state, count < 4,
              let sv = sceneView else { return }

        guard let query = sv.raycastQuery(
                from: screenPoint,
                allowing: .estimatedPlane,
                alignment: .horizontal),
              let hit = sv.session.raycast(query).first
        else { return }

        let pos = SIMD3<Float>(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )
        corners.append(pos)

        let markerAnchor = ARAnchor(name: "corner_\(count)", transform: hit.worldTransform)
        sv.session.add(anchor: markerAnchor)
        cornerAnchorIDs.append(markerAnchor.identifier)

        let next = count + 1
        if next == 4 {
            if let data = computeCalibration(from: corners) {
                calibrationData = data
                let kbAnchor = ARAnchor(name: "keyboard_calibrated",
                                        transform: data.anchorTransform)
                sv.session.add(anchor: kbAnchor)
            }
            state = .done
        } else {
            state = .collecting(count: next)
        }
    }

    func reset() {
        if let sv = sceneView, let frame = sv.session.currentFrame {
            for anchor in frame.anchors {
                if cornerAnchorIDs.contains(anchor.identifier)
                    || anchor.name == "keyboard_calibrated" {
                    sv.session.remove(anchor: anchor)
                }
            }
        }
        corners = []
        cornerAnchorIDs = []
        calibrationData = nil
        pendingAutoCorners = nil
        state = .idle
    }

    // MARK: - Automatic keyboard detection
    //
    // While waiting for the FIRST corner tap, continuously look for the
    // keyboard in the camera image: the white-keys strip is a high-contrast,
    // very elongated rectangle that VNDetectRectanglesRequest finds well from
    // above. Each detected corner is raycast against the LiDAR-detected
    // surface to a 3D world point, then the quad is validated against real
    // 88-key dimensions (~1.22 m × ~0.15 m) and must be confirmed by a second
    // consistent detection before it's committed — a single bad frame can't
    // place the keyboard. Manual tapping stays available the whole time and
    // takes precedence the moment the first corner is tapped.

    /// Call once per render frame (throttled internally). Safe on the render
    /// thread — Vision runs on a background queue, raycasts hop to main.
    func attemptAutoDetect(frame: ARFrame,
                           orientation: CGImagePropertyOrientation,
                           time: TimeInterval) {
        guard case .collecting(let count) = state, count == 0 else { return }
        guard time - lastAutoAttempt > 0.5, !autoBusy else { return }
        lastAutoAttempt = time
        autoBusy = true

        let pixelBuffer = frame.capturedImage
        autoQueue.async { [weak self] in
            guard let self else { return }
            let request = VNDetectRectanglesRequest()
            request.maximumObservations = 5
            request.minimumConfidence   = 0.55
            // The 88-key strip is ~8:1 — far outside the default aspect range.
            request.minimumAspectRatio  = 0.04
            request.maximumAspectRatio  = 0.35
            request.minimumSize         = 0.08
            request.quadratureTolerance = 22

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observations = request.results, !observations.isEmpty else {
                self.autoBusy = false
                return
            }
            let candidates = observations.sorted { $0.confidence > $1.confidence }
            DispatchQueue.main.async {
                self.processAutoCandidates(candidates, frame: frame)
                self.autoBusy = false
            }
        }
    }

    /// Main thread: convert Vision corners → view points → world raycasts,
    /// validate physical dimensions, and commit after two consistent hits.
    private func processAutoCandidates(_ candidates: [VNRectangleObservation],
                                       frame: ARFrame) {
        guard case .collecting(let count) = state, count == 0,
              let sv = sceneView, sv.bounds.width > 0 else { return }

        let viewport = sv.bounds.size
        let io = sv.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        let t  = frame.displayTransform(for: io, viewportSize: viewport)

        func viewPoint(_ p: CGPoint) -> CGPoint {
            // Vision normalized (origin bottom-left) → image normalized
            // (origin top-left) → view normalized → view points.
            let ip = CGPoint(x: p.x, y: 1 - p.y).applying(t)
            return CGPoint(x: ip.x * viewport.width, y: ip.y * viewport.height)
        }
        func raycast(_ p: CGPoint) -> SIMD3<Float>? {
            guard let q = sv.raycastQuery(from: p, allowing: .estimatedPlane,
                                          alignment: .horizontal),
                  let hit = sv.session.raycast(q).first else { return nil }
            let c = hit.worldTransform.columns.3
            return SIMD3<Float>(c.x, c.y, c.z)
        }

        let camT   = frame.camera.transform.columns.3
        let camPos = SIMD3<Float>(camT.x, camT.y, camT.z)

        for obs in candidates {
            let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
                .map(viewPoint)
            let world = pts.compactMap(raycast)
            guard world.count == 4,
                  let ordered = orderCorners(world, camPos: camPos),
                  validDimensions(ordered) else { continue }

            // Require a second consistent detection (< 4 cm per corner) before
            // committing — one noisy frame must never place the keyboard.
            if let prev = pendingAutoCorners, prev.count == 4,
               zip(prev, ordered).allSatisfy({ simd_length($0.0 - $0.1) < 0.04 }) {
                commitAutoDetection(ordered)
            } else {
                pendingAutoCorners = ordered
            }
            return
        }
    }

    /// Orders 4 world points as [near-left, near-right, far-right, far-left]
    /// relative to the camera, matching the manual tap order.
    private func orderCorners(_ pts: [SIMD3<Float>],
                              camPos: SIMD3<Float>) -> [SIMD3<Float>]? {
        let centroid = pts.reduce(SIMD3<Float>(repeating: 0), +) / 4
        let toUserRaw = SIMD3<Float>(camPos.x - centroid.x, 0, camPos.z - centroid.z)
        guard simd_length(toUserRaw) > 0.05 else { return nil }
        let toUser   = simd_normalize(toUserRaw)
        let rightDir = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), toUser))

        var nl, nr, fr, fl: SIMD3<Float>?
        for p in pts {
            let rel  = p - centroid
            let near = simd_dot(rel, toUser) > 0
            let right = simd_dot(rel, rightDir) > 0
            switch (near, right) {
            case (true,  false): nl = p
            case (true,  true):  nr = p
            case (false, true):  fr = p
            case (false, false): fl = p
            }
        }
        guard let a = nl, let b = nr, let c = fr, let d = fl else { return nil }
        return [a, b, c, d]
    }

    /// Physical plausibility for a real 88-key keyboard.
    private func validDimensions(_ c: [SIMD3<Float>]) -> Bool {
        func flat(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(v.x, 0, v.z) }
        let wNear = simd_length(flat(c[1] - c[0]))
        let wFar  = simd_length(flat(c[2] - c[3]))
        let dL    = simd_length(flat(c[3] - c[0]))
        let dR    = simd_length(flat(c[2] - c[1]))
        let width = (wNear + wFar) / 2
        let depth = (dL + dR) / 2
        return width > 1.00 && width < 1.40
            && depth > 0.08 && depth < 0.26
            && abs(wNear - wFar) < 0.15
            && abs(dL - dR) < 0.10
    }

    private func commitAutoDetection(_ ordered: [SIMD3<Float>]) {
        guard let sv = sceneView,
              let data = computeCalibration(from: ordered) else { return }

        corners = ordered
        for (i, p) in ordered.enumerated() {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
            let marker = ARAnchor(name: "corner_\(i)", transform: t)
            sv.session.add(anchor: marker)
            cornerAnchorIDs.append(marker.identifier)
        }
        calibrationData = data
        sv.session.add(anchor: ARAnchor(name: "keyboard_calibrated",
                                        transform: data.anchorTransform))
        pendingAutoCorners = nil
        state = .done
    }

    // MARK: - Geometry

    private func computeCalibration(from pts: [SIMD3<Float>]) -> CalibrationData? {
        guard pts.count == 4 else { return nil }
        // Tap order: near-left → near-right → far-right → far-left
        let (nl, nr, fr, fl) = (pts[0], pts[1], pts[2], pts[3])

        let center = (nl + nr + fr + fl) * 0.25

        // Y axis is always world-up — the piano is on a horizontal surface.
        // Deriving Y from a cross product of imprecisely-tapped corners can
        // produce a tilted Y, which makes the whole overlay lean and the
        // per-key positions drift off the real keys.
        let kbY = SIMD3<Float>(0, 1, 0)

        // X axis (low → high notes) comes from the WIDTH edges — the ~1.2 m
        // key-line the user can tap precisely. Deriving X indirectly from the
        // short ~15 cm near/far edges (as a cross product of Z) amplified any
        // tap error into a visible rotation of every key position, which is
        // exactly the "notes are a bit off" symptom. Averaging both width
        // edges also cancels independent per-corner error.
        let xRaw  = (nr - nl) + (fr - fl)
        let xFlat = SIMD3<Float>(xRaw.x, 0, xRaw.z)
        guard simd_length(xFlat) > 0.01 else { return nil }
        var kbX = simd_normalize(xFlat)

        // Z completes the right-handed frame (X × Y right-handed triple:
        // Z = cross(X, Y) points toward the player when X runs left→right).
        var kbZ = simd_normalize(simd_cross(kbX, kbY))

        // Safety: if the tap order was mirrored, Z would point away from the
        // player — detect via the near−far hint and flip both axes.
        let zHintRaw = (nl + nr) * 0.5 - (fl + fr) * 0.5
        let zHint    = SIMD3<Float>(zHintRaw.x, 0, zHintRaw.z)
        if simd_dot(kbZ, zHint) < 0 { kbX = -kbX; kbZ = -kbZ }

        let col0 = SIMD4<Float>(kbX.x, kbX.y, kbX.z, 0)
        let col1 = SIMD4<Float>(kbY.x, kbY.y, kbY.z, 0)
        let col2 = SIMD4<Float>(kbZ.x, kbZ.y, kbZ.z, 0)
        let col3 = SIMD4<Float>(center.x, center.y, center.z, 1)
        let transform = simd_float4x4(columns: (col0, col1, col2, col3))

        // Measure width/depth in the horizontal plane to avoid LiDAR height noise
        // inflating the scale factors.
        let wL = simd_length(SIMD3<Float>(nr.x - nl.x, 0, nr.z - nl.z))
        let wF = simd_length(SIMD3<Float>(fr.x - fl.x, 0, fr.z - fl.z))
        let dL = simd_length(SIMD3<Float>(fl.x - nl.x, 0, fl.z - nl.z))
        let dR = simd_length(SIMD3<Float>(fr.x - nr.x, 0, fr.z - nr.z))
        let measuredWidth = (wL + wF) * 0.5
        let measuredDepth = (dL + dR) * 0.5

        return CalibrationData(
            anchorTransform: transform,
            widthScale: measuredWidth / KeyboardLayout.totalWidth,
            depthScale: measuredDepth / KeyboardLayout.whiteKeyDepth
        )
    }
}

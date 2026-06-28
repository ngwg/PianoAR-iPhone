import ARKit
import simd
import Combine

struct CalibrationData {
    let anchorTransform: simd_float4x4
    let widthScale: Float   // measured width / standard keyboard width
    let depthScale: Float   // measured depth / standard keyboard depth
}

enum CalibrationState: Equatable {
    case idle
    case collecting(count: Int)  // 0–3 corners tapped
    case done

    static func == (lhs: CalibrationState, rhs: CalibrationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.collecting(let a), .collecting(let b)): return a == b
        case (.done, .done): return true
        default: return false
        }
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

    func startCalibration() {
        reset()
        state = .collecting(count: 0)
    }

    // Called on the main thread from the tap gesture.
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
        state = .idle
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

        // Z axis: near-center → far-center = away from player; we want toward player.
        // Project onto the horizontal plane and normalize so slight height differences
        // in the tapped corners don't tilt the Z axis.
        let zRaw = (nl + nr) * 0.5 - (fl + fr) * 0.5     // near − far = toward player
        let zFlat = SIMD3<Float>(zRaw.x, 0, zRaw.z)
        let kbZ  = simd_normalize(zFlat)

        // Re-derive X from Y and Z for a right-handed orthogonal frame.
        // cross(kbY, kbZ) gives keyboard-right (low notes on user's left, high on right).
        // cross(kbZ, kbY) was wrong — it produced -kbX, mirroring the whole overlay.
        let kbX = simd_cross(kbY, kbZ)

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

import ARKit
import SceneKit
import Combine

enum PlacementState {
    case scanning       // looking for horizontal planes
    case readyToPlace   // at least one plane found, waiting for a confirm gesture
    case placed         // keyboard anchor created
}

/// Places the virtual 88-key keyboard on a detected horizontal plane.
///
/// The phone is inside a headset shell during normal use, so the touchscreen
/// isn't reachable — placement is entirely hand-driven: point at the desired
/// spot on the table with one hand (that fingertip's LiDAR-derived 3D position
/// IS the point, no raycast needed), then pinch with the OTHER hand to confirm.
final class PlacementManager: ObservableObject {
    @Published var state: PlacementState = .scanning

    weak var sceneView: ARSCNView?

    // Called from ARSCNViewDelegate on the rendering thread when a plane anchor appears.
    func onPlaneAdded() {
        guard state == .scanning else { return }
        DispatchQueue.main.async { self.state = .readyToPlace }
    }

    /// Call every render frame while `state == .readyToPlace`. `pointTip` is the
    /// pointing hand's fingertip world position (from `GestureDetector.pointAndConfirm`);
    /// `confirmed` is true on the single frame the other hand's pinch fires.
    /// Returns a live preview position (fingertip XZ, snapped to the nearest
    /// detected plane's height) for a reticle, or nil if there's nothing to show.
    @discardableResult
    func updateHandPlacement(pointTip: SIMD3<Float>?, confirmed: Bool,
                             frame: ARFrame) -> SIMD3<Float>? {
        guard state == .readyToPlace, let sv = sceneView, let tip = pointTip else { return nil }

        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return nil }
        let nearest = planes.min {
            abs($0.transform.columns.3.y - tip.y) < abs($1.transform.columns.3.y - tip.y)
        }!
        let previewPos = SIMD3<Float>(tip.x, nearest.transform.columns.3.y, tip.z)

        if confirmed {
            place(at: previewPos, cameraTransform: frame.camera.transform, sceneView: sv)
        }
        return previewPos
    }

    private func place(at pos: SIMD3<Float>, cameraTransform: simd_float4x4, sceneView sv: ARSCNView) {
        // Orient keyboard so its near edge (keyboard +Z) faces the camera.
        let camPos = SIMD3<Float>(cameraTransform.columns.3.x,
                                   cameraTransform.columns.3.y,
                                   cameraTransform.columns.3.z)
        let toUser  = camPos - pos
        // Keyboard +Z = toward user (near edge); project onto horizontal plane.
        let rawZ    = SIMD3<Float>(toUser.x, 0, toUser.z)
        let kbZ     = simd_length(rawZ) > 0.01 ? simd_normalize(rawZ)
                                                : SIMD3<Float>(0, 0, 1)
        let kbY     = SIMD3<Float>(0, 1, 0)             // always world-up
        // cross(kbY, kbZ) gives a right-handed frame where kbX points from
        // low notes (user's left) to high notes (user's right).
        let kbX     = simd_cross(kbY, kbZ)

        var t = matrix_identity_float4x4
        t.columns.0 = SIMD4<Float>(kbX.x, kbX.y, kbX.z, 0)
        t.columns.1 = SIMD4<Float>(kbY.x, kbY.y, kbY.z, 0)
        t.columns.2 = SIMD4<Float>(kbZ.x, kbZ.y, kbZ.z, 0)
        t.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1)

        let anchor = ARAnchor(name: "keyboard", transform: t)
        sv.session.add(anchor: anchor)
        DispatchQueue.main.async { self.state = .placed }
    }

    // Remove the keyboard anchor so the user can re-place it.
    func reset(session: ARSessionModel) {
        if let frame = session.session.currentFrame {
            for anchor in frame.anchors where anchor.name == "keyboard" {
                session.session.remove(anchor: anchor)
            }
            let hasPlanes = frame.anchors.contains { $0 is ARPlaneAnchor }
            DispatchQueue.main.async {
                self.state = hasPlanes ? .readyToPlace : .scanning
            }
        } else {
            DispatchQueue.main.async { self.state = .scanning }
        }
    }
}

import ARKit
import SceneKit
import Combine

enum PlacementState {
    case scanning       // looking for horizontal planes
    case readyToPlace   // at least one plane found, waiting for tap
    case placed         // keyboard anchor created
}

final class PlacementManager: ObservableObject {
    @Published var state: PlacementState = .scanning

    weak var sceneView: ARSCNView?

    // Called from ARSCNViewDelegate on the rendering thread when a plane anchor appears.
    func onPlaneAdded() {
        guard state == .scanning else { return }
        DispatchQueue.main.async { self.state = .readyToPlace }
    }

    // Called from a tap gesture on the main thread.
    func handleTap(at screenPoint: CGPoint) {
        guard state == .readyToPlace, let sv = sceneView else { return }

        guard let query = sv.raycastQuery(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ) else { return }

        guard let hit  = sv.session.raycast(query).first,
              let frame = sv.session.currentFrame
        else { return }

        // Orient keyboard so its near edge (keyboard +Z) faces the camera.
        // Raw hit.worldTransform has gravity-aligned axes, not camera-view-aligned,
        // so the keyboard would appear sideways or backwards without this.
        let hitPos = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                   hit.worldTransform.columns.3.y,
                                   hit.worldTransform.columns.3.z)
        let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                   frame.camera.transform.columns.3.y,
                                   frame.camera.transform.columns.3.z)
        let toUser  = camPos - hitPos
        // Keyboard +Z = toward user (near edge); project onto horizontal plane.
        let rawZ    = SIMD3<Float>(toUser.x, 0, toUser.z)
        let kbZ     = simd_length(rawZ) > 0.01 ? simd_normalize(rawZ)
                                                : SIMD3<Float>(0, 0, 1)
        let kbY     = SIMD3<Float>(0, 1, 0)           // always world-up
        let kbX     = simd_cross(kbZ, kbY)             // keyboard right (low→high notes)

        var t = hit.worldTransform
        t.columns.0 = SIMD4<Float>(kbX.x, kbX.y, kbX.z, 0)
        t.columns.1 = SIMD4<Float>(kbY.x, kbY.y, kbY.z, 0)
        t.columns.2 = SIMD4<Float>(kbZ.x, kbZ.y, kbZ.z, 0)
        // columns.3 (translation) kept from hit.worldTransform

        let anchor = ARAnchor(name: "keyboard", transform: t)
        sv.session.add(anchor: anchor)
        state = .placed
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

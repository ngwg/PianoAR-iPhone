import SwiftUI
import ARKit
import SceneKit

struct ARPassthroughView: UIViewRepresentable {
    let session:       ARSessionModel
    let placement:     PlacementManager
    let calibration:   CalibrationManager
    let handTracker:   HandTracker
    let songPlayer:    SongPlayer
    let pressDetector: PressDetector
    let onTap:         (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(placement: placement, calibration: calibration,
                    handTracker: handTracker, songPlayer: songPlayer,
                    pressDetector: pressDetector, onTap: onTap)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session           = session.session
        view.delegate          = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously          = true
        view.preferredFramesPerSecond     = 60
        view.contentMode                  = .scaleAspectFill
        view.debugOptions                 = []

        placement.sceneView   = view
        calibration.sceneView = view

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        placement.sceneView   = uiView
        calibration.sceneView = uiView
        context.coordinator.onTap          = onTap
        context.coordinator.songPlayer     = songPlayer
        context.coordinator.pressDetector  = pressDetector
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let placement:     PlacementManager
        let calibration:   CalibrationManager
        let handTracker:   HandTracker
        var songPlayer:    SongPlayer
        var pressDetector: PressDetector
        var onTap: (CGPoint) -> Void

        private var hand3D:  Hand3DOverlay?
        private var highway: NoteHighway?
        private weak var keyboardNode: SCNNode?

        init(placement: PlacementManager, calibration: CalibrationManager,
             handTracker: HandTracker, songPlayer: SongPlayer,
             pressDetector: PressDetector,
             onTap: @escaping (CGPoint) -> Void) {
            self.placement     = placement
            self.calibration   = calibration
            self.handTracker   = handTracker
            self.songPlayer    = songPlayer
            self.pressDetector = pressDetector
            self.onTap         = onTap
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? ARSCNView else { return }
            onTap(g.location(in: v))
        }

        // MARK: Per-frame update — runs on the SceneKit render thread at 60 fps.
        // Updating SCNNode positions here means zero async-dispatch lag:
        // the nodes are repositioned and rendered in the same frame.

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame    = sceneView.session.currentFrame else { return }

            if hand3D == nil {
                hand3D = Hand3DOverlay(scene: sceneView.scene)
            }

            handTracker.maybeProcess(frame)
            let hands = handTracker.snapshot()
            hand3D?.update(hands: hands)

            // Press detection: fingertip depth vs. keyboard surface
            let presses = pressDetector.update(
                hands: hands, keyboardNode: keyboardNode, time: time
            )
            for p in presses {
                highway?.registerPress(keyIndex: p.keyIndex)
            }

            highway?.update(player: songPlayer)
        }

        // MARK: Anchor → node

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            if anchor.name == "keyboard" {
                let n  = KeyboardNode.make()
                let hw = NoteHighway()
                n.addChildNode(hw.rootNode)
                highway = hw
                keyboardNode = n
                pressDetector.reset()
                return n
            }
            if anchor.name == "keyboard_calibrated" {
                let n = KeyboardNode.makeOverlay()
                if let d = calibration.calibrationData {
                    n.scale = SCNVector3(d.widthScale, 1, d.depthScale)
                }
                let hw = NoteHighway()
                n.addChildNode(hw.rootNode)
                highway = hw
                keyboardNode = n
                pressDetector.reset()
                return n
            }
            if let name = anchor.name, name.hasPrefix("corner_") { return cornerMarker() }
            if let plane = anchor as? ARPlaneAnchor {
                placement.onPlaneAdded()
                return planeNode(for: plane)
            }
            return nil
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            updatePlane(node, for: plane)
        }

        private func cornerMarker() -> SCNNode {
            let s = SCNSphere(radius: 0.012); let m = SCNMaterial()
            m.diffuse.contents = UIColor.orange; m.emission.contents = UIColor.orange.withAlphaComponent(0.6)
            s.materials = [m]; return SCNNode(geometry: s)
        }

        private func planeNode(for a: ARPlaneAnchor) -> SCNNode {
            let root = SCNNode()
            let geo  = SCNPlane(width: CGFloat(a.planeExtent.width), height: CGFloat(a.planeExtent.height))
            let mat  = SCNMaterial(); mat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.22); mat.isDoubleSided = true
            geo.materials = [mat]
            let child = SCNNode(geometry: geo); child.name = "planeGeom"
            child.eulerAngles.x = -.pi / 2; child.simdPosition = a.center
            root.addChildNode(child); return root
        }

        private func updatePlane(_ node: SCNNode, for a: ARPlaneAnchor) {
            guard let c = node.childNode(withName: "planeGeom", recursively: false),
                  let g = c.geometry as? SCNPlane else { return }
            g.width = CGFloat(a.planeExtent.width); g.height = CGFloat(a.planeExtent.height)
            c.simdPosition = a.center
        }
    }
}

// MARK: - 3-D hand overlay

/// 21 joint spheres + 23 bone cylinders per hand, in world-space metres.
/// Sized like real anatomy so they scale correctly with hand distance.
/// Additive blending: overlapping volumes (palm, knuckles) add their glow
/// together and reach near-white, while thinner areas (finger tips) stay
/// semi-translucent — Quest-style fill without a real mesh.
private final class Hand3DOverlay {

    // Radii in metres, indexed parallel to HandTracker.allJoints.
    private static let sphereR: [Float] = [
        0.020,                                    // wrist
        0.011, 0.010, 0.009, 0.008,               // thumb
        0.012, 0.010, 0.009, 0.007,               // index
        0.012, 0.010, 0.009, 0.007,               // middle
        0.012, 0.010, 0.009, 0.007,               // ring
        0.010, 0.009, 0.008, 0.006,               // little
    ]
    private static let cylR: Float = 0.008        // finger-width cylinder

    private var sph: [[SCNNode]] = []   // [hand 0/1][joint 0-20]
    private var cyl: [[SCNNode]] = []   // [hand 0/1][bone  0-22]

    init(scene: SCNScene) {
        for _ in 0..<2 {
            var sNodes: [SCNNode] = []
            var cNodes: [SCNNode] = []

            for i in 0..<HandTracker.allJoints.count {
                let geo = SCNSphere(radius: CGFloat(Self.sphereR[i]))
                geo.segmentCount = 8          // low-poly — fine at finger scale
                geo.materials    = [Self.mat()]
                let n = SCNNode(geometry: geo)
                n.isHidden = true; n.renderingOrder = 100
                scene.rootNode.addChildNode(n)
                sNodes.append(n)
            }

            for _ in 0..<HandTracker.boneConnections.count {
                let geo = SCNCylinder(radius: CGFloat(Self.cylR), height: 1.0)
                geo.radialSegmentCount = 6    // hexagonal — smooth enough at 8-mm scale
                geo.materials    = [Self.mat()]
                let n = SCNNode(geometry: geo)
                n.isHidden = true; n.renderingOrder = 100
                scene.rootNode.addChildNode(n)
                cNodes.append(n)
            }

            sph.append(sNodes); cyl.append(cNodes)
        }
    }

    func update(hands: [HandTracker.HandResult]) {
        sph.forEach { $0.forEach { $0.isHidden = true } }
        cyl.forEach { $0.forEach { $0.isHidden = true } }

        for hand in hands {
            let h = hand.isLeft ? 0 : 1
            guard h < 2 else { continue }

            for (i, name) in HandTracker.allJoints.enumerated() {
                guard let p = hand.joints[name] else { continue }
                sph[h][i].simdPosition = p
                sph[h][i].isHidden     = false
            }

            for (i, (fi, ti)) in HandTracker.boneConnections.enumerated() {
                guard let a = hand.joints[HandTracker.allJoints[fi]],
                      let b = hand.joints[HandTracker.allJoints[ti]] else { continue }
                place(cyl[h][i], from: a, to: b)
            }
        }
    }

    // MARK: Helpers

    private static func mat() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel         = .constant     // unlit — not affected by scene lights
        m.diffuse.contents      = UIColor.black
        m.emission.contents     = UIColor(white: 0.32, alpha: 1.0)
        m.blendMode             = .add          // additive: overlaps accumulate toward white
        m.writesToDepthBuffer   = false         // hand nodes don't occlude each other
        m.readsFromDepthBuffer  = true          // still occluded by opaque scene objects
        m.isDoubleSided         = true
        return m
    }

    private func place(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let diff = b - a
        let len  = simd_length(diff)
        guard len > 0.001 else { return }
        let dir = diff / len
        let up  = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(dir, up)
        let q: simd_quatf
        if      dot >  0.9999 { q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        else if dot < -0.9999 { q = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)) }
        else                   { q = simd_quatf(from: up, to: dir) }
        node.simdPosition    = (a + b) * 0.5
        node.simdOrientation = q
        node.scale           = SCNVector3(1, Float(len), 1)
        node.isHidden        = false
    }
}

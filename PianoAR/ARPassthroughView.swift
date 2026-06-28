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
    let audioDetector: AudioPitchDetector
    let keyTuning:     KeyTuning
    let onTap:         (CGPoint) -> Void
    var onMenuAction:  ((MenuAction) -> Void)?
    var showDebug:     Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(placement: placement, calibration: calibration,
                    handTracker: handTracker, songPlayer: songPlayer,
                    pressDetector: pressDetector, audioDetector: audioDetector,
                    keyTuning: keyTuning,
                    onTap: onTap,
                    onMenuAction: onMenuAction)
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
        context.coordinator.onTap         = onTap
        context.coordinator.onMenuAction  = onMenuAction
        context.coordinator.showDebug     = showDebug
        context.coordinator.songPlayer    = songPlayer
        context.coordinator.pressDetector = pressDetector
        context.coordinator.audioDetector = audioDetector
        context.coordinator.keyTuning     = keyTuning
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let placement:     PlacementManager
        let calibration:   CalibrationManager
        let handTracker:   HandTracker
        var songPlayer:    SongPlayer
        var pressDetector: PressDetector
        var audioDetector: AudioPitchDetector
        var keyTuning:     KeyTuning
        var onTap:        (CGPoint) -> Void
        var onMenuAction: ((MenuAction) -> Void)?
        var showDebug:    Bool = false

        private var hand3D:      Hand3DOverlay?
        private var highway:     NoteHighway?
        private var menuOverlay: ARMenuOverlay?
        private let gestureDetector = GestureDetector()
        private weak var keyboardNode: SCNNode?

        init(placement: PlacementManager, calibration: CalibrationManager,
             handTracker: HandTracker, songPlayer: SongPlayer,
             pressDetector: PressDetector, audioDetector: AudioPitchDetector,
             keyTuning: KeyTuning,
             onTap: @escaping (CGPoint) -> Void,
             onMenuAction: ((MenuAction) -> Void)? = nil) {
            self.placement     = placement
            self.calibration   = calibration
            self.handTracker   = handTracker
            self.songPlayer    = songPlayer
            self.pressDetector = pressDetector
            self.audioDetector = audioDetector
            self.keyTuning     = keyTuning
            self.onTap         = onTap
            self.onMenuAction  = onMenuAction
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? ARSCNView else { return }
            onTap(g.location(in: v))
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame    = sceneView.session.currentFrame else { return }

            if hand3D == nil {
                hand3D = Hand3DOverlay(scene: sceneView.scene)
            }

            handTracker.maybeProcess(frame)
            let hands = handTracker.snapshot()
            let audio = audioDetector.snapshot()
            let expectedKeyIndices = songPlayer.expectedKeyIndicesNow()
            hand3D?.update(hands: hands)

            // ── Gesture detection ──────────────────────────────────────────
            let pinches = gestureDetector.update(hands: hands, time: time)
            if let kb = keyboardNode, let menu = menuOverlay {
                if let action = menu.update(
                    pinchEvents: pinches,
                    hands: hands,
                    keyboardNode: kb,
                    isPlaying: songPlayer.isPlaying,
                    debugOn: showDebug
                ) {
                    let cb = onMenuAction
                    DispatchQueue.main.async { cb?(action) }
                }
            }

            // ── Press detection ────────────────────────────────────────────
            let presses = pressDetector.update(
                hands: hands, keyboardNode: keyboardNode, time: time,
                audioSnapshot: audio,
                expectedKeyIndices: expectedKeyIndices,
                keyTuning: keyTuning
            )
            for p in presses {
                switch songPlayer.registerPress(keyIndex: p.keyIndex, noteName: p.noteName) {
                case .correct(let expectedKeyIndex, _):
                    highway?.registerPress(keyIndex: expectedKeyIndex)
                case .wrong(let playedKeyIndex, _, _, _):
                    highway?.registerMiss(keyIndex: playedKeyIndex)
                case .ignored:
                    highway?.registerPress(keyIndex: p.keyIndex)
                }
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
                let menu = ARMenuOverlay()
                n.addChildNode(menu.rootNode)
                menuOverlay = menu
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
                let menu = ARMenuOverlay()
                n.addChildNode(menu.rootNode)
                menuOverlay = menu
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

private final class Hand3DOverlay {

    private static let sphereR: [Float] = [
        0.020,
        0.011, 0.010, 0.009, 0.008,
        0.012, 0.010, 0.009, 0.007,
        0.012, 0.010, 0.009, 0.007,
        0.012, 0.010, 0.009, 0.007,
        0.010, 0.009, 0.008, 0.006,
    ]
    private static let cylR: Float = 0.008

    private var sph: [[SCNNode]] = []
    private var cyl: [[SCNNode]] = []

    init(scene: SCNScene) {
        for _ in 0..<2 {
            var sNodes: [SCNNode] = []
            var cNodes: [SCNNode] = []

            for i in 0..<HandTracker.allJoints.count {
                let geo = SCNSphere(radius: CGFloat(Self.sphereR[i]))
                geo.segmentCount = 8
                geo.materials    = [Self.mat()]
                let n = SCNNode(geometry: geo)
                n.isHidden = true; n.renderingOrder = 100
                scene.rootNode.addChildNode(n)
                sNodes.append(n)
            }

            for _ in 0..<HandTracker.boneConnections.count {
                let geo = SCNCylinder(radius: CGFloat(Self.cylR), height: 1.0)
                geo.radialSegmentCount = 6
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

    private static func mat() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel        = .constant
        m.diffuse.contents     = UIColor.black
        m.emission.contents    = UIColor(white: 0.32, alpha: 1.0)
        m.blendMode            = .add
        m.writesToDepthBuffer  = false
        // Depth-reading against virtual key geometry causes hand spheres to flicker
        // when fingertips are at key-surface depth. Drawing hand markers on top of
        // everything is the correct behaviour — you always want to see them.
        m.readsFromDepthBuffer = false
        m.isDoubleSided        = true
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

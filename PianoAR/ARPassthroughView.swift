import SwiftUI
import ARKit
import SceneKit
import ImageIO

struct ARPassthroughView: UIViewRepresentable {
    let session:       ARSessionModel
    let calibration:   CalibrationManager
    let handTracker:   HandTracker
    let songPlayer:    SongPlayer
    let pressDetector: PressDetector
    let audioDetector: AudioPitchDetector
    let keyTuning:     KeyTuning
    var onMenuAction:   ((MenuAction) -> Void)?
    var showDebug:      Bool   = false
    var availableSongs: [Song] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(calibration: calibration,
                    handTracker: handTracker, songPlayer: songPlayer,
                    pressDetector: pressDetector, audioDetector: audioDetector,
                    keyTuning: keyTuning,
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

        calibration.sceneView = view

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        calibration.sceneView = uiView

        // Feed Vision the correct image orientation for the actual mounting.
        // ARKit's capturedImage is upright for landscapeRight (.up); landscapeLeft
        // is 180° from that (.down). Getting this right keeps hand detection sharp
        // and — critically — keeps left/right chirality correct.
        if let io = uiView.window?.windowScene?.interfaceOrientation {
            handTracker.imageOrientation = (io == .landscapeLeft) ? .down : .up
        }
        context.coordinator.onMenuAction   = onMenuAction
        context.coordinator.showDebug      = showDebug
        context.coordinator.availableSongs = availableSongs
        context.coordinator.songPlayer     = songPlayer
        context.coordinator.pressDetector  = pressDetector
        context.coordinator.audioDetector  = audioDetector
        context.coordinator.keyTuning      = keyTuning
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let calibration:   CalibrationManager
        let handTracker:   HandTracker
        var songPlayer:    SongPlayer
        var pressDetector: PressDetector
        var audioDetector: AudioPitchDetector
        var keyTuning:     KeyTuning
        var onMenuAction:   ((MenuAction) -> Void)?
        var showDebug:      Bool   = false
        var availableSongs: [Song] = []

        private var hand3D:      Hand3DOverlay?
        private var highway:     NoteHighway?
        private var menuOverlay: ARMenuOverlay?
        private var hintBar:     HintBarOverlay?
        private weak var keyboardNode: SCNNode?

        init(calibration: CalibrationManager,
             handTracker: HandTracker, songPlayer: SongPlayer,
             pressDetector: PressDetector, audioDetector: AudioPitchDetector,
             keyTuning: KeyTuning,
             onMenuAction: ((MenuAction) -> Void)? = nil) {
            self.calibration   = calibration
            self.handTracker   = handTracker
            self.songPlayer    = songPlayer
            self.pressDetector = pressDetector
            self.audioDetector = audioDetector
            self.keyTuning     = keyTuning
            self.onMenuAction  = onMenuAction
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? ARSCNView else { return }
            calibration.handleTap(at: g.location(in: v))
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
            // Hand model renders above UI (renderingOrder 300 > buttons 200)
            hand3D?.update(hands: hands, menu: menuOverlay, keyboardNode: keyboardNode)

            // Try to find the keyboard automatically while waiting for the
            // first corner tap (manual taps always take precedence).
            calibration.attemptAutoDetect(frame: frame,
                                          orientation: handTracker.imageOrientation,
                                          time: time)

            // ── Setup hint bar (camera-locked AR text) ─────────────────────────
            if hintBar == nil, let cam = sceneView.pointOfView {
                hintBar = HintBarOverlay(cameraNode: cam)
            }
            hintBar?.update(text: currentHintText())

            // AR menu: direct fingertip touch — no pinch required
            if let kb = keyboardNode, let menu = menuOverlay {
                let camT = frame.camera.transform.columns.3
                if let action = menu.update(
                    hands: hands,
                    keyboardNode: kb,
                    time: time,
                    isPlaying: songPlayer.isPlaying,
                    debugOn: showDebug,
                    availableSongs: availableSongs,
                    cameraWorldPos: SIMD3<Float>(camT.x, camT.y, camT.z)
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
                return planeNode(for: plane)
            }
            return nil
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            updatePlane(node, for: plane)
        }

        private func currentHintText() -> String {
            switch calibration.state {
            case .idle:
                return "Tap the screen at each corner of your piano"
            case .collecting(let n):
                let labels = [
                    "Auto-scanning for your keyboard… or tap corner 1/4 (near-left)",
                    "Tap corner 2/4 — near-right (high notes, front)",
                    "Tap corner 3/4 — far-right (high notes, back)",
                    "Tap corner 4/4 — far-left (low notes, back)",
                ]
                return labels[min(n, 3)]
            case .done:
                return ""
            }
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

// MARK: - Camera-locked hint bar
//
// Small always-in-view text pill for setup guidance (surface scanning, corner
// calibration instructions). Parented to the camera node so it stays in view,
// so this is the last piece of UI in the app that's fully in AR — nothing is
// drawn in 2-D SwiftUI over the video feed.

private final class HintBarOverlay {
    private static let w: Float = 0.34
    private static let h: Float = 0.052
    private static let texW: CGFloat = 760
    private static let texH: CGFloat = 116
    private static let camOffset = SCNVector3(0, -0.15, -0.55)

    private let node: SCNNode
    private let mat:  SCNMaterial
    private var lastText = ""

    init(cameraNode: SCNNode) {
        let geo = SCNPlane(width: CGFloat(Self.w), height: CGFloat(Self.h))
        mat = SCNMaterial()
        mat.lightingModel        = .constant
        mat.diffuse.contents     = UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 0.85)
        mat.blendMode            = .alpha
        mat.isDoubleSided        = true
        mat.writesToDepthBuffer  = false
        mat.readsFromDepthBuffer = false
        geo.materials = [mat]

        node = SCNNode(geometry: geo)
        node.position       = Self.camOffset
        node.renderingOrder = 240
        node.opacity        = 0
        cameraNode.addChildNode(node)
    }

    func update(text: String) {
        guard !text.isEmpty else {
            if node.opacity > 0.01 { node.runAction(SCNAction.fadeOut(duration: 0.20)) }
            lastText = ""
            return
        }
        if node.opacity < 0.95 { node.runAction(SCNAction.fadeIn(duration: 0.25)) }
        guard text != lastText else { return }
        lastText = text
        let m = mat
        DispatchQueue.main.async { m.diffuse.contents = HintBarOverlay.bake(text) }
    }

    func remove() { node.removeFromParentNode() }

    private static func bake(_ text: String) -> UIImage {
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { _ in
            let rect = CGRect(origin: .zero, size: sz).insetBy(dx: 4, dy: 4)
            UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 0.88).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 28).fill()
            UIColor(white: 1, alpha: 0.16).setStroke()
            let b = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 28)
            b.lineWidth = 1.5
            b.stroke()

            let para = NSMutableParagraphStyle()
            para.alignment     = .center
            para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para,
            ]
            (text as NSString).draw(in: rect.insetBy(dx: 24, dy: 14), withAttributes: attrs)
        }
    }
}

// MARK: - 3-D hand overlay
//
// Renders a realistic skin-toned hand skeleton in world space.
// renderingOrder = 300 ensures the hand always appears in front of the AR
// menu buttons (200) and note-highway geometry (50–100), so the player's
// virtual hand visually "goes over" all UI elements.
//
// The index-fingertip node doubles as a touch cursor: it glows blue when
// near an AR menu button and green when within trigger distance.

private final class Hand3DOverlay {

    // Joint sphere radii (mm → m), indexed by HandTracker.allJoints order
    // [0]=wrist, [1-4]=thumb, [5-8]=index, [9-12]=middle, [13-16]=ring, [17-20]=little
    private static let sphereR: [Float] = [
        0.018,                              // wrist
        0.010, 0.009, 0.008, 0.007,        // thumb CMC MP IP TIP
        0.011, 0.009, 0.008, 0.007,        // index MCP PIP DIP TIP
        0.011, 0.009, 0.008, 0.007,        // middle
        0.010, 0.009, 0.008, 0.007,        // ring
        0.009, 0.008, 0.007, 0.006,        // little
    ]
    private static let cylR: Float = 0.0055

    // Index joint in allJoints that is the index fingertip (used as touch cursor)
    private static let indexTipJoint = 8
    private static let thumbTipJoint = 4

    // Skin-tone palette (CGColor — thread-safe for render-thread emission changes)
    private static let cgSkin  = CGColor(red: 0.88, green: 0.71, blue: 0.55, alpha: 1)
    private static let cgCursorHover   = CGColor(red: 0.15, green: 0.55, blue: 1.00, alpha: 1)
    private static let cgCursorTouch   = CGColor(red: 0.08, green: 0.96, blue: 0.40, alpha: 1)
    private static let cgCursorInactive = CGColor(red: 0.70, green: 0.55, blue: 0.42, alpha: 1)

    // Nodes: [hand 0=left, 1=right][joint/bone index]
    private var sph:    [[SCNNode]] = []
    private var cyl:    [[SCNNode]] = []
    // Render-rate presentation positions. Vision updates at 10-20Hz depending
    // on thermals; easing toward each new tracked target at 60Hz removes the
    // visible staircase without feeding delayed points back into detection.
    private var displayPositions: [[SIMD3<Float>?]] = []
    // Separate tracked index-tip sphere materials for cursor glow changes
    private var idxTipMat: [SCNMaterial] = []

    init(scene: SCNScene) {
        let skinMat  = Self.makeMat(skin: true,  isTip: false)
        let tipMat   = Self.makeMat(skin: true,  isTip: true)
        let boneMat  = Self.makeMat(skin: false, isTip: false)

        for _ in 0..<2 {
            var sNodes: [SCNNode] = []
            var cNodes: [SCNNode] = []
            var idxMat: SCNMaterial?

            for i in 0..<HandTracker.allJoints.count {
                let r   = CGFloat(Self.sphereR[i])
                let geo = SCNSphere(radius: r)
                geo.segmentCount = 10
                let isTip = (i == Self.indexTipJoint || i == Self.thumbTipJoint ||
                              i == 12 || i == 16 || i == 20)
                let mat: SCNMaterial
                if i == Self.indexTipJoint {
                    // Dedicated mutable material for cursor glow
                    mat = Self.makeMat(skin: true, isTip: true)
                    idxMat = mat
                } else {
                    mat = isTip ? tipMat : skinMat
                }
                geo.materials = [mat]
                let n = SCNNode(geometry: geo)
                n.isHidden       = true
                n.renderingOrder = 300
                scene.rootNode.addChildNode(n)
                sNodes.append(n)
            }

            for _ in 0..<HandTracker.boneConnections.count {
                let geo = SCNCylinder(radius: CGFloat(Self.cylR), height: 1.0)
                geo.radialSegmentCount = 8
                geo.materials    = [boneMat]
                let n = SCNNode(geometry: geo)
                n.isHidden       = true
                n.renderingOrder = 300
                scene.rootNode.addChildNode(n)
                cNodes.append(n)
            }

            sph.append(sNodes)
            cyl.append(cNodes)
            displayPositions.append(Array(repeating: nil,
                                          count: HandTracker.allJoints.count))
            idxTipMat.append(idxMat ?? Self.makeMat(skin: true, isTip: true))
        }
    }

    /// Call from render thread. `menu` and `keyboardNode` are optional:
    /// if provided, the index-fingertip cursor node changes colour based on
    /// its proximity to AR menu buttons.
    func update(hands: [HandTracker.HandResult],
                menu: ARMenuOverlay?,
                keyboardNode: SCNNode?) {
        sph.forEach { $0.forEach { $0.isHidden = true } }
        cyl.forEach { $0.forEach { $0.isHidden = true } }
        var activeTracks = Set<Int>()

        for hand in hands {
            let h = hand.id
            guard sph.indices.contains(h) else { continue }
            activeTracks.insert(h)

            for (i, name) in HandTracker.allJoints.enumerated() {
                guard let target = hand.joints[name] else {
                    displayPositions[h][i] = nil
                    continue
                }
                // Directly-tracked joints render exactly where the tracker put
                // them — the stabilizer already smooths, and easing again here
                // stacked a second lag on top ("there is a delay"). Only
                // reconstructed joints keep light easing to hide their jumps.
                let presented: SIMD3<Float>
                if hand.estimated.contains(name),
                   let previous = displayPositions[h][i],
                   simd_length(target - previous) < 0.12 {
                    presented = previous + (target - previous) * 0.55
                } else {
                    presented = target
                }
                displayPositions[h][i] = presented
                sph[h][i].simdPosition = presented
                sph[h][i].opacity = CGFloat(hand.visibility)
                sph[h][i].isHidden     = false
            }

            for (i, (fi, ti)) in HandTracker.boneConnections.enumerated() {
                guard !sph[h][fi].isHidden, !sph[h][ti].isHidden else { continue }
                let a = sph[h][fi].simdPosition
                let b = sph[h][ti].simdPosition
                placeCylinder(cyl[h][i], from: a, to: b)
                cyl[h][i].opacity = CGFloat(hand.visibility)
            }

            // Touch cursor: colour the index-tip sphere based on menu proximity
            if let idxWorld = hand.joints[HandTracker.allJoints[Self.indexTipJoint]],
               let m = menu, let kb = keyboardNode {
                let prox = m.maxProximity(worldPos: idxWorld, keyboardNode: kb)
                // Proximity: 0=none, <0.4=approach, 0.4-0.9=hover, >0.9=near-touch
                let cursorColor: CGColor
                if prox > 0.88 {
                    cursorColor = Self.cgCursorTouch   // green — about to trigger
                } else if prox > 0.20 {
                    // Lerp blue intensity with proximity
                    let t = (prox - 0.20) / 0.68
                    cursorColor = CGColor(red: 0.15 + CGFloat(t) * 0.0,
                                         green: 0.55 - CGFloat(t) * 0.25,
                                         blue: 1.00,
                                         alpha: 1)
                } else {
                    cursorColor = Self.cgCursorInactive
                }
                idxTipMat[h].emission.contents = cursorColor
            }
        }

        for h in displayPositions.indices where !activeTracks.contains(h) {
            displayPositions[h] = Array(repeating: nil,
                                        count: HandTracker.allJoints.count)
        }
    }

    // ── Material factories ────────────────────────────────────────────────

    private static func makeMat(skin: Bool, isTip: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel        = .constant
        if skin {
            // Warm skin tone — alpha blend so it looks solid, not additive
            m.diffuse.contents   = UIColor(red: 0.86, green: 0.69, blue: 0.53, alpha: isTip ? 1.0 : 0.88)
            m.emission.contents  = isTip
                ? CGColor(red: 0.70, green: 0.55, blue: 0.42, alpha: 1)  // initial cursor colour
                : CGColor(red: 0.20, green: 0.13, blue: 0.07, alpha: 1)  // subtle warm self-emission
        } else {
            // Bone cylinders: slightly darker skin
            m.diffuse.contents   = UIColor(red: 0.78, green: 0.62, blue: 0.47, alpha: 0.82)
            m.emission.contents  = CGColor(red: 0.15, green: 0.09, blue: 0.04, alpha: 1)
        }
        m.blendMode            = .alpha
        m.writesToDepthBuffer  = false
        m.readsFromDepthBuffer = false   // always render, never hidden by virtual geometry
        m.isDoubleSided        = true
        return m
    }

    // ── Cylinder placement (render thread) ───────────────────────────────

    private func placeCylinder(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
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

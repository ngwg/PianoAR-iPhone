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

        // Hand scan: loads the saved per-user bone-length profile, or runs a
        // one-time scan at startup ("hold your hands out") and persists it.
        private var handProfile: HandProfile? = HandProfile.load()
        private let handScanner = HandScanner()

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
                hand3D?.profile = handProfile
            }

            handTracker.maybeProcess(frame)
            let hands = handTracker.snapshot()
            let audio = audioDetector.snapshot()
            let expectedKeyIndices = songPlayer.expectedKeyIndicesNow()

            // One-time hand scan (first launch only): measure the user's bone
            // lengths while they hold their hands in view, save to storage,
            // then drive the hand model through the fixed-length skeleton.
            if handProfile == nil {
                if handScanner.ingest(hands: hands, time: time),
                   let p = handScanner.profile {
                    handProfile = p
                    hand3D?.profile = p
                    DispatchQueue.main.async { p.save() }
                }
            }

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
            if handProfile == nil { return handScanner.hintText }
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
// Renders a hologram-style "glove" skeleton around the user's real hand:
// translucent additive cyan bones + joints, so the real hand stays visible
// through it in passthrough instead of being covered by opaque blobs.
//
// When a HandProfile is set (measured at first launch, saved on device), the
// skeleton is driven through a forward-kinematics pass that enforces the
// user's real bone lengths: per-frame Vision noise can slide a joint along
// its bone but can no longer stretch or shrink the bone, which makes the
// whole hand read as one rigid model instead of independently jittering dots.
//
// renderingOrder = 300 ensures the hand always appears in front of the AR
// menu panel (200) and note-highway geometry (50–100). The index-fingertip
// node doubles as a touch cursor: blue near the AR menu, green at trigger.

private final class Hand3DOverlay {

    // Joint sphere radii (m), indexed by HandTracker.allJoints order
    // [0]=wrist, [1-4]=thumb, [5-8]=index, [9-12]=middle, [13-16]=ring, [17-20]=little
    private static let sphereR: [Float] = [
        0.011,                              // wrist
        0.007, 0.006, 0.0055, 0.0065,      // thumb CMC MP IP TIP
        0.007, 0.006, 0.0055, 0.0065,      // index
        0.007, 0.006, 0.0055, 0.0065,      // middle
        0.007, 0.006, 0.0055, 0.0065,      // ring
        0.0065, 0.0055, 0.005, 0.006,      // little
    ]
    private static let cylR: Float = 0.0032

    private static let indexTipJoint = 8

    // Hologram palette (CGColor — thread-safe for render-thread changes)
    private static let cgBone   = CGColor(red: 0.35, green: 0.75, blue: 1.00, alpha: 0.55)
    private static let cgJoint  = CGColor(red: 0.55, green: 0.85, blue: 1.00, alpha: 0.75)
    private static let cgTip    = CGColor(red: 0.80, green: 0.95, blue: 1.00, alpha: 0.95)
    private static let cgCursorTouch = CGColor(red: 0.10, green: 0.98, blue: 0.45, alpha: 1)

    /// Bone-length profile measured at first launch; nil until scanned.
    var profile: HandProfile?

    // Nodes: [hand 0=left, 1=right][joint/bone index]
    private var sph: [[SCNNode]] = []
    private var cyl: [[SCNNode]] = []
    private var idxTipMat: [SCNMaterial] = []

    init(scene: SCNScene) {
        let jointMat = Self.makeMat(Self.cgJoint)
        let tipMat   = Self.makeMat(Self.cgTip)
        let boneMat  = Self.makeMat(Self.cgBone)

        for _ in 0..<2 {
            var sNodes: [SCNNode] = []
            var cNodes: [SCNNode] = []
            var idxMat: SCNMaterial?

            for i in 0..<HandTracker.allJoints.count {
                let geo = SCNSphere(radius: CGFloat(Self.sphereR[i]))
                geo.segmentCount = 12
                let isTip = (i == 4 || i == 8 || i == 12 || i == 16 || i == 20)
                let mat: SCNMaterial
                if i == Self.indexTipJoint {
                    mat = Self.makeMat(Self.cgTip)     // dedicated: cursor glow
                    idxMat = mat
                } else {
                    mat = isTip ? tipMat : jointMat
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
            idxTipMat.append(idxMat ?? Self.makeMat(Self.cgTip))
        }
    }

    /// Call from render thread.
    func update(hands: [HandTracker.HandResult],
                menu: ARMenuOverlay?,
                keyboardNode: SCNNode?) {
        sph.forEach { $0.forEach { $0.isHidden = true } }
        cyl.forEach { $0.forEach { $0.isHidden = true } }

        for hand in hands {
            let h = hand.isLeft ? 0 : 1
            guard h < sph.count else { continue }

            // Collect joint positions by index.
            var pos: [Int: SIMD3<Float>] = [:]
            for (i, name) in HandTracker.allJoints.enumerated() {
                if let p = hand.joints[name] { pos[i] = p }
            }

            // Forward-kinematics pass: walk each finger chain from the wrist
            // outward, re-projecting every child joint onto its calibrated
            // bone length. boneConnections lists chains in wrist→tip order,
            // so parents are always corrected before their children. The 3
            // palm cross-links at the end are visual-only and stay free.
            if let lens = profile?.lengths(isLeft: hand.isLeft) {
                for i in 0..<min(HandProfile.chainBoneCount, lens.count) {
                    let (a, b) = HandTracker.boneConnections[i]
                    guard let pa = pos[a], let pb = pos[b] else { continue }
                    let d = pb - pa
                    let l = simd_length(d)
                    guard l > 1e-4 else { continue }
                    pos[b] = pa + d / l * lens[i]
                }
            }

            for (i, p) in pos {
                sph[h][i].simdPosition = p
                sph[h][i].isHidden     = false
            }
            for (i, (fi, ti)) in HandTracker.boneConnections.enumerated() {
                guard let a = pos[fi], let b = pos[ti] else { continue }
                placeCylinder(cyl[h][i], from: a, to: b)
            }

            // Touch cursor: index-tip colour tracks AR-menu proximity.
            if let idxWorld = pos[Self.indexTipJoint],
               let m = menu, let kb = keyboardNode {
                let prox = m.maxProximity(worldPos: idxWorld, keyboardNode: kb)
                let cursorColor: CGColor
                if prox > 0.88 {
                    cursorColor = Self.cgCursorTouch
                } else if prox > 0.20 {
                    let t = CGFloat((prox - 0.20) / 0.68)
                    cursorColor = CGColor(red: 0.30 + t * 0.2, green: 0.75,
                                          blue: 1.0, alpha: 0.85 + t * 0.15)
                } else {
                    cursorColor = Self.cgTip
                }
                idxTipMat[h].emission.contents = cursorColor
            }
        }
    }

    // ── Material factory (additive hologram) ──────────────────────────────

    private static func makeMat(_ color: CGColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel        = .constant
        m.diffuse.contents     = UIColor.black          // additive: colour via emission
        m.emission.contents    = color
        m.blendMode            = .add
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

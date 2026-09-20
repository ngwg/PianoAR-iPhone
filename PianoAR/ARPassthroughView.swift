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
    var comfort:        ComfortSnapshot
    var onMenuAction:   ((MenuAction) -> Void)?
    var showDebug:      Bool   = false
    var showKeyLabels:  Bool   = true
    var alignment = KeyboardAlignment()           // SETUP › ALIGN fine placement
    var recorder: SessionRecorder?                // SETUP › RECORD diagnostics
    var calibrationRun: PianoCalibration?         // SETUP › CALIBRATE guided pass
    var availableSongs: [Song] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(calibration: calibration,
                    handTracker: handTracker, songPlayer: songPlayer,
                    pressDetector: pressDetector, audioDetector: audioDetector,
                    keyTuning: keyTuning)
    }

    func makeUIView(context: Context) -> StereoARContainer {
        let container = StereoARContainer(session: session.session)
        // Only the LEFT view drives the app: delegate callbacks, anchors, and
        // raycasts all go through it.
        container.left.delegate = context.coordinator
        context.coordinator.warp = container.warp
        calibration.sceneView = container.left
        container.apply(comfort)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        container.addGestureRecognizer(tap)
        return container
    }

    func updateUIView(_ uiView: StereoARContainer, context: Context) {
        calibration.sceneView = uiView.left

        // Feed Vision the correct image orientation for the actual mounting.
        // ARKit's capturedImage is upright for landscapeRight (.up); landscapeLeft
        // is 180° from that (.down). Getting this right keeps hand detection sharp
        // and — critically — keeps left/right chirality correct.
        if let io = uiView.window?.windowScene?.interfaceOrientation {
            handTracker.imageOrientation = (io == .landscapeLeft) ? .down : .up
        }
        if uiView.comfort != comfort { uiView.apply(comfort) }

        context.coordinator.onMenuAction = onMenuAction
        context.coordinator.config.set(Coordinator.Config(
            showDebug: showDebug,
            showKeyLabels: showKeyLabels,
            comfort: comfort,
            alignment: alignment,
            recorder: recorder,
            calibration: calibrationRun,
            songs: availableSongs
        ))
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        /// Everything SwiftUI hands the render thread, swapped atomically.
        struct Config {
            var showDebug = false
            var showKeyLabels = true
            var comfort = ComfortSnapshot.default
            var alignment = KeyboardAlignment()
            var recorder: SessionRecorder?
            var calibration: PianoCalibration?
            var songs: [Song] = []
        }

        let calibration:   CalibrationManager
        let handTracker:   HandTracker
        let songPlayer:    SongPlayer
        let pressDetector: PressDetector
        let audioDetector: AudioPitchDetector
        let keyTuning:     KeyTuning
        let config = Locked(Config())
        var onMenuAction: ((MenuAction) -> Void)?
        weak var warp: MotionWarp?

        private var hand3D:      Hand3DOverlay?
        private var highway:     NoteHighway?
        private var menuOverlay: ARMenuOverlay?
        private var hud:         PracticeHUDOverlay?
        private var debugPanel:  DebugPanelOverlay?
        private var hintBar:     HintBarOverlay?
        /// The keyboard content node: key tops sit at y = whiteKeyHeight in
        /// its local space, exactly on the real key tops (see nodeFor).
        private weak var keyboardNode: SCNNode?
        /// Unscaled parent of the keyboard content + UI panels (alignment target).
        private weak var keyboardFrame: SCNNode?
        private weak var outlines: SCNNode?
        private var outlinesUntil: TimeInterval = 0
        private var baseScale = SIMD2<Float>(1, 1)          // mapped width / depth scale
        private var pinchMarker: SCNNode?
        private let planeNodes = NSHashTable<SCNNode>.weakObjects()
        private var lastFrameTime: TimeInterval = 0
        private var fps: Double = 60
        private var loggedSerial = -1
        private var lastTuningSave: TimeInterval = 0
        private var wasRecording = false
        private var lastHeardAttack = -1

        init(calibration: CalibrationManager,
             handTracker: HandTracker, songPlayer: SongPlayer,
             pressDetector: PressDetector, audioDetector: AudioPitchDetector,
             keyTuning: KeyTuning) {
            self.calibration   = calibration
            self.handTracker   = handTracker
            self.songPlayer    = songPlayer
            self.pressDetector = pressDetector
            self.audioDetector = audioDetector
            self.keyTuning     = keyTuning
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let container = g.view as? StereoARContainer else { return }
            // Both eyes show the same image; a tap on either maps to the same
            // point of the driving (left) view.
            calibration.handleTap(at: container.leftViewPoint(for: g.location(in: container)))
        }

        // MARK: Per-frame loop (SceneKit render thread)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame    = sceneView.session.currentFrame else { return }
            // The frame this pass draws — MotionWarp re-aims it until the next.
            warp?.noteRendered(frame: frame)
            let cfg = config.get()
            if lastFrameTime > 0, time > lastFrameTime {
                fps += (1 / (time - lastFrameTime) - fps) * 0.05
            }
            lastFrameTime = time

            if hand3D == nil { hand3D = Hand3DOverlay(scene: sceneView.scene) }

            handTracker.maybeProcess(frame)
            let hands = handTracker.snapshot()
            let audio = audioDetector.snapshot()
            let camT  = frame.camera.transform.columns.3
            let camPos = SIMD3<Float>(camT.x, camT.y, camT.z)

            songPlayer.tick()
            cfg.recorder?.tick()
            // Acknowledge the strike immediately — identifying the note takes
            // a third of a second, hearing one takes 40 ms.
            if let att = audio.attack, att.id != lastHeardAttack {
                lastHeardAttack = att.id
                highway?.registerStrike()
            }
            // What the verifier has learned about this piano, kept for the
            // next session (cheap: only writes when something changed).
            if time - lastTuningSave > 4 { lastTuningSave = time; PianoTuning.shared.saveIfNeeded() }
            let pending   = songPlayer.pendingKeyIndicesNow()
            let groupKeys = songPlayer.groupKeyIndicesNow()
            // Re-announce the expected notes whenever recording starts, not
            // only when the group changes: the first recording came back with
            // no "expect" lines at all, because the one that mattered had been
            // emitted before the recorder was switched on.
            let rec = cfg.recorder?.isRecording ?? false
            if rec != wasRecording { wasRecording = rec; if rec { loggedSerial = -1 } }
            if songPlayer.groupSerial != loggedSerial {
                loggedSerial = songPlayer.groupSerial
                cfg.recorder?.log("expect", [
                    "serial": songPlayer.groupSerial,
                    "playing": songPlayer.isPlaying,
                    "wait": songPlayer.waitMode,
                    "keys": groupKeys.sorted(),
                    "names": groupKeys.sorted().map { KeyboardLayout.keys[$0].noteName },
                    "pending": pending.sorted(),
                ])
            }
            audioDetector.setExpectedKeys(groupKeys, relax: songPlayer.struggle)

            hand3D?.update(hands: hands, style: cfg.comfort.handStyle,
                           menu: menuOverlay, keyboardNode: keyboardNode)

            // ── Calibration: pinch mapping (and taps), planes, hints ─────────
            calibration.attemptAutoDetect(frame: frame,
                                          orientation: handTracker.imageOrientation,
                                          time: time)
            calibration.attemptPinchMapping(hands: hands, cameraPosition: camPos, time: time)
            let calibrating = calibration.state.isCollecting
            for node in planeNodes.allObjects { node.isHidden = !calibrating }
            updatePinchMarker(scene: sceneView.scene)

            if hintBar == nil, let cam = sceneView.pointOfView {
                hintBar = HintBarOverlay(cameraNode: cam)
            }
            // Calibration takes over the hint bar and logs a labelled
            // example for every onset: what was asked for, and when.
            if let cal = cfg.calibration, cal.active {
                if let asked = cal.consume(attack: audio.attack, time: time) {
                    cfg.recorder?.log("calib", [
                        "key": asked,
                        "name": KeyboardLayout.keys[asked].noteName,
                        "onset": audio.attack?.timestamp ?? time,
                        "index": cal.index - 1,
                    ])
                }
                hintBar?.update(text: cal.prompt)
            } else {
                hintBar?.update(text: currentHintText(time: time))
            }

            // Fine placement from SETUP › ALIGN, on top of the mapping.
            let a = cfg.alignment
            keyboardFrame?.simdPosition = SIMD3<Float>(a.x, -KeyboardLayout.whiteKeyHeight + a.y, a.z)
            keyboardFrame?.simdOrientation = simd_quatf(angle: a.yaw, axis: SIMD3<Float>(0, 1, 0))
            keyboardNode?.scale = SCNVector3(baseScale.x * a.width, 1, baseScale.y)
            outlines?.isHidden = !((menuOverlay?.showsAlignment ?? false) || time < outlinesUntil)

            // ── AR menu ──────────────────────────────────────────────────────
            if let kb = keyboardNode, let menu = menuOverlay {
                let hud = songPlayer.hudSnapshot()
                let state = MenuState(
                    isPlaying: hud.isPlaying,
                    isComplete: hud.isComplete,
                    debugOn: cfg.showDebug,
                    songTitles: cfg.songs.map { $0.title ?? "Untitled" },
                    currentTitle: songPlayer.song?.title ?? "",
                    tempoPercent: hud.tempoPercent,
                    hand: hud.hand,
                    waitMode: hud.waitMode,
                    comfort: cfg.comfort,
                    keyLabels: cfg.showKeyLabels,
                    alignReadout: cfg.alignment.readout,
                    recording: cfg.recorder?.isRecording ?? false,
                    recordSeconds: cfg.recorder?.seconds ?? 0,
                    calibrating: cfg.calibration?.active ?? false)
                if let action = menu.update(hands: hands, keyboardNode: kb, time: time,
                                            state: state, availableSongs: cfg.songs,
                                            cameraWorldPos: camPos) {
                    let cb = onMenuAction
                    DispatchQueue.main.async { cb?(action) }
                }
            }

            // ── Press detection ────────────────────────────────────────────
            let presses = pressDetector.update(
                hands: hands, keyboardNode: keyboardNode, time: time,
                audioSnapshot: audio,
                expectedKeyIndices: pending,
                groupKeyIndices: groupKeys,
                upcomingKeyIndices: songPlayer.upcomingKeyIndices(),
                struggling: songPlayer.struggle >= 2,
                groupSerial: songPlayer.groupSerial,
                keyTuning: keyTuning
            )
            for p in presses {
                let outcome = songPlayer.registerPress(keyIndex: p.keyIndex, noteName: p.noteName,
                                                       at: p.timestamp)
                cfg.recorder?.log("accept", [
                    "k": p.keyIndex, "n": p.noteName, "c": p.confidence,
                    "src": p.source.rawValue, "strike": p.timestamp,
                    "outcome": String(describing: outcome).prefix(24).description,
                ])
                switch outcome {
                case .correct(let expectedKeyIndex, _):
                    highway?.registerPress(keyIndex: expectedKeyIndex)
                case .wrong(let playedKeyIndex, _, _, _):
                    highway?.registerMiss(keyIndex: playedKeyIndex)
                case .ignored:
                    // Free play: still show what was detected.
                    if !songPlayer.isPlaying { highway?.registerPress(keyIndex: p.keyIndex) }
                }
            }

            highway?.showKeyLabels = cfg.showKeyLabels
            highway?.update(player: songPlayer)
            hud?.update(hud: songPlayer.hudSnapshot(), time: time)
            debugPanel?.update(visible: cfg.showDebug,
                               lines: cfg.showDebug ? debugLines(frame: frame, hands: hands) : [],
                               time: time)
        }

        private func debugLines(frame: ARFrame, hands: [HandTracker.HandResult]) -> [String] {
            let tracking: String
            switch frame.camera.trackingState {
            case .normal: tracking = "normal"
            case .notAvailable: tracking = "not available"
            case .limited: tracking = "limited"
            }
            let thermal: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: thermal = "cool"
            case .fair: thermal = "warm"
            case .serious: thermal = "HOT"
            case .critical: thermal = "CRITICAL"
            @unknown default: thermal = "?"
            }
            let depth = frame.smoothedSceneDepth != nil || frame.sceneDepth != nil
            var lines = [
                "— SYSTEM",
                String(format: "%.0f fps · tracking %@ · %@", fps, tracking, thermal),
                "hands \(hands.count) · LiDAR depth \(depth ? "yes" : "no")",
                "— PRESS DETECTION",
            ]
            lines += pressDetector.debugSnapshot().prefix(14)
            lines.append("— AUDIO")
            lines += audioDetector.debugSnapshot().prefix(6)
            lines.append(PianoTuning.shared.readout())
            return lines
        }

        // MARK: Anchor → node

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            if anchor.name == "keyboard_calibrated" {
                let root = SCNNode()

                // Corner taps / auto-detect raycast onto the real KEY TOPS, so
                // the anchor origin sits at key-top height. KeyboardLayout's
                // frame puts key tops at y = whiteKeyHeight, so everything sits
                // that much lower. (It used to float ~1.5 cm above the keys; seen
                // from the head at a steep angle that parallax slid the cues
                // sideways — up to nearly a key near the ends — and made them
                // swim relative to the real keys with every head movement.)
                let frameNode = SCNNode()
                frameNode.simdPosition = SIMD3<Float>(0, -KeyboardLayout.whiteKeyHeight, 0)
                root.addChildNode(frameNode)

                // Keys + waterfall follow the measured keyboard size...
                let content = KeyboardNode.makeOverlay()
                if let d = calibration.calibrationData {
                    baseScale = SIMD2<Float>(d.widthScale, d.depthScale)
                } else {
                    baseScale = SIMD2<Float>(1, 1)
                }
                content.scale = SCNVector3(baseScale.x, 1, baseScale.y)
                let hw = NoteHighway()
                content.addChildNode(hw.rootNode)
                // Bright key outlines: shown for a few seconds after mapping so
                // you can check the fit, and whenever SETUP is open.
                let outline = KeyboardNode.makeOutlines()
                content.addChildNode(outline)
                outlines = outline
                outlinesUntil = CACurrentMediaTime() + 8
                frameNode.addChildNode(content)

                // ...UI panels are never stretched by that scale.
                let menu = ARMenuOverlay()
                frameNode.addChildNode(menu.rootNode)
                let hudNode = PracticeHUDOverlay()
                frameNode.addChildNode(hudNode.rootNode)
                let dbg = DebugPanelOverlay()
                frameNode.addChildNode(dbg.rootNode)

                highway       = hw
                menuOverlay   = menu
                hud           = hudNode
                debugPanel    = dbg
                keyboardNode  = content
                keyboardFrame = frameNode
                pressDetector.reset()
                return root
            }
            if let name = anchor.name, name.hasPrefix("corner_") { return cornerMarker() }
            if let plane = anchor as? ARPlaneAnchor {
                let node = planeNode(for: plane)
                planeNodes.add(node)
                return node
            }
            return nil
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            updatePlane(node, for: plane)
        }

        private func currentHintText(time: TimeInterval) -> String {
            if let hint = calibration.mappingHint(time: time) { return hint }
            switch calibration.state {
            case .idle:
                return "Look at your piano keys"
            case .collecting(let n):
                let labels = [
                    "",
                    "Tap corner 2/4 — near-right (high notes, front)",
                    "Tap corner 3/4 — far-right (high notes, back)",
                    "Tap corner 4/4 — far-left (low notes, back)",
                ]
                return labels[min(max(n, 0), 3)]
            case .done:
                return ""
            }
        }

        /// A glowing dot at the live pinch point while mapping; it grows and
        /// turns green as the half-second hold completes.
        private func updatePinchMarker(scene: SCNScene) {
            guard let preview = calibration.pinchPreview else {
                pinchMarker?.isHidden = true
                return
            }
            if pinchMarker == nil {
                let s = SCNSphere(radius: 0.010)
                s.segmentCount = 16
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.writesToDepthBuffer = false
                m.readsFromDepthBuffer = false
                s.materials = [m]
                let n = SCNNode(geometry: s)
                n.renderingOrder = 320
                scene.rootNode.addChildNode(n)
                pinchMarker = n
            }
            guard let n = pinchMarker else { return }
            let p = CGFloat(preview.progress)
            n.simdPosition = preview.position
            let scale = Float(0.8 + 0.8 * p)
            n.scale = SCNVector3(scale, scale, scale)
            n.geometry?.firstMaterial?.diffuse.contents =
                UIColor(red: 1 - 0.8 * p, green: 0.6 + 0.4 * p, blue: 1 - 0.6 * p, alpha: 0.95)
            n.isHidden = false
        }

        private func cornerMarker() -> SCNNode {
            let s = SCNSphere(radius: 0.008)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.orange
            m.emission.contents = UIColor.orange.withAlphaComponent(0.6)
            s.materials = [m]
            return SCNNode(geometry: s)
        }

        /// Faint scan feedback while calibrating only — hidden afterwards so
        /// no flickering cyan sheets resize over the piano during practice.
        private func planeNode(for a: ARPlaneAnchor) -> SCNNode {
            let root = SCNNode()
            let geo  = SCNPlane(width: CGFloat(a.planeExtent.width), height: CGFloat(a.planeExtent.height))
            let mat  = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.14)
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            geo.materials = [mat]
            let child = SCNNode(geometry: geo)
            child.name = "planeGeom"
            child.eulerAngles.x = -.pi / 2
            child.simdPosition = a.center
            root.addChildNode(child)
            return root
        }

        private func updatePlane(_ node: SCNNode, for a: ARPlaneAnchor) {
            guard let c = node.childNode(withName: "planeGeom", recursively: false),
                  let g = c.geometry as? SCNPlane else { return }
            g.width = CGFloat(a.planeExtent.width)
            g.height = CGFloat(a.planeExtent.height)
            c.simdPosition = a.center
        }
    }
}

// MARK: - Camera-locked hint bar
//
// Small always-in-view text pill for setup guidance. Kept narrow (~25° wide)
// and only shown while calibrating: head-locked UI is a comfort cost, so it
// is the only head-locked element in the app.

private final class HintBarOverlay {
    private static let w: Float = 0.26
    private static let h: Float = 0.040
    private static let texW: CGFloat = 780
    private static let texH: CGFloat = 120
    private static let camOffset = SCNVector3(0, -0.12, -0.60)

    private let node: SCNNode
    private let mat:  SCNMaterial
    private var lastText = ""

    init(cameraNode: SCNNode) {
        let geo = SCNPlane(width: CGFloat(Self.w), height: CGFloat(Self.h))
        mat = SCNMaterial()
        mat.lightingModel        = .constant
        mat.diffuse.contents     = UIColor.clear
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
            if !lastText.isEmpty { node.runAction(SCNAction.fadeOut(duration: 0.20), forKey: "fade") }
            lastText = ""
            return
        }
        if lastText.isEmpty { node.runAction(SCNAction.fadeIn(duration: 0.25), forKey: "fade") }
        guard text != lastText else { return }
        lastText = text
        let m = mat
        DispatchQueue.main.async { m.diffuse.contents = HintBarOverlay.bake(text) }
    }

    private static func bake(_ text: String) -> UIImage {
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { _ in
            let rect = CGRect(origin: .zero, size: sz).insetBy(dx: 4, dy: 4)
            UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 0.86).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 30).fill()
            UIColor(white: 1, alpha: 0.16).setStroke()
            let b = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 30)
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
            (text as NSString).draw(in: rect.insetBy(dx: 24, dy: 12), withAttributes: attrs)
        }
    }
}

// MARK: - 3-D hand overlay
//
// Your real hands are already in the passthrough image, so by default only
// small fingertip dots are drawn (enough to see that tracking is locked on,
// without a jittery skeleton sitting on top of your fingers). The full
// skeleton is one tap away in COMFORT › HAND DISPLAY. renderingOrder 300 keeps
// the hand in front of the menu (200) and the note waterfall (40–100).
//
// The index fingertip doubles as a touch cursor: it glows blue near the AR
// menu and green within trigger distance.

private final class Hand3DOverlay {
    // Joint sphere radii, indexed by HandTracker.allJoints order
    // [0]=wrist, [1-4]=thumb, [5-8]=index, [9-12]=middle, [13-16]=ring, [17-20]=little
    private static let sphereR: [Float] = [
        0.018,
        0.010, 0.009, 0.008, 0.007,
        0.011, 0.009, 0.008, 0.007,
        0.011, 0.009, 0.008, 0.007,
        0.010, 0.009, 0.008, 0.007,
        0.009, 0.008, 0.007, 0.006,
    ]
    private static let tipJoints: Set<Int> = [4, 8, 12, 16, 20]
    private static let cylR: Float = 0.0055
    private static let indexTipJoint = 8

    private static let cgCursorTouch    = CGColor(red: 0.08, green: 0.96, blue: 0.40, alpha: 1)
    private static let cgCursorInactive = CGColor(red: 0.70, green: 0.55, blue: 0.42, alpha: 1)

    private var sph: [[SCNNode]] = []    // [hand 0=left, 1=right][joint]
    private var cyl: [[SCNNode]] = []    // [hand][bone]
    private var idxTipMat: [SCNMaterial] = []
    private var lastStyle: HandStyle?

    init(scene: SCNScene) {
        let skinMat = Self.makeMat(skin: true,  isTip: false)
        let tipMat  = Self.makeMat(skin: true,  isTip: true)
        let boneMat = Self.makeMat(skin: false, isTip: false)

        for _ in 0..<2 {
            var sNodes: [SCNNode] = []
            var cNodes: [SCNNode] = []
            var idxMat: SCNMaterial?
            for i in 0..<HandTracker.allJoints.count {
                let geo = SCNSphere(radius: CGFloat(Self.sphereR[i]))
                geo.segmentCount = 10
                let mat: SCNMaterial
                if i == Self.indexTipJoint {
                    mat = Self.makeMat(skin: true, isTip: true)   // own material: cursor glow
                    idxMat = mat
                } else {
                    mat = Self.tipJoints.contains(i) ? tipMat : skinMat
                }
                geo.materials = [mat]
                let n = SCNNode(geometry: geo)
                n.isHidden = true
                n.renderingOrder = 300
                scene.rootNode.addChildNode(n)
                sNodes.append(n)
            }
            for _ in 0..<HandTracker.boneConnections.count {
                let geo = SCNCylinder(radius: CGFloat(Self.cylR), height: 1.0)
                geo.radialSegmentCount = 8
                geo.materials = [boneMat]
                let n = SCNNode(geometry: geo)
                n.isHidden = true
                n.renderingOrder = 300
                scene.rootNode.addChildNode(n)
                cNodes.append(n)
            }
            sph.append(sNodes)
            cyl.append(cNodes)
            idxTipMat.append(idxMat ?? Self.makeMat(skin: true, isTip: true))
        }
    }

    /// Render thread.
    func update(hands: [HandTracker.HandResult], style: HandStyle,
                menu: ARMenuOverlay?, keyboardNode: SCNNode?) {
        sph.forEach { $0.forEach { $0.isHidden = true } }
        cyl.forEach { $0.forEach { $0.isHidden = true } }
        guard style != .hidden else { return }

        if style != lastStyle {
            lastStyle = style
            // Fingertip dots are a touch smaller so they sit on the nail.
            let tipScale: Float = style == .fingertips ? 0.8 : 1.0
            for hand in sph {
                for i in Self.tipJoints { hand[i].scale = SCNVector3(tipScale, tipScale, tipScale) }
            }
        }

        for hand in hands {
            let h = hand.isLeft ? 0 : 1
            guard h < sph.count else { continue }

            for (i, name) in HandTracker.allJoints.enumerated() {
                guard style == .skeleton || Self.tipJoints.contains(i),
                      let p = hand.joints[name] else { continue }
                sph[h][i].simdPosition = p
                sph[h][i].isHidden     = false
            }

            if style == .skeleton {
                for (i, (fi, ti)) in HandTracker.boneConnections.enumerated() {
                    guard let a = hand.joints[HandTracker.allJoints[fi]],
                          let b = hand.joints[HandTracker.allJoints[ti]] else { continue }
                    placeCylinder(cyl[h][i], from: a, to: b)
                }
            }

            // Touch cursor colour from proximity to the AR menu.
            if let idxWorld = hand.joints[HandTracker.allJoints[Self.indexTipJoint]],
               let m = menu, let kb = keyboardNode {
                let prox = m.maxProximity(worldPos: idxWorld, keyboardNode: kb)
                let color: CGColor
                if prox > 0.88 {
                    color = Self.cgCursorTouch
                } else if prox > 0.20 {
                    let t = CGFloat((prox - 0.20) / 0.68)
                    color = CGColor(red: 0.15, green: 0.55 - t * 0.25, blue: 1.0, alpha: 1)
                } else {
                    color = Self.cgCursorInactive
                }
                idxTipMat[h].emission.contents = color
            }
        }
    }

    private static func makeMat(skin: Bool, isTip: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        if skin {
            m.diffuse.contents  = UIColor(red: 0.86, green: 0.69, blue: 0.53, alpha: isTip ? 1.0 : 0.88)
            m.emission.contents = isTip
                ? CGColor(red: 0.70, green: 0.55, blue: 0.42, alpha: 1)
                : CGColor(red: 0.20, green: 0.13, blue: 0.07, alpha: 1)
        } else {
            m.diffuse.contents  = UIColor(red: 0.78, green: 0.62, blue: 0.47, alpha: 0.82)
            m.emission.contents = CGColor(red: 0.15, green: 0.09, blue: 0.04, alpha: 1)
        }
        m.blendMode            = .alpha
        m.writesToDepthBuffer  = false
        m.readsFromDepthBuffer = false   // always drawn, never hidden by virtual geometry
        m.isDoubleSided        = true
        return m
    }

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
        node.scale           = SCNVector3(1, len, 1)
        node.isHidden        = false
    }
}

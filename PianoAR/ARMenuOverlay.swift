import SceneKit
import UIKit
import Vision
import simd

enum MenuAction {
    case playStop, restart, skip, toggleDebug, recalibrate
    /// Choosing a song now only *loads* it — the song's own page is where you
    /// set hands and tempo and then start. Loading and starting in one tap
    /// meant every choice began with a scramble to pause.
    case select(Song?)
    case tempo(Double)                    // delta, e.g. -0.05
    case cycleHand, toggleWaitMode
    case viewScale(Double), lensSpacing(Double)
    case toggleSmoothing, toggleStereo, cycleHandStyle, resetComfort, cycleFrameRate
    case align(KeyboardAlignment.Adjust)  // fine placement of the key overlay
    case toggleKeyLabels
    case toggleRecording                  // SETUP › RECORD diagnostics capture
    case toggleCalibration                // SETUP › CALIBRATE guided note pass
    case seek(Double)                     // 0...1 along the piece
    case loopSetStart, loopSetEnd, loopPhrase, loopToggle
    case cycleTextSize, toggleContrast, cycleDwell, toggleColorBlind, resetAccess
    case cycleAlignMode
}

/// Everything the panel shows, captured once per frame on the render thread.
struct MenuState: Equatable {
    var isPlaying = false
    var isComplete = false
    var debugOn = false
    var currentTitle = ""
    var tempoPercent = 100
    var hand: PracticeHand = .both
    var waitMode = true
    var comfort = ComfortSnapshot.default
    var keyLabels = true
    var alignReadout = ""
    var recording = false
    var recordSeconds = 0
    var calibrating = false
    var progress: Float = 0
    var bar = 0
    var barCount = 0
    var loopOn = false
    var loopFrom: Float = 0
    var loopTo: Float = 1
    var loopFirstBar = 0
    var loopLastBar = 0
    var loopLaps = 0
    var access = AccessibilitySnapshot.default
    var alignMode: AlignMode = .nudge
    // Live scoring, so the practice screen can show what is going well and
    // the result screen has something to report.
    var correct = 0
    var wrong = 0
    var missed = 0
    var streak = 0
    var bestStreak = 0
    var accuracy: Double = 0
    var timingMs: Double = 0
    var cards: [ARMenuOverlay.SongCard] = []
    /// nil when the microphone is fine.
    var micProblem: String? = nil
}

/// Floating "tablet" AR panel — Quest-3 interaction model.
///
///   1. **Cursor (line-of-sight ray)** — a ray from the camera through the
///      index fingertip, intersected with the panel plane: the cursor lands
///      exactly where the finger visually covers the panel.
///   2. **Select = pinch** (aim-lagged), with physical poke and a slow dwell
///      as fallbacks.
///   3. **Move = pinch-and-hold the title bar**; the panel follows the palm
///      and turns to face you.
///
/// Four tabs — LIBRARY, PRACTICE, COMFORT, SETUP. While a song plays the
/// panel minimizes itself to a small PAUSE · MENU pill so it stays out of
/// your view of the keys.
///
/// UIKit drawing is strictly main-thread; the render thread only mutates
/// SCNNode transforms and material contents.
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Panel geometry ──────────────────────────────────────────────────────
    // Small, and off to the side where it does not cover the keys or the
    // sheet. Making it bigger to fit more on it was the wrong move: the way
    // to stop a panel feeling cramped is to put less on it.
    // 0.36 × 0.24 is exactly 3:2, the same as the 960 × 640 texture, so a
    // square in texture space is square in the headset. It was 0.34 wide,
    // which quietly stretched every circle and every corner radius.
    static let panW: Float = 0.36
    static let panH: Float = 0.24
    static let texW: CGFloat = 960
    static let texH: CGFloat = 640

    // ── Default placement (right of keyboard centre, lifted, tilted) ────────
    /// Centred above the keys and tilted toward the player.
    ///
    /// It used to sit 37 cm to the right of centre, which meant turning your
    /// head to reach anything — and turning your head inside a headset is the
    /// one movement that costs you the alignment you just set up. It only
    /// appears when the song is stopped, so overlapping the note sheet costs
    /// nothing.
    private static let initPos = SIMD3<Float>(KeyboardLayout.totalWidth * 0.26, 0.27, 0.20)
    private static let initRotX: Float = -Float.pi * 0.24
    private static let initRotY: Float = -Float.pi * 0.11

    // ── Cursor / click thresholds ───────────────────────────────────────────
    private static let tipMaxBehind: Float        = 0.12
    private static let pokeArmZ:     Float        = 0.080
    private static let pokeFireZ:    Float        = 0.015
    // Dwell is the fallback when a pinch will not register, which inside a
    // headset is often — the hands sit at the bottom edge of the camera and
    // half occlude themselves. How long it takes now lives in
    // AccessibilitySettings, because the right value differs per person.
    private static let debounce:     TimeInterval = 0.30
    private static let xyMargin:     Float        = 0.030
    private static let pinchOn:  Float = 0.022
    private static let pinchOff: Float = 0.048
    private static let aimLag: TimeInterval = 0.15
    private static let grabHold: TimeInterval = 0.25
    private static let grabPinchOff:  Float        = 0.065
    private static let grabLostGrace: TimeInterval = 0.40
    private static let dragSmooth:    Float        = 0.45
    private static let yawSmooth:     Float        = 0.18
    // Once the cursor is on a control it takes a deliberate movement to
    // leave it, so a tremor cannot slide the selection onto its neighbour.
    private static let stickyInflate: CGFloat = 64

    // ── Distance-adaptive scale ─────────────────────────────────────────────
    private static let refDistance:   Float = 0.55
    private static let minScale:      Float = 1.0
    private static let maxScale:      Float = 2.4
    private static let scaleSmooth:   Float = 0.05
    private static let scaleDeadband: Float = 0.10

    // ── Tabs / regions ──────────────────────────────────────────────────────
    // ── State (render thread) ───────────────────────────────────────────────
    private var screen: Screen = .browse
    /// Where BACK goes. Only one level deep, which is all the app needs.
    private var backTo: Screen = .browse
    private var libPage = 0
    private var minimized = false
    private var selectedIndex: Int? = nil
    /// Set when a song finishes so the result screen comes up by itself —
    /// you should not have to go looking for how you did.
    private var shownResultFor = -1

    /// ALIGN open → the renderer lights up the key outlines.
    var showsAlignment: Bool { !minimized && screen == .align }
    private var wasPlaying = false
    private var state = MenuState()
    private var songs: [Song] = []
    private var needsRebake = true
    private var lastTap: TimeInterval = -999

    // Cursor / dwell / poke
    private var dwellRegion:    Region        = .none
    private var dwellStart:     TimeInterval  = 0
    private var pokeArmed:      Bool          = false
    private var firedRegion:    Region        = .none
    private var hotRegion:      Region        = .none
    private var cursorLeft:     Bool?         = nil
    private var fireFlashUntil: TimeInterval  = 0
    private var pinchClosed:    [Bool: Bool]  = [:]
    private var aimHist: [(pos: SIMD3<Float>, t: TimeInterval)] = []
    private var pendingGrabSide:  Bool?        = nil
    private var pendingGrabStart: TimeInterval = 0

    // Grab
    private var grabbed:      Bool          = false
    private var grabSide:     Bool?         = nil
    private var grabOffset:   SIMD3<Float>  = .zero
    private var grabTarget:   SIMD3<Float>  = .zero
    private var grabLastSeen: TimeInterval  = 0
    private var curYaw:       Float         = ARMenuOverlay.initRotY

    private var cursorSmoothed: SIMD3<Float>? = nil
    /// Where the cursor last sat, in texture space — the scrub bar needs the
    /// position it was tapped at, not merely that it was tapped.
    private var cursorTex: CGPoint = .zero
    private var curScale:   Float        = 1.0
    private var scaleGoal:  Float        = 1.0
    private var flashUntil: TimeInterval = 0

    // ── Scene nodes ─────────────────────────────────────────────────────────
    private var panelNode:   SCNNode!
    private var panelMat:    SCNMaterial!
    private var cursorNode:  SCNNode!
    private var cursorMat:   SCNMaterial!
    private var borderNodes: [SCNNode] = []

    init() { build() }

    // MARK: - Build

    private func build() {
        let geo  = SCNPlane(width: CGFloat(Self.panW), height: CGFloat(Self.panH))
        panelMat = SCNMaterial()
        panelMat.lightingModel        = .constant
        panelMat.diffuse.contents     = UIColor(red: 0.045, green: 0.03, blue: 0.13, alpha: 0.97)
        panelMat.blendMode            = .alpha
        panelMat.isDoubleSided        = true
        panelMat.writesToDepthBuffer  = false
        panelMat.readsFromDepthBuffer = false
        geo.materials = [panelMat]

        panelNode = SCNNode(geometry: geo)
        panelNode.simdPosition   = Self.initPos
        panelNode.eulerAngles    = SCNVector3(Self.initRotX, Self.initRotY, 0)
        panelNode.renderingOrder = 200
        rootNode.addChildNode(panelNode)

        addBorder()
        addCursor()
        dispatchBake()
        panelNode.opacity = 0
        panelNode.runAction(SCNAction.fadeIn(duration: 0.42))
    }

    private func addBorder() {
        let baseEmission = UIColor(red: 0.42, green: 0.20, blue: 0.85, alpha: 0.65).cgColor
        let baseDiffuse  = UIColor(red: 0.55, green: 0.30, blue: 0.98, alpha: 0.75)
        let t: Float = 0.0032
        struct Edge { var w: Float; var h: Float; var x: Float; var y: Float }
        let edges: [Edge] = [
            Edge(w: Self.panW + t*2, h: t, x: 0, y:  Self.panH/2),
            Edge(w: Self.panW + t*2, h: t, x: 0, y: -Self.panH/2),
            Edge(w: t, h: Self.panH, x: -Self.panW/2, y: 0),
            Edge(w: t, h: Self.panH, x:  Self.panW/2, y: 0),
        ]
        for e in edges {
            let mat = SCNMaterial()
            mat.lightingModel       = .constant
            mat.diffuse.contents    = baseDiffuse
            mat.emission.contents   = baseEmission
            mat.writesToDepthBuffer = false
            let box = SCNBox(width: CGFloat(e.w), height: CGFloat(e.h), length: 0.001, chamferRadius: 0)
            box.materials = [mat]
            let n = SCNNode(geometry: box)
            n.simdPosition   = SIMD3<Float>(e.x, e.y, 0.0005)
            n.renderingOrder = 201
            panelNode.addChildNode(n)
            borderNodes.append(n)
        }
    }

    private func addCursor() {
        let geo = SCNSphere(radius: 0.010)
        geo.segmentCount = 16
        cursorMat = SCNMaterial()
        cursorMat.lightingModel        = .constant
        cursorMat.diffuse.contents     = UIColor.white
        cursorMat.emission.contents    = UIColor.white.cgColor
        cursorMat.blendMode            = .alpha
        cursorMat.writesToDepthBuffer  = false
        cursorMat.readsFromDepthBuffer = false
        geo.materials = [cursorMat]
        cursorNode = SCNNode(geometry: geo)
        cursorNode.renderingOrder = 205
        cursorNode.isHidden       = true
        panelNode.addChildNode(cursorNode)
    }

    // MARK: - Per-frame update  (render thread)

    func update(hands:          [HandTracker.HandResult],
                keyboardNode:   SCNNode,
                time:           TimeInterval,
                state newState: MenuState,
                availableSongs: [Song],
                cameraWorldPos: SIMD3<Float>?) -> MenuAction? {

        var dirty = false
        if newState != state {
            // Minimize when playback starts, come back when it stops/ends.
            if newState.isPlaying && !wasPlaying {
                minimized = true; screen = .play; backTo = .browse
            }
            if !newState.isPlaying && wasPlaying { minimized = false }
            wasPlaying = newState.isPlaying
            // Finishing a piece is the one moment the app has something to
            // say, so it says it without being asked.
            let played = newState.correct + newState.wrong + newState.missed
            if newState.isComplete, played > 0, shownResultFor != played {
                shownResultFor = played
                minimized = false
                screen = .results
                backTo = .play
            }
            if !newState.isComplete { shownResultFor = -1 }
            state = newState
            dirty = true
        }
        songs = availableSongs
        let pages = max(1, (songs.count + Self.libPerPage - 1) / Self.libPerPage)
        if libPage >= pages { libPage = pages - 1; dirty = true }
        for n in borderNodes { n.isHidden = minimized }

        // ── Distance-adaptive scale ──────────────────────────────────────────
        if let cp = cameraWorldPos {
            let d      = simd_length(cp - panelNode.simdWorldPosition)
            let target = simd_clamp(d / Self.refDistance, Self.minScale, Self.maxScale)
            if abs(target - scaleGoal) / scaleGoal > Self.scaleDeadband { scaleGoal = target }
            curScale += Self.scaleSmooth * (scaleGoal - curScale)
            panelNode.scale = SCNVector3(curScale, curScale, curScale)
        }

        // ── Pinch state per hand (thumb + index, hysteresis + edge) ─────────
        struct Pinch { let isLeft: Bool; let began: Bool; let closed: Bool }
        var pinches: [Pinch] = []
        for hand in hands {
            guard let t = hand.joints[.thumbTip],
                  let i = hand.joints[.indexTip] else { continue }
            let dist = simd_length(t - i)
            let was  = pinchClosed[hand.isLeft] ?? false
            var began = false
            if !was, dist < Self.pinchOn  { pinchClosed[hand.isLeft] = true; began = true }
            if  was, dist > Self.pinchOff { pinchClosed[hand.isLeft] = false }
            pinches.append(Pinch(isLeft: hand.isLeft, began: began,
                                 closed: pinchClosed[hand.isLeft] ?? false))
        }

        // ── Grab: panel follows the palm while the handle pinch is held ─────
        if grabbed {
            var shouldRelease = false
            if let side = grabSide, let hand = hands.first(where: { $0.isLeft == side }) {
                grabLastSeen = time
                if let t = hand.joints[.thumbTip], let i = hand.joints[.indexTip],
                   simd_length(t - i) > Self.grabPinchOff {
                    shouldRelease = true
                } else if let anchor = Self.palmAnchor(hand), let parent = panelNode.parent {
                    let target = parent.simdConvertPosition(anchor, from: nil) + grabOffset
                    grabTarget = grabTarget * Self.dragSmooth + target * (1 - Self.dragSmooth)
                    panelNode.simdPosition = grabTarget
                    if let cp = cameraWorldPos {
                        let camLocal = parent.simdConvertPosition(cp, from: nil)
                        let d = camLocal - panelNode.simdPosition
                        if simd_length(SIMD3<Float>(d.x, 0, d.z)) > 0.05 {
                            var delta = atan2(d.x, d.z) - curYaw
                            while delta >  .pi { delta -= 2 * .pi }
                            while delta < -.pi { delta += 2 * .pi }
                            curYaw += delta * Self.yawSmooth
                            panelNode.eulerAngles = SCNVector3(Self.initRotX, curYaw, 0)
                        }
                    }
                }
            } else if time - grabLastSeen > Self.grabLostGrace {
                shouldRelease = true
            }
            if shouldRelease {
                grabbed = false; grabSide = nil
                dirty = true
                pulse()
            }
            cursorNode.isHidden = true
            cursorSmoothed = nil
            if hotRegion != .none { hotRegion = .none; dirty = true }
            finishFrame(time: time, dirty: dirty)
            return nil
        }

        // ── Line-of-sight cursor ─────────────────────────────────────────────
        struct Hit { let local: SIMD3<Float>; let tip: SIMD3<Float>; let isLeft: Bool }
        var hits: [Hit] = []
        if let cp = cameraWorldPos {
            let camLocal = panelNode.simdConvertPosition(cp, from: nil)
            for hand in hands {
                guard let tipWorld = hand.joints[.indexTip] else { continue }
                let tipLocal = panelNode.simdConvertPosition(tipWorld, from: nil)
                guard tipLocal.z > -Self.tipMaxBehind else { continue }
                let d = tipLocal - camLocal
                guard abs(d.z) > 1e-5 else { continue }
                let t = -camLocal.z / d.z
                guard t > 0 else { continue }
                let hit = camLocal + d * t
                guard abs(hit.x) < Self.panW/2 + Self.xyMargin,
                      abs(hit.y) < Self.panH/2 + Self.xyMargin else { continue }
                hits.append(Hit(local: hit, tip: tipLocal, isLeft: hand.isLeft))
            }
        }
        let best = hits.first(where: { $0.isLeft == cursorLeft })
                ?? hits.min(by: { abs($0.tip.z) < abs($1.tip.z) })

        var result: MenuAction? = nil

        if let b = best {
            let pinch = pinches.first(where: { $0.isLeft == b.isLeft })

            let sm: SIMD3<Float>
            if let prev = cursorSmoothed, cursorLeft == b.isLeft {
                // Was 0.5 — barely any smoothing, so the ray jittered with
                // every frame of hand-tracking noise.
                sm = prev + 0.28 * (b.local - prev)
            } else {
                sm = b.local
            }
            cursorSmoothed = sm
            cursorTex = texPoint(localX: sm.x, localY: sm.y)

            aimHist.append((sm, time))
            aimHist.removeAll { time - $0.t > 0.5 }
            let aimPos = aimHist.last(where: { time - $0.t >= Self.aimLag })?.pos
                      ?? aimHist.first?.pos ?? sm
            let laggedRegion = regionAt(localX: aimPos.x, localY: aimPos.y)

            let raw = regionAt(localX: sm.x, localY: sm.y)
            var region = raw
            if raw == .none, dwellRegion != .none, let r = rectFor(dwellRegion) {
                let pt = texPoint(localX: sm.x, localY: sm.y)
                if r.insetBy(dx: -Self.stickyInflate, dy: -Self.stickyInflate).contains(pt) {
                    region = dwellRegion
                }
            }

            if region != hotRegion { hotRegion = region; dirty = true }
            if cursorLeft != b.isLeft {
                cursorLeft  = b.isLeft
                pokeArmed   = false
                dwellRegion = region
                dwellStart  = time
            }
            if region != dwellRegion { dwellRegion = region; dwellStart = time }
            if region != firedRegion { firedRegion = .none }

            // Grab: pinch must be HELD on the handle (expanded panel only).
            if !minimized, pinch?.began == true, laggedRegion == .handle {
                pendingGrabSide  = b.isLeft
                pendingGrabStart = time
            }
            if let side = pendingGrabSide {
                let stillClosed = pinches.first(where: { $0.isLeft == side })?.closed ?? true
                let onHandle    = region == .handle || laggedRegion == .handle
                if !stillClosed || !onHandle {
                    pendingGrabSide = nil
                } else if time - pendingGrabStart > Self.grabHold,
                          let parent = panelNode.parent,
                          let hand = hands.first(where: { $0.isLeft == side }),
                          let anchor = Self.palmAnchor(hand) {
                    grabbed      = true
                    grabSide     = side
                    grabOffset   = panelNode.simdPosition - parent.simdConvertPosition(anchor, from: nil)
                    grabTarget   = panelNode.simdPosition
                    grabLastSeen = time
                    pendingGrabSide = nil
                    dirty = true
                    pulse()
                }
            }

            // Select: pinch (aim-lagged, primary), physical poke, or dwell.
            let pinchFire = (pinch?.began ?? false) && laggedRegion.actionable
            let targetStable = (time - dwellStart) > 0.20
            let tipOnFace = abs(b.tip.x) < Self.panW/2 && abs(b.tip.y) < Self.panH/2
            if b.tip.z > Self.pokeArmZ { pokeArmed = true }
            let poked = pokeArmed && tipOnFace && targetStable && b.tip.z < Self.pokeFireZ
            // With hover-to-select off the ring stays empty: showing a
            // progress arc that never completes would promise a selection
            // that is not coming.
            let dwellSecs = state.access.dwell.seconds
            let dwellProg = dwellSecs.map {
                Float(simd_clamp((time - dwellStart) / $0, 0, 1))
            } ?? 0
            let dwellFire = dwellSecs.map { (time - dwellStart) >= $0 } == true
                            && firedRegion != region
                            && region.actionable

            if time - lastTap > Self.debounce {
                var firedOn: Region? = nil
                if pinchFire                                    { firedOn = laggedRegion }
                else if (poked || dwellFire), region.actionable { firedOn = region }
                if let fr = firedOn {
                    result = fire(fr, dirty: &dirty)
                    lastTap        = time
                    fireFlashUntil = time + 0.18
                    pokeArmed      = false
                    firedRegion    = fr
                    dwellRegion    = .none
                    dwellStart     = time
                    pulse()
                }
            }

            if minimized && region == .none {
                cursorNode.isHidden = true     // nothing to point at around the pill
            } else {
                updateCursor(local: sm, progress: region == .handle ? 0 : dwellProg,
                             actionable: region.actionable || region == .handle, time: time)
            }
        } else {
            cursorNode.isHidden = true
            cursorSmoothed  = nil
            aimHist.removeAll()
            pendingGrabSide = nil
            dwellRegion = .none
            firedRegion = .none
            pokeArmed   = false
            cursorLeft  = nil
            if hotRegion != .none { hotRegion = .none; dirty = true }
        }

        finishFrame(time: time, dirty: dirty)
        return result
    }

    private func finishFrame(time: TimeInterval, dirty: Bool) {
        let borderEmission: CGColor
        if grabbed || time < flashUntil {
            borderEmission = UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 0.95).cgColor
        } else {
            borderEmission = UIColor(red: 0.42, green: 0.20, blue: 0.85, alpha: 0.65).cgColor
        }
        for n in borderNodes { n.geometry?.firstMaterial?.emission.contents = borderEmission }
        if dirty || needsRebake { needsRebake = false; dispatchBake() }
    }

    /// Stable drag control point: centroid of wrist + knuckles.
    private static func palmAnchor(_ hand: HandTracker.HandResult) -> SIMD3<Float>? {
        let names: [VNHumanHandPoseObservation.JointName] =
            [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let pts = names.compactMap { hand.joints[$0] }
        guard pts.count >= 2 else { return hand.joints[.indexTip] }
        return pts.reduce(SIMD3<Float>(repeating: 0), +) / Float(pts.count)
    }

    private func updateCursor(local: SIMD3<Float>, progress: Float,
                              actionable: Bool, time: TimeInterval) {
        cursorNode.isHidden = false
        cursorNode.simdPosition = SIMD3<Float>(local.x, local.y, 0.007)
        let scale: Float
        let color: CGColor
        if time < fireFlashUntil {
            scale = 1.7
            color = CGColor(red: 0.10, green: 1.0, blue: 0.40, alpha: 1)
        } else if actionable {
            scale = 1.0 + progress * 0.7
            color = CGColor(red: CGFloat(1.0 - progress * 0.9), green: 1.0,
                            blue: CGFloat(1.0 - progress * 0.6), alpha: 1)
        } else {
            scale = 0.7
            color = CGColor(red: 1, green: 1, blue: 1, alpha: 0.6)
        }
        cursorNode.scale = SCNVector3(scale, scale, scale)
        cursorMat.emission.contents = color
        cursorMat.diffuse.contents  = color
    }

    private func pulse() { flashUntil = CACurrentMediaTime() + 0.20 }

    // MARK: - Proximity query (hand overlay cursor colour)

    func maxProximity(worldPos: SIMD3<Float>, keyboardNode: SCNNode) -> Float {
        let local  = panelNode.simdConvertPosition(worldPos, from: nil)
        let zProx  = simd_clamp(1.0 - abs(local.z) / 0.12, 0, 1)
        let xFade  = simd_clamp(1.0 - max(0, abs(local.x) - Self.panW/2) / 0.05, 0, 1)
        let yFade  = simd_clamp(1.0 - max(0, abs(local.y) - Self.panH/2) / 0.05, 0, 1)
        return zProx * xFade * yFade
    }

    // MARK: - Region resolution / firing

    private var pageCount: Int { max(1, (songs.count + Self.libPerPage - 1) / Self.libPerPage) }

    /// Panel-local metres → texture pixels.
    private func texPoint(localX: Float, localY: Float) -> CGPoint {
        let u = CGFloat((localX + Self.panW/2) / Self.panW)
        let v = CGFloat(1.0 - (localY + Self.panH/2) / Self.panH)
        return CGPoint(x: u * Self.texW, y: v * Self.texH)
    }

    private func regionAt(localX: Float, localY: Float) -> Region {
        let pt = texPoint(localX: localX, localY: localY)
        if minimized {
            if Self.pauseRect.contains(pt)    { return .pillPause }
            if Self.pillLoopRect.contains(pt) { return .pillLoop }
            if Self.pillSkipRect.contains(pt) { return .pillSkip }
            if Self.menuRect.contains(pt)     { return .pillMenu }
            return .none
        }
        if pt.y < Self.handleH { return .handle }
        for i in NavItem.allCases.indices where Self.navRect(i).contains(pt) { return .nav(i) }
        if screen.isPushed, Self.backRect.contains(pt) { return .back }
        if state.isPlaying, Self.minimizeRect.contains(pt) { return .minimize }
        if screen.isSettings {
            for i in 0..<3 where Self.settingsTabRect(i).contains(pt) { return .settingsTab(i) }
        }
        if screen == .browse {
            let first = libPage * Self.libPerPage
            let count = min(Self.libPerPage, songs.count - first)
            for i in 0..<max(0, count) where Self.libCellRect(i).contains(pt) {
                return .song(first + i)
            }
            if pageCount <= 1 { return .none }
        }
        return Self.controls(for: screen).first { $0.1.contains(pt) }?.0 ?? .none
    }

    /// The texture rect of a region (sticky targeting + highlight ring).
    private func rectFor(_ region: Region) -> CGRect? {
        switch region {
        case .none:            return nil
        case .handle:          return CGRect(x: 0, y: 0, width: Self.texW, height: Self.handleH)
        case .nav(let i):      return Self.navRect(i)
        case .settingsTab(let i): return Self.settingsTabRect(i)
        case .back:            return Self.backRect
        case .song(let i):
            let local = i - libPage * Self.libPerPage
            return (0..<Self.libPerPage).contains(local) ? Self.libCellRect(local) : nil
        case .pagePrev:        return Self.pagePrevRect
        case .pageNext:        return Self.pageNextRect
        case .minimize:        return Self.minimizeRect
        case .pillPause:       return Self.pauseRect
        case .pillLoop:        return Self.pillLoopRect
        case .pillSkip:        return Self.pillSkipRect
        case .pillMenu:        return Self.menuRect
        default:
            return Self.allControls.first { $0.0 == region }?.1
        }
    }

    /// Applies a region's effect. Pure navigation returns nil; everything
    /// else becomes a MenuAction for ContentView.
    private func fire(_ region: Region, dirty: inout Bool) -> MenuAction? {
        switch region {
        case .none, .handle:
            return nil

        // ── navigation ──────────────────────────────────────────────────
        case .nav(let i):
            let target = NavItem(rawValue: i)?.screen ?? .browse
            if screen != target { screen = target; backTo = target; dirty = true }
            return nil
        case .settingsTab(let i):
            let target: Screen = [.view, .access, .align][min(2, max(0, i))]
            if screen != target { screen = target; dirty = true }
            return nil
        case .back:
            screen = backTo; dirty = true; return nil
        case .song(let i):
            guard i >= 0, i < songs.count else { return nil }
            selectedIndex = i
            screen = .song
            backTo = .browse
            dirty = true
            return .select(songs[i])
        case .pagePrev:
            libPage = max(0, libPage - 1); dirty = true; return nil
        case .pageNext:
            libPage = min(pageCount - 1, libPage + 1); dirty = true; return nil
        case .minimize:
            minimized = true; dirty = true; return nil
        case .pillMenu:
            minimized = false; dirty = true; return nil

        // ── transport ───────────────────────────────────────────────────
        case .startSong:
            screen = .play; backTo = .browse; dirty = true; return .restart
        case .pillPause, .play:  return .playStop
        case .pillSkip, .skip:   return .skip
        case .restart:           return .restart
        case .againSong:
            screen = .play; backTo = .browse; dirty = true; return .restart
        case .backToSongs:
            screen = .browse; backTo = .browse; dirty = true; return nil
        case .practiceWeak:
            screen = .play; backTo = .browse; dirty = true; return .loopPhrase

        // ── practice controls ───────────────────────────────────────────
        case .tempoDown, .songTempoDown: return .tempo(-0.05)
        case .tempoUp, .songTempoUp:     return .tempo(0.05)
        case .hand, .songHand:           return .cycleHand
        case .wait, .songWait:           return .toggleWaitMode
        case .seek:
            // The bar is inset inside its card, so aiming has to be measured
            // against the track the player can actually see.
            let track = Self.seekTrack
            let f = (cursorTex.x - track.minX) / track.width
            return .seek(Double(min(1, max(0, f))))
        case .loopPhrase:        return .loopPhrase
        case .loopA:             return .loopSetStart
        case .loopB:             return .loopSetEnd
        case .pillLoop, .loopOn: return .loopToggle

        // ── access ──────────────────────────────────────────────────────
        case .textSize:          return .cycleTextSize
        case .contrast:          return .toggleContrast
        case .dwell:             return .cycleDwell
        case .colorBlind:        return .toggleColorBlind
        case .accessReset:       return .resetAccess

        // ── view ────────────────────────────────────────────────────────
        case .viewDown:          return .viewScale(-0.02)
        case .viewUp:            return .viewScale(0.02)
        case .lensDown:          return .lensSpacing(-0.5)
        case .lensUp:            return .lensSpacing(0.5)
        case .smooth:            return .toggleSmoothing
        case .stereo:            return .toggleStereo
        case .handStyle:         return .cycleHandStyle
        case .frameRate:         return .cycleFrameRate
        case .comfortReset:      return .resetComfort

        // ── align ───────────────────────────────────────────────────────
        case .mapKeys:           return .recalibrate
        case .debug:             return .toggleDebug
        case .labels:            return .toggleKeyLabels
        case .alignReset:        return .align(.reset)
        case .record:            return .toggleRecording
        case .calibrate:         return .toggleCalibration
        case .alignMode:         return .cycleAlignMode
        case .padLeft:
            switch state.alignMode {
            case .nudge: return .align(.moveX(-KeyboardAlignment.slideStep))
            case .keys:  return .align(.moveX(-KeyboardAlignment.keyStep))
            case .shape: return .align(.width(-KeyboardAlignment.widthStep))
            }
        case .padRight:
            switch state.alignMode {
            case .nudge: return .align(.moveX(KeyboardAlignment.slideStep))
            case .keys:  return .align(.moveX(KeyboardAlignment.keyStep))
            case .shape: return .align(.width(KeyboardAlignment.widthStep))
            }
        case .padUp:
            switch state.alignMode {
            case .nudge: return .align(.moveZ(-KeyboardAlignment.slideStep))
            case .keys:  return .align(.moveY(KeyboardAlignment.heightStep))
            case .shape: return .align(.rotate(KeyboardAlignment.turnStep))
            }
        case .padDown:
            switch state.alignMode {
            case .nudge: return .align(.moveZ(KeyboardAlignment.slideStep))
            case .keys:  return .align(.moveY(-KeyboardAlignment.heightStep))
            case .shape: return .align(.rotate(-KeyboardAlignment.turnStep))
            }
        }
    }

    // MARK: - Texture dispatch

    private func dispatchBake() {
        let first = libPage * Self.libPerPage
        let cards = Array(state.cards.dropFirst(first).prefix(Self.libPerPage))
        let sel = selectedIndex.flatMap { i in
            (0..<state.cards.count).contains(i) ? state.cards[i] : nil
        }
        let snap = PanelSnap(screen: screen, minimized: minimized, state: state,
                             page: libPage, pageCount: pageCount, pageCards: cards,
                             selected: sel, grabbing: grabbed, hotRect: rectFor(hotRegion))
        let mat = panelMat!
        DispatchQueue.main.async { mat.diffuse.contents = ARMenuOverlay.bake(snap) }
    }

}

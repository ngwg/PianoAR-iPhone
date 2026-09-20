import SceneKit
import UIKit
import Vision
import simd

enum MenuAction {
    case playStop, restart, skip, loadAndPlay(Song?), toggleDebug, recalibrate
    case tempo(Double)                    // delta, e.g. -0.05
    case cycleHand, toggleWaitMode
    case viewScale(Double), lensSpacing(Double)
    case toggleSmoothing, toggleStereo, cycleHandStyle, resetComfort
    case align(KeyboardAlignment.Adjust)  // fine placement of the key overlay
    case toggleKeyLabels
    case toggleRecording                  // SETUP › RECORD diagnostics capture
    case toggleCalibration                // SETUP › CALIBRATE guided note pass
    case seek(Double)                     // 0...1 along the piece
    case loopSetStart, loopSetEnd, loopPhrase, loopToggle
    case cycleTextSize, toggleContrast, cycleDwell, toggleColorBlind, resetAccess
}

/// Everything the panel shows, captured once per frame on the render thread.
struct MenuState: Equatable {
    var isPlaying = false
    var isComplete = false
    var debugOn = false
    var songTitles: [String] = []
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
    private static let panW: Float = 0.36
    private static let panH: Float = 0.24
    private static let texW: CGFloat = 960
    private static let texH: CGFloat = 640

    private static let handleH: CGFloat = 58
    private static let tabBarH: CGFloat = 72
    private static let headerH: CGFloat = 56
    private static var contentTop: CGFloat { handleH + headerH }
    private static var tabTop: CGFloat { texH - tabBarH }

    // ── Library grid ────────────────────────────────────────────────────────
    private static let libCols = 2
    private static let libRows = 6
    private static let libGap: CGFloat = 10
    private static let libCellH: CGFloat = 56
    private static var libPerPage: Int { libCols * libRows }
    private static func libCellRect(_ i: Int) -> CGRect {
        let area = CGRect(x: 22, y: contentTop, width: texW - 44, height: tabTop - contentTop - 8)
        let col = i % libCols, row = i / libCols
        let cellW = (area.width - CGFloat(libCols - 1) * libGap) / CGFloat(libCols)
        return CGRect(x: area.minX + CGFloat(col) * (cellW + libGap),
                      y: area.minY + CGFloat(row) * (libCellH + libGap),
                      width: cellW, height: libCellH)
    }

    // ── Shared control rects: hit-testing, drawing and the target ring all
    //    come from these, so they can never drift apart. ────────────────────
    private static let minimizeRect = CGRect(x: 22, y: 64, width: 190, height: 44)
    private static let pagePrevRect = CGRect(x: 700, y: 64, width: 110, height: 44)
    private static let pageNextRect = CGRect(x: 828, y: 64, width: 110, height: 44)

    // ── Practice ────────────────────────────────────────────────────────
    // Four bands, each one a row of controls of the same height, all on the
    // same 36 px side margin. Nothing here is smaller than 110 × 78 px,
    // which at the panel's near scale is about a 2 cm target.
    /// The scrub bar. It is the one control that is *aimed* at rather than
    /// pressed, so its hit area is the whole card, not just the track.
    private static let seekRect      = CGRect(x: 36,  y: 176, width: 888, height: 94)
    private static let restartRect   = CGRect(x: 36,  y: 280, width: 252, height: 104)
    private static let playRect      = CGRect(x: 318, y: 280, width: 324, height: 104)
    private static let skipRect      = CGRect(x: 672, y: 280, width: 252, height: 104)
    private static let loopPhraseRect = CGRect(x: 36,  y: 394, width: 282, height: 78)
    private static let loopARect      = CGRect(x: 348, y: 394, width: 132, height: 78)
    private static let loopBRect      = CGRect(x: 498, y: 394, width: 132, height: 78)
    private static let loopOnRect     = CGRect(x: 648, y: 394, width: 276, height: 78)
    private static let tempoDownRect = CGRect(x: 36,  y: 482, width: 110, height: 78)
    private static let tempoUpRect   = CGRect(x: 256, y: 482, width: 110, height: 78)
    private static let waitRect      = CGRect(x: 396, y: 482, width: 252, height: 78)
    private static let handRect      = CGRect(x: 672, y: 482, width: 252, height: 78)

    // ── Access ──────────────────────────────────────────────────────────
    private static let textSizeRect  = CGRect(x: 36,  y: 138, width: 888, height: 90)
    private static let contrastRect  = CGRect(x: 36,  y: 236, width: 888, height: 90)
    private static let dwellRect     = CGRect(x: 36,  y: 334, width: 888, height: 90)
    private static let cbRect        = CGRect(x: 36,  y: 432, width: 600, height: 90)
    private static let accessResetRect = CGRect(x: 648, y: 432, width: 276, height: 90)

    // Comfort
    private static let viewDownRect  = CGRect(x: 560, y: 126, width: 80, height: 56)
    private static let viewUpRect    = CGRect(x: 840, y: 126, width: 80, height: 56)
    private static let lensDownRect  = CGRect(x: 560, y: 196, width: 80, height: 56)
    private static let lensUpRect    = CGRect(x: 840, y: 196, width: 80, height: 56)
    private static let smoothRect    = CGRect(x: 40,  y: 300, width: 430, height: 84)
    private static let stereoRect    = CGRect(x: 490, y: 300, width: 430, height: 84)
    private static let handStyleRect = CGRect(x: 40,  y: 400, width: 430, height: 84)
    private static let comfortResetRect = CGRect(x: 490, y: 400, width: 430, height: 84)

    // Setup
    // Setup: top row, then an ALIGN grid of labelled button pairs (two columns).
    private static let mapRect       = CGRect(x: 24,  y: 118, width: 300, height: 76)
    private static let debugRect     = CGRect(x: 340, y: 118, width: 268, height: 76)
    private static let labelsRect    = CGRect(x: 624, y: 118, width: 312, height: 76)
    private static func alignCell(row: Int, col: Int, button: Int) -> CGRect {
        CGRect(x: (col == 0 ? 24 : 492) + 196 + CGFloat(button) * 124,
               y: 218 + CGFloat(row) * 84, width: 118, height: 74)
    }
    private static func alignLabel(row: Int, col: Int) -> CGRect {
        CGRect(x: (col == 0 ? 24 : 492) + 6, y: 218 + CGFloat(row) * 84, width: 188, height: 74)
    }
    private static let alignResetRect = CGRect(x: 24, y: 480, width: 430, height: 80)
    private static let recordRect     = CGRect(x: 492, y: 480, width: 300, height: 80)
    private static let calibRect      = CGRect(x: 806, y: 480, width: 130, height: 80)

    // Minimized pill
    private static let pillRect     = CGRect(x: 40,  y: 16, width: 880, height: 116)
    private static let pauseRect    = CGRect(x: 58,  y: 30, width: 206, height: 88)
    private static let pillLoopRect = CGRect(x: 276, y: 30, width: 206, height: 88)
    private static let pillSkipRect = CGRect(x: 494, y: 30, width: 206, height: 88)
    private static let menuRect     = CGRect(x: 712, y: 30, width: 190, height: 88)

    private static func tabRect(_ t: Tab) -> CGRect {
        let w = texW / CGFloat(Tab.allCases.count)
        return CGRect(x: CGFloat(t.rawValue) * w, y: tabTop, width: w, height: tabBarH)
    }

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
    private enum Tab: Int, CaseIterable {
        case library, practice, comfort, access, setup
        /// Short enough to fit five tabs across, even at HUGE text.
        var title: String {
            switch self {
            case .library:  return "SONGS"
            case .practice: return "PLAY"
            case .comfort:  return "VIEW"
            case .access:   return "ACCESS"
            case .setup:    return "SETUP"
            }
        }
        /// Spelled out in the header, where there is room.
        var heading: String {
            switch self {
            case .library:  return "LIBRARY"
            case .practice: return "PRACTICE"
            case .comfort:  return "VIEW & COMFORT"
            case .access:   return "ACCESSIBILITY"
            case .setup:    return "SETUP"
            }
        }
    }

    private enum Region: Equatable {
        case none
        case handle
        case tab(Tab)
        case song(Int)                     // absolute song index
        case pagePrev, pageNext, minimize
        case play, restart, skip, tempoDown, tempoUp, hand, wait, seek
        case loopPhrase, loopA, loopB, loopOn
        case textSize, contrast, dwell, colorBlind, accessReset
        case viewDown, viewUp, lensDown, lensUp, smooth, stereo, handStyle, comfortReset
        case mapKeys, debug, labels, alignReset, record, calibrate
        case slideLeft, slideRight, keyLeft, keyRight, depthAway, depthToward
        case widthMinus, widthPlus, turnLeft, turnRight, heightDown, heightUp
        case pillPause, pillSkip, pillMenu, pillLoop

        var actionable: Bool { self != .none && self != .handle }
    }

    // ── State (render thread) ───────────────────────────────────────────────
    private var activeTab: Tab = .library
    private var libPage = 0
    private var minimized = false

    /// SETUP tab open → the renderer lights up the key outlines.
    var showsAlignment: Bool { !minimized && activeTab == .setup }
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
            if newState.isPlaying && !wasPlaying { minimized = true; activeTab = .practice }
            if !newState.isPlaying && wasPlaying { minimized = false }
            wasPlaying = newState.isPlaying
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

    private static let practiceControls: [(Region, CGRect)] = [
        (.play, playRect), (.restart, restartRect), (.skip, skipRect),
        (.seek, seekRect),
        (.loopPhrase, loopPhraseRect), (.loopA, loopARect),
        (.loopB, loopBRect), (.loopOn, loopOnRect),
        (.tempoDown, tempoDownRect), (.tempoUp, tempoUpRect),
        (.hand, handRect), (.wait, waitRect),
    ]
    private static let accessControls: [(Region, CGRect)] = [
        (.textSize, textSizeRect), (.contrast, contrastRect), (.dwell, dwellRect),
        (.colorBlind, cbRect), (.accessReset, accessResetRect),
    ]
    private static let comfortControls: [(Region, CGRect)] = [
        (.viewDown, viewDownRect), (.viewUp, viewUpRect),
        (.lensDown, lensDownRect), (.lensUp, lensUpRect),
        (.smooth, smoothRect), (.stereo, stereoRect),
        (.handStyle, handStyleRect), (.comfortReset, comfortResetRect),
    ]
    private static let setupControls: [(Region, CGRect)] = [
        (.mapKeys, mapRect), (.debug, debugRect), (.labels, labelsRect),
        (.slideLeft, alignCell(row: 0, col: 0, button: 0)), (.slideRight, alignCell(row: 0, col: 0, button: 1)),
        (.keyLeft, alignCell(row: 0, col: 1, button: 0)), (.keyRight, alignCell(row: 0, col: 1, button: 1)),
        (.depthAway, alignCell(row: 1, col: 0, button: 0)), (.depthToward, alignCell(row: 1, col: 0, button: 1)),
        (.widthMinus, alignCell(row: 1, col: 1, button: 0)), (.widthPlus, alignCell(row: 1, col: 1, button: 1)),
        (.turnLeft, alignCell(row: 2, col: 0, button: 0)), (.turnRight, alignCell(row: 2, col: 0, button: 1)),
        (.heightDown, alignCell(row: 2, col: 1, button: 0)), (.heightUp, alignCell(row: 2, col: 1, button: 1)),
        (.alignReset, alignResetRect), (.record, recordRect), (.calibrate, calibRect),
    ]

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
        for t in Tab.allCases where Self.tabRect(t).contains(pt) { return .tab(t) }
        if state.isPlaying, Self.minimizeRect.contains(pt) { return .minimize }

        let table: [(Region, CGRect)]
        switch activeTab {
        case .library:
            if pageCount > 1 {
                if Self.pagePrevRect.contains(pt) { return .pagePrev }
                if Self.pageNextRect.contains(pt) { return .pageNext }
            }
            let first = libPage * Self.libPerPage
            let count = min(Self.libPerPage, songs.count - first)
            for i in 0..<max(0, count) where Self.libCellRect(i).contains(pt) {
                return .song(first + i)
            }
            return .none
        case .practice: table = Self.practiceControls
        case .comfort:  table = Self.comfortControls
        case .access:   table = Self.accessControls
        case .setup:    table = Self.setupControls
        }
        return table.first { $0.1.contains(pt) }?.0 ?? .none
    }

    /// The texture rect of a region (sticky targeting + highlight ring).
    private func rectFor(_ region: Region) -> CGRect? {
        switch region {
        case .none:        return nil
        case .handle:      return CGRect(x: 0, y: 0, width: Self.texW, height: Self.handleH)
        case .tab(let t):  return Self.tabRect(t)
        case .song(let i):
            let local = i - libPage * Self.libPerPage
            return (0..<Self.libPerPage).contains(local) ? Self.libCellRect(local) : nil
        case .pagePrev:    return Self.pagePrevRect
        case .pageNext:    return Self.pageNextRect
        case .minimize:    return Self.minimizeRect
        case .pillPause:   return Self.pauseRect
        case .pillLoop:    return Self.pillLoopRect
        case .pillSkip:    return Self.pillSkipRect
        case .pillMenu:    return Self.menuRect
        default:
            let all = Self.practiceControls + Self.comfortControls
                    + Self.accessControls + Self.setupControls
            return all.first { $0.0 == region }?.1
        }
    }

    /// Applies a region's effect. Pure navigation returns nil; everything
    /// else becomes a MenuAction for ContentView.
    private func fire(_ region: Region, dirty: inout Bool) -> MenuAction? {
        switch region {
        case .none, .handle:
            return nil
        case .tab(let t):
            if activeTab != t { activeTab = t; dirty = true }
            return nil
        case .song(let i):
            activeTab = .practice
            dirty = true
            return .loadAndPlay(i >= 0 && i < songs.count ? songs[i] : nil)
        case .pagePrev:
            libPage = max(0, libPage - 1); dirty = true; return nil
        case .pageNext:
            libPage = min(pageCount - 1, libPage + 1); dirty = true; return nil
        case .minimize:
            minimized = true; dirty = true; return nil
        case .pillMenu:
            minimized = false; dirty = true; return nil
        case .pillPause, .play:  return .playStop
        case .pillSkip, .skip:   return .skip
        case .restart:           return .restart
        case .tempoDown:         return .tempo(-0.05)
        case .tempoUp:           return .tempo(0.05)
        case .hand:              return .cycleHand
        case .wait:              return .toggleWaitMode
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
        case .textSize:          return .cycleTextSize
        case .contrast:          return .toggleContrast
        case .dwell:             return .cycleDwell
        case .colorBlind:        return .toggleColorBlind
        case .accessReset:       return .resetAccess
        case .viewDown:          return .viewScale(-0.02)
        case .viewUp:            return .viewScale(0.02)
        case .lensDown:          return .lensSpacing(-0.5)
        case .lensUp:            return .lensSpacing(0.5)
        case .smooth:            return .toggleSmoothing
        case .stereo:            return .toggleStereo
        case .handStyle:         return .cycleHandStyle
        case .comfortReset:      return .resetComfort
        case .mapKeys:           return .recalibrate
        case .debug:             return .toggleDebug
        case .labels:            return .toggleKeyLabels
        case .alignReset:        return .align(.reset)
        case .record:            return .toggleRecording
        case .calibrate:         return .toggleCalibration
        case .slideLeft:         return .align(.moveX(-KeyboardAlignment.slideStep))
        case .slideRight:        return .align(.moveX(KeyboardAlignment.slideStep))
        case .keyLeft:           return .align(.moveX(-KeyboardAlignment.keyStep))
        case .keyRight:          return .align(.moveX(KeyboardAlignment.keyStep))
        case .depthAway:         return .align(.moveZ(-KeyboardAlignment.slideStep))
        case .depthToward:       return .align(.moveZ(KeyboardAlignment.slideStep))
        case .widthMinus:        return .align(.width(-KeyboardAlignment.widthStep))
        case .widthPlus:         return .align(.width(KeyboardAlignment.widthStep))
        case .turnLeft:          return .align(.rotate(KeyboardAlignment.turnStep))
        case .turnRight:         return .align(.rotate(-KeyboardAlignment.turnStep))
        case .heightDown:        return .align(.moveY(-KeyboardAlignment.heightStep))
        case .heightUp:          return .align(.moveY(KeyboardAlignment.heightStep))
        }
    }

    // MARK: - Texture dispatch

    private struct PanelSnap {
        let tab: Tab
        let minimized: Bool
        let state: MenuState
        let page: Int
        let pageCount: Int
        let pageTitles: [String]
        let grabbing: Bool
        let hotRect: CGRect?
    }

    private func dispatchBake() {
        let first = libPage * Self.libPerPage
        let titles = Array(state.songTitles.dropFirst(first).prefix(Self.libPerPage))
        let snap = PanelSnap(tab: activeTab, minimized: minimized, state: state,
                             page: libPage, pageCount: pageCount, pageTitles: titles,
                             grabbing: grabbed, hotRect: rectFor(hotRegion))
        let mat = panelMat!
        DispatchQueue.main.async { mat.diffuse.contents = ARMenuOverlay.bake(snap) }
    }

    // MARK: - Baking  (main thread only — UIKit)

    // Brighter than before, and the neutral state far lighter. Everything is
    // seen through two plastic lenses inside a dark shell, which costs a lot
    // of brightness and most of the saturation — colours that look right on a
    // monitor read as grey mush in the headset.
    // ── Style state ─────────────────────────────────────────────────────
    // Set once at the top of bake() and read by every draw helper below.
    // bake() is only ever called from the main queue and runs start to
    // finish synchronously, so these never overlap between two bakes.
    private static var tScale: CGFloat = 1
    private static var hiCon = false

    static func fnt(_ size: CGFloat, _ w: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: (size * tScale).rounded(), weight: w)
    }
    static func monoFnt(_ size: CGFloat, _ w: UIFont.Weight) -> UIFont {
        .monospacedDigitSystemFont(ofSize: (size * tScale).rounded(), weight: w)
    }
    /// White at a given alpha — lifted in high-contrast mode, where every
    /// subtitle and hint that was deliberately faint becomes unreadable.
    private static func dim(_ a: CGFloat) -> UIColor {
        UIColor(white: 1, alpha: hiCon ? min(1, a * 0.45 + 0.55) : a)
    }
    private static func lift(_ c: UIColor) -> UIColor {
        guard hiCon else { return c }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a) else { return c }
        return UIColor(hue: h, saturation: sat * 0.86, brightness: min(1, b * 1.15 + 0.10), alpha: a)
    }

    private static var accentBlue:   UIColor { lift(UIColor(red: 0.32, green: 0.66, blue: 1.00, alpha: 1)) }
    private static var accentGreen:  UIColor { lift(UIColor(red: 0.20, green: 0.80, blue: 0.44, alpha: 1)) }
    private static var accentRed:    UIColor { lift(UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1)) }
    private static var accentPurple: UIColor { lift(UIColor(red: 0.60, green: 0.40, blue: 1.00, alpha: 1)) }
    /// Loops get their own colour so a marked section is never confused with
    /// progress (blue) or with a toggle that happens to be on (green).
    private static var accentAmber:  UIColor { lift(UIColor(red: 1.00, green: 0.70, blue: 0.22, alpha: 1)) }
    private static var neutral:      UIColor { UIColor(white: 1, alpha: hiCon ? 0.34 : 0.22) }

    /// The visible part of the scrub bar. The hit area is the whole card
    /// around it, but a tap has to be measured against what you can see.
    private static var seekTrack: CGRect {
        CGRect(x: seekRect.minX + 20, y: seekRect.minY + 38, width: seekRect.width - 40, height: 26)
    }

    /// A grouping container — the thing that stops a screen reading as a
    /// loose pile of buttons.
    private static func card(_ r: CGRect, radius: CGFloat = 22) {
        UIColor(white: 1, alpha: hiCon ? 0.12 : 0.055).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
        dim(0.12).setStroke()
        let b = UIBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius)
        b.lineWidth = 1.5
        b.stroke()
    }

    private static func rightAligned(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.maxX - sz.width, y: rect.midY - sz.height / 2), withAttributes: attrs)
    }

    /// One settings line: name on the left, current value on the right.
    /// Reads as a list rather than a wall of identical buttons, and the
    /// whole row is the target.
    private static func settingRow(_ r: CGRect, _ label: String, _ value: String, on: Bool) {
        button(r, "", fill: neutral, size: 1, radius: 26)
        leftTruncated(label, in: CGRect(x: r.minX + 28, y: r.minY, width: r.width * 0.52, height: r.height),
                      font: fnt(27, .heavy), color: .white)
        rightAligned(value, in: CGRect(x: r.midX, y: r.minY, width: r.width / 2 - 28, height: r.height),
                     font: fnt(27, .heavy), color: on ? accentGreen : dim(0.72))
    }

    private static func wrapped(_ text: String, in rect: CGRect, size: CGFloat,
                                align: NSTextAlignment = .left, alpha: CGFloat = 0.55) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: rect, withAttributes: [.font: fnt(size, .medium),
                                                           .foregroundColor: dim(alpha),
                                                           .paragraphStyle: para])
    }

    private static func bake(_ s: PanelSnap) -> UIImage {
        tScale = s.state.access.textSize.scale
        hiCon  = s.state.access.highContrast
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { ctx in
            if s.minimized {
                drawPill(s)
                ring(s.hotRect)
                return
            }
            let full = CGRect(origin: .zero, size: sz)
            UIColor(red: 0.03, green: 0.02, blue: 0.09, alpha: hiCon ? 1.0 : 0.97).setFill()
            UIBezierPath(roundedRect: full, cornerRadius: 30).fill()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [UIColor(red: hiCon ? 0.04 : 0.11,
                                                          green: hiCon ? 0.03 : 0.06,
                                                          blue: hiCon ? 0.10 : 0.24, alpha: 1).cgColor,
                                                  UIColor(red: hiCon ? 0.01 : 0.04,
                                                          green: hiCon ? 0.01 : 0.02,
                                                          blue: hiCon ? 0.04 : 0.12, alpha: 1).cgColor] as CFArray,
                                         locations: [0, 1]) {
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: full, cornerRadius: 28).addClip()
                ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: 0, y: texH), options: [])
                ctx.cgContext.restoreGState()
            }

            drawGrabHandle(s)
            drawHeader(s)
            switch s.tab {
            case .library:  drawLibrary(s)
            case .practice: drawPractice(s)
            case .comfort:  drawComfort(s)
            case .access:   drawAccess(s)
            case .setup:    drawSetup(s)
            }
            drawTabBar(s)
            ring(s.hotRect)
        }
    }

    /// Bright ring around whatever the cursor targets.
    private static func ring(_ r: CGRect?) {
        guard let r else { return }
        // In high contrast the ring becomes yellow: at a glance it has to be
        // obvious which control is armed, and a pale blue outline on a dark
        // panel is exactly the cue that low-vision users lose first.
        let c = hiCon ? UIColor(red: 1.0, green: 0.92, blue: 0.25, alpha: 1)
                      : UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.95)
        c.withAlphaComponent(0.22).setStroke()
        let glow = UIBezierPath(roundedRect: r.insetBy(dx: -9, dy: -9), cornerRadius: 24)
        glow.lineWidth = 10
        glow.stroke()
        c.setStroke()
        let p = UIBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), cornerRadius: 20)
        p.lineWidth = hiCon ? 6 : 4
        p.stroke()
    }

    private static func button(_ r: CGRect, _ title: String, fill: UIColor,
                               size: CGFloat = 22, weight: UIFont.Weight = .bold,
                               text: UIColor = .white, radius: CGFloat = 16) {
        let rad = min(radius, r.height / 2)
        let path = UIBezierPath(roundedRect: r, cornerRadius: rad)
        fill.setFill()
        path.fill()
        // A top-down sheen: a flat fill reads as a painted rectangle, the
        // same fill with a highlight along its top edge reads as a key.
        if let ctx = UIGraphicsGetCurrentContext(),
           let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [UIColor(white: 1, alpha: 0.18).cgColor,
                                       UIColor(white: 1, alpha: 0.00).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.saveGState()
            path.addClip()
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY),
                                   end: CGPoint(x: r.minX, y: r.midY), options: [])
            ctx.restoreGState()
        }
        dim(hiCon ? 0.55 : 0.16).setStroke()
        let b = UIBezierPath(roundedRect: r.insetBy(dx: 0.9, dy: 0.9), cornerRadius: rad)
        b.lineWidth = hiCon ? 2.5 : 1.5
        b.stroke()
        guard !title.isEmpty else { return }
        centered(title, in: r, font: fnt(size, weight), color: text)
    }

    private static func drawPill(_ s: PanelSnap) {
        UIColor(red: 0.04, green: 0.03, blue: 0.11, alpha: hiCon ? 0.98 : 0.88).setFill()
        UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).fill()
        button(pauseRect, s.state.isPlaying ? "❚❚  PAUSE" : "▶  PLAY",
               fill: s.state.isPlaying ? accentRed : accentBlue, size: 31, weight: .heavy, radius: 40)
        // The loop you want is nearly always the bars you have just played,
        // so marking one has to be reachable without opening the menu.
        button(pillLoopRect, s.state.loopOn ? "⟲  LOOP ON" : "⟲  LOOP",
               fill: s.state.loopOn ? accentAmber : neutral, size: 31, weight: .heavy,
               text: s.state.loopOn ? .black : .white, radius: 40)
        button(pillSkipRect, "SKIP  ▸▸", fill: neutral, size: 31, weight: .heavy, radius: 40)
        button(menuRect, "☰  MENU", fill: accentPurple, size: 31, weight: .heavy, radius: 40)
    }

    private static func drawGrabHandle(_ s: PanelSnap) {
        let bg: UIColor = s.grabbing
            ? UIColor(red: 0.16, green: 0.46, blue: 0.22, alpha: 0.95)
            : UIColor(red: 0.13, green: 0.07, blue: 0.30, alpha: 0.92)
        bg.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: texW, height: handleH)).fill()
        UIColor(white: 1, alpha: s.grabbing ? 0.95 : 0.55).setFill()
        for dx in [-22, 0, 22] {
            let x = texW / 2 + CGFloat(dx)
            UIBezierPath(ovalIn: CGRect(x: x - 4.5, y: handleH / 2 - 4.5, width: 9, height: 9)).fill()
        }
        let title = s.grabbing ? "MOVING…" : "PIANOAR"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: fnt(25, .black),
            .foregroundColor: UIColor(white: 1, alpha: s.grabbing ? 0.95 : 0.65),
            .kern: 3.2 as NSObject,
        ]
        let tsz = title.size(withAttributes: attrs)
        title.draw(at: CGPoint(x: 24, y: (handleH - tsz.height) / 2), withAttributes: attrs)
        if !s.grabbing {
            let hint = "PINCH & HOLD TO MOVE"
            let hAttrs: [NSAttributedString.Key: Any] = [
                .font: fnt(21, .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.45),
            ]
            let hsz = hint.size(withAttributes: hAttrs)
            hint.draw(at: CGPoint(x: texW - hsz.width - 24, y: (handleH - hsz.height) / 2),
                      withAttributes: hAttrs)
        }
    }

    private static func drawHeader(_ s: PanelSnap) {
        centered(s.tab.heading, in: CGRect(x: 0, y: handleH, width: texW, height: headerH),
                 font: fnt(29, .black), color: dim(0.62))
        if s.state.isPlaying {
            button(minimizeRect, "▾  MINIMIZE", fill: neutral, size: 24)
        }
        if s.tab == .library, s.pageCount > 1 {
            button(pagePrevRect, "‹ PREV", fill: s.page > 0 ? neutral : UIColor(white: 1, alpha: 0.03), size: 24)
            button(pageNextRect, "NEXT ›", fill: s.page < s.pageCount - 1 ? neutral : UIColor(white: 1, alpha: 0.03), size: 24)
        }
    }

    private static func drawTabBar(_ s: PanelSnap) {
        UIColor(white: 1, alpha: 0.04).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: tabTop, width: texW, height: tabBarH)).fill()
        for t in Tab.allCases {
            let r = tabRect(t)
            if t == s.tab {
                accentPurple.setFill()
                UIBezierPath(roundedRect: r.insetBy(dx: 7, dy: 8), cornerRadius: 18).fill()
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: r.midX - 26, y: r.maxY - 9,
                                                 width: 52, height: 4),
                             cornerRadius: 2).fill()
            }
            centered(t.title, in: r, font: fnt(24, .bold),
                     color: t == s.tab ? .white : dim(0.5))
        }
        UIColor(white: 1, alpha: 0.16).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: tabTop, width: texW, height: 1)).fill()
    }

    private static func drawLibrary(_ s: PanelSnap) {
        let accents: [UIColor] = [
            UIColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1),
            UIColor(red: 0.75, green: 0.42, blue: 1.00, alpha: 1),
            UIColor(red: 0.24, green: 0.82, blue: 0.68, alpha: 1),
            UIColor(red: 1.00, green: 0.60, blue: 0.28, alpha: 1),
            UIColor(red: 1.00, green: 0.40, blue: 0.60, alpha: 1),
        ]
        if s.pageTitles.isEmpty {
            centered("No songs", in: CGRect(x: 0, y: contentTop, width: texW, height: 200),
                     font: fnt(29, .semibold), color: UIColor(white: 1, alpha: 0.5))
        }
        // The library is not limited to what ships with the app, and nothing
        // said so. Any MIDI file dropped into the app's folder shows up here,
        // which is the answer for every piece that is still in copyright and
        // so cannot be written into the app itself.
        centered("Add your own: put a .mid file in Files › On My iPhone › PianoAR",
                 in: CGRect(x: 0, y: 556, width: texW, height: 26),
                 font: fnt(21, .medium),
                 color: UIColor(white: 1, alpha: 0.45))
        for (i, title) in s.pageTitles.enumerated() {
            let rect = libCellRect(i)
            let accent = accents[(s.page * libPerPage + i) % accents.count]
            UIColor(red: 0.11, green: 0.07, blue: 0.24, alpha: 0.95).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 15).fill()
            accent.withAlphaComponent(0.55).setStroke()
            let border = UIBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 15)
            border.lineWidth = 1.5
            border.stroke()
            let chip = CGRect(x: rect.minX + 10, y: rect.midY - 18, width: 36, height: 36)
            accent.setFill()
            UIBezierPath(roundedRect: chip, cornerRadius: 10).fill()
            centered("♪", in: chip, font: fnt(25, .bold), color: .white)
            let textRect = CGRect(x: chip.maxX + 10, y: rect.minY,
                                  width: rect.maxX - chip.maxX - 18, height: rect.height)
            leftTruncated(title.isEmpty ? "Untitled" : title, in: textRect,
                          font: fnt(25, .semibold), color: .white)
        }
        if s.pageCount > 1 {
            centered("\(s.page + 1) / \(s.pageCount)",
                     in: CGRect(x: 0, y: tabTop - 30, width: texW, height: 26),
                     font: fnt(21, .bold), color: UIColor(white: 1, alpha: 0.45))
        }
    }

    private static func drawPractice(_ s: PanelSnap) {
        let st = s.state
        let hasSong = !st.currentTitle.isEmpty

        // ── title and where you are in it ────────────────────────────────
        leftTruncated(hasSong ? st.currentTitle : "Pick a song in SONGS",
                      in: CGRect(x: 40, y: 118, width: 590, height: 50),
                      font: fnt(31, .heavy), color: .white)
        if st.barCount > 0 {
            rightAligned("BAR \(st.bar) / \(st.barCount)",
                         in: CGRect(x: 630, y: 118, width: 294, height: 50),
                         font: monoFnt(26, .heavy), color: dim(0.75))
        }

        // ── scrub bar ────────────────────────────────────────────────────
        card(seekRect)
        let track = seekTrack
        let prog  = CGFloat(min(1, max(0, st.progress)))
        let clamp01: (Float) -> CGFloat = { CGFloat(min(1, max(0, $0))) }

        // bar ticks, one per four bars, so long pieces stay readable
        if st.barCount > 0 {
            let step = max(4, (st.barCount / 12 + 1) * 4)
            dim(0.20).setFill()
            var b = step
            while b < st.barCount {
                let x = track.minX + track.width * CGFloat(b) / CGFloat(st.barCount)
                UIBezierPath(rect: CGRect(x: x - 1, y: track.minY - 13, width: 2, height: 10)).fill()
                b += step
            }
        }

        dim(0.14).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 13).fill()

        // the marked section sits behind progress and stands taller than it,
        // so "where I am" and "what I am repeating" never look like one thing
        if st.loopOn {
            let a = track.minX + track.width * clamp01(st.loopFrom)
            let b = track.minX + track.width * clamp01(st.loopTo)
            let band = CGRect(x: a, y: track.minY - 7, width: max(6, b - a), height: track.height + 14)
            accentAmber.withAlphaComponent(0.30).setFill()
            UIBezierPath(roundedRect: band, cornerRadius: 12).fill()
            accentAmber.setFill()
            for x in [a, b] {
                UIBezierPath(roundedRect: CGRect(x: x - 3, y: band.minY, width: 6, height: band.height),
                             cornerRadius: 3).fill()
            }
        }

        let done = CGRect(x: track.minX, y: track.minY, width: track.width * prog, height: track.height)
        accentBlue.setFill()
        UIBezierPath(roundedRect: done, cornerRadius: 13).fill()

        // playhead: white disc with a dark core, readable over any of the above
        let hx = track.minX + track.width * prog
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: hx - 15, y: track.midY - 15, width: 30, height: 30)).fill()
        UIColor(red: 0.05, green: 0.04, blue: 0.14, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: hx - 5, y: track.midY - 5, width: 10, height: 10)).fill()

        let caption: String
        if st.loopOn {
            caption = st.loopLaps > 0
                ? "LOOP  bars \(st.loopFirstBar)–\(st.loopLastBar)   ·   \(st.loopLaps)× round"
                : "LOOP  bars \(st.loopFirstBar)–\(st.loopLastBar)"
        } else {
            caption = hasSong ? "Tap anywhere on the bar to jump there" : ""
        }
        centered(caption, in: CGRect(x: track.minX, y: seekRect.maxY - 28, width: track.width, height: 26),
                 font: fnt(21, .semibold), color: st.loopOn ? accentAmber : dim(0.55))

        // ── transport ────────────────────────────────────────────────────
        button(restartRect, "↺  START", fill: neutral, size: 28, radius: 26)
        button(playRect, st.isPlaying ? "❚❚  PAUSE" : "▶  PLAY",
               fill: st.isPlaying ? accentRed : accentBlue, size: 38, weight: .black, radius: 26)
        button(skipRect, "SKIP  ▸▸", fill: neutral, size: 28, radius: 26)

        // ── section practice ─────────────────────────────────────────────
        button(loopPhraseRect, "⟲  LOOP 4 BARS", fill: neutral, size: 25, radius: 24)
        button(loopARect, "SET  A", fill: neutral, size: 24, radius: 24)
        button(loopBRect, "SET  B", fill: neutral, size: 24, radius: 24)
        button(loopOnRect, st.loopOn ? "LOOP:  ON" : "LOOP:  OFF",
               fill: st.loopOn ? accentAmber : neutral, size: 26,
               text: st.loopOn ? .black : .white, radius: 24)

        // ── tempo, mode, hands ───────────────────────────────────────────
        button(tempoDownRect, "−", fill: neutral, size: 40, weight: .black, radius: 24)
        button(tempoUpRect, "+", fill: neutral, size: 40, weight: .black, radius: 24)
        centered("\(st.tempoPercent)%",
                 in: CGRect(x: tempoDownRect.maxX, y: tempoDownRect.minY,
                            width: tempoUpRect.minX - tempoDownRect.maxX, height: tempoDownRect.height),
                 font: monoFnt(32, .heavy), color: .white)
        button(waitRect, st.waitMode ? "WAIT FOR ME" : "PLAY-ALONG",
               fill: st.waitMode ? accentGreen : accentPurple, size: 24, radius: 24)
        button(handRect, st.hand.label.uppercased(), fill: neutral, size: 24, radius: 24)
    }

    private static func drawAccess(_ s: PanelSnap) {
        let a = s.state.access
        settingRow(textSizeRect, "TEXT SIZE", a.textSize.label, on: a.textSize != .normal)
        settingRow(contrastRect, "HIGH CONTRAST", a.highContrast ? "ON" : "OFF", on: a.highContrast)
        settingRow(dwellRect, "HOVER TO SELECT", a.dwell.label, on: a.dwell != .off)
        settingRow(cbRect, "COLOUR-BLIND SAFE", a.colorBlindSafe ? "ON" : "OFF", on: a.colorBlindSafe)
        button(accessResetRect, "RESET", fill: neutral, size: 26, radius: 26)
        wrapped("HOVER TO SELECT fires a control by resting on it, for when a pinch will not "
                + "register — set it OFF to require a pinch. COLOUR-BLIND SAFE keeps the hands "
                + "blue and orange but turns played notes white and wrong ones magenta.",
                in: CGRect(x: 40, y: 526, width: texW - 80, height: 40), size: 20)
    }

    private static func drawComfort(_ s: PanelSnap) {
        let c = s.state.comfort
        let labelFont = fnt(27, .heavy)
        let valueFont = fnt(33, .heavy)
        leftTruncated("VIEW SIZE", in: CGRect(x: 40, y: viewDownRect.minY, width: 480, height: viewDownRect.height),
                      font: labelFont, color: .white)
        leftTruncated("LENS SPACING", in: CGRect(x: 40, y: lensDownRect.minY, width: 480, height: lensDownRect.height),
                      font: labelFont, color: .white)
        for (down, up, value) in [(viewDownRect, viewUpRect, "\(Int((c.viewScale * 100).rounded()))%"),
                                  (lensDownRect, lensUpRect, String(format: "%.1f mm", c.lensSpacingMM))] {
            button(down, "−", fill: neutral, size: 40, weight: .black)
            button(up, "+", fill: neutral, size: 40, weight: .black)
            centered(value, in: CGRect(x: down.maxX, y: down.minY, width: up.minX - down.maxX, height: down.height),
                     font: valueFont, color: .white)
        }
        button(smoothRect, c.motionSmoothing ? "MOTION SMOOTHING:  ON" : "MOTION SMOOTHING:  OFF",
               fill: c.motionSmoothing ? accentGreen : neutral, size: 26)
        button(stereoRect, c.stereoMode == .dual ? "RENDER:  DUAL" : "RENDER:  SINGLE (FAST)",
               fill: c.stereoMode == .dual ? neutral : accentPurple, size: 26)
        button(handStyleRect, "HAND DISPLAY:  \(c.handStyle.label)", fill: neutral, size: 26)
        button(comfortResetRect, "RESET VIEW", fill: neutral, size: 26)

        let hint = "Motion sick? Stare at a far edge and shake your head. World swings AGAINST "
            + "your turn → lower VIEW SIZE. It DRAGS WITH you → raise it. Slide the headset "
            + "lenses to your eyes, then set LENS SPACING until everything looks single and sharp."
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        (hint as NSString).draw(in: CGRect(x: 50, y: 424, width: texW - 100, height: 130),
                                withAttributes: [.font: fnt(24, .medium),
                                                 .foregroundColor: UIColor(white: 1, alpha: 0.62),
                                                 .paragraphStyle: para])
    }

    private static func drawSetup(_ s: PanelSnap) {
        button(mapRect, "⌖  MAP KEYS (PINCH)", fill: accentBlue, size: 26)
        button(debugRect, s.state.debugOn ? "DEBUG:  ON" : "DEBUG:  OFF",
               fill: s.state.debugOn ? accentGreen : neutral, size: 26)
        button(labelsRect, s.state.keyLabels ? "KEY LABELS:  ON" : "KEY LABELS:  OFF",
               fill: s.state.keyLabels ? accentGreen : neutral, size: 26)

        centered(s.state.alignReadout, in: CGRect(x: 20, y: 182, width: texW - 40, height: 34),
                 font: monoFnt(22, .semibold),
                 color: UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.9))

        let rows: [(label: String, minus: String, plus: String)] = [
            ("SLIDE 5 mm", "◀", "▶"), ("SLIDE 1 KEY", "◀◀", "▶▶"),
            ("DEPTH", "▲ away", "▼ near"), ("WIDTH", "−", "+"),
            ("TURN", "↺", "↻"), ("HEIGHT", "▼", "▲"),
        ]
        let labelFont = fnt(24, .heavy)
        for (i, r) in rows.enumerated() {
            let row = i / 2, col = i % 2
            leftTruncated(r.label, in: alignLabel(row: row, col: col), font: labelFont,
                          color: UIColor(white: 1, alpha: 0.75))
            button(alignCell(row: row, col: col, button: 0), r.minus, fill: neutral, size: 30, weight: .black)
            button(alignCell(row: row, col: col, button: 1), r.plus, fill: neutral, size: 30, weight: .black)
        }
        button(alignResetRect, "RESET ALIGNMENT", fill: neutral, size: 25)
        button(recordRect,
               s.state.recording ? String(format: "● RECORDING  %d:%02d",
                                          s.state.recordSeconds / 60, s.state.recordSeconds % 60)
                                 : "◉  RECORD SESSION",
               fill: s.state.recording ? accentRed : neutral, size: 25)

        button(calibRect, s.state.calibrating ? "STOP" : "CALIBRATE",
               fill: s.state.calibrating ? accentGreen : neutral, size: 23)

        let hint = "Outlines show where the app thinks your keys are — line them up with the real ones. "
            + "RECORD saves the mic audio and every decision to Files › PianoAR › Diagnostics. "
            + "CALIBRATE (with RECORD on) names each note for you to play, so the log says exactly what was meant."
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        (hint as NSString).draw(in: CGRect(x: 30, y: 500, width: 900, height: 60),
                                withAttributes: [.font: fnt(21, .medium),
                                                 .foregroundColor: UIColor(white: 1, alpha: 0.55),
                                                 .paragraphStyle: para])
    }

    private static func centered(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.minX + (rect.width - sz.width) / 2,
                              y: rect.minY + (rect.height - sz.height) / 2), withAttributes: attrs)
    }

    /// Single line, left-aligned, vertically centred, tail-truncated.
    private static func leftTruncated(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let h = font.lineHeight
        (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
                                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }
}

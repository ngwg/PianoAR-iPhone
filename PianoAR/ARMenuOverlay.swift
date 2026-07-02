import SceneKit
import UIKit
import Vision
import simd

enum MenuAction { case playStop, restart, loadAndPlay(Song?), toggleDebug, recalibrate }

/// Large floating "tablet" AR panel — PianoVision / Quest-3 style.
///
/// Interaction, all single-hand, no pinch:
///
///   1. **Cursor** — the index fingertip is projected straight onto the panel
///      plane (panel-local X/Y), and a glowing dot is drawn there. Targeting
///      relies on X/Y (which Vision gives reliably), never on the finger
///      reaching an exact depth in mid-air.
///   2. **Click** — either **poke** (push the finger through: a clean depth
///      crossing fires instantly) or **dwell** (hold the cursor still on a
///      control for ~0.45s: a ring fills and fires). Poke is the fast path;
///      dwell is the guaranteed fallback when depth is noisy.
///   3. **Grab** — pinch (thumb + index together) on the top handle strip to
///      hold the panel; it follows the pinch while held and drops the moment
///      you open your fingers. Wide on/off hysteresis rides through the
///      landmark noise that made an earlier pinch implementation flaky.
///
/// All UIKit drawing is strictly main-thread (DispatchQueue.main.async). The
/// render thread only mutates SCNNode transforms and CGColor/UIImage refs, all
/// of which are documented thread-safe on SCNMaterial.
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Panel geometry ──────────────────────────────────────────────────────
    private static let panW: Float = 0.48
    private static let panH: Float = 0.32

    private static let texW: CGFloat = 960
    private static let texH: CGFloat = 640

    // UI zone heights (texture pixels)
    private static let handleH:  CGFloat = 58
    private static let tabBarH:  CGFloat = 72
    private static let headerH:  CGFloat = 56

    // Library is a 2-column grid of song cards (fits up to 12 = 6 rows)
    private static let libCols:  Int     = 2
    private static let libGap:   CGFloat = 10
    private static let libCellH: CGFloat = 56

    private static func libArea() -> CGRect {
        CGRect(x: 22, y: handleH + headerH,
               width: texW - 44,
               height: (texH - tabBarH) - (handleH + headerH) - 8)
    }
    private static func libMaxVisible() -> Int {
        let rows = Int((libArea().height + libGap) / (libCellH + libGap))
        return max(0, rows) * libCols
    }
    private static func libCellRect(_ i: Int) -> CGRect {
        let area  = libArea()
        let col   = i % libCols
        let row   = i / libCols
        let cellW = (area.width - CGFloat(libCols - 1) * libGap) / CGFloat(libCols)
        return CGRect(x: area.minX + CGFloat(col) * (cellW + libGap),
                      y: area.minY + CGFloat(row) * (libCellH + libGap),
                      width: cellW, height: libCellH)
    }

    // Shared control rects — single source of truth for hit-testing, the
    // baked drawing, AND the target highlight, so they can never drift apart.
    private static var ctlTopY: CGFloat { handleH + headerH }
    private static var ctlMidY: CGFloat { ctlTopY + (texH - tabBarH - ctlTopY) / 2 }
    private static var dbgRect:    CGRect { CGRect(x: 28, y: ctlTopY + 12, width: 190, height: 44) }
    private static var recalRect:  CGRect { CGRect(x: texW - 248, y: ctlTopY + 12, width: 220, height: 44) }
    private static var playRect:   CGRect { CGRect(x: texW/2 - 150, y: ctlMidY - 44, width: 300, height: 88) }
    private static var rstRect:    CGRect { CGRect(x: texW/2 - 110, y: ctlMidY + 62, width: 220, height: 54) }
    private static var tabLibRect: CGRect { CGRect(x: 0,      y: texH - tabBarH, width: texW/2, height: tabBarH) }
    private static var tabCtlRect: CGRect { CGRect(x: texW/2, y: texH - tabBarH, width: texW/2, height: tabBarH) }

    // ── Default placement (right of keyboard centre, lifted, tilted) ────────
    private static let initPos = SIMD3<Float>(KeyboardLayout.totalWidth * 0.30, 0.30, 0.18)
    private static let initRotX: Float = -Float.pi * 0.28
    private static let initRotY: Float = -Float.pi * 0.13

    // ── Cursor / click thresholds ───────────────────────────────────────────
    private static let hoverMaxZ:  Float        = 0.28
    private static let pokeArmZ:   Float        = 0.090
    private static let pokeFireZ:  Float        = 0.040
    private static let dwellTime:  TimeInterval = 0.45
    private static let debounce:   TimeInterval = 0.32
    private static let xyMargin:   Float        = 0.030

    // ── Grab thresholds (pinch the handle to hold, release pinch to drop) ──
    // Hysteresis between on/off keeps a slightly noisy thumb–index distance
    // from dropping the panel mid-move. While held, the panel follows the
    // PALM (wrist + knuckle centroid), not the pinch midpoint — the thumb and
    // index tips occlude each other during a pinch, which is exactly when
    // Vision loses them, so the pinch midpoint is the least reliable control
    // point at the worst possible moment. The palm stays cleanly visible.
    private static let grabPinchOn:   Float        = 0.035
    private static let grabPinchOff:  Float        = 0.065
    private static let grabLostGrace: TimeInterval = 0.40   // hand fully gone → drop
    private static let dragSmooth:    Float        = 0.45
    private static let yawSmooth:     Float        = 0.18   // face-camera easing while held

    // ── Sticky targeting ────────────────────────────────────────────────────
    // Once a control is targeted, it stays targeted until the cursor clearly
    // leaves (its rect inflated by this many texture pixels). Without this,
    // natural hand sway across the 10 px gaps between grid cells reset the
    // dwell timer constantly and dwell-select almost never completed.
    private static let stickyInflate: CGFloat = 34

    // ── Distance-adaptive scale ─────────────────────────────────────────────
    // The panel has a fixed world size, so from farther away it shrinks to
    // hand-size and its touch targets become impossible. Scale it with camera
    // distance so it keeps a roughly constant apparent (angular) size: at the
    // reference distance it's 1×, and it grows linearly beyond that. Because
    // fingertip → panel-local conversion goes through the node transform, the
    // touch zones scale up with it automatically.
    private static let refDistance: Float = 0.55   // metres at which scale = 1×
    private static let minScale:    Float = 1.0
    private static let maxScale:    Float = 2.4
    private static let scaleSmooth: Float = 0.10   // per-frame EMA toward target

    // ── Tabs / regions ──────────────────────────────────────────────────────
    private enum Tab { case library, controls }

    private enum Region: Equatable {
        case none
        case tab(Bool)        // true = library, false = controls
        case song(Int)
        case play, restart, debug, recalibrate

        var actionable: Bool { self != .none }
    }

    // ── State (render thread) ───────────────────────────────────────────────
    private var activeTab:      Tab     = .library
    private var availableSongs: [Song]  = []
    private var isPlaying              = false
    private var debugOn                = false
    private var needsRebake            = true
    private var lastTap: TimeInterval  = -999

    // Cursor / dwell / poke
    private var dwellRegion:    Region        = .none
    private var dwellStart:     TimeInterval  = 0
    private var pokeArmed:      Bool          = false
    private var firedRegion:    Region        = .none
    private var hotRegion:      Region        = .none   // targeted control (highlighted in bake)
    private var cursorLeft:     Bool?         = nil
    private var fireFlashUntil: TimeInterval  = 0

    // Grab (pinch handle to hold, release to drop)
    private var grabbed:      Bool          = false
    private var grabSide:     Bool?         = nil
    private var grabOffset:   SIMD3<Float>  = .zero
    private var grabTarget:   SIMD3<Float>  = .zero
    private var grabLastSeen: TimeInterval  = 0
    private var curYaw:       Float         = ARMenuOverlay.initRotY

    // Cursor smoothing (panel-local EMA so the dot sticks to the fingertip
    // without jitter)
    private var cursorSmoothed: SIMD3<Float>? = nil

    // Distance-adaptive scale + fire-flash (border feedback)
    private var curScale:   Float        = 1.0
    private var flashUntil: TimeInterval = 0

    // ── Scene nodes ─────────────────────────────────────────────────────────
    private var panelNode:   SCNNode!
    private var panelMat:    SCNMaterial!
    private var cursorNode:  SCNNode!
    private var cursorMat:   SCNMaterial!
    private var borderNodes: [SCNNode] = []

    init() { build() }

    // MARK: - Build  (main thread)

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
        animateIn()
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

            let box = SCNBox(width: CGFloat(e.w), height: CGFloat(e.h),
                             length: 0.001, chamferRadius: 0)
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
                isPlaying:      Bool,
                debugOn:        Bool = false,
                availableSongs: [Song] = [],
                cameraWorldPos: SIMD3<Float>? = nil) -> MenuAction? {

        var dirty = false
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying; dirty = true }
        if self.debugOn   != debugOn   { self.debugOn   = debugOn;   dirty = true }

        let newTitles = availableSongs.map { $0.title ?? "" }
        let oldTitles = self.availableSongs.map { $0.title ?? "" }
        if newTitles != oldTitles { self.availableSongs = availableSongs; dirty = true }

        // ── Distance-adaptive scale ──────────────────────────────────────────
        // Keeps the panel a usable apparent size no matter how far the user
        // stands from it. Touch zones ride along automatically because the
        // fingertip → panel-local transform includes node scale.
        if let cp = cameraWorldPos {
            let d      = simd_length(cp - panelNode.simdWorldPosition)
            let target = simd_clamp(d / Self.refDistance, Self.minScale, Self.maxScale)
            curScale  += Self.scaleSmooth * (target - curScale)
            panelNode.scale = SCNVector3(curScale, curScale, curScale)
        }

        // ── Pinch info per hand (thumb + index) ─────────────────────────────
        struct Pinch { let isLeft: Bool; let mid: SIMD3<Float>; let dist: Float }
        var pinches: [Pinch] = []
        for hand in hands {
            guard let t = hand.joints[.thumbTip],
                  let i = hand.joints[.indexTip] else { continue }
            pinches.append(Pinch(isLeft: hand.isLeft, mid: (t + i) * 0.5,
                                  dist: simd_length(t - i)))
        }

        // ── Grab: pinch the handle to hold. While held the panel follows the
        // PALM with an offset (stable even when the pinching fingertips
        // occlude each other), yaws to face the camera, and releases only on
        // a clearly-opened pinch — a lost joint for a few frames keeps
        // holding rather than dropping mid-move.
        if grabbed {
            var shouldRelease = false
            if let side = grabSide, let hand = hands.first(where: { $0.isLeft == side }) {
                grabLastSeen = time
                // Release only on positive evidence: both pinch joints seen
                // AND clearly apart. Missing joints ≠ released.
                if let t = hand.joints[.thumbTip], let i = hand.joints[.indexTip],
                   simd_length(t - i) > Self.grabPinchOff {
                    shouldRelease = true
                } else if let anchor = Self.palmAnchor(hand), let parent = panelNode.parent {
                    let target = parent.simdConvertPosition(anchor, from: nil) + grabOffset
                    grabTarget = grabTarget * Self.dragSmooth + target * (1 - Self.dragSmooth)
                    panelNode.simdPosition = grabTarget

                    // Yaw toward the camera so the panel faces you wherever
                    // you carry it (kept after release).
                    if let cp = cameraWorldPos, let parent2 = panelNode.parent {
                        let camLocal = parent2.simdConvertPosition(cp, from: nil)
                        let d = camLocal - panelNode.simdPosition
                        if simd_length(SIMD3<Float>(d.x, 0, d.z)) > 0.05 {
                            let targetYaw = atan2(d.x, d.z)
                            var delta = targetYaw - curYaw
                            while delta >  .pi { delta -= 2 * .pi }
                            while delta < -.pi { delta += 2 * .pi }
                            curYaw += delta * Self.yawSmooth
                            panelNode.eulerAngles = SCNVector3(Self.initRotX, curYaw, 0)
                        }
                    }
                }
            } else if time - grabLastSeen > Self.grabLostGrace {
                shouldRelease = true   // hand fully gone for a while → drop
            }

            if shouldRelease {
                grabbed = false; grabSide = nil
                dirty = true
                pulse()
            }
            cursorNode.isHidden = true
            cursorSmoothed = nil
            if hotRegion != .none { hotRegion = .none; dirty = true }
            if dirty || needsRebake { needsRebake = false; dispatchBake() }
            return nil
        }
        // Start a grab: a fresh pinch near the handle strip (generous zone —
        // this is a deliberate two-finger gesture, precision isn't needed).
        let handleLocalH = Float(Self.handleH / Self.texH) * Self.panH
        for p in pinches where p.dist < Self.grabPinchOn {
            let local = panelNode.simdConvertPosition(p.mid, from: nil)
            let inHandle = abs(local.x) < Self.panW/2 + 0.05
                        && local.y >  Self.panH/2 - handleLocalH * 1.6
                        && local.y <  Self.panH/2 + 0.06
                        && abs(local.z) < 0.14
            if inHandle, let parent = panelNode.parent,
               let hand = hands.first(where: { $0.isLeft == p.isLeft }),
               let anchor = Self.palmAnchor(hand) {
                grabbed      = true
                grabSide     = p.isLeft
                grabOffset   = panelNode.simdPosition - parent.simdConvertPosition(anchor, from: nil)
                grabTarget   = panelNode.simdPosition
                grabLastSeen = time
                dirty = true
                pulse()
                break
            }
        }
        if grabbed {
            cursorNode.isHidden = true
            cursorSmoothed = nil
            if dirty || needsRebake { needsRebake = false; dispatchBake() }
            return nil
        }

        // ── Cursor + click ────────────────────────────────────────────────────
        var result: MenuAction? = nil
        let pinchingSides = Set(pinches.filter { $0.dist < Self.grabPinchOff }.map { $0.isLeft })

        // Pick the index fingertip closest to the panel face, within bounds.
        // Hands mid-pinch are excluded — they're gesturing, not pointing.
        var best: (local: SIMD3<Float>, isLeft: Bool)? = nil
        for hand in hands {
            if pinchingSides.contains(hand.isLeft) { continue }
            guard let tip = hand.joints[.indexTip] else { continue }
            let local = panelNode.simdConvertPosition(tip, from: nil)
            guard abs(local.x) < Self.panW/2 + Self.xyMargin,
                  abs(local.y) < Self.panH/2 + Self.xyMargin,
                  local.z > -0.03, local.z < Self.hoverMaxZ else { continue }
            if best == nil || abs(local.z) < abs(best!.local.z) {
                best = (local, hand.isLeft)
            }
        }

        if let b = best {
            // EMA in panel-local space: the visible dot stays glued to the
            // fingertip without frame-to-frame jitter, and the SAME smoothed
            // position drives hit-testing so what you see is what you select.
            let sm: SIMD3<Float>
            if let prev = cursorSmoothed, cursorLeft == b.isLeft {
                sm = prev + 0.45 * (b.local - prev)
            } else {
                sm = b.local
            }
            cursorSmoothed = sm

            // Sticky targeting: raw region, but if the cursor briefly leaves
            // into dead space (a grid gap, a border) while staying within the
            // current target's inflated rect, keep the target — this is what
            // lets dwell actually complete despite natural hand sway.
            let raw = regionAt(localX: sm.x, localY: sm.y)
            var region = raw
            if raw == .none, dwellRegion != .none,
               let r = Self.rectFor(dwellRegion) {
                let pt = texPoint(localX: sm.x, localY: sm.y)
                if r.insetBy(dx: -Self.stickyInflate, dy: -Self.stickyInflate).contains(pt) {
                    region = dwellRegion
                }
            }

            // Highlight whatever is currently targeted (rebake on change).
            if region != hotRegion { hotRegion = region; dirty = true }

            if cursorLeft != b.isLeft {
                cursorLeft  = b.isLeft
                pokeArmed   = false
                dwellRegion = region
                dwellStart  = time
            }
            if region != dwellRegion { dwellRegion = region; dwellStart = time }
            if region != firedRegion { firedRegion = .none }

            if sm.z > Self.pokeArmZ { pokeArmed = true }
            let poked = pokeArmed && sm.z < Self.pokeFireZ

            let dwellProg = Float(simd_clamp((time - dwellStart) / Self.dwellTime, 0, 1))
            let dwellFire = (time - dwellStart) >= Self.dwellTime && firedRegion != region

            if region.actionable, time - lastTap > Self.debounce, poked || dwellFire {
                result = fire(region, dirty: &dirty)
                lastTap        = time
                fireFlashUntil = time + 0.18
                pokeArmed      = false
                firedRegion    = region
                dwellRegion    = .none
                dwellStart     = time
                pulse()
            }

            updateCursor(local: sm, progress: dwellProg,
                         actionable: region.actionable, time: time)
        } else {
            cursorNode.isHidden = true
            cursorSmoothed = nil
            dwellRegion = .none
            firedRegion = .none
            pokeArmed   = false
            cursorLeft  = nil
            if hotRegion != .none { hotRegion = .none; dirty = true }
        }

        // Border emission reflects grab / fire-flash state (CGColor — render-safe)
        let borderEmission: CGColor
        if grabbed || time < flashUntil {
            borderEmission = UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 0.95).cgColor
        } else {
            borderEmission = UIColor(red: 0.42, green: 0.20, blue: 0.85, alpha: 0.65).cgColor
        }
        for n in borderNodes { n.geometry?.firstMaterial?.emission.contents = borderEmission }

        if dirty || needsRebake { needsRebake = false; dispatchBake() }
        return result
    }

    /// Stable drag control point: centroid of wrist + knuckles. These joints
    /// stay cleanly visible during a pinch, unlike the pinching fingertips.
    private static func palmAnchor(_ hand: HandTracker.HandResult) -> SIMD3<Float>? {
        let names: [VNHumanHandPoseObservation.JointName] =
            [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let pts = names.compactMap { hand.joints[$0] }
        guard pts.count >= 2 else { return hand.joints[.indexTip] }
        return pts.reduce(SIMD3<Float>(repeating: 0), +) / Float(pts.count)
    }

    // MARK: - Cursor visuals  (render thread)

    private func updateCursor(local: SIMD3<Float>, progress: Float,
                              actionable: Bool, time: TimeInterval) {
        cursorNode.isHidden = false
        cursorNode.simdPosition = SIMD3<Float>(local.x, local.y, 0.007)

        let flashing = time < fireFlashUntil
        let scale: Float
        let color: CGColor
        if flashing {
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

    // MARK: - Region resolution / firing

    /// Panel-local metres → texture pixels.
    private func texPoint(localX: Float, localY: Float) -> CGPoint {
        let u = CGFloat((localX + Self.panW/2) / Self.panW)
        let v = CGFloat(1.0 - (localY + Self.panH/2) / Self.panH)
        return CGPoint(x: u * Self.texW, y: v * Self.texH)
    }

    private func regionAt(localX: Float, localY: Float) -> Region {
        let pt = texPoint(localX: localX, localY: localY)
        if pt.y < Self.handleH { return .none }               // handle = grab only
        if Self.tabLibRect.contains(pt) { return .tab(true) }
        if Self.tabCtlRect.contains(pt) { return .tab(false) }
        switch activeTab {
        case .library:
            let count = min(availableSongs.count, Self.libMaxVisible())
            for i in 0..<count where Self.libCellRect(i).contains(pt) {
                return .song(i)
            }
            return .none
        case .controls:
            if Self.dbgRect.contains(pt)   { return .debug }
            if Self.recalRect.contains(pt) { return .recalibrate }
            if Self.playRect.contains(pt)  { return .play }
            if Self.rstRect.contains(pt)   { return .restart }
            return .none
        }
    }

    /// The texture rect of a region (for sticky targeting and the highlight).
    private static func rectFor(_ region: Region) -> CGRect? {
        switch region {
        case .none:            return nil
        case .tab(let lib):    return lib ? Self.tabLibRect : Self.tabCtlRect
        case .song(let i):     return Self.libCellRect(i)
        case .debug:           return Self.dbgRect
        case .recalibrate:     return Self.recalRect
        case .play:            return Self.playRect
        case .restart:         return Self.rstRect
        }
    }

    /// Apply a region's effect. Returns a MenuAction for the caller to dispatch
    /// (or nil for pure UI navigation like tab switches).
    private func fire(_ region: Region, dirty: inout Bool) -> MenuAction? {
        switch region {
        case .none:
            return nil
        case .tab(let library):
            let wanted: Tab = library ? .library : .controls
            if activeTab != wanted { activeTab = wanted; dirty = true }
            return nil
        case .song(let i):
            activeTab = .controls; dirty = true
            let song: Song? = (i >= 0 && i < availableSongs.count) ? availableSongs[i] : nil
            return .loadAndPlay(song)
        case .play:        return .playStop
        case .restart:     return .restart
        case .debug:       return .toggleDebug
        case .recalibrate: return .recalibrate
        }
    }

    // MARK: - Proximity query (for Hand3DOverlay fingertip colour)

    func maxProximity(worldPos: SIMD3<Float>, keyboardNode: SCNNode) -> Float {
        let local  = panelNode.simdConvertPosition(worldPos, from: nil)
        let zProx  = simd_clamp(1.0 - abs(local.z) / 0.12, 0, 1)
        let xFade  = simd_clamp(1.0 - max(0, abs(local.x) - Self.panW/2) / 0.05, 0, 1)
        let yFade  = simd_clamp(1.0 - max(0, abs(local.y) - Self.panH/2) / 0.05, 0, 1)
        return zProx * xFade * yFade
    }

    // MARK: - Texture dispatch

    private func dispatchBake() {
        let snap = PanelSnap(tab: activeTab, songs: availableSongs,
                             isPlaying: isPlaying, debugOn: debugOn,
                             grabbing: grabbed, hot: hotRegion)
        let mat  = panelMat!
        DispatchQueue.main.async {
            mat.diffuse.contents = ARMenuOverlay.bake(snap)
        }
    }

    // MARK: - Texture baking  (main thread only — UIKit)

    private struct PanelSnap {
        let tab:       Tab
        let songs:     [Song]
        let isPlaying: Bool
        let debugOn:   Bool
        let grabbing:  Bool
        let hot:       Region
    }

    private static func bake(_ s: PanelSnap) -> UIImage {
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { ctx in
            // Layered background gives a soft depth cue without a real shadow API.
            let full = CGRect(origin: .zero, size: sz)
            UIColor(red: 0.03, green: 0.02, blue: 0.09, alpha: 0.97).setFill()
            UIBezierPath(roundedRect: full, cornerRadius: 28).fill()

            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor(red: 0.10, green: 0.05, blue: 0.22, alpha: 1).cgColor,
                    UIColor(red: 0.05, green: 0.03, blue: 0.14, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]
            )!
            ctx.cgContext.saveGState()
            UIBezierPath(roundedRect: full, cornerRadius: 28).addClip()
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: 0, y: texH), options: [])
            ctx.cgContext.restoreGState()

            drawGrabHandle(s)
            drawTabBar(s)
            switch s.tab {
            case .library:  drawLibrary(s)
            case .controls: drawControls(s)
            }

            // Target highlight: a bright ring around whatever the cursor is
            // on, so it's always obvious what a poke/dwell would select.
            if let r = rectFor(s.hot) {
                UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.95).setStroke()
                let ring = UIBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4),
                                        cornerRadius: 18)
                ring.lineWidth = 4
                ring.stroke()
            }
        }
    }

    private static func drawGrabHandle(_ s: PanelSnap) {
        let bg: UIColor = s.grabbing
            ? UIColor(red: 0.16, green: 0.46, blue: 0.22, alpha: 0.95)
            : UIColor(red: 0.13, green: 0.07, blue: 0.30, alpha: 0.92)
        bg.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: texW, height: handleH)).fill()

        let dotColor: UIColor = s.grabbing ? UIColor(white: 1, alpha: 0.95) : UIColor(white: 1, alpha: 0.55)
        dotColor.setFill()
        let cy: CGFloat = handleH / 2
        let r:  CGFloat = 4.5
        for dx in [-22, 0, 22] {
            let x = texW / 2 + CGFloat(dx)
            UIBezierPath(ovalIn: CGRect(x: x - r, y: cy - r, width: r*2, height: r*2)).fill()
        }

        let title = s.grabbing ? "MOVING…" : "PIANOAR"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .black),
            .foregroundColor: UIColor(white: 1, alpha: s.grabbing ? 0.95 : 0.60),
            .kern: 3.2 as NSObject,
        ]
        let tsz = title.size(withAttributes: attrs)
        title.draw(at: CGPoint(x: 24, y: (handleH - tsz.height) / 2), withAttributes: attrs)

        if !s.grabbing {
            let hint = "✌ PINCH HERE TO MOVE"
            let hAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.40),
            ]
            let hsz = hint.size(withAttributes: hAttrs)
            hint.draw(at: CGPoint(x: texW - hsz.width - 24, y: (handleH - hsz.height) / 2),
                      withAttributes: hAttrs)
        }

        UIColor(white: 1, alpha: 0.14).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: handleH - 1, width: texW, height: 1)).fill()
    }

    private static func drawTabBar(_ s: PanelSnap) {
        let y = texH - tabBarH
        let activeX: CGFloat = s.tab == .library ? 0 : texW / 2

        UIColor(white: 1, alpha: 0.04).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: y, width: texW, height: tabBarH)).fill()

        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(red: 0.42, green: 0.18, blue: 0.90, alpha: 0.85).cgColor,
                UIColor(red: 0.28, green: 0.10, blue: 0.68, alpha: 0.85).cgColor,
            ] as CFArray, locations: [0, 1])!
        UIGraphicsGetCurrentContext()?.saveGState()
        UIBezierPath(rect: CGRect(x: activeX, y: y, width: texW/2, height: tabBarH)).addClip()
        UIGraphicsGetCurrentContext()?.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: y), end: CGPoint(x: 0, y: y + tabBarH), options: [])
        UIGraphicsGetCurrentContext()?.restoreGState()

        UIColor(white: 1, alpha: 0.16).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: y, width: texW, height: 1)).fill()
        UIColor(white: 1, alpha: 0.10).setFill()
        UIBezierPath(rect: CGRect(x: texW/2 - 0.5, y: y + 14, width: 1, height: tabBarH - 28)).fill()

        let f = UIFont.systemFont(ofSize: 21, weight: .bold)
        centered("LIBRARY",  in: CGRect(x: 0,      y: y, width: texW/2, height: tabBarH),
                 font: f, color: s.tab == .library  ? .white : UIColor(white:1,alpha:0.40))
        centered("CONTROLS", in: CGRect(x: texW/2, y: y, width: texW/2, height: tabBarH),
                 font: f, color: s.tab == .controls ? .white : UIColor(white:1,alpha:0.40))
    }

    private static func drawLibrary(_ s: PanelSnap) {
        centered("LIBRARY", in: CGRect(x: 0, y: handleH, width: texW, height: headerH),
                 font: .systemFont(ofSize: 23, weight: .black),
                 color: UIColor(white: 1, alpha: 0.60))

        let accents: [UIColor] = [
            UIColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1),
            UIColor(red: 0.75, green: 0.42, blue: 1.00, alpha: 1),
            UIColor(red: 0.24, green: 0.82, blue: 0.68, alpha: 1),
            UIColor(red: 1.00, green: 0.60, blue: 0.28, alpha: 1),
            UIColor(red: 1.00, green: 0.40, blue: 0.60, alpha: 1),
        ]

        let count = min(s.songs.count, libMaxVisible())
        for i in 0..<count {
            let rect   = libCellRect(i)
            let accent = accents[i % accents.count]

            UIColor(red: 0.11, green: 0.07, blue: 0.24, alpha: 0.95).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 15).fill()
            accent.withAlphaComponent(0.55).setStroke()
            let border = UIBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 15)
            border.lineWidth = 1.5
            border.stroke()
            // Subtle inner highlight along the top edge, cheap fake-glass touch.
            UIColor(white: 1, alpha: 0.06).setFill()
            UIBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.4),
                        cornerRadius: 15).fill()

            let chip = CGRect(x: rect.minX + 10, y: rect.midY - 18, width: 36, height: 36)
            accent.setFill()
            UIBezierPath(roundedRect: chip, cornerRadius: 10).fill()
            centered("♪", in: chip, font: .systemFont(ofSize: 20, weight: .bold), color: .white)

            let title = s.songs[i].title ?? "Untitled"
            let textRect = CGRect(x: chip.maxX + 10, y: rect.minY,
                                  width: rect.maxX - chip.maxX - 18, height: rect.height)
            leftTruncated(title, in: textRect,
                          font: .systemFont(ofSize: 18, weight: .semibold), color: .white)
        }
    }

    private static func drawControls(_ s: PanelSnap) {
        centered("CONTROLS", in: CGRect(x: 0, y: handleH, width: texW, height: headerH),
                 font: .systemFont(ofSize: 23, weight: .black),
                 color: UIColor(white: 1, alpha: 0.60))

        // Debug (left) / Recalibrate (right) — a matched pair of pill buttons
        let dbgBg = s.debugOn
            ? UIColor(red: 0.10, green: 0.48, blue: 0.18, alpha: 0.85)
            : UIColor(white: 1, alpha: 0.09)
        dbgBg.setFill()
        UIBezierPath(roundedRect: dbgRect, cornerRadius: 13).fill()
        centered(s.debugOn ? "⚙ DEBUG ON" : "⚙ DEBUG",
                 in: dbgRect,
                 font: .systemFont(ofSize: 17, weight: .semibold),
                 color: s.debugOn ? UIColor(red: 0.55, green: 1.00, blue: 0.65, alpha: 1)
                                  : UIColor(white: 1, alpha: 0.60))

        UIColor(white: 1, alpha: 0.09).setFill()
        UIBezierPath(roundedRect: recalRect, cornerRadius: 13).fill()
        centered("⌖ RECALIBRATE", in: recalRect,
                 font: .systemFont(ofSize: 17, weight: .semibold),
                 color: UIColor(white: 1, alpha: 0.60))

        centered(s.isPlaying ? "● PLAYING" : "— READY —",
                 in: CGRect(x: 0, y: ctlTopY + 72, width: texW, height: 38),
                 font: .systemFont(ofSize: 21, weight: .black),
                 color: s.isPlaying
                    ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 1)
                    : UIColor(white: 1, alpha: 0.42))

        let playBg: UIColor = s.isPlaying
            ? UIColor(red: 0.82, green: 0.12, blue: 0.12, alpha: 0.95)
            : UIColor(red: 0.16, green: 0.50, blue: 0.98, alpha: 0.95)
        playBg.setFill()
        UIBezierPath(roundedRect: playRect, cornerRadius: 24).fill()
        UIColor(white: 1, alpha: 0.24).setStroke()
        let pb = UIBezierPath(roundedRect: playRect.insetBy(dx: 1, dy: 1), cornerRadius: 24)
        pb.lineWidth = 1.5
        pb.stroke()
        centered(s.isPlaying ? "■   STOP" : "▶   PLAY",
                 in: playRect, font: .systemFont(ofSize: 36, weight: .black), color: .white)

        UIColor(white: 1, alpha: 0.11).setFill()
        UIBezierPath(roundedRect: rstRect, cornerRadius: 15).fill()
        centered("↺   RESTART", in: rstRect,
                 font: .systemFont(ofSize: 21, weight: .bold),
                 color: UIColor(white: 1, alpha: 0.80))
    }

    private static func centered(_ text: String, in rect: CGRect,
                                  font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        let x  = rect.minX + (rect.width  - sz.width)  / 2
        let y  = rect.minY + (rect.height - sz.height) / 2
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    /// Single line, left-aligned, vertically centred, truncated with an ellipsis
    /// if it overflows the rect width.
    private static func leftTruncated(_ text: String, in rect: CGRect,
                                      font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]
        let h = font.lineHeight
        let r = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        (text as NSString).draw(in: r, withAttributes: attrs)
    }

    // MARK: - Entrance / feedback animation  (render thread — SCNAction is safe)

    // Note: no scale-based animations here — the distance-adaptive scale pass
    // owns panelNode.scale every frame, so entrance is a fade and tap feedback
    // is a border flash (via `flashUntil`) instead of a scale pulse.

    private func animateIn() {
        panelNode.opacity = 0
        panelNode.runAction(SCNAction.fadeIn(duration: 0.42))
    }

    /// Border flashes green briefly when a control fires (checked per frame in
    /// update() alongside the grab state).
    private func pulse() {
        flashUntil = CACurrentMediaTime() + 0.20
    }
}

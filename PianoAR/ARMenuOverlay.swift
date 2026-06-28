import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, loadAndPlay(Song?), toggleDebug }

/// Large floating "tablet" AR panel — PianoVision / Quest-3 style.
///
/// Three interactions, all driven by the index fingertip + thumb:
///
///   1. **Cursor** — the index fingertip is projected straight onto the panel
///      plane (panel-local X/Y), and a glowing dot is drawn there. Targeting
///      therefore relies on X/Y (which Vision gives reliably) and never on the
///      finger reaching an exact depth in mid-air. You can always *see* where
///      you're pointing.
///   2. **Click** — either **poke** (push the finger through the panel: a clean
///      depth crossing fires instantly) or **dwell** (hold the cursor still on a
///      control for ~0.5 s: a ring fills and fires). Poke is the fast path; dwell
///      is the guaranteed fallback when LiDAR depth is too noisy to poke cleanly.
///   3. **Grab** — pinch (thumb+index) on the top handle strip drags the panel
///      anywhere in space, with EMA smoothing; release to drop.
///
/// All UIKit drawing is strictly main-thread (DispatchQueue.main.async). The
/// render thread only mutates SCNNode transforms and CGColor/UIImage refs, all
/// of which are documented thread-safe on SCNMaterial.
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Panel geometry ──────────────────────────────────────────────────────
    private static let panW: Float = 0.48
    private static let panH: Float = 0.30

    private static let texW: CGFloat = 960
    private static let texH: CGFloat = 600

    // UI zone heights (texture pixels)
    private static let handleH:  CGFloat = 56
    private static let tabBarH:  CGFloat = 70
    private static let headerH:  CGFloat = 54
    private static let songRowH: CGFloat = 70

    // ── Default placement (right of keyboard centre, lifted, tilted) ────────
    private static let initPos = SIMD3<Float>(KeyboardLayout.totalWidth * 0.30, 0.30, 0.18)
    private static let initRotX: Float = -Float.pi * 0.28
    private static let initRotY: Float = -Float.pi * 0.13

    // ── Cursor / click thresholds ───────────────────────────────────────────
    // Generous reach: the cursor appears (and dwell works) from up to ~28 cm in
    // front of the panel, so you can tap from a comfortable distance without
    // having to push your finger all the way to the virtual surface.
    private static let hoverMaxZ:  Float        = 0.28   // show cursor within 28 cm of face
    private static let pokeArmZ:   Float        = 0.090  // finger must start beyond this …
    private static let pokeFireZ:  Float        = 0.040  // … then cross inside this to poke
    private static let dwellTime:  TimeInterval = 0.45
    private static let debounce:   TimeInterval = 0.32
    private static let xyMargin:   Float        = 0.030

    // ── Grab thresholds ─────────────────────────────────────────────────────
    private static let grabPinchOn:  Float = 0.030
    private static let grabPinchOff: Float = 0.055
    private static let grabHandleM:  Float = 0.050
    private static let dragSmooth:   Float = 0.55

    // ── Tabs / regions ──────────────────────────────────────────────────────
    private enum Tab { case library, controls }

    private enum Region: Equatable {
        case none
        case tab(Bool)        // true = library, false = controls
        case song(Int)        // 0 = built-in, i>0 = imported[i-1]
        case play, restart, debug

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
    private var pokeArmed:      Bool          = false   // finger has pulled back beyond arm dist
    private var firedRegion:    Region        = .none   // latch: blocks dwell auto-repeat
    private var cursorLeft:     Bool?         = nil      // which hand currently drives the cursor
    private var fireFlashUntil: TimeInterval  = 0

    // Grab
    private var grabSide:   Bool?        = nil
    private var grabOffset: SIMD3<Float> = .zero
    private var grabTarget: SIMD3<Float> = .zero

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
        panelMat.diffuse.contents     = UIColor(red: 0.06, green: 0.03, blue: 0.18, alpha: 0.97)
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
    }

    private func addBorder() {
        let baseEmission = UIColor(red: 0.35, green: 0.15, blue: 0.70, alpha: 0.55).cgColor
        let baseDiffuse  = UIColor(red: 0.45, green: 0.22, blue: 0.85, alpha: 0.70)
        let t: Float = 0.003

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
                availableSongs: [Song] = []) -> MenuAction? {

        var dirty = false
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying; dirty = true }
        if self.debugOn   != debugOn   { self.debugOn   = debugOn;   dirty = true }

        let newTitles = availableSongs.map { $0.title ?? "" }
        let oldTitles = self.availableSongs.map { $0.title ?? "" }
        if newTitles != oldTitles { self.availableSongs = availableSongs; dirty = true }

        // ── Pinch info ───────────────────────────────────────────────────────
        struct Pinch { let isLeft: Bool; let mid: SIMD3<Float>; let dist: Float }
        var pinches: [Pinch] = []
        for hand in hands {
            guard let t = hand.joints[.thumbTip],
                  let i = hand.joints[.indexTip] else { continue }
            pinches.append(Pinch(isLeft: hand.isLeft, mid: (t + i) * 0.5,
                                  dist: simd_length(t - i)))
        }

        // ── Grab ───────────────────────────────────────────────────────────
        let prevGrab = grabSide
        if let side = grabSide {
            if let p = pinches.first(where: { $0.isLeft == side }), p.dist < Self.grabPinchOff,
               let parent = panelNode.parent {
                let pinchLocal = parent.simdConvertPosition(p.mid, from: nil)
                let target     = pinchLocal + grabOffset
                grabTarget     = grabTarget * Self.dragSmooth + target * (1 - Self.dragSmooth)
                panelNode.simdPosition = grabTarget
            } else {
                grabSide = nil
            }
        }
        if grabSide == nil {
            for p in pinches where p.dist < Self.grabPinchOn {
                let panelLocal = panelNode.simdConvertPosition(p.mid, from: nil)
                let inHandle = abs(panelLocal.z) < 0.07
                            && abs(panelLocal.x) < Self.panW / 2 + 0.02
                            && panelLocal.y >  Self.panH / 2 - Self.grabHandleM
                            && panelLocal.y <  Self.panH / 2 + 0.025
                if inHandle, let parent = panelNode.parent {
                    let pinchLocal = parent.simdConvertPosition(p.mid, from: nil)
                    grabSide   = p.isLeft
                    grabOffset = panelNode.simdPosition - pinchLocal
                    grabTarget = panelNode.simdPosition
                    break
                }
            }
        }
        if (prevGrab == nil) != (grabSide == nil) { dirty = true }

        // ── Cursor + click  (skipped while grabbing) ─────────────────────────
        var result: MenuAction? = nil
        if grabSide == nil {
            let pinchingSides = Set(pinches.filter { $0.dist < Self.grabPinchOff }.map { $0.isLeft })

            // Pick the index fingertip closest to the panel face, within bounds.
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
                let region = regionAt(localX: b.local.x, localY: b.local.y)

                // Reset per-finger state when a different hand takes the cursor.
                if cursorLeft != b.isLeft {
                    cursorLeft  = b.isLeft
                    pokeArmed   = false
                    dwellRegion = region
                    dwellStart  = time
                }

                // Dwell bookkeeping — restart the timer whenever the target changes.
                if region != dwellRegion {
                    dwellRegion = region
                    dwellStart  = time
                }

                // Release the latch once the cursor leaves the region it last fired on,
                // so dwell can fire there again (but won't auto-repeat while held).
                if region != firedRegion { firedRegion = .none }

                // Poke: arm when the finger is pulled back past the arm distance, then
                // fire the moment it crosses the (much closer) fire distance. Tracking an
                // armed flag rather than a single-frame delta lets slower pokes register.
                // A re-poke needs a fresh pull-back, so it never auto-repeats while held.
                if b.local.z > Self.pokeArmZ { pokeArmed = true }
                let poked = pokeArmed && b.local.z < Self.pokeFireZ

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
                }

                updateCursor(local: b.local, progress: dwellProg,
                             actionable: region.actionable, time: time)
            } else {
                cursorNode.isHidden = true
                dwellRegion = .none
                firedRegion = .none
                pokeArmed   = false
                cursorLeft  = nil
            }
        } else {
            cursorNode.isHidden = true
        }

        // Border emission reflects grab state (CGColor — render-safe)
        let borderEmission: CGColor = grabSide != nil
            ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 0.95).cgColor
            : UIColor(red: 0.35, green: 0.15, blue: 0.70, alpha: 0.55).cgColor
        for n in borderNodes { n.geometry?.firstMaterial?.emission.contents = borderEmission }

        if dirty || needsRebake { needsRebake = false; dispatchBake() }
        return result
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
            color = UIColor(red: 0.10, green: 1.0, blue: 0.40, alpha: 1).cgColor
        } else if actionable {
            // White → green as the dwell ring fills
            scale = 1.0 + progress * 0.7
            color = CGColor(red: CGFloat(1.0 - progress * 0.9),
                            green: 1.0,
                            blue:  CGFloat(1.0 - progress * 0.6),
                            alpha: 1)
        } else {
            scale = 0.7
            color = UIColor(white: 1, alpha: 0.6).cgColor
        }
        cursorNode.scale = SCNVector3(scale, scale, scale)
        cursorMat.emission.contents = color
        cursorMat.diffuse.contents  = color
    }

    // MARK: - Region resolution / firing

    private func regionAt(localX: Float, localY: Float) -> Region {
        let u  = CGFloat((localX + Self.panW/2) / Self.panW)
        let v  = CGFloat(1.0 - (localY + Self.panH/2) / Self.panH)
        let px = u * Self.texW
        let py = v * Self.texH

        if py < Self.handleH { return .none }                 // handle = drag only
        if py >= Self.texH - Self.tabBarH {
            return .tab(px < Self.texW / 2)
        }
        switch activeTab {
        case .library:
            let startY = Self.handleH + Self.headerH
            let maxY   = Self.texH - Self.tabBarH
            let count  = 1 + availableSongs.count
            for i in 0..<count {
                let rowY = startY + CGFloat(i) * Self.songRowH
                guard rowY + Self.songRowH <= maxY else { break }
                if py >= rowY, py < rowY + Self.songRowH { return .song(i) }
            }
            return .none
        case .controls:
            let cx    = Self.texW / 2
            let topY  = Self.handleH + Self.headerH
            let contH = Self.texH - Self.tabBarH - topY
            let midY  = topY + contH / 2
            if CGRect(x: 28, y: topY + 12, width: 200, height: 44).contains(CGPoint(x: px, y: py)) { return .debug }
            if CGRect(x: cx - 150, y: midY - 50, width: 300, height: 88).contains(CGPoint(x: px, y: py)) { return .play }
            if CGRect(x: cx - 110, y: midY + 56, width: 220, height: 54).contains(CGPoint(x: px, y: py)) { return .restart }
            return .none
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
            let song: Song? = i == 0 ? nil : (i - 1 < availableSongs.count ? availableSongs[i - 1] : nil)
            return .loadAndPlay(song)
        case .play:    return .playStop
        case .restart: return .restart
        case .debug:   return .toggleDebug
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
                             grabbing: grabSide != nil)
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
    }

    private static func bake(_ s: PanelSnap) -> UIImage {
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { _ in
            UIColor(red: 0.06, green: 0.03, blue: 0.18, alpha: 0.97).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 24).fill()

            drawGrabHandle(s)
            drawTabBar(s)
            switch s.tab {
            case .library:  drawLibrary(s)
            case .controls: drawControls(s)
            }
        }
    }

    private static func drawGrabHandle(_ s: PanelSnap) {
        let bg: UIColor = s.grabbing
            ? UIColor(red: 0.18, green: 0.50, blue: 0.22, alpha: 0.95)
            : UIColor(red: 0.10, green: 0.05, blue: 0.26, alpha: 0.92)
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

        let title = s.grabbing ? "MOVING…" : "PIANO"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .black),
            .foregroundColor: UIColor(white: 1, alpha: s.grabbing ? 0.95 : 0.55),
            .kern: 3.0 as NSObject,
        ]
        let sz = title.size(withAttributes: attrs)
        title.draw(at: CGPoint(x: 22, y: (handleH - sz.height) / 2), withAttributes: attrs)

        UIColor(white: 1, alpha: 0.13).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: handleH - 1, width: texW, height: 1)).fill()
    }

    private static func drawTabBar(_ s: PanelSnap) {
        let y = texH - tabBarH
        let activeX: CGFloat = s.tab == .library ? 0 : texW / 2
        UIColor(red: 0.30, green: 0.12, blue: 0.62, alpha: 0.80).setFill()
        UIBezierPath(rect: CGRect(x: activeX, y: y, width: texW/2, height: tabBarH)).fill()

        UIColor(white: 1, alpha: 0.15).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: y, width: texW, height: 1)).fill()
        UIColor(white: 1, alpha: 0.10).setFill()
        UIBezierPath(rect: CGRect(x: texW/2 - 0.5, y: y + 12, width: 1, height: tabBarH - 24)).fill()

        let f = UIFont.systemFont(ofSize: 22, weight: .bold)
        centered("LIBRARY",  in: CGRect(x: 0,      y: y, width: texW/2, height: tabBarH),
                 font: f, color: s.tab == .library  ? .white : UIColor(white:1,alpha:0.38))
        centered("CONTROLS", in: CGRect(x: texW/2, y: y, width: texW/2, height: tabBarH),
                 font: f, color: s.tab == .controls ? .white : UIColor(white:1,alpha:0.38))
    }

    private static func drawLibrary(_ s: PanelSnap) {
        let topY = handleH
        centered("LIBRARY", in: CGRect(x: 0, y: topY, width: texW, height: headerH),
                 font: .systemFont(ofSize: 24, weight: .black),
                 color: UIColor(white: 1, alpha: 0.55))

        let startY = topY + headerH
        let maxY   = texH - tabBarH

        let entries: [(String, String)] = [("♪", "Right Hand Primer")] +
            s.songs.map { ("♪", $0.title ?? "Untitled") }

        let iconBg    = UIColor(red: 0.28, green: 0.12, blue: 0.58, alpha: 0.65)
        let titleFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let chevFont  = UIFont.systemFont(ofSize: 28, weight: .light)

        for (i, (icon, title)) in entries.enumerated() {
            let rowY = startY + CGFloat(i) * songRowH
            guard rowY + songRowH <= maxY else { break }

            if i % 2 == 0 {
                UIColor(white: 1, alpha: 0.04).setFill()
                UIBezierPath(rect: CGRect(x: 0, y: rowY, width: texW, height: songRowH)).fill()
            }
            UIColor(white: 1, alpha: 0.07).setFill()
            UIBezierPath(rect: CGRect(x: 24, y: rowY + songRowH - 1, width: texW - 48, height: 1)).fill()

            iconBg.setFill()
            let iconRect = CGRect(x: 20, y: rowY + (songRowH - 42) / 2, width: 42, height: 42)
            UIBezierPath(ovalIn: iconRect).fill()
            centered(icon, in: iconRect, font: .systemFont(ofSize: 20, weight: .bold), color: .white)

            let tAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white]
            let tSize  = title.size(withAttributes: tAttrs)
            title.draw(at: CGPoint(x: 74, y: rowY + (songRowH - tSize.height) / 2), withAttributes: tAttrs)

            centered("›", in: CGRect(x: texW - 40, y: rowY, width: 28, height: songRowH),
                     font: chevFont, color: UIColor(white: 1, alpha: 0.30))
        }
    }

    private static func drawControls(_ s: PanelSnap) {
        let topY  = handleH + headerH
        let contH = texH - tabBarH - topY
        let cx    = texW / 2
        let midY  = topY + contH / 2

        centered("CONTROLS", in: CGRect(x: 0, y: handleH, width: texW, height: headerH),
                 font: .systemFont(ofSize: 24, weight: .black),
                 color: UIColor(white: 1, alpha: 0.55))

        let dbgBg = s.debugOn
            ? UIColor(red: 0.10, green: 0.48, blue: 0.18, alpha: 0.85)
            : UIColor(white: 1, alpha: 0.09)
        dbgBg.setFill()
        let dbgRect = CGRect(x: 28, y: topY + 12, width: 200, height: 44)
        UIBezierPath(roundedRect: dbgRect, cornerRadius: 11).fill()
        centered(s.debugOn ? "⚙  DEBUG ON" : "⚙  DEBUG",
                 in: dbgRect,
                 font: .systemFont(ofSize: 18, weight: .semibold),
                 color: s.debugOn ? UIColor(red: 0.55, green: 1.00, blue: 0.65, alpha: 1)
                                  : UIColor(white: 1, alpha: 0.55))

        centered(s.isPlaying ? "● PLAYING" : "— READY —",
                 in: CGRect(x: 0, y: topY + 72, width: texW, height: 40),
                 font: .systemFont(ofSize: 22, weight: .black),
                 color: s.isPlaying
                    ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 1)
                    : UIColor(white: 1, alpha: 0.40))

        let playBg: UIColor = s.isPlaying
            ? UIColor(red: 0.80, green: 0.10, blue: 0.10, alpha: 0.94)
            : UIColor(red: 0.13, green: 0.46, blue: 0.96, alpha: 0.94)
        playBg.setFill()
        let playRect = CGRect(x: cx - 150, y: midY - 50, width: 300, height: 88)
        UIBezierPath(roundedRect: playRect, cornerRadius: 22).fill()
        UIColor(white: 1, alpha: 0.22).setStroke()
        let pb = UIBezierPath(roundedRect: playRect.insetBy(dx: 1, dy: 1), cornerRadius: 22)
        pb.lineWidth = 1.5
        pb.stroke()
        centered(s.isPlaying ? "■   STOP" : "▶   PLAY",
                 in: playRect, font: .systemFont(ofSize: 38, weight: .black), color: .white)

        UIColor(white: 1, alpha: 0.11).setFill()
        let rstRect = CGRect(x: cx - 110, y: midY + 56, width: 220, height: 54)
        UIBezierPath(roundedRect: rstRect, cornerRadius: 14).fill()
        centered("↺   RESTART", in: rstRect,
                 font: .systemFont(ofSize: 22, weight: .bold),
                 color: UIColor(white: 1, alpha: 0.78))
    }

    private static func centered(_ text: String, in rect: CGRect,
                                  font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        let x  = rect.minX + (rect.width  - sz.width)  / 2
        let y  = rect.minY + (rect.height - sz.height) / 2
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }
}

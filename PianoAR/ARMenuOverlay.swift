import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, loadAndPlay(Song?), toggleDebug }

/// Large floating "tablet" AR panel — PianoVision / Quest-3 style.
///
/// Two interactions:
///   1. **Touch** — index fingertip approaches panel face, UV hit-tests a
///      CGRect region (buttons, song rows, tabs). Skipped while pinching.
///   2. **Grab** — pinch (thumb + index) within the top handle strip starts
///      a drag; panel position follows the pinch midpoint with EMA smoothing;
///      release pinch to drop. Panel stays where you put it.
///
/// All UIKit drawing is strictly main-thread via DispatchQueue.main.async.
/// The render thread only swaps `UIImage` refs (thread-safe per SCNMaterial).
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Panel geometry ──────────────────────────────────────────────────────
    private static let panW: Float = 0.48
    private static let panH: Float = 0.30

    // Texture resolution (2000 px/m keeps text sharp)
    private static let texW: CGFloat = 960
    private static let texH: CGFloat = 600

    // UI zone heights (texture pixels)
    private static let handleH:  CGFloat = 56
    private static let tabBarH:  CGFloat = 70
    private static let headerH:  CGFloat = 54
    private static let songRowH: CGFloat = 70

    // ── Default placement (right of keyboard centre, lifted, tilted) ────────
    private static let initPos = SIMD3<Float>(KeyboardLayout.totalWidth * 0.30,
                                              0.30,
                                              0.18)
    private static let initRotX: Float = -Float.pi * 0.28
    private static let initRotY: Float = -Float.pi * 0.13

    // ── Touch / grab thresholds ─────────────────────────────────────────────
    private static let triggerZ:    Float       = 0.024
    private static let debounce:    TimeInterval = 0.28
    private static let grabPinchOn:  Float       = 0.030
    private static let grabPinchOff: Float       = 0.055
    private static let grabHandleM:  Float       = 0.050   // top 50 mm = handle in panel-local
    private static let dragSmooth:   Float       = 0.55    // EMA: 0 = no smooth, 1 = no motion

    // ── Tabs ────────────────────────────────────────────────────────────────
    private enum Tab { case library, controls }

    // ── State (render thread) ───────────────────────────────────────────────
    private var activeTab:      Tab     = .library
    private var availableSongs: [Song]  = []
    private var isPlaying              = false
    private var debugOn                = false
    private var needsRebake            = true
    private var lastTap: TimeInterval  = -999

    // Grab
    private var grabSide:    Bool?         = nil   // nil=not grabbed, true=left grabbing
    private var grabOffset:  SIMD3<Float>  = .zero // panelPos - pinchLocal at grab start
    private var grabTarget:  SIMD3<Float>  = .zero // EMA-smoothed target

    // ── Scene nodes ─────────────────────────────────────────────────────────
    private var panelNode: SCNNode!
    private var panelMat:  SCNMaterial!
    private var borderNodes: [SCNNode] = []

    init() { build() }

    // MARK: - Build  (main thread, init time)

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

        // ── Pinch info per hand ──────────────────────────────────────────────
        struct Pinch { let isLeft: Bool; let mid: SIMD3<Float>; let dist: Float }
        var pinches: [Pinch] = []
        for hand in hands {
            guard let t = hand.joints[.thumbTip],
                  let i = hand.joints[.indexTip] else { continue }
            pinches.append(Pinch(isLeft: hand.isLeft, mid: (t + i) * 0.5,
                                  dist: simd_length(t - i)))
        }

        // ── Grab handling ────────────────────────────────────────────────────
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
                // Pinch midpoint must be inside the top handle strip of the panel face
                let panelLocal = panelNode.simdConvertPosition(p.mid, from: nil)
                let inHandle = abs(panelLocal.z) < 0.07
                            && abs(panelLocal.x) < Self.panW / 2 + 0.02
                            && panelLocal.y >  Self.panH / 2 - Self.grabHandleM
                            && panelLocal.y <  Self.panH / 2 + 0.025
                if inHandle, let parent = panelNode.parent {
                    let pinchLocal = parent.simdConvertPosition(p.mid, from: nil)
                    grabSide       = p.isLeft
                    grabOffset     = panelNode.simdPosition - pinchLocal
                    grabTarget     = panelNode.simdPosition
                    break
                }
            }
        }
        if (prevGrab == nil) != (grabSide == nil) { dirty = true }

        // ── Touch (skipped for any hand currently pinching) ──────────────────
        let pinchingSides = Set(pinches.filter { $0.dist < Self.grabPinchOff }.map { $0.isLeft })
        var result: MenuAction? = nil
        if grabSide == nil {
            for hand in hands {
                if pinchingSides.contains(hand.isLeft) { continue }
                guard let idxWorld = hand.joints[.indexTip] else { continue }

                let local = panelNode.simdConvertPosition(idxWorld, from: nil)
                guard local.z > -0.005, local.z < Self.triggerZ else { continue }
                guard abs(local.x) < Self.panW / 2,
                      abs(local.y) < Self.panH / 2 else { continue }

                let u = CGFloat((local.x + Self.panW / 2) / Self.panW)
                let v = CGFloat(1.0 - (local.y + Self.panH / 2) / Self.panH)

                let (action, tabChanged) = performHitTest(u: u, v: v)
                if tabChanged { dirty = true }

                if let action, time - lastTap > Self.debounce {
                    if case .loadAndPlay = action {
                        activeTab = .controls
                        dirty = true
                    }
                    lastTap = time
                    result  = action
                    break
                }
            }
        }

        // Update border emission to reflect grab state — cheap, render-safe (CGColor)
        let borderEmission: CGColor = grabSide != nil
            ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 0.95).cgColor   // green = grabbed
            : UIColor(red: 0.35, green: 0.15, blue: 0.70, alpha: 0.55).cgColor
        for n in borderNodes {
            n.geometry?.firstMaterial?.emission.contents = borderEmission
        }

        if dirty || needsRebake {
            needsRebake = false
            dispatchBake()
        }
        return result
    }

    // MARK: - Hit testing

    private func performHitTest(u: CGFloat, v: CGFloat) -> (MenuAction?, Bool) {
        let px = u * Self.texW
        let py = v * Self.texH

        // Reserve top handle as drag-only — no touch actions
        if py < Self.handleH { return (nil, false) }

        // Bottom tab bar
        if py >= Self.texH - Self.tabBarH {
            let wanted: Tab = px < Self.texW / 2 ? .library : .controls
            if activeTab != wanted { activeTab = wanted; return (nil, true) }
            return (nil, false)
        }

        switch activeTab {
        case .library:  return (libraryHit(px: px, py: py), false)
        case .controls: return (controlsHit(px: px, py: py), false)
        }
    }

    private func libraryHit(px: CGFloat, py: CGFloat) -> MenuAction? {
        let startY = Self.handleH + Self.headerH
        let maxY   = Self.texH - Self.tabBarH
        let count  = 1 + availableSongs.count
        for i in 0..<count {
            let rowY = startY + CGFloat(i) * Self.songRowH
            guard rowY + Self.songRowH <= maxY else { break }
            if py >= rowY, py < rowY + Self.songRowH {
                let song: Song? = i == 0 ? nil : availableSongs[i - 1]
                return .loadAndPlay(song)
            }
        }
        return nil
    }

    private func controlsHit(px: CGFloat, py: CGFloat) -> MenuAction? {
        let cx    = Self.texW / 2
        let topY  = Self.handleH + Self.headerH
        let contH = Self.texH - Self.tabBarH - topY
        let midY  = topY + contH / 2

        let dbg = CGRect(x: 28, y: topY + 12, width: 200, height: 44)
        if dbg.contains(CGPoint(x: px, y: py)) { return .toggleDebug }

        let play = CGRect(x: cx - 150, y: midY - 50, width: 300, height: 88)
        if play.contains(CGPoint(x: px, y: py)) { return .playStop }

        let rst = CGRect(x: cx - 110, y: midY + 56, width: 220, height: 54)
        if rst.contains(CGPoint(x: px, y: py)) { return .restart }

        return nil
    }

    // MARK: - Proximity query (for Hand3DOverlay cursor colour)

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

    // MARK: - Texture baking  (main thread only)

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
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz),
                         cornerRadius: 24).fill()

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

        // Three grip dots in the centre — the canonical "drag me" affordance
        let dotColor: UIColor = s.grabbing
            ? UIColor(white: 1, alpha: 0.95)
            : UIColor(white: 1, alpha: 0.55)
        dotColor.setFill()
        let cy: CGFloat = handleH / 2
        let r:  CGFloat = 4.5
        for dx in [-22, 0, 22] {
            let x = texW / 2 + CGFloat(dx)
            UIBezierPath(ovalIn: CGRect(x: x - r, y: cy - r, width: r*2, height: r*2)).fill()
        }

        // Label on left
        let title = s.grabbing ? "MOVING…" : "PIANO"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .black),
            .foregroundColor: UIColor(white: 1, alpha: s.grabbing ? 0.95 : 0.55),
            .kern: 3.0 as NSObject,
        ]
        let sz = title.size(withAttributes: attrs)
        title.draw(at: CGPoint(x: 22, y: (handleH - sz.height) / 2), withAttributes: attrs)

        // Bottom hairline
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

            let tAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont, .foregroundColor: UIColor.white]
            let tSize  = title.size(withAttributes: tAttrs)
            title.draw(at: CGPoint(x: 74, y: rowY + (songRowH - tSize.height) / 2),
                       withAttributes: tAttrs)

            centered("›", in: CGRect(x: texW - 40, y: rowY, width: 28, height: songRowH),
                     font: chevFont, color: UIColor(white: 1, alpha: 0.30))
        }
    }

    private static func drawControls(_ s: PanelSnap) {
        let topY  = handleH + headerH
        let contH = texH - tabBarH - topY
        let cx    = texW / 2
        let midY  = topY + contH / 2

        // Section header
        centered("CONTROLS", in: CGRect(x: 0, y: handleH, width: texW, height: headerH),
                 font: .systemFont(ofSize: 24, weight: .black),
                 color: UIColor(white: 1, alpha: 0.55))

        // Debug button (top-left)
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

        // Status label
        centered(s.isPlaying ? "● PLAYING" : "— READY —",
                 in: CGRect(x: 0, y: topY + 72, width: texW, height: 40),
                 font: .systemFont(ofSize: 22, weight: .black),
                 color: s.isPlaying
                    ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 1)
                    : UIColor(white: 1, alpha: 0.40))

        // Play / Stop button
        let playBg: UIColor = s.isPlaying
            ? UIColor(red: 0.80, green: 0.10, blue: 0.10, alpha: 0.94)
            : UIColor(red: 0.13, green: 0.46, blue: 0.96, alpha: 0.94)
        playBg.setFill()
        let playRect = CGRect(x: cx - 150, y: midY - 50, width: 300, height: 88)
        UIBezierPath(roundedRect: playRect, cornerRadius: 22).fill()
        UIColor(white: 1, alpha: 0.22).setStroke()
        let border = UIBezierPath(roundedRect: playRect.insetBy(dx: 1, dy: 1),
                                  cornerRadius: 22)
        border.lineWidth = 1.5
        border.stroke()
        centered(s.isPlaying ? "■   STOP" : "▶   PLAY",
                 in: playRect,
                 font: .systemFont(ofSize: 38, weight: .black),
                 color: .white)

        // Restart button
        UIColor(white: 1, alpha: 0.11).setFill()
        let rstRect = CGRect(x: cx - 110, y: midY + 56, width: 220, height: 54)
        UIBezierPath(roundedRect: rstRect, cornerRadius: 14).fill()
        centered("↺   RESTART", in: rstRect,
                 font: .systemFont(ofSize: 22, weight: .bold),
                 color: UIColor(white: 1, alpha: 0.78))
    }

    private static func centered(_ text: String, in rect: CGRect,
                                  font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        let x  = rect.minX + (rect.width  - sz.width)  / 2
        let y  = rect.minY + (rect.height - sz.height) / 2
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }
}

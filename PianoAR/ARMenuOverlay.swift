import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, loadAndPlay(Song?), toggleDebug }

/// Large floating "tablet" AR panel — PianoVision-style.
///
/// Architecture:
///  • One SCNPlane in keyboard-local space, tilted to face the camera looking down.
///  • A UIImage is baked on the main thread whenever visible state changes, then
///    set as diffuse.contents (thread-safe from any thread).
///  • Touch: convert fingertip world pos → panel-local XYZ, check Z proximity,
///    then UV hit-test static CGRect regions. No velocity gate — just debounce.
///  • All UIKit drawing is strictly in static `bake*` methods called only via
///    DispatchQueue.main.async — never on the SceneKit render thread.
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Panel geometry ──────────────────────────────────────────────────────
    private static let panW: Float  = 0.52    // metres
    private static let panH: Float  = 0.32

    // Texture resolution — 2000 px/m keeps text sharp without wasting memory
    private static let texW: CGFloat = 1040
    private static let texH: CGFloat = 640

    // UI zone heights (in texture pixels)
    private static let tabBarH:  CGFloat = 72
    private static let headerH:  CGFloat = 60
    private static let songRowH: CGFloat = 72

    // Touch threshold: fingertip within this many metres of panel surface → hit
    private static let triggerZ: Float    = 0.022   // 22 mm
    private static let debounce: TimeInterval = 0.30

    // ── State (mutated only on render thread) ───────────────────────────────
    private enum Tab { case library, controls }
    private var activeTab:      Tab      = .library
    private var availableSongs: [Song]   = []
    private var isPlaying               = false
    private var debugOn                 = false
    private var needsRebake             = true
    private var lastTap: TimeInterval   = -999

    // ── Scene nodes ─────────────────────────────────────────────────────────
    private var panelNode: SCNNode!
    private var panelMat:  SCNMaterial!

    init() { build() }

    // MARK: - Build  (runs on main thread at init time)

    private func build() {
        let geo = SCNPlane(width: CGFloat(Self.panW), height: CGFloat(Self.panH))
        panelMat = SCNMaterial()
        panelMat.lightingModel        = .constant
        panelMat.diffuse.contents     = UIColor(red: 0.06, green: 0.03, blue: 0.18, alpha: 0.97)
        panelMat.blendMode            = .alpha
        panelMat.isDoubleSided        = true
        panelMat.writesToDepthBuffer  = false
        panelMat.readsFromDepthBuffer = false
        geo.materials = [panelMat]

        panelNode = SCNNode(geometry: geo)
        // Position: centred over keyboard, above surface and toward player.
        // Tilt ~54° so the face is roughly toward a camera looking 45-60° down.
        panelNode.simdPosition = SIMD3<Float>(0, 0.30, 0.18)
        panelNode.eulerAngles  = SCNVector3(-Float.pi * 0.30, 0, 0)
        panelNode.renderingOrder = 200
        rootNode.addChildNode(panelNode)

        // Thin glowing border frame
        addBorder()

        // Kick off first bake
        dispatchBake()
    }

    private func addBorder() {
        // Four edge bars as thin SCNBox nodes
        let edgeColor = UIColor(red: 0.45, green: 0.22, blue: 0.85, alpha: 0.70)
        let t: Float = 0.003   // thickness

        struct Edge { var w: Float; var h: Float; var x: Float; var y: Float }
        let edges: [Edge] = [
            Edge(w: Self.panW + t*2, h: t, x: 0, y:  Self.panH/2),   // top
            Edge(w: Self.panW + t*2, h: t, x: 0, y: -Self.panH/2),   // bottom
            Edge(w: t, h: Self.panH, x: -Self.panW/2, y: 0),          // left
            Edge(w: t, h: Self.panH, x:  Self.panW/2, y: 0),          // right
        ]
        let mat = SCNMaterial()
        mat.lightingModel       = .constant
        mat.diffuse.contents    = edgeColor
        mat.emission.contents   = UIColor(red: 0.35, green: 0.15, blue: 0.70, alpha: 0.55)
        mat.writesToDepthBuffer = false

        for e in edges {
            let box = SCNBox(width: CGFloat(e.w), height: CGFloat(e.h), length: 0.001, chamferRadius: 0)
            box.materials = [mat]
            let n = SCNNode(geometry: box)
            n.simdPosition   = SIMD3<Float>(e.x, e.y, 0.0005)
            n.renderingOrder = 201
            panelNode.addChildNode(n)
        }
    }

    // MARK: - Per-frame update  (SceneKit render thread)

    func update(hands:          [HandTracker.HandResult],
                keyboardNode:   SCNNode,
                time:           TimeInterval,
                isPlaying:      Bool,
                debugOn:        Bool = false,
                availableSongs: [Song] = []) -> MenuAction? {

        // State change detection
        var dirty = false
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying; dirty = true }
        if self.debugOn   != debugOn   { self.debugOn   = debugOn;   dirty = true }

        let newTitles = availableSongs.map { $0.title ?? "" }
        let oldTitles = self.availableSongs.map { $0.title ?? "" }
        if newTitles != oldTitles { self.availableSongs = availableSongs; dirty = true }

        // Touch detection
        var result: MenuAction? = nil
        for hand in hands {
            guard let idxWorld = hand.joints[.indexTip] else { continue }

            // Panel-local coordinates: XY on panel face, Z = depth from face (+Z = in front)
            let local = panelNode.simdConvertPosition(idxWorld, from: nil)

            // Accept only the front side within trigger distance
            guard local.z > -0.005, local.z < Self.triggerZ else { continue }
            guard abs(local.x) < Self.panW / 2,
                  abs(local.y) < Self.panH / 2 else { continue }

            // UV: u left→right, v top→bottom (UIKit convention)
            let u = CGFloat((local.x + Self.panW / 2) / Self.panW)
            let v = CGFloat(1.0 - (local.y + Self.panH / 2) / Self.panH)

            let (action, tabChanged) = performHitTest(u: u, v: v)
            if tabChanged { dirty = true }

            if let action, time - lastTap > Self.debounce {
                if case .loadAndPlay = action {
                    activeTab = .controls  // auto-navigate to controls after song pick
                    dirty = true
                }
                lastTap = time
                result  = action
                break
            }
        }

        // Rebake texture if state changed (dispatch to main thread)
        if dirty || needsRebake {
            needsRebake = false
            dispatchBake()
        }

        return result
    }

    // MARK: - Hit testing  (render thread, pure math)

    private func performHitTest(u: CGFloat, v: CGFloat) -> (MenuAction?, Bool) {
        let px = u * Self.texW
        let py = v * Self.texH

        // Tab bar (bottom region)
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
        let startY = Self.headerH
        let maxY   = Self.texH - Self.tabBarH
        // Row 0 = built-in, rows 1..n = imported songs
        let allCount = 1 + availableSongs.count

        for i in 0..<allCount {
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
        let centerX = Self.texW / 2
        let topY    = Self.headerH
        let contH   = Self.texH - Self.tabBarH - topY
        let midY    = topY + contH / 2

        // Debug button (top-left)
        let dbgRect = CGRect(x: 32, y: topY + 14, width: 220, height: 46)
        if dbgRect.contains(CGPoint(x: px, y: py)) { return .toggleDebug }

        // Play/Stop (large, centred)
        let playRect = CGRect(x: centerX - 160, y: midY - 52, width: 320, height: 88)
        if playRect.contains(CGPoint(x: px, y: py)) { return .playStop }

        // Restart (below play)
        let rstRect = CGRect(x: centerX - 120, y: midY + 52, width: 240, height: 56)
        if rstRect.contains(CGPoint(x: px, y: py)) { return .restart }

        return nil
    }

    // MARK: - Proximity query for Hand3DOverlay cursor  (render thread)

    func maxProximity(worldPos: SIMD3<Float>, keyboardNode: SCNNode) -> Float {
        let local = panelNode.simdConvertPosition(worldPos, from: nil)
        let halfW = Self.panW / 2
        let halfH = Self.panH / 2
        let zProx  = simd_clamp(1.0 - abs(local.z) / 0.12, 0, 1)
        let xFade  = simd_clamp(1.0 - max(0, abs(local.x) - halfW) / 0.05, 0, 1)
        let yFade  = simd_clamp(1.0 - max(0, abs(local.y) - halfH) / 0.05, 0, 1)
        return zProx * xFade * yFade
    }

    // MARK: - Texture dispatch  (may be called from render thread)

    private func dispatchBake() {
        let snap = PanelSnap(tab: activeTab, songs: availableSongs,
                             isPlaying: isPlaying, debugOn: debugOn)
        let mat  = panelMat!
        DispatchQueue.main.async {
            mat.diffuse.contents = ARMenuOverlay.bake(snap)
        }
    }

    // MARK: - Texture baking  (main thread only — UIKit)

    private struct PanelSnap {
        let tab:      Tab
        let songs:    [Song]
        let isPlaying: Bool
        let debugOn:   Bool
    }

    private static func bake(_ s: PanelSnap) -> UIImage {
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { _ in
            // Background
            UIColor(red: 0.06, green: 0.03, blue: 0.18, alpha: 0.97).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 24).fill()

            drawTabBar(s)
            switch s.tab {
            case .library:  drawLibrary(s)
            case .controls: drawControls(s)
            }
        }
    }

    // ── Tab bar ──────────────────────────────────────────────────────────────

    private static func drawTabBar(_ s: PanelSnap) {
        let y = texH - tabBarH

        // Active tab highlight
        let activeX: CGFloat = s.tab == .library ? 0 : texW / 2
        UIColor(red: 0.30, green: 0.12, blue: 0.62, alpha: 0.80).setFill()
        UIBezierPath(roundedRect: CGRect(x: activeX, y: y, width: texW/2, height: tabBarH),
                     cornerRadius: 0).fill()

        // Top border
        UIColor(white: 1, alpha: 0.15).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: y, width: texW, height: 1)).fill()

        // Centre divider
        UIColor(white: 1, alpha: 0.10).setFill()
        UIBezierPath(rect: CGRect(x: texW/2 - 0.5, y: y + 12, width: 1, height: tabBarH - 24)).fill()

        let font = UIFont.systemFont(ofSize: 22, weight: .bold)
        centered("LIBRARY",  in: CGRect(x: 0,       y: y, width: texW/2, height: tabBarH),
                 font: font, color: s.tab == .library  ? .white : UIColor(white:1,alpha:0.38))
        centered("CONTROLS", in: CGRect(x: texW/2,  y: y, width: texW/2, height: tabBarH),
                 font: font, color: s.tab == .controls ? .white : UIColor(white:1,alpha:0.38))
    }

    // ── Library view ─────────────────────────────────────────────────────────

    private static func drawLibrary(_ s: PanelSnap) {
        // Header
        centered("LIBRARY", in: CGRect(x: 0, y: 0, width: texW, height: headerH),
                 font: .systemFont(ofSize: 26, weight: .black),
                 color: UIColor(white: 1, alpha: 0.55))

        let startY = headerH
        let maxY   = texH - tabBarH

        let entries: [(String, String)] = [("♪", "Right Hand Primer")] +
            s.songs.map { ("♪", $0.title ?? "Untitled") }

        let iconBg    = UIColor(red: 0.28, green: 0.12, blue: 0.58, alpha: 0.65)
        let titleFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let chevFont  = UIFont.systemFont(ofSize: 28, weight: .light)

        for (i, (icon, title)) in entries.enumerated() {
            let rowY = startY + CGFloat(i) * songRowH
            guard rowY + songRowH <= maxY else { break }

            // Alternating row tint
            if i % 2 == 0 {
                UIColor(white: 1, alpha: 0.04).setFill()
                UIBezierPath(rect: CGRect(x: 0, y: rowY, width: texW, height: songRowH)).fill()
            }

            // Row separator
            UIColor(white: 1, alpha: 0.07).setFill()
            UIBezierPath(rect: CGRect(x: 24, y: rowY + songRowH - 1, width: texW - 48, height: 1)).fill()

            // Icon circle
            iconBg.setFill()
            let iconRect = CGRect(x: 20, y: rowY + (songRowH - 42) / 2, width: 42, height: 42)
            UIBezierPath(ovalIn: iconRect).fill()
            centered(icon, in: iconRect, font: .systemFont(ofSize: 20, weight: .bold), color: .white)

            // Title
            let tAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white]
            let tSize  = title.size(withAttributes: tAttrs)
            title.draw(at: CGPoint(x: 74, y: rowY + (songRowH - tSize.height) / 2),
                       withAttributes: tAttrs)

            // Chevron
            centered("›", in: CGRect(x: texW - 40, y: rowY, width: 28, height: songRowH),
                     font: chevFont, color: UIColor(white: 1, alpha: 0.30))
        }
    }

    // ── Controls view ─────────────────────────────────────────────────────────

    private static func drawControls(_ s: PanelSnap) {
        let topY   = headerH
        let contH  = texH - tabBarH - topY
        let centX  = texW / 2
        let midY   = topY + contH / 2

        // ── Debug button (top-left) ──────────────────────────────────────────
        let dbgBg = s.debugOn
            ? UIColor(red: 0.10, green: 0.48, blue: 0.18, alpha: 0.85)
            : UIColor(white: 1, alpha: 0.09)
        dbgBg.setFill()
        let dbgRect = CGRect(x: 32, y: topY + 14, width: 220, height: 46)
        UIBezierPath(roundedRect: dbgRect, cornerRadius: 11).fill()
        centered(s.debugOn ? "⚙  DEBUG ON" : "⚙  DEBUG",
                 in: dbgRect,
                 font: .systemFont(ofSize: 19, weight: .semibold),
                 color: s.debugOn ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 1) : UIColor(white:1,alpha:0.55))

        // ── Status label ────────────────────────────────────────────────────
        let statusColor: UIColor = s.isPlaying
            ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 1)
            : UIColor(white: 1, alpha: 0.40)
        centered(s.isPlaying ? "● PLAYING" : "— READY —",
                 in: CGRect(x: 0, y: topY + 76, width: texW, height: 48),
                 font: .systemFont(ofSize: 24, weight: .black),
                 color: statusColor)

        // ── Play / Stop button ───────────────────────────────────────────────
        let playBg: UIColor = s.isPlaying
            ? UIColor(red: 0.78, green: 0.08, blue: 0.08, alpha: 0.92)
            : UIColor(red: 0.12, green: 0.44, blue: 0.96, alpha: 0.92)
        playBg.setFill()
        let playRect = CGRect(x: centX - 160, y: midY - 52, width: 320, height: 88)
        UIBezierPath(roundedRect: playRect, cornerRadius: 22).fill()
        // Subtle border
        UIColor(white: 1, alpha: 0.20).setStroke()
        let playBorder = UIBezierPath(roundedRect: playRect.insetBy(dx: 1, dy: 1), cornerRadius: 22)
        playBorder.lineWidth = 1.5
        playBorder.stroke()
        centered(s.isPlaying ? "■   STOP" : "▶   PLAY",
                 in: playRect,
                 font: .systemFont(ofSize: 38, weight: .black),
                 color: .white)

        // ── Restart button ───────────────────────────────────────────────────
        UIColor(white: 1, alpha: 0.11).setFill()
        let rstRect = CGRect(x: centX - 120, y: midY + 52, width: 240, height: 56)
        UIBezierPath(roundedRect: rstRect, cornerRadius: 14).fill()
        centered("↺   RESTART", in: rstRect,
                 font: .systemFont(ofSize: 24, weight: .bold),
                 color: UIColor(white: 1, alpha: 0.75))
    }

    // ── Shared text helper ────────────────────────────────────────────────────

    private static func centered(_ text: String, in rect: CGRect,
                                  font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        let x  = rect.minX + (rect.width  - sz.width)  / 2
        let y  = rect.minY + (rect.height - sz.height) / 2
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }
}

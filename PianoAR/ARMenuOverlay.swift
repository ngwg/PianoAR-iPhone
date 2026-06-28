import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, prevSong, nextSong, toggleDebug }

/// Direct-touch AR control panel.
///
/// Interaction model: a 3-D SDF (signed-distance function) is evaluated from
/// each tracked fingertip to each button's bounding volume every frame.
/// No pinch required — the user just reaches out and presses the button.
///
/// Proximity → continuous CGColor emission glow (thread-safe on render thread).
/// UIKit drawing (UIGraphicsImageRenderer) is strictly confined to init().
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Layout ──────────────────────────────────────────────────────────────
    private static let btnW:  Float   = 0.135   // 135 mm wide
    private static let btnH:  Float   = 0.062   // 62 mm tall
    private static let btnD:  Float   = 0.010   // 10 mm depth
    private static let gap:   Float   = 0.082   // 82 mm centre-to-centre (vertical)

    // Touch zone: extend btnD in front to create a generous approach zone.
    // The SDF checks this extended box so the trigger fires as the finger
    // gets close rather than requiring a literal physical intersection.
    private static let touchHalfZ: Float = 0.032  // 32 mm in front of button

    // Thresholds
    private static let triggerDist: Float       = 0.016  // 16 mm → confirmed press
    private static let hoverDist:   Float       = 0.085  // 85 mm → glow starts
    private static let debounce:    TimeInterval = 0.22  // 220 ms between taps

    // Texture resolution
    private static let texW: CGFloat = 540
    private static let texH: CGFloat = 204

    // ── CGColor constants (thread-safe; used only from render thread) ──────
    private static let cgBlack  = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let cgHoverR: CGFloat = 0.12
    private static let cgHoverG: CGFloat = 0.38
    private static let cgHoverB: CGFloat = 1.00
    private static let cgFlashR: CGFloat = 0.04
    private static let cgFlashG: CGFloat = 0.95
    private static let cgFlashB: CGFloat = 0.38

    // ── Per-button state ─────────────────────────────────────────────────────
    private struct Button {
        let node:        SCNNode
        let action:      MenuAction
        let localPos:    SIMD3<Float>
        let halfNormal:  SIMD3<Float>   // half-extents for SDF (no Z extend)
        let halfTouch:   SIMD3<Float>   // half-extents for SDF (extended Z)
        var glowLevel:   Float = 0      // 0..1 updated every frame
        var isActive:    Bool  = false
        // Pre-baked textures (UIKit, main thread only)
        let texNormal:   UIImage
        let texActive:   UIImage        // "■ STOP" / "⚙ DEBUG ON" variant
    }

    private var buttons:       [Button]           = []
    private var isPlaying      = false
    private var debugOn        = false
    // Debounce per hand side
    private var lastTap:       [Bool: TimeInterval] = [false: -999, true: -999]
    // Velocity history: key = "L_idx" / "R_idx" etc.
    private var velHist:       [String: [(SIMD3<Float>, TimeInterval)]] = [:]

    init() { build() }

    // MARK: - Build  (runs on main thread at anchor creation time)

    private func build() {
        let colX: Float    = KeyboardLayout.totalWidth * 0.5 + 0.082
        let colZ: Float    = KeyboardLayout.whiteKeyDepth * 0.5 + 0.058
        let colYTop: Float = 0.218   // top button Y in keyboard-local space
        // Centre of 5-button column:  colYTop - 2 * gap
        let colYCtr: Float = colYTop - Self.gap * 2

        let hN = SIMD3<Float>(Self.btnW/2, Self.btnH/2, Self.btnD/2)
        let hT = SIMD3<Float>(Self.btnW/2, Self.btnH/2, Self.btnD/2 + Self.touchHalfZ)

        // ── Background panel ──────────────────────────────────────────────
        let panH = CGFloat(Self.gap * 4 + Self.btnH + 0.050)
        let panGeo = SCNBox(width:  CGFloat(Self.btnW + 0.024),
                            height: panH,
                            length: CGFloat(Self.btnD * 0.55),
                            chamferRadius: 0.014)
        panGeo.materials = [panMaterial(UIColor(red: 0.02, green: 0.02, blue: 0.09, alpha: 0.94))]
        let panNode = SCNNode(geometry: panGeo)
        panNode.simdPosition   = SIMD3<Float>(colX, colYCtr, colZ - Self.btnD * 0.22)
        panNode.renderingOrder = 195
        rootNode.addChildNode(panNode)

        // ── Top / bottom accent lines ─────────────────────────────────────
        for sign: Float in [-1, 1] {
            let lineGeo = SCNBox(width:  CGFloat(Self.btnW + 0.024),
                                 height: 0.0018,
                                 length: 0.003,
                                 chamferRadius: 0)
            lineGeo.materials = [accentLineMaterial()]
            let lNode = SCNNode(geometry: lineGeo)
            lNode.simdPosition   = SIMD3<Float>(colX, Float(panNode.simdPosition.y) + sign * Float(panH * 0.5), colZ)
            lNode.renderingOrder = 197
            rootNode.addChildNode(lNode)
        }

        // ── Header label ──────────────────────────────────────────────────
        let hdr = headerLabelNode(text: "CONTROLS")
        hdr.simdPosition   = SIMD3<Float>(colX, colYTop + Self.gap * 0.46, colZ)
        hdr.renderingOrder = 198
        rootNode.addChildNode(hdr)

        // ── Buttons ───────────────────────────────────────────────────────
        let specs: [(label: String, active: String, action: MenuAction)] = [
            ("▶  PLAY",    "■  STOP",      .playStop),
            ("↺  RESTART", "↺  RESTART",   .restart),
            ("◀  PREV",    "◀  PREV",      .prevSong),
            ("▶▶ NEXT",   "▶▶ NEXT",     .nextSong),
            ("⚙  DEBUG",  "⚙  DEBUG ON", .toggleDebug),
        ]

        for (i, spec) in specs.enumerated() {
            let yPos     = colYTop - Float(i) * Self.gap
            let localPos = SIMD3<Float>(colX, yPos, colZ)

            let texNormal = makeButtonTexture(label: spec.label,   isActive: false)
            let texActive = makeButtonTexture(label: spec.active,  isActive: true)

            let mat = SCNMaterial()
            mat.lightingModel        = .constant
            mat.diffuse.contents     = texNormal
            mat.emission.contents    = Self.cgBlack
            mat.blendMode            = .alpha
            mat.writesToDepthBuffer  = false
            mat.readsFromDepthBuffer = false

            let box = SCNBox(width:         CGFloat(Self.btnW),
                             height:        CGFloat(Self.btnH),
                             length:        CGFloat(Self.btnD),
                             chamferRadius: 0.008)
            box.materials = [mat]     // one shared material — all faces

            let node = SCNNode(geometry: box)
            node.simdPosition   = localPos
            node.renderingOrder = 200
            rootNode.addChildNode(node)

            buttons.append(Button(
                node: node, action: spec.action, localPos: localPos,
                halfNormal: hN, halfTouch: hT,
                texNormal: texNormal, texActive: texActive
            ))
        }
    }

    // MARK: - Per-frame update  (called on SceneKit render thread)

    /// Returns a triggered action if a fingertip presses a button this frame.
    func update(hands:        [HandTracker.HandResult],
                keyboardNode: SCNNode,
                time:         TimeInterval,
                isPlaying:    Bool,
                debugOn:      Bool = false) -> MenuAction? {

        if self.isPlaying != isPlaying { self.isPlaying = isPlaying; syncPlayButton()  }
        if self.debugOn   != debugOn   { self.debugOn   = debugOn;   syncDebugButton() }

        // Build local-space fingertip list (index tips preferred, also thumb)
        struct Tip { let local: SIMD3<Float>; let isLeft: Bool; let key: String }
        var tips: [Tip] = []
        for hand in hands {
            let side = hand.isLeft ? "L" : "R"
            if let p = hand.joints[.indexTip] {
                tips.append(Tip(local: keyboardNode.simdConvertPosition(p, from: nil),
                                isLeft: hand.isLeft, key: "\(side)_i"))
            }
            if let p = hand.joints[.thumbTip] {
                tips.append(Tip(local: keyboardNode.simdConvertPosition(p, from: nil),
                                isLeft: hand.isLeft, key: "\(side)_t"))
            }
        }

        // Velocity history (up to 5 frames, pruned after 300 ms)
        for t in tips {
            var h = velHist[t.key] ?? []
            h.append((t.local, time))
            if h.count > 5 { h.removeFirst() }
            velHist[t.key] = h
        }
        velHist = velHist.filter { _, v in (time - (v.last?.1 ?? 0)) < 0.30 }

        var result: MenuAction? = nil

        for i in 0..<buttons.count {
            // Find the closest tip to this button
            var minDist: Float = Self.hoverDist + 1
            var closestTip: Tip? = nil
            for t in tips {
                let d = sdf(t.local, buttons[i].localPos, buttons[i].halfTouch)
                if d < minDist { minDist = d; closestTip = t }
            }

            // ── Continuous proximity glow ────────────────────────────────
            let t01 = simd_clamp(1 - minDist / Self.hoverDist, 0, 1)
            let glow = t01 * t01   // quadratic — fast near button, subtle far
            if abs(glow - buttons[i].glowLevel) > 0.008 {
                buttons[i].glowLevel = glow
                setGlow(index: i, glow: glow)
            }

            // ── Touch trigger ────────────────────────────────────────────
            guard result == nil, let tip = closestTip, minDist < Self.triggerDist else { continue }

            // Velocity gate: fingertip must be moving *toward* the button
            // (SDF decreasing = dist decreasing = approaching).
            // This prevents resting-hand false triggers.
            var approaching = true
            if let hist = velHist[tip.key], hist.count >= 2 {
                let prevDist = sdf(hist.first!.0, buttons[i].localPos, buttons[i].halfTouch)
                approaching = prevDist > minDist   // was further away before
            }
            guard approaching else { continue }

            // Debounce per hand side
            let last = lastTap[tip.isLeft] ?? -999
            guard time - last > Self.debounce else { continue }
            lastTap[tip.isLeft] = time

            result = buttons[i].action
            flashButton(index: i)
        }

        return result
    }

    // MARK: - Proximity query for external callers (render thread, pure math)

    /// Returns a 0…1 proximity value for any world-space point.
    /// 1 = touching a button; 0 = outside hover zone.
    func maxProximity(worldPos: SIMD3<Float>, keyboardNode: SCNNode) -> Float {
        let local = keyboardNode.simdConvertPosition(worldPos, from: nil)
        var best: Float = 0
        for btn in buttons {
            let d = sdf(local, btn.localPos, btn.halfTouch)
            let t = simd_clamp(1 - d / Self.hoverDist, 0, 1)
            if t > best { best = t }
        }
        return best * best
    }

    // MARK: - Glow  (render thread — CGColor assignment is thread-safe)

    private func setGlow(index: Int, glow: Float) {
        let mat = buttons[index].node.geometry?.firstMaterial
        if buttons[index].isActive {
            // Active: constant state-colour emission (red for stop, green for debug)
            let (r, g, b) = activeEmission(buttons[index].action)
            let i = CGFloat(0.22 + glow * 0.40)
            mat?.emission.contents = CGColor(red: r*i, green: g*i, blue: b*i, alpha: 1)
        } else {
            // Normal: blue proximity glow
            let i = CGFloat(glow * 0.60)
            mat?.emission.contents = CGColor(red: Self.cgHoverR * i,
                                             green: Self.cgHoverG * i,
                                             blue:  Self.cgHoverB * i, alpha: 1)
        }
    }

    private func flashButton(index: Int) {
        let mat = buttons[index].node.geometry?.firstMaterial
        mat?.emission.contents = CGColor(red: Self.cgFlashR, green: Self.cgFlashG,
                                         blue: Self.cgFlashB, alpha: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            self.setGlow(index: index, glow: self.buttons[index].glowLevel)
        }
    }

    private func activeEmission(_ action: MenuAction) -> (CGFloat, CGFloat, CGFloat) {
        switch action {
        case .playStop:    return (0.90, 0.08, 0.05)   // red
        case .toggleDebug: return (0.08, 0.85, 0.10)   // green
        default:           return (0.60, 0.60, 0.60)
        }
    }

    // MARK: - State sync  (render thread, swaps pre-baked UIImage refs)

    private func syncPlayButton() {
        guard let i = buttons.firstIndex(where: { $0.action == .playStop }) else { return }
        buttons[i].isActive = isPlaying
        // UIImage is immutable; setting diffuse.contents on render thread is thread-safe.
        buttons[i].node.geometry?.firstMaterial?.diffuse.contents =
            isPlaying ? buttons[i].texActive : buttons[i].texNormal
        setGlow(index: i, glow: buttons[i].glowLevel)
    }

    private func syncDebugButton() {
        guard let i = buttons.firstIndex(where: { $0.action == .toggleDebug }) else { return }
        buttons[i].isActive = debugOn
        buttons[i].node.geometry?.firstMaterial?.diffuse.contents =
            debugOn ? buttons[i].texActive : buttons[i].texNormal
        setGlow(index: i, glow: buttons[i].glowLevel)
    }

    // MARK: - SDF math  (pure, no UIKit)

    /// Axis-aligned box signed-distance function.
    /// Returns 0 at the surface, negative inside, positive outside.
    private func sdf(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ h: SIMD3<Float>) -> Float {
        let q = simd_abs(p - c) - h
        return simd_length(simd_max(q, .zero)) + min(max(q.x, max(q.y, q.z)), 0)
    }

    // MARK: - Texture baking  (UIKit — only called from build() on main thread)

    private func makeButtonTexture(label: String, isActive: Bool) -> UIImage {
        let w = Self.texW, h = Self.texH
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: w, height: h)

            // Glass background
            let bg: UIColor = isActive
                ? UIColor(red: 0.05, green: 0.18, blue: 0.07, alpha: 0.96)
                : UIColor(red: 0.04, green: 0.04, blue: 0.14, alpha: 0.94)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: 28)
            bg.setFill(); path.fill()

            // Border
            let borderAlpha: CGFloat = isActive ? 0.55 : 0.28
            let borderColor = isActive
                ? UIColor(red: 0.30, green: 1.00, blue: 0.40, alpha: borderAlpha)
                : UIColor(white: 1, alpha: borderAlpha)
            borderColor.setStroke()
            path.lineWidth = 4
            path.stroke()

            // Label
            let labelColor: UIColor = isActive
                ? UIColor(red: 0.45, green: 1.00, blue: 0.55, alpha: 1)
                : UIColor.white
            let font  = UIFont.systemFont(ofSize: 56, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
            let size  = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (w - size.width) / 2, y: (h - size.height) / 2),
                       withAttributes: attrs)
        }
    }

    // MARK: - Reusable material / node factories

    private func panMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel        = .constant
        m.diffuse.contents     = color
        m.blendMode            = .alpha
        m.writesToDepthBuffer  = false
        m.readsFromDepthBuffer = false
        return m
    }

    private func accentLineMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel        = .constant
        m.diffuse.contents     = UIColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 0.70)
        m.emission.contents    = UIColor(red: 0.15, green: 0.40, blue: 1.00, alpha: 0.60)
        m.writesToDepthBuffer  = false
        m.readsFromDepthBuffer = false
        return m
    }

    private func headerLabelNode(text: String) -> SCNNode {
        let w: CGFloat = 480, h: CGFloat = 56
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let img = renderer.image { _ in
            let font  = UIFont.systemFont(ofSize: 20, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.38),
                .kern: 4.5 as NSObject,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (w - size.width)/2, y: (h - size.height)/2),
                      withAttributes: attrs)
        }
        let plane   = SCNPlane(width: CGFloat(Self.btnW + 0.020), height: 0.026)
        let mat     = panMaterial(.clear)
        mat.diffuse.contents = img
        plane.materials      = [mat]
        return SCNNode(geometry: plane)
    }
}

import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, prevSong, nextSong, toggleDebug }

/// Floating AR control panel anchored to the right side of the keyboard.
/// Buttons are UIImage-textured SCNPlanes — text is rendered via CoreGraphics so
/// it centres correctly and reads cleanly through the headset lens.
/// Activated by pinch gestures from GestureDetector; hover glow on approach.
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Colours ────────────────────────────────────────────────────────────
    private static let colNormal  = UIColor(white: 0.10, alpha: 0.88)
    private static let colHover   = UIColor(red: 0.15, green: 0.42, blue: 1.00, alpha: 0.96)
    private static let colFlash   = UIColor(red: 0.12, green: 0.90, blue: 0.45, alpha: 1.00)
    private static let colStop    = UIColor(red: 0.82, green: 0.14, blue: 0.14, alpha: 0.92)
    private static let colDebugOn = UIColor(red: 0.10, green: 0.60, blue: 0.12, alpha: 0.90)

    // ── Button geometry ────────────────────────────────────────────────────
    private static let btnW:  CGFloat = 0.130   // 13 cm wide
    private static let btnH:  CGFloat = 0.058   // 5.8 cm tall
    private static let btnD:  CGFloat = 0.007   // 7 mm depth
    private static let gap:   Float   = 0.072   // 7.2 cm centre-to-centre (vertical)

    // Texture resolution (points × 2 for retina)
    private static let texW:  CGFloat = 320
    private static let texH:  CGFloat = 140

    // ── Per-button state ───────────────────────────────────────────────────
    private struct Button {
        let node:          SCNNode
        let action:        MenuAction
        let localPosition: SIMD3<Float>
        let hoverRadius:   Float = 0.090
        let hitRadius:     Float = 0.058
        var hovered:       Bool  = false
        var label:         String
    }

    private var buttons:    [Button]   = []
    private var isPlaying   = false
    private var debugOn     = false

    init() { build() }

    // MARK: - Build

    private func build() {
        // Panel background — subtle dark card behind all buttons
        let panelH = Float(Self.gap) * 4 + Float(Self.btnH)
        let panelGeo = SCNBox(
            width:         Self.btnW  + 0.016,
            height:        CGFloat(panelH) + 0.016,
            length:        Self.btnD * 0.5,
            chamferRadius: 0.010
        )
        let panelMat = SCNMaterial()
        panelMat.lightingModel        = .constant
        panelMat.diffuse.contents     = UIColor(white: 0.05, alpha: 0.78)
        panelMat.blendMode            = .alpha
        panelMat.writesToDepthBuffer  = false
        panelMat.readsFromDepthBuffer = false
        panelGeo.materials = [panelMat]
        let panelNode = SCNNode(geometry: panelGeo)
        panelNode.renderingOrder = 195

        // Column position in keyboard-local space:
        //   x  = just right of the rightmost key
        //   z  = same z as near-edge menu (slightly in front of near edge)
        //   y  = centre of the button column
        let colX: Float = KeyboardLayout.totalWidth * 0.5 + 0.075
        let colZ: Float = KeyboardLayout.whiteKeyDepth * 0.5 + 0.050
        let colYTop: Float = 0.26

        panelNode.simdPosition = SIMD3<Float>(colX, colYTop - Self.gap * 1.5, colZ)
        rootNode.addChildNode(panelNode)

        // Header label
        let headerNode = labelNode(
            text: "MENU",
            bgColor: UIColor(white: 0.0, alpha: 0.0),
            textColor: UIColor(white: 1.0, alpha: 0.40),
            fontSize: 16, bold: false
        )
        headerNode.simdPosition = SIMD3<Float>(colX, colYTop + Float(Self.gap) * 0.5 + 0.012, colZ)
        headerNode.renderingOrder = 198
        rootNode.addChildNode(headerNode)

        // Five buttons top-to-bottom
        let specs: [(String, MenuAction)] = [
            ("▶  Play",      .playStop),
            ("↺  Restart",   .restart),
            ("◀  Prev",      .prevSong),
            ("▶▶  Next",    .nextSong),
            ("⚙  Debug",    .toggleDebug),
        ]

        for (i, (label, action)) in specs.enumerated() {
            let yPos = colYTop - Float(i) * Self.gap
            let localPos = SIMD3<Float>(colX, yPos, colZ)
            let node = makeButtonNode(label: label, bgColor: Self.colNormal)
            node.simdPosition = localPos
            rootNode.addChildNode(node)
            buttons.append(Button(
                node: node, action: action,
                localPosition: localPos, label: label
            ))
        }
    }

    // MARK: - Per-frame update

    func update(pinchEvents:  [PinchEvent],
                hands:        [HandTracker.HandResult],
                keyboardNode: SCNNode,
                isPlaying:    Bool,
                debugOn:      Bool = false) -> MenuAction? {

        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            refreshPlayLabel(isPlaying: isPlaying)
        }
        if self.debugOn != debugOn {
            self.debugOn = debugOn
            refreshDebugLabel(debugOn: debugOn)
        }

        updateHover(hands: hands, keyboardNode: keyboardNode)

        for event in pinchEvents {
            let local = keyboardNode.simdConvertPosition(event.worldPosition, from: nil)
            for i in 0..<buttons.count {
                if simd_length(local - buttons[i].localPosition) < buttons[i].hitRadius {
                    flashButton(index: i)
                    return buttons[i].action
                }
            }
        }
        return nil
    }

    // MARK: - Hover

    private func updateHover(hands: [HandTracker.HandResult], keyboardNode: SCNNode) {
        var tips: [SIMD3<Float>] = []
        for hand in hands {
            if let t = hand.joints[.thumbTip], let idx = hand.joints[.indexTip] {
                tips.append((t + idx) * 0.5)
            }
        }
        for i in 0..<buttons.count {
            let nowHovered = tips.contains {
                let local = keyboardNode.simdConvertPosition($0, from: nil)
                return simd_length(local - buttons[i].localPosition) < buttons[i].hoverRadius
            }
            guard nowHovered != buttons[i].hovered else { continue }
            buttons[i].hovered = nowHovered
            let bg = nowHovered ? Self.colHover : normalColor(for: buttons[i].action)
            rebakeButton(index: i, bgColor: bg)
        }
    }

    // MARK: - Flash

    private func flashButton(index: Int) {
        rebakeButton(index: index, bgColor: Self.colFlash)
        let action = buttons[index].action
        let hovered = buttons[index].hovered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let bg = hovered ? Self.colHover : self.normalColor(for: action)
            self.rebakeButton(index: index, bgColor: bg)
        }
    }

    // MARK: - Label refresh

    private func refreshPlayLabel(isPlaying: Bool) {
        guard let i = buttons.firstIndex(where: { $0.action == .playStop }) else { return }
        buttons[i].label = isPlaying ? "■  Stop" : "▶  Play"
        let bg = isPlaying ? Self.colStop
                           : (buttons[i].hovered ? Self.colHover : Self.colNormal)
        rebakeButton(index: i, bgColor: bg)
    }

    private func refreshDebugLabel(debugOn: Bool) {
        guard let i = buttons.firstIndex(where: { $0.action == .toggleDebug }) else { return }
        buttons[i].label = debugOn ? "⚙  Debug ON" : "⚙  Debug"
        let bg = debugOn ? Self.colDebugOn
                         : (buttons[i].hovered ? Self.colHover : Self.colNormal)
        rebakeButton(index: i, bgColor: bg)
    }

    private func normalColor(for action: MenuAction) -> UIColor {
        switch action {
        case .playStop:    return isPlaying ? Self.colStop    : Self.colNormal
        case .toggleDebug: return debugOn   ? Self.colDebugOn : Self.colNormal
        default:           return Self.colNormal
        }
    }

    // MARK: - Node helpers

    private func makeButtonNode(label: String, bgColor: UIColor) -> SCNNode {
        let box = SCNBox(width: Self.btnW, height: Self.btnH,
                         length: Self.btnD, chamferRadius: 0.006)
        let mat = SCNMaterial()
        mat.lightingModel        = .constant
        mat.diffuse.contents     = makeTexture(label: label, bgColor: bgColor)
        mat.blendMode            = .alpha
        mat.writesToDepthBuffer  = false
        mat.readsFromDepthBuffer = false
        mat.isDoubleSided        = false
        box.materials = Array(repeating: mat, count: 6)   // same on all faces

        let node = SCNNode(geometry: box)
        node.renderingOrder = 200
        return node
    }

    private func rebakeButton(index: Int, bgColor: UIColor) {
        let label = buttons[index].label
        let tex   = makeTexture(label: label, bgColor: bgColor)
        buttons[index].node.geometry?.materials.forEach { $0.diffuse.contents = tex }
    }

    // ── Texture baking ─────────────────────────────────────────────────────

    private func makeTexture(label: String, bgColor: UIColor) -> UIImage {
        let w = Self.texW, h = Self.texH
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { ctx in
            // Background with rounded corners
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 20)
            bgColor.setFill()
            path.fill()

            // Subtle border
            UIColor.white.withAlphaComponent(0.20).setStroke()
            path.lineWidth = 3
            path.stroke()

            // Centered label text
            let font = UIFont.systemFont(ofSize: 38, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font:            font,
                .foregroundColor: UIColor.white,
            ]
            let size   = label.size(withAttributes: attrs)
            let origin = CGPoint(x: (w - size.width)  / 2,
                                 y: (h - size.height) / 2)
            label.draw(at: origin, withAttributes: attrs)
        }
    }

    private func labelNode(text: String, bgColor: UIColor, textColor: UIColor,
                           fontSize: CGFloat, bold: Bool) -> SCNNode {
        let w: CGFloat = 200, h: CGFloat = 40
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let img = renderer.image { _ in
            let font: UIFont = bold
                ? .boldSystemFont(ofSize: fontSize)
                : .systemFont(ofSize: fontSize, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: textColor
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (w - size.width) / 2, y: (h - size.height) / 2),
                      withAttributes: attrs)
        }
        let plane = SCNPlane(width: Self.btnW, height: 0.022)
        let mat   = SCNMaterial()
        mat.lightingModel        = .constant
        mat.diffuse.contents     = img
        mat.blendMode            = .alpha
        mat.writesToDepthBuffer  = false
        mat.readsFromDepthBuffer = false
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        return node
    }
}

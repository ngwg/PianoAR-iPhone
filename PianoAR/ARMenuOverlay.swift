import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, prevSong, nextSong, toggleDebug }

/// AR floating control panel — 5 buttons in a vertical column right of the keyboard.
/// All UIImage textures are pre-baked at init (main thread); the render thread only
/// swaps `diffuse.contents`, which SCNMaterial documents as thread-safe.
final class ARMenuOverlay {
    let rootNode = SCNNode()

    // ── Colours ────────────────────────────────────────────────────────────
    private static let colNormal  = UIColor(white: 0.10, alpha: 0.88)
    private static let colHover   = UIColor(red: 0.15, green: 0.42, blue: 1.00, alpha: 0.96)
    private static let colFlash   = UIColor(red: 0.12, green: 0.90, blue: 0.45, alpha: 1.00)
    private static let colStop    = UIColor(red: 0.82, green: 0.14, blue: 0.14, alpha: 0.92)
    private static let colDebugOn = UIColor(red: 0.10, green: 0.60, blue: 0.12, alpha: 0.90)

    // ── Button geometry ────────────────────────────────────────────────────
    private static let btnW: CGFloat = 0.130
    private static let btnH: CGFloat = 0.058
    private static let btnD: CGFloat = 0.007
    private static let gap:  Float   = 0.072

    // Texture atlas dimensions
    private static let texW: CGFloat = 320
    private static let texH: CGFloat = 140

    // ── Per-button state ───────────────────────────────────────────────────
    private struct Button {
        let node:          SCNNode
        let action:        MenuAction
        let localPosition: SIMD3<Float>
        let hoverRadius:   Float = 0.090
        let hitRadius:     Float = 0.058
        var hovered:       Bool  = false
        var label:         String
        // Pre-baked textures — swapped on render thread (SCNMaterial.contents is thread-safe)
        var texNormal:     UIImage
        var texHover:      UIImage
        var texSpecial:    UIImage? // stop colour / debugOn colour
        var texFlash:      UIImage
    }

    private var buttons:  [Button] = []
    private var isPlaying = false
    private var debugOn   = false

    init() { build() }

    // MARK: - Build (runs on main thread at anchor creation)

    private func build() {
        let colX: Float    = KeyboardLayout.totalWidth * 0.5 + 0.075
        let colZ: Float    = KeyboardLayout.whiteKeyDepth * 0.5 + 0.050
        let colYTop: Float = 0.26

        // Panel background card.
        // 5 buttons span (N-1)*gap + btnH; centre of column is colYTop - 2*gap.
        let panelH = CGFloat(Self.gap) * 4 + Self.btnH
        let panelGeo = SCNBox(
            width:         Self.btnW + 0.016,
            height:        panelH    + 0.020,
            length:        Self.btnD * 0.5,
            chamferRadius: 0.010
        )
        let panelMat = SCNMaterial()
        panelMat.lightingModel        = .constant
        panelMat.diffuse.contents     = UIColor(white: 0.05, alpha: 0.78)
        panelMat.blendMode            = .alpha
        panelMat.writesToDepthBuffer  = false
        panelMat.readsFromDepthBuffer = false
        panelGeo.materials    = [panelMat]
        let panelNode         = SCNNode(geometry: panelGeo)
        panelNode.simdPosition = SIMD3<Float>(colX, colYTop - Self.gap * 2, colZ)
        panelNode.renderingOrder = 195
        rootNode.addChildNode(panelNode)

        // "MENU" header label
        let headerNode = makeLabelNode(text: "MENU")
        headerNode.simdPosition   = SIMD3<Float>(colX, colYTop + Self.gap * 0.45, colZ)
        headerNode.renderingOrder = 198
        rootNode.addChildNode(headerNode)

        let specs: [(String, MenuAction)] = [
            ("▶  Play",    .playStop),
            ("↺  Restart", .restart),
            ("◀  Prev",    .prevSong),
            ("▶▶ Next",   .nextSong),
            ("⚙  Debug",  .toggleDebug),
        ]

        for (i, (label, action)) in specs.enumerated() {
            let yPos     = colYTop - Float(i) * Self.gap
            let localPos = SIMD3<Float>(colX, yPos, colZ)

            let specialColor: UIColor? = {
                switch action {
                case .playStop:    return Self.colStop
                case .toggleDebug: return Self.colDebugOn
                default:           return nil
                }
            }()

            let texNormal  = makeTexture(label: label, bgColor: Self.colNormal)
            let texHover   = makeTexture(label: label, bgColor: Self.colHover)
            let texFlash   = makeTexture(label: label, bgColor: Self.colFlash)
            let texSpecial = specialColor.map { makeTexture(label: specialLabel(for: action), bgColor: $0) }

            let mat        = SCNMaterial()
            mat.lightingModel        = .constant
            mat.diffuse.contents     = texNormal
            mat.blendMode            = .alpha
            mat.writesToDepthBuffer  = false
            mat.readsFromDepthBuffer = false

            let box = SCNBox(width: Self.btnW, height: Self.btnH,
                             length: Self.btnD, chamferRadius: 0.006)
            box.materials = [mat]     // one material — all faces share it

            let node              = SCNNode(geometry: box)
            node.simdPosition     = localPos
            node.renderingOrder   = 200
            rootNode.addChildNode(node)

            buttons.append(Button(
                node: node, action: action, localPosition: localPos,
                label: label,
                texNormal: texNormal, texHover: texHover,
                texSpecial: texSpecial, texFlash: texFlash
            ))
        }
    }

    // MARK: - Per-frame update (called on SceneKit render thread)

    func update(pinchEvents:  [PinchEvent],
                hands:        [HandTracker.HandResult],
                keyboardNode: SCNNode,
                isPlaying:    Bool,
                debugOn:      Bool = false) -> MenuAction? {

        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            rebakePlayButton()
        }
        if self.debugOn != debugOn {
            self.debugOn = debugOn
            rebakeDebugButton()
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

    // MARK: - Hover (render thread — only sets pre-baked UIImage references)

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
            applyCurrentTexture(index: i)
        }
    }

    // MARK: - Flash (render thread)

    private func flashButton(index: Int) {
        setTexture(index: index, tex: buttons[index].texFlash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            // Read current hovered state at execution time, not capture time.
            self.applyCurrentTexture(index: index)
        }
    }

    // MARK: - State refresh (render thread)

    private func rebakePlayButton() {
        guard let i = buttons.firstIndex(where: { $0.action == .playStop }) else { return }
        applyCurrentTexture(index: i)
    }

    private func rebakeDebugButton() {
        guard let i = buttons.firstIndex(where: { $0.action == .toggleDebug }) else { return }
        applyCurrentTexture(index: i)
    }

    // MARK: - Texture application (render thread — safe, SCNMaterial.contents is thread-safe)

    private func applyCurrentTexture(index: Int) {
        let btn = buttons[index]
        let tex: UIImage
        switch btn.action {
        case .playStop:
            tex = isPlaying ? (btn.texSpecial ?? btn.texNormal)
                            : (btn.hovered   ? btn.texHover   : btn.texNormal)
        case .toggleDebug:
            tex = debugOn   ? (btn.texSpecial ?? btn.texNormal)
                            : (btn.hovered   ? btn.texHover   : btn.texNormal)
        default:
            tex = btn.hovered ? btn.texHover : btn.texNormal
        }
        setTexture(index: index, tex: tex)
    }

    private func setTexture(index: Int, tex: UIImage) {
        buttons[index].node.geometry?.firstMaterial?.diffuse.contents = tex
    }

    // MARK: - Texture baking (UIKit — must only be called on main thread / during init)

    private func makeTexture(label: String, bgColor: UIColor) -> UIImage {
        let w = Self.texW, h = Self.texH
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 20)
            bgColor.setFill()
            path.fill()

            UIColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 3
            path.stroke()

            let font  = UIFont.systemFont(ofSize: 38, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let size  = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (w - size.width) / 2, y: (h - size.height) / 2),
                       withAttributes: attrs)
        }
    }

    private func makeLabelNode(text: String) -> SCNNode {
        let w: CGFloat = 200, h: CGFloat = 36
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let img = renderer.image { _ in
            let font  = UIFont.systemFont(ofSize: 15, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.42)
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (w - size.width) / 2, y: (h - size.height) / 2),
                      withAttributes: attrs)
        }
        let plane     = SCNPlane(width: Self.btnW, height: 0.020)
        let mat       = SCNMaterial()
        mat.lightingModel        = .constant
        mat.diffuse.contents     = img
        mat.blendMode            = .alpha
        mat.writesToDepthBuffer  = false
        mat.readsFromDepthBuffer = false
        plane.materials = [mat]
        return SCNNode(geometry: plane)
    }

    // MARK: - Helpers

    private func specialLabel(for action: MenuAction) -> String {
        switch action {
        case .playStop:    return "■  Stop"
        case .toggleDebug: return "⚙  Debug ON"
        default:           return ""
        }
    }
}

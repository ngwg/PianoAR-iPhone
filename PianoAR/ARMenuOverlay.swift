import SceneKit
import UIKit
import simd

enum MenuAction { case playStop, restart, nextSong }

final class ARMenuOverlay {
    let rootNode = SCNNode()

    // Colours
    private static let colNormal = UIColor(white: 0.12, alpha: 0.88)
    private static let colHover  = UIColor(red: 0.20, green: 0.50, blue: 1.00, alpha: 0.95)
    private static let colFlash  = UIColor(red: 0.15, green: 1.00, blue: 0.45, alpha: 1.00)
    private static let colStop   = UIColor(red: 0.85, green: 0.18, blue: 0.18, alpha: 0.92)

    private struct Button {
        let node:          SCNNode
        let action:        MenuAction
        let localPosition: SIMD3<Float>
        let hoverRadius:   Float = 0.080
        let hitRadius:     Float = 0.055
        var hovered:       Bool  = false
    }

    private var buttons: [Button] = []
    // keeps "is song currently playing?" so we can update Play/Stop label
    private var isPlaying = false

    init() { build() }

    private func build() {
        let specs: [(String, MenuAction, Float)] = [
            ("▶ Play",    .playStop, -0.28),
            ("↺ Restart", .restart,   0.00),
            ("▸▸ Next",   .nextSong,  0.28),
        ]

        // In keyboard-local coords: just above and in front of the near edge.
        let y: Float = 0.095
        let z: Float = KeyboardLayout.whiteKeyDepth * 0.5 + 0.06

        for (label, action, x) in specs {
            let localPos = SIMD3<Float>(x, y, z)

            // Box
            let box   = SCNBox(width: 0.120, height: 0.048, length: 0.008,
                               chamferRadius: 0.006)
            let mat   = SCNMaterial()
            mat.lightingModel        = .constant
            mat.diffuse.contents     = Self.colNormal
            mat.blendMode            = .alpha
            mat.isDoubleSided        = true
            mat.writesToDepthBuffer  = false
            mat.readsFromDepthBuffer = false   // always render on top of key geometry
            box.materials = [mat]

            let node = SCNNode(geometry: box)
            node.simdPosition   = localPos
            node.renderingOrder = 200
            rootNode.addChildNode(node)

            // Label
            let txt           = SCNText(string: label, extrusionDepth: 0.001)
            txt.font          = UIFont.boldSystemFont(ofSize: 1.0)
            txt.flatness      = 0.05
            let tmat = SCNMaterial()
            tmat.lightingModel        = .constant
            tmat.diffuse.contents     = UIColor.white
            tmat.writesToDepthBuffer  = false
            tmat.readsFromDepthBuffer = false
            txt.materials = [tmat]
            let tnode         = SCNNode(geometry: txt)
            tnode.scale       = SCNVector3(0.009, 0.009, 0.009)
            // Rough centering — SCNText anchors at lower-left.
            let charCount     = Float(label.count)
            tnode.simdPosition = SIMD3<Float>(-charCount * 0.0042, -0.010, 0.005)
            tnode.renderingOrder = 201
            node.addChildNode(tnode)

            buttons.append(Button(node: node, action: action, localPosition: localPos))
        }
    }

    // MARK: - Per-frame update

    /// Call every frame with the current keyboard node and hand midpoints.
    /// Returns nil usually; returns an action when a pinch fires on a button.
    func update(pinchEvents: [PinchEvent],
                hands: [HandTracker.HandResult],
                keyboardNode: SCNNode,
                isPlaying: Bool) -> MenuAction? {
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            refreshPlayLabel(isPlaying: isPlaying)
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
        // Collect both thumb+index midpoints
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
            buttons[i].node.geometry?.firstMaterial?.diffuse.contents =
                nowHovered ? Self.colHover : normalColor(for: buttons[i].action)
        }
    }

    // MARK: - Flash feedback

    private func flashButton(index: Int) {
        let mat = buttons[index].node.geometry?.firstMaterial
        mat?.diffuse.contents = Self.colFlash
        let action = buttons[index].action
        let hovered = buttons[index].hovered
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            mat?.diffuse.contents = hovered ? Self.colHover : self.normalColor(for: action)
        }
    }

    private func normalColor(for action: MenuAction) -> UIColor {
        action == .playStop && isPlaying ? Self.colStop : Self.colNormal
    }

    private func refreshPlayLabel(isPlaying: Bool) {
        guard let btn = buttons.first(where: { $0.action == .playStop }),
              let child = btn.node.childNodes.first,
              let txt   = child.geometry as? SCNText
        else { return }
        txt.string = isPlaying ? "■ Stop" : "▶ Play"
        let charCount = Float((txt.string as? String ?? "").count)
        child.simdPosition = SIMD3<Float>(-charCount * 0.0042, -0.010, 0.005)
        btn.node.geometry?.firstMaterial?.diffuse.contents =
            isPlaying ? Self.colStop : Self.colNormal
    }
}

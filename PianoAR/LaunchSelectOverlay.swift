import SceneKit
import UIKit
import simd

/// Camera-locked AR "HUD" panel shown at app launch (and whenever re-opened via
/// the mode chip) to choose Virtual vs Real piano mode.
///
/// Parented directly to the ARSCNView's pointOfView node, so it rides along
/// with head movement every frame for free — no per-frame repositioning code
/// needed, exactly like a Quest-style menu that's always in view.
///
/// Interaction matches the main AR menu exactly: the index fingertip projects
/// onto the panel and a glowing cursor dot follows it; poke (push through) or
/// dwell (~0.45s hold) selects a card.
final class LaunchSelectOverlay {

    // ── Panel geometry ──────────────────────────────────────────────────────
    private static let panW: Float = 0.50
    private static let panH: Float = 0.30
    private static let texW: CGFloat = 1000
    private static let texH: CGFloat = 600

    // Offset in the camera's own local space (camera looks down -Z, so a
    // negative Z is "in front of the face").
    private static let camOffset = SCNVector3(0, -0.02, -0.62)

    // ── Cursor / click thresholds — identical feel to the main AR menu ─────
    private static let hoverMaxZ:  Float        = 0.28
    private static let pokeArmZ:   Float        = 0.090
    private static let pokeFireZ:  Float        = 0.040
    private static let dwellTime:  TimeInterval = 0.45
    private static let debounce:   TimeInterval = 0.32
    private static let xyMargin:   Float        = 0.030
    private static let headerFrac: Float        = 0.24   // top strip is non-interactive

    private enum Region: Equatable { case none, virtual, real }

    // ── State (render thread) ───────────────────────────────────────────────
    private var dwellRegion:    Region       = .none
    private var dwellStart:     TimeInterval = 0
    private var pokeArmed:      Bool         = false
    private var firedRegion:    Region       = .none
    private var cursorLeft:     Bool?        = nil
    private var fireFlashUntil: TimeInterval = 0
    private var lastFire:       TimeInterval = -999

    // ── Scene nodes ─────────────────────────────────────────────────────────
    private var panelNode:  SCNNode!
    private var panelMat:   SCNMaterial!
    private var cursorNode: SCNNode!
    private var cursorMat:  SCNMaterial!

    init(cameraNode: SCNNode) {
        build(parent: cameraNode)
    }

    // MARK: - Build  (may run on the render thread — only geometry/UIColor here;
    // the UIGraphicsImageRenderer bake is dispatched to main separately)

    private func build(parent: SCNNode) {
        let geo  = SCNPlane(width: CGFloat(Self.panW), height: CGFloat(Self.panH))
        panelMat = SCNMaterial()
        panelMat.lightingModel        = .constant
        panelMat.diffuse.contents     = UIColor(red: 0.05, green: 0.03, blue: 0.14, alpha: 0.97)
        panelMat.blendMode            = .alpha
        panelMat.isDoubleSided        = true
        panelMat.writesToDepthBuffer  = false
        panelMat.readsFromDepthBuffer = false
        geo.materials = [panelMat]

        panelNode = SCNNode(geometry: geo)
        panelNode.position       = Self.camOffset
        panelNode.renderingOrder = 250
        parent.addChildNode(panelNode)

        addCursor()
        dispatchBake()
        animateIn()
    }

    private func addCursor() {
        let geo = SCNSphere(radius: 0.011)
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
        cursorNode.renderingOrder = 255
        cursorNode.isHidden       = true
        panelNode.addChildNode(cursorNode)
    }

    // MARK: - Per-frame update  (render thread)

    /// Returns the chosen mode the frame a card is selected, or nil otherwise.
    func update(hands: [HandTracker.HandResult], time: TimeInterval) -> AppMode? {
        var best: (local: SIMD3<Float>, isLeft: Bool)? = nil
        for hand in hands {
            guard let tip = hand.joints[.indexTip] else { continue }
            let local = panelNode.simdConvertPosition(tip, from: nil)
            guard abs(local.x) < Self.panW/2 + Self.xyMargin,
                  abs(local.y) < Self.panH/2 + Self.xyMargin,
                  local.z > -0.03, local.z < Self.hoverMaxZ else { continue }
            if best == nil || abs(local.z) < abs(best!.local.z) { best = (local, hand.isLeft) }
        }

        guard let b = best else {
            cursorNode.isHidden = true
            dwellRegion = .none; firedRegion = .none; pokeArmed = false; cursorLeft = nil
            return nil
        }

        let region = regionAt(x: b.local.x, y: b.local.y)

        if cursorLeft != b.isLeft {
            cursorLeft  = b.isLeft
            pokeArmed   = false
            dwellRegion = region
            dwellStart  = time
        }
        if region != dwellRegion { dwellRegion = region; dwellStart = time }
        if region != firedRegion { firedRegion = .none }

        if b.local.z > Self.pokeArmZ { pokeArmed = true }
        let poked = pokeArmed && b.local.z < Self.pokeFireZ

        let dwellProg = Float(simd_clamp((time - dwellStart) / Self.dwellTime, 0, 1))
        let dwellFire = (time - dwellStart) >= Self.dwellTime && firedRegion != region

        var result: AppMode? = nil
        if region != .none, time - lastFire > Self.debounce, poked || dwellFire {
            lastFire       = time
            fireFlashUntil = time + 0.18
            pokeArmed      = false
            firedRegion    = region
            dwellRegion    = .none
            dwellStart     = time
            pulse()
            result = (region == .virtual) ? .virtualPiano : .realPiano
        }

        updateCursor(local: b.local, progress: dwellProg, actionable: region != .none, time: time)
        return result
    }

    private func regionAt(x: Float, y: Float) -> Region {
        let vFrac = 1.0 - Float((y + Self.panH/2) / Self.panH)   // 0 = top, 1 = bottom
        guard vFrac > Self.headerFrac, abs(x) < Self.panW/2 else { return .none }
        return x < 0 ? .virtual : .real
    }

    private func updateCursor(local: SIMD3<Float>, progress: Float,
                              actionable: Bool, time: TimeInterval) {
        cursorNode.isHidden     = false
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
        cursorNode.scale             = SCNVector3(scale, scale, scale)
        cursorMat.emission.contents  = color
        cursorMat.diffuse.contents   = color
    }

    // MARK: - Teardown

    func remove() {
        let group = SCNAction.group([
            SCNAction.fadeOut(duration: 0.22),
            SCNAction.scale(to: 0.7, duration: 0.22),
        ])
        panelNode.runAction(SCNAction.sequence([group, SCNAction.removeFromParentNode()]))
    }

    // MARK: - Entrance / feedback animation

    private func animateIn() {
        panelNode.opacity = 0
        panelNode.scale   = SCNVector3(0.7, 0.7, 0.7)
        let grow = SCNAction.scale(to: 1.0, duration: 0.42); grow.timingMode = .easeOut
        let fade = SCNAction.fadeIn(duration: 0.42)
        panelNode.runAction(SCNAction.group([grow, fade]))
    }

    private func pulse() {
        panelNode.removeAction(forKey: "pulse")
        let up = SCNAction.scale(to: 1.04, duration: 0.08); up.timingMode = .easeOut
        let dn = SCNAction.scale(to: 1.0,  duration: 0.11); dn.timingMode = .easeIn
        panelNode.runAction(SCNAction.sequence([up, dn]), forKey: "pulse")
    }

    // MARK: - Texture dispatch

    private func dispatchBake() {
        let mat = panelMat!
        DispatchQueue.main.async {
            mat.diffuse.contents = LaunchSelectOverlay.bake()
        }
    }

    // MARK: - Texture baking  (main thread only — UIKit)

    private static func bake() -> UIImage {
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { _ in
            UIColor(red: 0.05, green: 0.03, blue: 0.14, alpha: 0.97).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 32).fill()

            centered("PIANOAR", in: CGRect(x: 0, y: 22, width: texW, height: 44),
                     font: .systemFont(ofSize: 26, weight: .black), color: UIColor(white: 1, alpha: 0.85))
            centered("Choose how you want to play", in: CGRect(x: 0, y: 64, width: texW, height: 28),
                     font: .systemFont(ofSize: 15, weight: .medium), color: UIColor(white: 1, alpha: 0.5))

            let pad: CGFloat = 40, gap: CGFloat = 24
            let cardW = (texW - pad * 2 - gap) / 2
            let cardTop: CGFloat = 118
            let card0 = CGRect(x: pad, y: cardTop, width: cardW, height: texH - cardTop - 30)
            let card1 = CGRect(x: pad + cardW + gap, y: cardTop, width: cardW, height: texH - cardTop - 30)

            drawCard(card0, icon: "▥", title: "VIRTUAL PIANO",
                     blurb: "Place a full 88-key keyboard on any table.",
                     accent: UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1))
            drawCard(card1, icon: "♫", title: "REAL PIANO",
                     blurb: "Overlay the note guide onto your real keys.",
                     accent: UIColor(red: 0.70, green: 0.35, blue: 1.0, alpha: 1))
        }
    }

    private static func drawCard(_ rect: CGRect, icon: String, title: String,
                                 blurb: String, accent: UIColor) {
        UIColor(white: 1, alpha: 0.06).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 22).fill()
        accent.withAlphaComponent(0.55).setStroke()
        let border = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 22)
        border.lineWidth = 2
        border.stroke()

        let iconRect = CGRect(x: rect.midX - 34, y: rect.minY + 24, width: 68, height: 68)
        accent.withAlphaComponent(0.20).setFill()
        UIBezierPath(ovalIn: iconRect).fill()
        centered(icon, in: iconRect, font: .systemFont(ofSize: 30, weight: .bold), color: accent)

        centered(title, in: CGRect(x: rect.minX, y: iconRect.maxY + 12, width: rect.width, height: 28),
                 font: .systemFont(ofSize: 19, weight: .bold), color: .white)

        let blurbTop  = iconRect.maxY + 46
        let blurbRect = CGRect(x: rect.minX + 16, y: blurbTop,
                               width: rect.width - 32, height: max(0, rect.maxY - blurbTop - 12))
        wrapped(blurb, in: blurbRect, font: .systemFont(ofSize: 13, weight: .regular),
                color: UIColor(white: 1, alpha: 0.55))
    }

    private static func centered(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.minX + (rect.width - sz.width) / 2,
                              y: rect.minY + (rect.height - sz.height) / 2), withAttributes: attrs)
    }

    private static func wrapped(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.alignment     = .center
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}

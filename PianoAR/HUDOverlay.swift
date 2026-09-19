import SceneKit
import UIKit

/// World-locked practice HUD: a slim status bar at the top of the note
/// waterfall (song, progress, accuracy, streak, feedback) that becomes a
/// results card when the song ends. World-locked on purpose — UI glued to
/// the head is a known discomfort trigger in headsets.
///
/// Textures are baked with UIKit on the main thread; the render thread only
/// decides when to re-bake (on change, ≤ 8 Hz) and swaps the image.
final class PracticeHUDOverlay {
    let rootNode = SCNNode()

    private static let barSize  = CGSize(width: 1024, height: 150)
    private static let cardSize = CGSize(width: 1024, height: 560)
    private static let barWorld: (w: Float, h: Float)  = (0.44, 0.064)
    private static let cardWorld: (w: Float, h: Float) = (0.44, 0.24)

    private let barNode: SCNNode
    private let barMat = SCNMaterial()
    private let cardNode: SCNNode
    private let cardMat = SCNMaterial()

    private var lastHUD: PracticeHUD?
    private var lastBake: TimeInterval = 0

    /// Keyboard-local placement: top of the waterfall sheet, same tilt.
    init(sheetTilt: Float = 0.26, sheetHeight: Float = 0.40) {
        for m in [barMat, cardMat] {
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.clear
            m.blendMode = .alpha
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = false
        }
        let barGeo = SCNPlane(width: CGFloat(Self.barWorld.w), height: CGFloat(Self.barWorld.h))
        barGeo.materials = [barMat]
        barNode = SCNNode(geometry: barGeo)
        let cardGeo = SCNPlane(width: CGFloat(Self.cardWorld.w), height: CGFloat(Self.cardWorld.h))
        cardGeo.materials = [cardMat]
        cardNode = SCNNode(geometry: cardGeo)
        cardNode.isHidden = true

        // Same frame as the waterfall sheet (see NoteHighway).
        let frame = SCNNode()
        frame.simdPosition = SIMD3<Float>(0, KeyboardLayout.whiteKeyHeight + 0.004,
                                          -KeyboardLayout.whiteKeyDepth / 2 - 0.004)
        frame.eulerAngles.x = -sheetTilt
        rootNode.addChildNode(frame)

        barNode.simdPosition = SIMD3<Float>(0, sheetHeight + Self.barWorld.h / 2 + 0.012, 0)
        barNode.renderingOrder = 150
        frame.addChildNode(barNode)

        cardNode.simdPosition = SIMD3<Float>(0, sheetHeight * 0.45, 0.01)
        cardNode.renderingOrder = 160
        frame.addChildNode(cardNode)
    }

    /// Render thread.
    func update(hud: PracticeHUD, time: TimeInterval) {
        guard hud != lastHUD, time - lastBake > 0.12 else { return }
        lastHUD = hud
        lastBake = time
        cardNode.isHidden = !hud.isComplete
        let barMat = barMat, cardMat = cardMat
        DispatchQueue.main.async {
            barMat.diffuse.contents = Self.bakeBar(hud)
            if hud.isComplete { cardMat.diffuse.contents = Self.bakeCard(hud) }
        }
    }

    // MARK: - Baking (main thread)

    private static func bakeBar(_ h: PracticeHUD) -> UIImage {
        let sz = barSize
        return UIGraphicsImageRenderer(size: sz).image { ctx in
            let r = CGRect(origin: .zero, size: sz).insetBy(dx: 3, dy: 3)
            UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 0.80).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 34).fill()
            UIColor(white: 1, alpha: 0.14).setStroke()
            let border = UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 34)
            border.lineWidth = 2
            border.stroke()

            // Title + mode line
            draw(h.title, at: CGPoint(x: 36, y: 20), size: 34, weight: .heavy, color: .white, maxWidth: 520)
            let mode = "\(h.waitMode ? "WAIT MODE" : "PLAY-ALONG")  ·  \(h.tempoPercent)%  ·  \(h.hand.label)"
            draw(mode, at: CGPoint(x: 36, y: 64), size: 20, weight: .bold,
                 color: UIColor(white: 1, alpha: 0.55), maxWidth: 560)

            // Progress bar
            let track = CGRect(x: 36, y: 104, width: 560, height: 12)
            UIColor(white: 1, alpha: 0.12).setFill()
            UIBezierPath(roundedRect: track, cornerRadius: 6).fill()
            var fill = track
            fill.size.width = max(12, track.width * CGFloat(min(1, max(0, h.progress))))
            UIColor(red: 0.35, green: 0.70, blue: 1.0, alpha: 1).setFill()
            UIBezierPath(roundedRect: fill, cornerRadius: 6).fill()

            // Stats (right side)
            draw("\(h.accuracyPercent)%", at: CGPoint(x: 640, y: 18), size: 54, weight: .black,
                 color: accuracyColor(h.accuracyPercent), maxWidth: 170)
            draw("ACCURACY", at: CGPoint(x: 644, y: 86), size: 16, weight: .bold,
                 color: UIColor(white: 1, alpha: 0.5), maxWidth: 170)
            draw("\(h.streak)", at: CGPoint(x: 830, y: 18), size: 54, weight: .black,
                 color: h.streak >= 10 ? UIColor(red: 1, green: 0.75, blue: 0.25, alpha: 1) : .white,
                 maxWidth: 150)
            draw("STREAK", at: CGPoint(x: 834, y: 86), size: 16, weight: .bold,
                 color: UIColor(white: 1, alpha: 0.5), maxWidth: 150)

            // Feedback / prompt
            let line = !h.feedback.isEmpty ? h.feedback
                : (!h.prompt.isEmpty ? "Play \(h.prompt)" : (h.isPlaying ? "" : "Pinch PLAY to start"))
            draw(line, at: CGPoint(x: 640, y: 112), size: 20, weight: .semibold,
                 color: UIColor(red: 0.6, green: 0.95, blue: 0.75, alpha: 1), maxWidth: 360)
            _ = ctx
        }
    }

    private static func bakeCard(_ h: PracticeHUD) -> UIImage {
        let sz = cardSize
        return UIGraphicsImageRenderer(size: sz).image { _ in
            let r = CGRect(origin: .zero, size: sz).insetBy(dx: 4, dy: 4)
            UIColor(red: 0.05, green: 0.03, blue: 0.13, alpha: 0.94).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 44).fill()
            UIColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 0.7).setStroke()
            let border = UIBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), cornerRadius: 44)
            border.lineWidth = 3
            border.stroke()

            drawCentered("SONG COMPLETE", y: 34, size: 30, weight: .black,
                         color: UIColor(white: 1, alpha: 0.7), width: sz.width)
            drawCentered(h.title, y: 78, size: 38, weight: .heavy, color: .white, width: sz.width)
            drawCentered("\(h.accuracyPercent)%", y: 130, size: 120, weight: .black,
                         color: accuracyColor(h.accuracyPercent), width: sz.width)
            let rows = [
                ("NOTES", "\(h.accepted)"),
                ("MISTAKES", "\(h.mistakes)"),
                ("MISSED", "\(h.missed)"),
                ("BEST STREAK", "\(h.bestStreak)"),
                ("TIMING", "±\(h.averageTimingMs) ms"),
            ]
            let colW = (sz.width - 80) / CGFloat(rows.count)
            for (i, row) in rows.enumerated() {
                let x = 40 + CGFloat(i) * colW
                drawCentered(row.1, y: 300, size: 40, weight: .heavy, color: .white, width: colW, x: x)
                drawCentered(row.0, y: 350, size: 17, weight: .bold,
                             color: UIColor(white: 1, alpha: 0.5), width: colW, x: x)
            }
            drawCentered("Pinch RESTART to go again, or pick a new song",
                         y: 450, size: 24, weight: .semibold,
                         color: UIColor(white: 1, alpha: 0.6), width: sz.width)
        }
    }

    private static func accuracyColor(_ pct: Int) -> UIColor {
        if pct >= 90 { return UIColor(red: 0.40, green: 1.00, blue: 0.55, alpha: 1) }
        if pct >= 70 { return UIColor(red: 1.00, green: 0.85, blue: 0.30, alpha: 1) }
        return UIColor(red: 1.00, green: 0.45, blue: 0.40, alpha: 1)
    }

    static func draw(_ text: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight,
                     color: UIColor, maxWidth: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(in: CGRect(x: p.x, y: p.y, width: maxWidth, height: font.lineHeight + 2),
                                withAttributes: [.font: font, .foregroundColor: color,
                                                 .paragraphStyle: para])
    }

    static func drawCentered(_ text: String, y: CGFloat, size: CGFloat, weight: UIFont.Weight,
                             color: UIColor, width: CGFloat, x: CGFloat = 0) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(in: CGRect(x: x, y: y, width: width, height: font.lineHeight + 2),
                                withAttributes: [.font: font, .foregroundColor: color,
                                                 .paragraphStyle: para])
    }
}

/// Live press-detection debug readout (the "debug overlay from day one" the
/// project brief asks for): per-finger trajectory state, audio onset/strike
/// verification, tracking + thermal state. Sits to the LEFT of the keyboard,
/// facing the player; only shown while Debug is on.
final class DebugPanelOverlay {
    let rootNode = SCNNode()
    private let mat = SCNMaterial()
    private var lastBake: TimeInterval = 0
    private var lastLines: [String] = []
    private static let tex = CGSize(width: 900, height: 900)

    init() {
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.clear
        mat.blendMode = .alpha
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        let geo = SCNPlane(width: 0.30, height: 0.30)
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        node.renderingOrder = 170
        node.eulerAngles = SCNVector3(-Float.pi * 0.22, Float.pi * 0.14, 0)
        node.simdPosition = SIMD3<Float>(-KeyboardLayout.totalWidth * 0.32, 0.22, 0.10)
        rootNode.addChildNode(node)
        rootNode.isHidden = true
    }

    /// Render thread.
    func update(visible: Bool, lines: [String], time: TimeInterval) {
        rootNode.isHidden = !visible
        guard visible, lines != lastLines, time - lastBake > 0.2 else { return }
        lastLines = lines
        lastBake = time
        let mat = mat
        DispatchQueue.main.async { mat.diffuse.contents = Self.bake(lines) }
    }

    private static func bake(_ lines: [String]) -> UIImage {
        UIGraphicsImageRenderer(size: tex).image { _ in
            let r = CGRect(origin: .zero, size: tex).insetBy(dx: 3, dy: 3)
            UIColor(white: 0, alpha: 0.78).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 30).fill()
            let font = UIFont.monospacedSystemFont(ofSize: 24, weight: .medium)
            var y: CGFloat = 26
            for line in lines.prefix(28) {
                let color: UIColor = line.hasPrefix("—") ? UIColor(red: 0.6, green: 0.85, blue: 1, alpha: 1)
                                                         : UIColor(white: 1, alpha: 0.9)
                (line as NSString).draw(at: CGPoint(x: 28, y: y),
                                        withAttributes: [.font: font, .foregroundColor: color])
                y += 30
            }
        }
    }
}

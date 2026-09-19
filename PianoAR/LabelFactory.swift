import UIKit

/// Pre-baked text textures for SceneKit labels.
///
/// SCNText builds real extruded 3-D glyph meshes — ~100 of them (key letters
/// + falling-note names) cost far more GPU than the rest of the overlay and
/// still looked soft. Every label is instead a flat plane with a small baked
/// image. Images are baked on the main thread (UIKit drawing) — `prewarm()`
/// at launch covers every note name — and the render thread only reads the
/// cache.
enum LabelFactory {
    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    /// Every note name A0…C8 plus the white-key letters. Call on main at launch.
    static func prewarm() {
        for key in KeyboardLayout.keys {
            _ = bakeIfNeeded(key.noteName, style: .note)
            if !key.isBlack {
                _ = bakeIfNeeded(keyLabelText(for: key), style: .keyLetter)
            }
        }
    }

    enum Style: String {
        case note        // on falling bars: bold white on transparent
        case keyLetter   // on the keys: soft white, C's show their octave
    }

    /// Render-thread safe: returns nil (and schedules a bake) on a miss.
    static func image(_ text: String, style: Style) -> UIImage? {
        let id = "\(style.rawValue):\(text)"
        lock.lock()
        let hit = cache[id]
        lock.unlock()
        if let hit { return hit }
        DispatchQueue.main.async { _ = bakeIfNeeded(text, style: style) }
        return nil
    }

    /// "C4" on C keys (octave landmarks), plain letters elsewhere.
    static func keyLabelText(for key: KeyboardLayout.Key) -> String {
        key.noteName.hasPrefix("C") ? key.noteName : String(key.noteName.prefix(1))
    }

    @discardableResult
    private static func bakeIfNeeded(_ text: String, style: Style) -> UIImage {
        let id = "\(style.rawValue):\(text)"
        lock.lock()
        if let hit = cache[id] { lock.unlock(); return hit }
        lock.unlock()

        let size = CGSize(width: 128, height: 64)
        let fontSize: CGFloat = style == .note ? 40 : 38
        let alpha: CGFloat = style == .note ? 1.0 : (text.count > 1 ? 0.95 : 0.70)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let shadow = NSShadow()
            shadow.shadowColor = UIColor(white: 0, alpha: 0.85)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = .zero
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: UIColor(white: 1, alpha: alpha),
                .paragraphStyle: para,
                .shadow: shadow,
            ]
            let h = UIFont.systemFont(ofSize: fontSize, weight: .heavy).lineHeight
            (text as NSString).draw(in: CGRect(x: 0, y: (size.height - h) / 2,
                                               width: size.width, height: h),
                                    withAttributes: attrs)
        }
        lock.lock()
        cache[id] = img
        lock.unlock()
        return img
    }
}

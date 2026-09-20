import Combine
import Foundation
import UIKit

/// Panel text size. Everything on the panel is drawn from one type scale, so
/// a single multiplier moves all of it at once.
///
/// This matters more here than on a phone held at arm's length: the panel is
/// seen through two plastic lenses that blur the edges of every glyph, and a
/// size that reads fine on a monitor can be unreadable in the shell.
enum TextSize: String, CaseIterable {
    case normal, large, huge

    var label: String {
        switch self {
        case .normal: return "NORMAL"
        case .large:  return "LARGE"
        case .huge:   return "HUGE"
        }
    }

    var scale: CGFloat {
        switch self {
        case .normal: return 1.00
        case .large:  return 1.16
        case .huge:   return 1.32
        }
    }

    var next: TextSize {
        switch self {
        case .normal: return .large
        case .large:  return .huge
        case .huge:   return .normal
        }
    }
}

/// How long the cursor must rest on a control before it fires by itself.
///
/// Pinching is the fast way to select, but it is also the way that fails:
/// the hands sit at the bottom edge of the camera, half occluding
/// themselves, and a pinch that the tracker never sees is a control that
/// cannot be pressed at all. Dwell is the path that always works, so it is
/// adjustable rather than fixed — and can be turned off for anyone whose
/// hands drift and who would otherwise trigger things by accident.
enum DwellSpeed: String, CaseIterable {
    case fast, medium, slow, off

    var label: String {
        switch self {
        case .fast:   return "FAST  0.35s"
        case .medium: return "MEDIUM  0.6s"
        case .slow:   return "SLOW  1.1s"
        case .off:    return "OFF (PINCH ONLY)"
        }
    }

    /// nil = never fire on dwell.
    var seconds: TimeInterval? {
        switch self {
        case .fast:   return 0.35
        case .medium: return 0.60
        case .slow:   return 1.10
        case .off:    return nil
        }
    }

    var next: DwellSpeed {
        switch self {
        case .fast:   return .medium
        case .medium: return .slow
        case .slow:   return .off
        case .off:    return .fast
        }
    }
}

/// Value copy for the render thread — the panel is laid out and drawn off
/// the main thread's settings object, so it needs a snapshot it can compare.
struct AccessibilitySnapshot: Equatable {
    var textSize: TextSize
    var highContrast: Bool
    var dwell: DwellSpeed
    var colorBlindSafe: Bool

    static let `default` = AccessibilitySnapshot(textSize: .normal,
                                                 highContrast: false,
                                                 dwell: .fast,
                                                 colorBlindSafe: false)
}

/// Accessibility options, persisted in UserDefaults.
///
/// Separate from ComfortSettings on purpose: comfort is about not feeling
/// sick, this is about being able to read and hit things at all.
final class AccessibilitySettings: ObservableObject {
    @Published private(set) var textSize: TextSize
    @Published private(set) var highContrast: Bool
    @Published private(set) var dwell: DwellSpeed
    @Published private(set) var colorBlindSafe: Bool

    private enum Key {
        static let textSize     = "a11y.textSize"
        static let contrast     = "a11y.highContrast"
        static let dwell        = "a11y.dwell"
        static let colorBlind   = "a11y.colorBlindSafe"
    }

    init() {
        let d = UserDefaults.standard
        textSize       = TextSize(rawValue: d.string(forKey: Key.textSize) ?? "") ?? .normal
        highContrast   = d.bool(forKey: Key.contrast)
        dwell          = DwellSpeed(rawValue: d.string(forKey: Key.dwell) ?? "") ?? .fast
        colorBlindSafe = d.bool(forKey: Key.colorBlind)
        NoteHighway.setPalette(colorBlindSafe: colorBlindSafe)
    }

    var snapshot: AccessibilitySnapshot {
        AccessibilitySnapshot(textSize: textSize, highContrast: highContrast,
                              dwell: dwell, colorBlindSafe: colorBlindSafe)
    }

    func cycleTextSize() {
        textSize = textSize.next
        UserDefaults.standard.set(textSize.rawValue, forKey: Key.textSize)
    }

    func toggleContrast() {
        highContrast.toggle()
        UserDefaults.standard.set(highContrast, forKey: Key.contrast)
    }

    func cycleDwell() {
        dwell = dwell.next
        UserDefaults.standard.set(dwell.rawValue, forKey: Key.dwell)
    }

    func toggleColorBlindSafe() {
        colorBlindSafe.toggle()
        UserDefaults.standard.set(colorBlindSafe, forKey: Key.colorBlind)
        NoteHighway.setPalette(colorBlindSafe: colorBlindSafe)
    }

    func reset() {
        textSize = .normal; highContrast = false; dwell = .fast; colorBlindSafe = false
        let d = UserDefaults.standard
        d.set(textSize.rawValue, forKey: Key.textSize)
        d.set(false, forKey: Key.contrast)
        d.set(dwell.rawValue, forKey: Key.dwell)
        d.set(false, forKey: Key.colorBlind)
        NoteHighway.setPalette(colorBlindSafe: false)
    }
}

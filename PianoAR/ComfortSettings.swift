import Combine
import Foundation

/// How the tracked hands are drawn. Your real hands are already visible in
/// the passthrough, so a full skeleton on top of them is mostly jittery
/// clutter; fingertip dots are enough to show tracking is working.
enum HandStyle: String, CaseIterable {
    case fingertips, skeleton, hidden

    var label: String {
        switch self {
        case .fingertips: return "FINGERTIPS"
        case .skeleton:   return "SKELETON"
        case .hidden:     return "HIDDEN"
        }
    }

    var next: HandStyle {
        switch self {
        case .fingertips: return .skeleton
        case .skeleton:   return .hidden
        case .hidden:     return .fingertips
        }
    }
}

/// What to ask the display for.
///
/// The panel is 120 Hz LTPO and the A18 Pro can usually feed it, but the
/// phone is sealed inside a cardboard shell with no airflow while running
/// ARKit, Vision, a camera and an FFT. When iOS decides it has had enough it
/// throttles *suddenly*, and a frame rate that falls off a cliff mid-practice
/// is itself a motion-sickness cue — so AUTO gives up a tier at a time as the
/// phone heats, long before iOS does it for us.
enum FrameRateCap: String, CaseIterable {
    case auto, hz120, hz90, hz60

    var label: String {
        switch self {
        case .auto:  return "AUTO (120 → 60)"
        case .hz120: return "120 Hz"
        case .hz90:  return "90 Hz"
        case .hz60:  return "60 Hz"
        }
    }

    /// The most this setting will ever ask for.
    var ceiling: Int {
        switch self {
        case .auto, .hz120: return 120
        case .hz90:         return 90
        case .hz60:         return 60
        }
    }

    /// AUTO is the only mode that steps down on heat; an explicit pick is
    /// still held back from a *critical* state, which is a thermal emergency
    /// rather than a preference.
    var followsThermals: Bool { self == .auto }

    var next: FrameRateCap {
        switch self {
        case .auto:  return .hz120
        case .hz120: return .hz90
        case .hz90:  return .hz60
        case .hz60:  return .auto
        }
    }
}

enum StereoMode: String {
    /// Two AR views, each rendering the shared scene (always works).
    case dual
    /// One AR view whose output is duplicated for the second eye by the
    /// compositor (half the GPU work → cooler phone, steadier frame rate).
    case replicated
}

/// Value copy of the comfort settings for the render thread / layout.
struct ComfortSnapshot: Equatable {
    var viewScale: Double
    var lensSpacingMM: Double
    var motionSmoothing: Bool
    var stereoMode: StereoMode
    var handStyle: HandStyle
    var frameRate: FrameRateCap

    static let `default` = ComfortSnapshot(viewScale: ComfortSettings.defaultViewScale,
                                           lensSpacingMM: ComfortSettings.defaultLensSpacingMM,
                                           motionSmoothing: true,
                                           stereoMode: .dual,
                                           handStyle: .fingertips,
                                           frameRate: .auto)
}

/// Headset comfort settings — the main motion-sickness levers — persisted
/// in UserDefaults.
///
/// * **View size**: how tall each eye's camera image is, as a fraction of
///   the screen height. Filling the whole half-screen (the old behaviour)
///   magnifies the world ~1.5× through the lenses, so every head turn moves
///   the image faster than your inner ear expects — the biggest single
///   sickness trigger. The right value makes things look life-size and the
///   world stay put when you turn your head.
/// * **Lens spacing**: each eye's image must be centred on its lens, or
///   your eyes are forced to diverge/cross to fuse them (eye strain,
///   double vision, nausea).
/// * **Motion smoothing**: 120 Hz gyro re-projection, see MotionWarp.
final class ComfortSettings: ObservableObject {
    // 1:1 scale is screen px per camera px = 18.11 px/mm · D_eff / fx. With a
    // ~42 mm effective lens distance and fx ≈ 1366 (16 Pro, 1920×1440) that
    // is 0.557 → an 802 px (267 pt) tall eye image = 0.66 of the screen
    // height. The old full-height layout was ~1.5× magnified.
    static let defaultViewScale = 0.66
    // Cardboard-class viewers put their lenses 60–64 mm apart; the VR-20's
    // lenses slide, so set them to your eyes first, then match this.
    static let defaultLensSpacingMM = 63.0
    static let viewScaleRange = 0.40...1.00
    static let lensSpacingRange = 54.0...72.0

    @Published private(set) var snapshot: ComfortSnapshot

    private static let storeKey = "comfort.v1"

    init() {
        var s = ComfortSnapshot.default
        if let d = UserDefaults.standard.dictionary(forKey: Self.storeKey) {
            if let v = d["viewScale"] as? Double { s.viewScale = v }
            if let v = d["lensSpacingMM"] as? Double { s.lensSpacingMM = v }
            if let v = d["motionSmoothing"] as? Bool { s.motionSmoothing = v }
            if let v = (d["stereoMode"] as? String).flatMap(StereoMode.init(rawValue:)) { s.stereoMode = v }
            if let v = (d["handStyle"] as? String).flatMap(HandStyle.init(rawValue:)) { s.handStyle = v }
            if let v = (d["frameRate"] as? String).flatMap(FrameRateCap.init(rawValue:)) { s.frameRate = v }
        }
        s.viewScale = Self.clamp(s.viewScale, Self.viewScaleRange)
        s.lensSpacingMM = Self.clamp(s.lensSpacingMM, Self.lensSpacingRange)
        snapshot = s
    }

    func adjustViewScale(by delta: Double) {
        update { $0.viewScale = Self.clamp((($0.viewScale + delta) * 100).rounded() / 100, Self.viewScaleRange) }
    }

    func adjustLensSpacing(by delta: Double) {
        update { $0.lensSpacingMM = Self.clamp($0.lensSpacingMM + delta, Self.lensSpacingRange) }
    }

    func toggleMotionSmoothing() { update { $0.motionSmoothing.toggle() } }

    func toggleStereoMode() {
        update { $0.stereoMode = $0.stereoMode == .dual ? .replicated : .dual }
    }

    func cycleHandStyle() { update { $0.handStyle = $0.handStyle.next } }

    func cycleFrameRate() { update { $0.frameRate = $0.frameRate.next } }

    func resetViewDefaults() {
        update {
            $0.viewScale = Self.defaultViewScale
            $0.lensSpacingMM = Self.defaultLensSpacingMM
        }
    }

    private func update(_ change: (inout ComfortSnapshot) -> Void) {
        var s = snapshot
        change(&s)
        guard s != snapshot else { return }
        snapshot = s
        UserDefaults.standard.set([
            "viewScale": s.viewScale,
            "lensSpacingMM": s.lensSpacingMM,
            "motionSmoothing": s.motionSmoothing,
            "stereoMode": s.stereoMode.rawValue,
            "handStyle": s.handStyle.rawValue,
            "frameRate": s.frameRate.rawValue,
        ], forKey: Self.storeKey)
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(r.upperBound, max(r.lowerBound, v))
    }
}

/// Tiny lock-protected box for values shared between the main thread and
/// the SceneKit render thread.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

import Foundation
import simd
import Vision

final class GestureDetector {
    // ── Single-hand "hold still to confirm" point picker ────────────────────
    // Used wherever a screen tap would normally pick a world point (virtual-
    // keyboard placement, real-piano corner calibration) — the phone is inside
    // a headset shell, so the screen isn't reachable. Pinch-based two-hand
    // confirm turned out unreliable (thumb/index landmarks are noisy at close
    // range, and coordinating two hands blind is awkward), so this matches the
    // AR menu's own dwell-click instead: whichever hand is available becomes
    // the pointer, and holding its fingertip roughly still for `dwellTime`
    // confirms that point. Single hand, no pinch distance measurement at all.
    private static let stillRadius: Float        = 0.014   // 14mm — must hold within this
    private static let dwellTime:   TimeInterval = 0.6

    private var anchor:   SIMD3<Float>?  = nil
    private var start:    TimeInterval   = 0
    private var fired:    Bool           = false
    private var handIsLeft: Bool?        = nil

    /// Call once per render frame. Returns the current candidate point (for a
    /// live reticle) and whether it was just confirmed (fires once per dwell).
    /// `progress` is 0…1 dwell fill, for visual feedback.
    func dwellPick(hands: [HandTracker.HandResult],
                   time: TimeInterval) -> (point: SIMD3<Float>?, progress: Float, confirmed: Bool) {
        // Prefer continuing with whichever hand we were already tracking, so the
        // reticle doesn't jump if a second hand briefly enters frame.
        var hand: HandTracker.HandResult? = nil
        if let cur = handIsLeft { hand = hands.first { $0.isLeft == cur } }
        if hand == nil { hand = hands.first { $0.joints[.indexTip] != nil } }
        handIsLeft = hand?.isLeft

        guard let tip = hand?.joints[.indexTip] else {
            anchor = nil; fired = false
            return (nil, 0, false)
        }

        if let a = anchor, simd_length(tip - a) < Self.stillRadius {
            // Still within the settle radius — keep accumulating dwell time.
        } else {
            anchor = tip
            start  = time
            fired  = false
        }

        let progress = Float(simd_clamp((time - start) / Self.dwellTime, 0, 1))
        var confirmed = false
        if !fired, progress >= 1.0 {
            fired = true
            confirmed = true
        }
        return (tip, progress, confirmed)
    }
}

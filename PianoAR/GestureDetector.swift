import Foundation
import simd
import Vision

struct PinchEvent {
    let worldPosition: SIMD3<Float>
    let isLeft: Bool
    let timestamp: TimeInterval
}

final class GestureDetector {
    // Distance thresholds (metres)
    private let onThreshold:  Float = 0.030
    private let offThreshold: Float = 0.050
    // Minimum time between consecutive pinches on the same hand
    private let debounce: TimeInterval = 0.22

    private var pinching:      [String: Bool]          = [:]
    private var lastPinchTime: [String: TimeInterval]  = [:]
    private var pointingIsLeft: Bool? = nil

    // Call once per render frame. Returns any new pinch-began events.
    func update(hands: [HandTracker.HandResult],
                time: TimeInterval) -> [PinchEvent] {
        var events: [PinchEvent] = []

        for hand in hands {
            let side = hand.isLeft ? "L" : "R"
            guard let thumb = hand.joints[.thumbTip],
                  let index = hand.joints[.indexTip] else {
                pinching[side] = false
                continue
            }

            let dist      = simd_length(thumb - index)
            let wasPinch  = pinching[side] ?? false

            if dist < onThreshold, !wasPinch {
                let last = lastPinchTime[side] ?? -999
                guard time - last > debounce else { continue }
                pinching[side]      = true
                lastPinchTime[side] = time
                events.append(PinchEvent(
                    worldPosition: (thumb + index) * 0.5,
                    isLeft: hand.isLeft,
                    timestamp: time
                ))
            } else if dist > offThreshold {
                pinching[side] = false
            }
        }

        return events
    }

    // True while the pinch is currently held (for hover / drag use).
    func isPinching(hand: String) -> Bool { pinching[hand] ?? false }

    // World-space midpoint of thumb+index for a given hand, if available.
    func pinchMidpoint(for hands: [HandTracker.HandResult],
                       isLeft: Bool) -> SIMD3<Float>? {
        guard let hand = hands.first(where: { $0.isLeft == isLeft }),
              let thumb = hand.joints[.thumbTip],
              let index = hand.joints[.indexTip]
        else { return nil }
        return (thumb + index) * 0.5
    }

    /// Two-handed "point and confirm", used wherever a screen tap would normally
    /// pick a world point (virtual-keyboard placement, real-piano corner
    /// calibration) — but the phone is inside a headset shell, so the screen
    /// isn't reachable at all. Instead: one hand's index fingertip IS the point
    /// (its 3D world position already comes from LiDAR via HandTracker, so no
    /// raycast is needed), and a pinch on the OTHER hand confirms it.
    ///
    /// The pointing-hand assignment is sticky across frames (stored in
    /// `pointingIsLeft`) so the reticle doesn't jump between hands frame to
    /// frame; it only reassigns when the current pointing hand disappears or
    /// itself starts pinching (which reads as "that hand just became the
    /// confirm hand instead").
    func pointAndConfirm(hands: [HandTracker.HandResult],
                         time: TimeInterval) -> (point: SIMD3<Float>?, confirmed: Bool) {
        let events = update(hands: hands, time: time)

        func usable(_ isLeft: Bool) -> HandTracker.HandResult? {
            guard let h = hands.first(where: { $0.isLeft == isLeft }),
                  h.joints[.indexTip] != nil,
                  !isPinching(hand: isLeft ? "L" : "R") else { return nil }
            return h
        }

        var pointHand: HandTracker.HandResult? = nil
        if let cur = pointingIsLeft, let h = usable(cur) {
            pointHand = h
        } else {
            // Default to the right hand pointing (left hand confirms) when both
            // are free — an arbitrary but consistent starting convention.
            pointHand = usable(false) ?? usable(true)
        }
        pointingIsLeft = pointHand?.isLeft

        let point = pointHand?.joints[.indexTip]
        let confirmed = events.contains { ev in
            guard let pIsLeft = pointingIsLeft else { return false }
            return ev.isLeft != pIsLeft
        }
        return (point, confirmed)
    }
}

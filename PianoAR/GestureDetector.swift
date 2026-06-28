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
}

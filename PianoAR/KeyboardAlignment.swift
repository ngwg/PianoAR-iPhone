import Foundation
import simd

/// Fine placement on top of the keyboard mapping (SETUP › ALIGN), so the
/// overlay can be moved exactly onto the real keys from inside the headset.
/// Keyboard-local axes: x along the keys (low → high), z toward the player,
/// y up.
struct KeyboardAlignment: Equatable {
    var x: Float = 0            // metres
    var z: Float = 0
    var y: Float = 0
    var yaw: Float = 0          // radians, around the keyboard centre
    var width: Float = 1        // multiplies the mapped keyboard width

    enum Adjust {
        case moveX(Float), moveZ(Float), moveY(Float), rotate(Float), width(Float), reset
    }

    static let slideStep: Float = 0.005                     // 5 mm per press
    static let keyStep: Float = KeyboardLayout.whiteKeyWidth // a whole key
    static let heightStep: Float = 0.002
    static let widthStep: Float = 0.005                     // 0.5 %
    static let turnStep: Float = 0.5 * .pi / 180            // 0.5°

    mutating func apply(_ adjust: Adjust) {
        switch adjust {
        case .moveX(let d):  x = Self.clamp(x + d, 0.30)
        case .moveZ(let d):  z = Self.clamp(z + d, 0.10)
        case .moveY(let d):  y = Self.clamp(y + d, 0.05)
        case .rotate(let d): yaw = Self.clamp(yaw + d, 0.20)
        case .width(let d):  width = min(1.15, max(0.85, width + d))
        case .reset:         self = KeyboardAlignment()
        }
    }

    private static func clamp(_ v: Float, _ limit: Float) -> Float { min(limit, max(-limit, v)) }

    var readout: String {
        String(format: "slide %+.0f mm · depth %+.0f mm · height %+.0f mm · width %.1f%% · turn %+.1f°",
               x * 1000, z * 1000, y * 1000, width * 100, yaw * 180 / Float.pi)
    }
}

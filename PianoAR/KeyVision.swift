import ARKit
import Foundation
import simd

/// Watching the keys themselves, rather than the fingers or the sound.
///
/// Jop's idea, and it attacks the problem exactly where audio is weakest: a
/// key is **spatially unambiguous**. Every failure that has dogged the
/// microphone — octave errors, semitone confusion, a bass note arriving as
/// its own tenth harmonic, one note masking another — simply does not exist
/// when you are looking at which piece of wood moved. It is also instant
/// (one camera frame, ~16 ms, against ~340 ms for a spectral verdict) and it
/// works the same at both ends of the keyboard.
///
/// The obvious objection is that a finger covers the key it presses. But the
/// part that moves most is the key's **front edge**, which drops about 10 mm
/// and sits below and in front of the fingertip, and the shadow in the gap
/// beside the key deepens as it tilts. Those are what this samples.
///
/// **This ships as measurement only.** It extracts a signal per key and
/// writes it to the diagnostics log; nothing depends on it yet. Everything
/// that went wrong with the audio detector went wrong because it was built
/// from reasoning and shipped before it was measured, so this one gets
/// measured on a real recording from Jop's own headset first.
final class KeyVision {
    /// One key's visual state this frame.
    struct Sample {
        var brightness: Float = 0      // mean luma over the key's front strip
        var baseline: Float = 0        // slow average — what "at rest" looks like
        var drop: Float = 0            // baseline - brightness, in luma units
        var visible: Bool = false
    }

    private(set) var samples = [Sample](repeating: Sample(), count: 88)
    private var lastRun: TimeInterval = 0
    private let interval: TimeInterval = 1.0 / 30.0
    /// How fast the at-rest brightness follows the scene. Slow, so a held key
    /// stays "pressed" rather than fading into the background, but not so slow
    /// that walking into a shadow ruins everything.
    private let baselineRate: Float = 0.02

    /// Samples every key's front strip in the camera image.
    /// - Parameter keyboard: the node whose local space the key layout lives
    ///   in (key tops at y = whiteKeyHeight).
    func update(frame: ARFrame, keyboard: SCNNode, time: TimeInterval,
                orientation: CGImagePropertyOrientation) {
        guard time - lastRun >= interval else { return }
        lastRun = time

        let pixels = frame.capturedImage
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let camera = frame.camera
        let size = CGSize(width: w, height: h)

        for k in 0..<88 {
            let key = KeyboardLayout.keys[k]
            // The front strip of the key: the last 15 mm of its depth, at the
            // key top. This is the part that swings down when pressed and the
            // part a finger is least likely to be covering.
            let x = key.xCenter - KeyboardLayout.totalWidth / 2
            let y = KeyboardLayout.whiteKeyHeight
            let zFront = key.isBlack ? -KeyboardLayout.whiteKeyDepth * 0.25
                                     : -KeyboardLayout.whiteKeyDepth * 0.06
            var sum: Float = 0
            var n = 0
            // A few points across the key's width, so one speck of dust or a
            // specular highlight cannot swing it.
            let halfWidth = (key.isBlack ? KeyboardLayout.whiteKeyWidth * 0.28
                                         : KeyboardLayout.whiteKeyWidth * 0.36)
            for dx in [-halfWidth, 0, halfWidth] {
                for dz in [Float(0), -0.010] {
                    let local = SCNVector3(x + dx, y, zFront + dz)
                    let world = keyboard.convertPosition(local, to: nil)
                    let p = camera.projectPoint(SIMD3<Float>(world.x, world.y, world.z),
                                                orientation: .landscapeRight,
                                                viewportSize: size)
                    let px = Int(p.x), py = Int(p.y)
                    guard px >= 1, px < w - 1, py >= 1, py < h - 1 else { continue }
                    sum += Float(luma[py * stride + px])
                    n += 1
                }
            }
            var s = samples[k]
            if n == 0 {
                s.visible = false
            } else {
                s.visible = true
                s.brightness = sum / Float(n)
                if s.baseline == 0 {
                    s.baseline = s.brightness
                } else {
                    s.baseline += (s.brightness - s.baseline) * baselineRate
                }
                s.drop = s.baseline - s.brightness
            }
            samples[k] = s
        }
    }

    /// The keys whose front strip has darkened most — a pressed key tilts away
    /// from the light and its gap deepens, so a press should read as a drop.
    func rankedDrops(limit: Int = 6) -> [(key: Int, drop: Float)] {
        samples.indices
            .filter { samples[$0].visible }
            .map { (key: $0, drop: samples[$0].drop) }
            .sorted { $0.drop > $1.drop }
            .prefix(limit)
            .map { $0 }
    }
}

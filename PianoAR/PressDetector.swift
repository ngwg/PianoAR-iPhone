import SceneKit
import Vision
import simd

struct PressEvent {
    let keyIndex: Int
    let noteName: String
    let confidence: Float
    let fingerID: String
    let timestamp: TimeInterval
}

final class PressDetector: ObservableObject {
    @Published var lastDetected: String = ""
    @Published var fingerDebugLines: [String] = []

    // Tunable thresholds — start conservative, tighten with real-device testing.
    private let pressDepth: Float = 0.008         // 8 mm below key surface → press
    private let minDescendVel: Float = -0.001     // m/frame downward to enter "descending"
    private let debounceInterval: TimeInterval = 0.18
    private let historyCount = 12
    private let flashRetain: TimeInterval = 2.0   // keep recent presses for UI

    // Per-finger tracking
    enum Phase: String { case idle, descending, pressed }

    private struct FingerTrack {
        var yHistory: [Float] = []
        var phase: Phase = .idle
        var lastPressTime: TimeInterval = 0
    }

    private var fingers: [String: FingerTrack] = [:]
    private var recentPresses: [PressEvent] = []
    private var lastDebugUpdate: TimeInterval = 0

    private static let tips: [(VNHumanHandPoseObservation.JointName, String)] = [
        (.thumbTip,  "thumb"),
        (.indexTip,  "index"),
        (.middleTip, "middle"),
        (.ringTip,   "ring"),
        (.littleTip, "little"),
    ]

    // MARK: - Render-thread entry point

    /// Call from `renderer(_:updateAtTime:)`. Returns newly detected presses this frame.
    func update(hands: [HandTracker.HandResult],
                keyboardNode: SCNNode?,
                time: TimeInterval) -> [PressEvent] {
        guard let kb = keyboardNode else { return [] }

        var newPresses: [PressEvent] = []
        var seen = Set<String>()
        var debugLines: [String] = []

        for hand in hands {
            let side = hand.isLeft ? "L" : "R"

            for (joint, fingerName) in Self.tips {
                guard let worldPos = hand.joints[joint] else { continue }
                let fid = "\(side)_\(fingerName)"
                seen.insert(fid)

                // World → keyboard-local (handles anchor position, rotation, and scale)
                let local = kb.simdConvertPosition(worldPos, from: nil)

                var track = fingers[fid] ?? FingerTrack()

                // Y history ring buffer
                track.yHistory.append(local.y)
                if track.yHistory.count > historyCount {
                    track.yHistory.removeFirst()
                }

                // Which key is this finger over?
                let key = findKey(localX: local.x, localZ: local.z)
                let surfaceY: Float = (key?.isBlack == true)
                    ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
                    : KeyboardLayout.whiteKeyHeight
                let depth = local.y - surfaceY   // negative = below surface

                // Smoothed velocity over 3 frames
                let vel: Float
                if track.yHistory.count >= 3 {
                    let h = track.yHistory
                    vel = (h[h.count - 1] - h[h.count - 3]) / 2.0
                } else {
                    vel = 0
                }

                // ── State machine ──────────────────────────────────────────
                switch track.phase {
                case .idle:
                    // Start tracking a potential press when finger moves toward surface
                    if vel < minDescendVel && depth < 0.025 {
                        track.phase = .descending
                    }

                case .descending:
                    // Finger crossed below the key surface by pressDepth
                    if depth < -pressDepth {
                        // Deceleration check: velocity was fast-negative, now slower
                        let h = track.yHistory
                        let prevVel = h.count >= 4
                            ? (h[h.count - 2] - h[h.count - 4]) / 2.0
                            : vel
                        let decelerated = vel > prevVel * 0.4

                        if let k = key,
                           (decelerated || depth < -pressDepth * 2.5),
                           time - track.lastPressTime > debounceInterval {
                            let conf = min(1.0, abs(depth) / 0.020)
                            newPresses.append(PressEvent(
                                keyIndex: k.index,
                                noteName: k.noteName,
                                confidence: conf,
                                fingerID: fid,
                                timestamp: time
                            ))
                            track.phase = .pressed
                            track.lastPressTime = time
                        }
                    }
                    // Finger retreated without reaching threshold
                    if vel > 0.001 && depth > 0.005 {
                        track.phase = .idle
                    }

                case .pressed:
                    // Wait for finger to lift back above surface
                    if depth > pressDepth * 0.5 {
                        track.phase = .idle
                    }
                }

                fingers[fid] = track

                let keyName = key?.noteName ?? "—"
                let depthMM = String(format: "%+.1f", depth * 1000)
                debugLines.append("\(fid) \(depthMM)mm \(track.phase.rawValue) [\(keyName)]")
            }
        }

        // Clear fingers no longer tracked
        for fid in fingers.keys where !seen.contains(fid) {
            fingers[fid] = FingerTrack()
        }

        // Maintain recent-press window
        recentPresses.append(contentsOf: newPresses)
        recentPresses.removeAll { time - $0.timestamp > flashRetain }

        // Throttled debug updates → main thread (~10 Hz)
        if time - lastDebugUpdate > 0.1 {
            lastDebugUpdate = time
            let detected: String
            if !newPresses.isEmpty {
                detected = newPresses.map(\.noteName).joined(separator: " ")
            } else if let last = recentPresses.last, time - last.timestamp < 1.5 {
                detected = last.noteName
            } else {
                detected = ""
            }
            let dbg = debugLines
            DispatchQueue.main.async { [weak self] in
                self?.lastDetected = detected
                self?.fingerDebugLines = dbg
            }
        }

        return newPresses
    }

    func reset() {
        fingers.removeAll()
        recentPresses.removeAll()
    }

    // MARK: - Key lookup from keyboard-local coordinates

    private func findKey(localX: Float, localZ: Float) -> KeyboardLayout.Key? {
        let leftEdge = -KeyboardLayout.totalWidth / 2
        let relX = localX - leftEdge
        guard relX >= -0.01, relX <= KeyboardLayout.totalWidth + 0.01 else { return nil }

        // Black keys exist only in the far-Z region of the keyboard
        let blackZStart = -(KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2
        if localZ < blackZStart + KeyboardLayout.blackKeyDepth * 0.4 {
            let halfW = KeyboardLayout.blackKeyWidth / 2
            for key in KeyboardLayout.keys where key.isBlack {
                if abs(relX - key.xCenter) < halfW { return key }
            }
        }

        let halfW = KeyboardLayout.whiteKeyWidth / 2
        for key in KeyboardLayout.keys where !key.isBlack {
            if abs(relX - key.xCenter) < halfW { return key }
        }
        return nil
    }
}

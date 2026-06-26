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
    private let keyLockoutInterval: TimeInterval = 0.24
    private let historyCount = 12
    private let flashRetain: TimeInterval = 2.0   // keep recent presses for UI
    private let guidedAttackWindow: TimeInterval = 0.20
    private let guidedMaxHover: Float = 0.120
    private let guidedMaxBelow: Float = 0.045
    private let guidedKeyXTolerance: Float = 0.010
    private let guidedKeyZTolerance: Float = 0.030

    // Per-finger tracking
    enum Phase: String { case idle, descending, pressed }

    private struct FingerTrack {
        var yHistory: [Float] = []
        var phase: Phase = .idle
        var lastPressTime: TimeInterval = 0
    }

    private struct FingerCandidate {
        let key: KeyboardLayout.Key
        let fingerID: String
        let score: Float
    }

    private var fingers: [String: FingerTrack] = [:]
    private var recentPresses: [PressEvent] = []
    private var lastKeyPressTime: [TimeInterval] = .init(repeating: -999, count: 88)
    private var lastGuidedAttackTime: TimeInterval = -999
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
                time: TimeInterval,
                audioSnapshot: PitchSnapshot? = nil,
                expectedKeyIndices: Set<Int> = [],
                keyTuning: KeyTuning? = nil) -> [PressEvent] {
        guard let kb = keyboardNode else { return [] }

        var newPresses: [PressEvent] = []
        var seen = Set<String>()
        var debugLines: [String] = []
        var guidedCandidates: [FingerCandidate] = []
        let guidedPractice = !expectedKeyIndices.isEmpty

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
                let key = findKey(localX: local.x, localZ: local.z, keyTuning: keyTuning)
                let guidedKey = expectedGuidedKey(
                    localX: local.x,
                    localZ: local.z,
                    expectedKeyIndices: expectedKeyIndices,
                    keyTuning: keyTuning
                ) ?? findKey(
                    localX: local.x,
                    localZ: local.z,
                    extraX: guidedKeyXTolerance,
                    extraZ: guidedKeyZTolerance,
                    keyTuning: keyTuning
                )
                let micBoost = key.map {
                    audioBoost(
                        for: $0.index,
                        snapshot: audioSnapshot,
                        time: time,
                        expectedKeyIndices: expectedKeyIndices
                    )
                } ?? 0
                let surfaceY: Float = (key?.isBlack == true)
                    ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
                    : KeyboardLayout.whiteKeyHeight
                let depth = local.y - surfaceY   // negative = below surface

                if let candidate = makeGuidedCandidate(
                    key: guidedKey,
                    fingerID: fid,
                    localY: local.y,
                    expectedKeyIndices: expectedKeyIndices
                ) {
                    guidedCandidates.append(candidate)
                }

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
                    if vel < minDescendVel && depth < 0.025 {
                        track.phase = .descending
                    }

                case .descending:
                    if depth < -pressDepth {
                        let h = track.yHistory
                        let prevVel = h.count >= 4
                            ? (h[h.count - 2] - h[h.count - 4]) / 2.0
                            : vel
                        let decelerated = vel > prevVel * 0.4

                        if !guidedPractice,
                           let k = key,
                           (decelerated || depth < -pressDepth * 2.5),
                           time - track.lastPressTime > debounceInterval,
                           time - lastKeyPressTime[k.index] > keyLockoutInterval {
                            let baseConf = min(1.0, abs(depth) / 0.020)
                            let conf = min(1.0, baseConf + micBoost)
                            newPresses.append(PressEvent(
                                keyIndex: k.index,
                                noteName: k.noteName,
                                confidence: conf,
                                fingerID: fid,
                                timestamp: time
                            ))
                            track.phase = .pressed
                            track.lastPressTime = time
                            lastKeyPressTime[k.index] = time
                        }
                    }
                    if vel > 0.001 && depth > 0.005 {
                        track.phase = .idle
                    }

                case .pressed:
                    if depth > pressDepth * 0.5 {
                        track.phase = .idle
                    }
                }

                fingers[fid] = track

                let keyName = guidedKey?.noteName ?? key?.noteName ?? "-"
                let depthMM = String(format: "%+.1f", depth * 1000)
                let micTag = micBoost > 0 ? " mic+\(String(format: "%.2f", micBoost))" : ""
                let guidedTag = guidedKey != nil ? " armed" : ""
                debugLines.append("\(fid) \(depthMM)mm \(track.phase.rawValue) [\(keyName)]\(guidedTag)\(micTag)")
            }
        }

        let guided = guidedPressEvents(
            from: guidedCandidates,
            expectedKeyIndices: expectedKeyIndices,
            snapshot: audioSnapshot,
            time: time
        )
        newPresses.append(contentsOf: guided)

        for fid in fingers.keys where !seen.contains(fid) {
            fingers[fid] = FingerTrack()
        }

        recentPresses.append(contentsOf: newPresses)
        recentPresses.removeAll { time - $0.timestamp > flashRetain }

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
        lastKeyPressTime = .init(repeating: -999, count: 88)
        lastGuidedAttackTime = -999
    }

    // MARK: - Key lookup from keyboard-local coordinates

    private func findKey(localX: Float,
                         localZ: Float,
                         extraX: Float = 0.004,
                         extraZ: Float = 0.018,
                         keyTuning: KeyTuning? = nil) -> KeyboardLayout.Key? {
        let leftEdge = -KeyboardLayout.totalWidth / 2
        let relX = localX - leftEdge
        guard relX >= -extraX, relX <= KeyboardLayout.totalWidth + extraX else { return nil }

        let whiteZMin = -KeyboardLayout.whiteKeyDepth / 2 - extraZ
        let whiteZMax = KeyboardLayout.whiteKeyDepth / 2 + extraZ
        guard localZ >= whiteZMin, localZ <= whiteZMax else { return nil }

        let blackZCenter = -(KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2
        let blackZMin = blackZCenter - KeyboardLayout.blackKeyDepth / 2 - extraZ
        let blackZMax = blackZCenter + KeyboardLayout.blackKeyDepth / 2 + extraZ
        if localZ >= blackZMin, localZ <= blackZMax {
            let halfW = KeyboardLayout.blackKeyWidth / 2 + extraX
            let black = KeyboardLayout.keys
                .filter {
                    guard $0.isBlack else { return false }
                    let center = tunedXCenter(for: $0, keyTuning: keyTuning)
                    let tunedHalfW = halfW + tunedWidthExtra(for: $0, keyTuning: keyTuning)
                    return abs(relX - center) < tunedHalfW
                }
                .min {
                    abs(relX - tunedXCenter(for: $0, keyTuning: keyTuning))
                        < abs(relX - tunedXCenter(for: $1, keyTuning: keyTuning))
                }
            if let black {
                return black
            }
        }

        let halfW = KeyboardLayout.whiteKeyWidth / 2 + extraX
        return KeyboardLayout.keys
            .filter {
                guard !$0.isBlack else { return false }
                let center = tunedXCenter(for: $0, keyTuning: keyTuning)
                let tunedHalfW = halfW + tunedWidthExtra(for: $0, keyTuning: keyTuning)
                return abs(relX - center) < tunedHalfW
            }
            .min {
                abs(relX - tunedXCenter(for: $0, keyTuning: keyTuning))
                    < abs(relX - tunedXCenter(for: $1, keyTuning: keyTuning))
            }
    }

    private func expectedGuidedKey(localX: Float,
                                   localZ: Float,
                                   expectedKeyIndices: Set<Int>,
                                   keyTuning: KeyTuning? = nil) -> KeyboardLayout.Key? {
        guard !expectedKeyIndices.isEmpty else { return nil }

        let leftEdge = -KeyboardLayout.totalWidth / 2
        let relX = localX - leftEdge
        var best: (key: KeyboardLayout.Key, score: Float)?

        for index in expectedKeyIndices.sorted() {
            guard index >= 0, index < KeyboardLayout.keys.count else { continue }
            let key = KeyboardLayout.keys[index]

            if key.isBlack {
                let blackZCenter = -(KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2
                let center = tunedXCenter(for: key, keyTuning: keyTuning)
                let halfX = KeyboardLayout.blackKeyWidth / 2
                    + guidedKeyXTolerance
                    + tunedWidthExtra(for: key, keyTuning: keyTuning)
                let halfZ = KeyboardLayout.blackKeyDepth / 2 + guidedKeyZTolerance
                let dx = abs(relX - center)
                let dz = abs(localZ - blackZCenter)
                guard dx <= halfX, dz <= halfZ else { continue }
                let score = 1.0 - min(1.0, dx / halfX) * 0.70 - min(1.0, dz / halfZ) * 0.30
                if best == nil || score > best!.score {
                    best = (key, score)
                }
            } else {
                let center = tunedXCenter(for: key, keyTuning: keyTuning)
                let halfX = KeyboardLayout.whiteKeyWidth / 2
                    + 0.008
                    + tunedWidthExtra(for: key, keyTuning: keyTuning)
                let halfZ = KeyboardLayout.whiteKeyDepth / 2 + guidedKeyZTolerance
                let dx = abs(relX - center)
                let dz = abs(localZ)
                guard dx <= halfX, dz <= halfZ else { continue }
                let score = 1.0 - min(1.0, dx / halfX) * 0.78 - min(1.0, dz / halfZ) * 0.22
                if best == nil || score > best!.score {
                    best = (key, score)
                }
            }
        }

        return best?.key
    }

    private func tunedXCenter(for key: KeyboardLayout.Key,
                              keyTuning: KeyTuning?) -> Float {
        key.xCenter + (keyTuning?.xOffset(for: key.index) ?? 0)
    }

    private func tunedWidthExtra(for key: KeyboardLayout.Key,
                                 keyTuning: KeyTuning?) -> Float {
        Swift.max(-0.008, keyTuning?.widthExtra(for: key.index) ?? 0)
    }

    private func makeGuidedCandidate(key: KeyboardLayout.Key?,
                                     fingerID: String,
                                     localY: Float,
                                     expectedKeyIndices: Set<Int>) -> FingerCandidate? {
        guard let key else { return nil }
        let surfaceY: Float = key.isBlack
            ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
            : KeyboardLayout.whiteKeyHeight
        let depth = localY - surfaceY
        guard depth > -guidedMaxBelow, depth < guidedMaxHover else { return nil }

        let hover = max(0, depth)
        let verticalScore = 1.0 - min(1.0, hover / guidedMaxHover)
        let isExpected = expectedKeyIndices.contains(key.index)
        let targetBonus: Float = isExpected ? 0.18 : 0
        return FingerCandidate(
            key: key,
            fingerID: fingerID,
            score: 0.46 + verticalScore * 0.34 + targetBonus
        )
    }

    private func guidedPressEvents(from candidates: [FingerCandidate],
                                   expectedKeyIndices: Set<Int>,
                                   snapshot: PitchSnapshot?,
                                   time: TimeInterval) -> [PressEvent] {
        guard !expectedKeyIndices.isEmpty,
              let snapshot,
              let attack = snapshot.attack,
              abs(time - attack.timestamp) <= guidedAttackWindow,
              attack.timestamp - lastGuidedAttackTime > 0.001
        else { return [] }

        var selected: [FingerCandidate] = []
        var usedFingers = Set<String>()
        for keyIndex in expectedKeyIndices.sorted() {
            let candidate = candidates
                .filter { $0.key.index == keyIndex && !usedFingers.contains($0.fingerID) }
                .max { $0.score < $1.score }
            if let candidate {
                selected.append(candidate)
                usedFingers.insert(candidate.fingerID)
            }
        }

        if selected.isEmpty,
           let wrong = candidates
                .filter({ !expectedKeyIndices.contains($0.key.index) })
                .max(by: { $0.score < $1.score }) {
            selected = [wrong]
        }

        guard !selected.isEmpty else { return [] }

        lastGuidedAttackTime = attack.timestamp

        return selected.map { candidate in
            lastKeyPressTime[candidate.key.index] = time
            let pitchBonus: Float = snapshot.activeNotes.contains {
                abs($0.keyIndex - candidate.key.index) <= 1
            } ? 0.08 : 0
            let expectedBonus: Float = expectedKeyIndices.contains(candidate.key.index) ? 0.12 : 0
            let confidence = min(
                1.0,
                candidate.score + attack.confidence * 0.20 + pitchBonus + expectedBonus
            )

            return PressEvent(
                keyIndex: candidate.key.index,
                noteName: candidate.key.noteName,
                confidence: confidence,
                fingerID: candidate.fingerID,
                timestamp: time
            )
        }
    }

    private func audioBoost(for keyIndex: Int,
                            snapshot: PitchSnapshot?,
                            time: TimeInterval,
                            expectedKeyIndices: Set<Int>) -> Float {
        guard let snapshot,
              let attack = snapshot.attack,
              abs(time - attack.timestamp) <= 0.12
        else { return 0 }

        if !expectedKeyIndices.isEmpty,
           !expectedKeyIndices.contains(keyIndex) {
            return 0
        }

        let pitchMatchesExpected = snapshot.activeNotes.contains {
            abs($0.keyIndex - keyIndex) <= 1
        }
        if pitchMatchesExpected {
            return 0.16 + attack.confidence * 0.18
        }
        return 0.06 + attack.confidence * 0.10
    }
}

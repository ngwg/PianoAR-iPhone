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

    // ── Non-guided (depth + trajectory) ──────────────────────────────────
    private let pressDepth:        Float    = 0.008
    private let minDescendVel:     Float    = -0.001
    private let debounceInterval:  TimeInterval = 0.18
    private let keyLockoutInterval: TimeInterval = 0.24
    private let historyCount = 12
    private let flashRetain:       TimeInterval = 2.0

    // ── Guided (audio-primary) ────────────────────────────────────────────
    // Window after an audio onset timestamp during which we accept a press.
    private let guidedAttackWindow:  TimeInterval = 0.22
    // Minimum onset confidence to fire — raise to cut false positives.
    private let guidedMinAttackConf: Float = 0.28
    // Pitch hint tolerance: ±N semitones of expected key counts as a match.
    private let pitchSemitoneWindow: Int   = 3
    // Keyboard presence check — Y range around key surface.
    private let kbAreaYMin:          Float = -0.06
    private let kbAreaYMax:          Float =  0.10
    // Extra Z tolerance beyond standard key depth.
    private let kbAreaZExtra:        Float =  0.040

    // ── State ─────────────────────────────────────────────────────────────

    enum Phase: String { case idle, descending, pressed }
    private struct FingerTrack {
        var yHistory:      [Float] = []
        var phase:         Phase   = .idle
        var lastPressTime: TimeInterval = 0
    }
    private struct FingertipLocal {
        let fingerID: String
        let localX:   Float
        let localY:   Float
        let localZ:   Float
    }

    private var fingers:          [String: FingerTrack] = [:]
    private var recentPresses:    [PressEvent]          = []
    private var lastKeyPressTime: [TimeInterval]        = .init(repeating: -999, count: 88)
    private var lastGuidedAttackTime: TimeInterval      = -999
    private var lastDebugUpdate:  TimeInterval          = 0

    private static let tips: [(VNHumanHandPoseObservation.JointName, String)] = [
        (.thumbTip,  "thumb"),
        (.indexTip,  "index"),
        (.middleTip, "middle"),
        (.ringTip,   "ring"),
        (.littleTip, "little"),
    ]

    // MARK: - Render-thread entry

    func update(hands: [HandTracker.HandResult],
                keyboardNode: SCNNode?,
                time: TimeInterval,
                audioSnapshot: PitchSnapshot? = nil,
                expectedKeyIndices: Set<Int> = [],
                keyTuning: KeyTuning? = nil) -> [PressEvent] {

        var newPresses: [PressEvent] = []
        var seen = Set<String>()
        var debugLines = [String]()

        let guided = !expectedKeyIndices.isEmpty

        if guided, let kb = keyboardNode {
            // ── Guided path: audio onset + loose presence check ──────────
            let events = guidedPressEvents(
                hands:              hands,
                keyboardNode:       kb,
                expectedKeyIndices: expectedKeyIndices,
                snapshot:           audioSnapshot,
                time:               time
            )
            newPresses.append(contentsOf: events)

            // Debug lines
            for hand in hands {
                let side = hand.isLeft ? "L" : "R"
                for (joint, name) in Self.tips {
                    guard let wp = hand.joints[joint] else { continue }
                    let lp = kb.simdConvertPosition(wp, from: nil)
                    debugLines.append(String(format: "%@_%@ y%+.0fmm", side, name, lp.y * 1000))
                }
            }
            if let atk = audioSnapshot?.attack {
                debugLines.append(String(format: "onset conf %.2f score %.2f", atk.confidence, atk.onsetScore))
            }

        } else if let kb = keyboardNode {
            // ── Non-guided path: depth + trajectory ──────────────────────
            for hand in hands {
                let side = hand.isLeft ? "L" : "R"
                for (joint, fingerName) in Self.tips {
                    guard let wp = hand.joints[joint] else { continue }
                    let fid  = "\(side)_\(fingerName)"
                    seen.insert(fid)
                    let lp   = kb.simdConvertPosition(wp, from: nil)
                    var track = fingers[fid] ?? FingerTrack()

                    track.yHistory.append(lp.y)
                    if track.yHistory.count > historyCount { track.yHistory.removeFirst() }

                    let key      = findKey(localX: lp.x, localZ: lp.z, keyTuning: keyTuning)
                    let surfaceY = key?.isBlack == true
                        ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
                        : KeyboardLayout.whiteKeyHeight
                    let depth    = lp.y - surfaceY
                    let vel: Float = track.yHistory.count >= 3
                        ? (track.yHistory.last! - track.yHistory[track.yHistory.count - 3]) / 2.0
                        : 0

                    switch track.phase {
                    case .idle:
                        if vel < minDescendVel && depth < 0.025 { track.phase = .descending }

                    case .descending:
                        if depth < -pressDepth,
                           let k = key,
                           time - track.lastPressTime > debounceInterval,
                           time - lastKeyPressTime[k.index] > keyLockoutInterval {
                            let h = track.yHistory
                            let pv = h.count >= 4 ? (h[h.count - 2] - h[h.count - 4]) / 2.0 : vel
                            if vel > pv * 0.4 || depth < -pressDepth * 2.5 {
                                let micBoost = audioBoost(audioSnapshot, time: time)
                                newPresses.append(PressEvent(
                                    keyIndex:   k.index,
                                    noteName:   k.noteName,
                                    confidence: min(1.0, abs(depth) / 0.020 + micBoost),
                                    fingerID:   fid,
                                    timestamp:  time
                                ))
                                track.phase = .pressed
                                track.lastPressTime = time
                                lastKeyPressTime[k.index] = time
                            }
                        }
                        if vel > 0.001 && depth > 0.005 { track.phase = .idle }

                    case .pressed:
                        if depth > pressDepth * 0.5 { track.phase = .idle }
                    }

                    fingers[fid] = track
                    debugLines.append(String(format: "%@ %+.0fmm %@ [%@]",
                                            fid, depth * 1000, track.phase.rawValue,
                                            key?.noteName ?? "-"))
                }
            }
            for fid in fingers.keys where !seen.contains(fid) { fingers[fid] = FingerTrack() }
        }

        recentPresses.append(contentsOf: newPresses)
        recentPresses.removeAll { time - $0.timestamp > flashRetain }

        if time - lastDebugUpdate > 0.10 {
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

    // MARK: - Guided press detection (audio-primary)
    //
    // In guided mode the song tells us exactly which key(s) to play — we don't
    // need to identify a key from fingertip X position. Instead:
    //
    //   1. Audio onset = "something was played" (timing signal).
    //   2. Loose keyboard-area presence check = "a hand is at the piano".
    //   3. Pitch FFT hints optionally add confidence (not required — mic at
    //      ~50 cm is noisy for bass notes and we don't want false rejections).
    //
    // We explicitly avoid identifying the key from vision X position because
    // Vision + LiDAR gives ≥1 cm world-space error on 23.5 mm keys — the math
    // cannot be reliable at that resolution.

    private func guidedPressEvents(hands: [HandTracker.HandResult],
                                   keyboardNode kb: SCNNode,
                                   expectedKeyIndices: Set<Int>,
                                   snapshot: PitchSnapshot?,
                                   time: TimeInterval) -> [PressEvent] {
        guard let snap   = snapshot,
              let attack = snap.attack,
              attack.confidence >= guidedMinAttackConf,
              abs(time - attack.timestamp) <= guidedAttackWindow,
              attack.timestamp > lastGuidedAttackTime
        else { return [] }

        // Loose keyboard presence check.
        let fingerPresent = anyFingerInKeyboardArea(hands: hands, keyboardNode: kb)

        // Pitch score: does the FFT hint agree with any expected key?
        let pitchScore = bestPitchScore(expectedKeyIndices: expectedKeyIndices, snapshot: snap)

        // Confidence:  onset (0…0.55) + pitch (0…0.30) + hand-present (0…0.15)
        var confidence  = attack.confidence * 0.55
        confidence     += pitchScore * 0.30
        confidence     += fingerPresent ? 0.15 : 0.0

        // Reject when pitch data is present and clearly contradicts expected note.
        let pitchContradict = !snap.activeNotes.isEmpty && pitchScore < 0.07
        guard confidence >= 0.30, !pitchContradict else { return [] }

        lastGuidedAttackTime = attack.timestamp

        // Assign best nearby fingertip to each expected key (fingerID only — not
        // used for key identification, just for debug display and dedup).
        let tips = collectFingertips(hands: hands, keyboardNode: kb)
        var usedFingers = Set<String>()

        return expectedKeyIndices.sorted().compactMap { keyIndex -> PressEvent? in
            guard keyIndex >= 0, keyIndex < KeyboardLayout.keys.count else { return nil }
            let key = KeyboardLayout.keys[keyIndex]
            lastKeyPressTime[keyIndex] = time

            let best = tips
                .filter { !usedFingers.contains($0.fingerID) }
                .min { abs($0.localX - key.xCenter) < abs($1.localX - key.xCenter) }
            if let f = best { usedFingers.insert(f.fingerID) }

            return PressEvent(
                keyIndex:   keyIndex,
                noteName:   key.noteName,
                confidence: min(1.0, confidence),
                fingerID:   best?.fingerID ?? "audio",
                timestamp:  time
            )
        }
    }

    // MARK: - Helpers

    private func collectFingertips(hands: [HandTracker.HandResult],
                                   keyboardNode kb: SCNNode) -> [FingertipLocal] {
        var out: [FingertipLocal] = []
        let leftEdge = -KeyboardLayout.totalWidth / 2
        for hand in hands {
            let side = hand.isLeft ? "L" : "R"
            for (joint, name) in Self.tips {
                guard let wp = hand.joints[joint] else { continue }
                let lp = kb.simdConvertPosition(wp, from: nil)
                out.append(FingertipLocal(
                    fingerID: "\(side)_\(name)",
                    localX:   lp.x - leftEdge,  // relative to left edge, matching key.xCenter
                    localY:   lp.y,
                    localZ:   lp.z
                ))
            }
        }
        return out
    }

    private func anyFingerInKeyboardArea(hands: [HandTracker.HandResult],
                                         keyboardNode kb: SCNNode) -> Bool {
        let halfW = KeyboardLayout.totalWidth  * 0.55
        let halfZ = KeyboardLayout.whiteKeyDepth * 0.5 + kbAreaZExtra
        for hand in hands {
            for (joint, _) in Self.tips {
                guard let wp = hand.joints[joint] else { continue }
                let lp = kb.simdConvertPosition(wp, from: nil)
                if lp.y > kbAreaYMin && lp.y < kbAreaYMax
                    && abs(lp.x) < halfW
                    && abs(lp.z) < halfZ {
                    return true
                }
            }
        }
        return false
    }

    private func bestPitchScore(expectedKeyIndices: Set<Int>,
                                snapshot: PitchSnapshot) -> Float {
        guard !snapshot.activeNotes.isEmpty else { return 0 }
        var best: Float = 0
        for keyIndex in expectedKeyIndices {
            for hint in snapshot.activeNotes {
                let d = abs(hint.keyIndex - keyIndex)
                guard d <= pitchSemitoneWindow else { continue }
                let penalty: Float = d == 0 ? 1.0 : d == 1 ? 0.75 : d == 2 ? 0.50 : 0.30
                let s = hint.magnitude * penalty
                if s > best { best = s }
            }
        }
        return best
    }

    private func audioBoost(_ snapshot: PitchSnapshot?, time: TimeInterval) -> Float {
        guard let snap   = snapshot,
              let attack = snap.attack,
              abs(time - attack.timestamp) <= 0.12
        else { return 0 }
        return 0.06 + attack.confidence * 0.10
    }

    // MARK: - Key lookup (non-guided mode only)

    private func findKey(localX: Float,
                         localZ: Float,
                         extraX: Float = 0.004,
                         extraZ: Float = 0.018,
                         keyTuning: KeyTuning? = nil) -> KeyboardLayout.Key? {
        let leftEdge = -KeyboardLayout.totalWidth / 2
        let relX     = localX - leftEdge
        guard relX >= -extraX, relX <= KeyboardLayout.totalWidth + extraX else { return nil }

        let wZMin = -KeyboardLayout.whiteKeyDepth / 2 - extraZ
        let wZMax =  KeyboardLayout.whiteKeyDepth / 2 + extraZ
        guard localZ >= wZMin, localZ <= wZMax else { return nil }

        let bZC  = -(KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2
        let bZMn = bZC - KeyboardLayout.blackKeyDepth / 2 - extraZ
        let bZMx = bZC + KeyboardLayout.blackKeyDepth / 2 + extraZ
        if localZ >= bZMn, localZ <= bZMx {
            let halfW = KeyboardLayout.blackKeyWidth / 2 + extraX
            if let b = KeyboardLayout.keys
                .filter({ $0.isBlack && abs(relX - tunedX($0, keyTuning)) < halfW + tunedWE($0, keyTuning) })
                .min(by: { abs(relX - tunedX($0, keyTuning)) < abs(relX - tunedX($1, keyTuning)) }) {
                return b
            }
        }

        let halfW = KeyboardLayout.whiteKeyWidth / 2 + extraX
        return KeyboardLayout.keys
            .filter { !$0.isBlack && abs(relX - tunedX($0, keyTuning)) < halfW + tunedWE($0, keyTuning) }
            .min { abs(relX - tunedX($0, keyTuning)) < abs(relX - tunedX($1, keyTuning)) }
    }

    private func tunedX(_ k: KeyboardLayout.Key, _ kt: KeyTuning?) -> Float {
        k.xCenter + (kt?.xOffset(for: k.index) ?? 0)
    }
    private func tunedWE(_ k: KeyboardLayout.Key, _ kt: KeyTuning?) -> Float {
        Swift.max(-0.008, kt?.widthExtra(for: k.index) ?? 0)
    }
}

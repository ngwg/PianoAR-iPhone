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

/// Vision-only key-press detection — there is no MIDI ground truth anywhere in
/// this project, so this is the core deliverable, not an experimental extra.
///
/// A real piano press has a distinctive SHAPE: the finger descends with real
/// speed, then decelerates hard right at the moment of contact (the "valley"
/// in its Y trajectory), sometimes with a small rebound. This detector looks
/// for that valley rather than a single-frame threshold crossing, using two
/// robustness measures over the old approach:
///
///  1. **Velocity is a least-squares slope**, not a 2-point finite difference.
///     Differentiating noisy position data amplifies noise; a short regression
///     over the last several samples smooths that out while staying responsive
///     (well under 200ms of added lag at Vision's throttled frame rate).
///  2. **Depth is measured relative to each finger's own recent rest height**
///     (a slowly-adapted baseline, frozen during a stroke), not an absolute
///     geometric key-surface Y. The absolute geometry depends on plane
///     detection, hand-point calibration, and LiDAR depth — all individually
///     noisy — so a fixed-mm threshold against it is fragile. Measuring the
///     dip against the finger's own hover height self-calibrates away that
///     bias. A loose absolute-geometry envelope still rejects detections that
///     are obviously implausible (e.g. a hand gesturing far above the keys).
final class PressDetector: ObservableObject {
    @Published var lastDetected: String = ""
    @Published var fingerDebugLines: [String] = []

    // ── Trajectory shape thresholds ──────────────────────────────────────────
    private let historySize:    Int   = 6       // regression window
    private let armDip:         Float = 0.003   // 3mm dip to arm "descending"
    private let pressDip:       Float = 0.006   // 6mm dip (from own baseline) confirms
    private let releaseDip:     Float = 0.002   // back within 2mm of baseline = released
    private let descendVel:     Float = 0.05    // m/s downward to arm descending
    private let settleVel:      Float = 0.02    // m/s — under this = "stopped" (the valley)
    private let baselineAlpha:  Float = 0.06    // slow EMA — adapts over ~1-2s, never mid-press
    private let envelopeY:      Float = 0.030   // ±30mm coarse geometric plausibility gate

    private let debounceInterval:   TimeInterval = 0.18
    private let keyLockoutInterval: TimeInterval = 0.24
    private let flashRetain:        TimeInterval = 2.0

    // ── Guided (per-key evidence) ────────────────────────────────────────
    private let guidedAttackWindow:  TimeInterval = 0.28
    private let guidedMinAttackConf: Float = 0.24
    private let pitchSemitoneWindow: Int   = 3
    // Audio path: a fingertip must be physically ON the key it accepts —
    // within this many white-key widths of the key centre, inside the key
    // bed's depth, and at surface height.
    private let onKeyXTolKeys:  Float = 1.5
    private let onKeyZExtra:    Float = 0.025
    private let onKeyYTol:      Float = 0.050

    // ── State ─────────────────────────────────────────────────────────────

    enum Phase: String { case idle, descending, pressed }

    private struct FingerTrack {
        var samples:        [(y: Float, t: TimeInterval)] = []
        var baseline:       Float = .nan
        var phase:          Phase = .idle
        var peakDescentVel: Float = 0
        var lastPressTime:  TimeInterval = 0
        var lastKeyIndex:   Int? = nil
        var lastValleyTime: TimeInterval = -999
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

        var visionCandidates: [PressEvent] = []
        var seen = Set<String>()
        var debugLines = [String]()

        if let kb = keyboardNode {
            // Trajectory tracking runs every frame regardless of guided/non-guided
            // — it's the primary signal in freeplay and the corroboration signal
            // for guided mode's audio-primary detection.
            for hand in hands {
                let side = hand.isLeft ? "L" : "R"
                for (joint, fingerName) in Self.tips {
                    let fid = "\(side)_\(fingerName)"
                    guard let wp = hand.joints[joint] else { continue }

                    // Occlusion-reconstructed (guessed) fingertips must never fire —
                    // there's no real observation behind them.
                    if hand.estimated.contains(joint) {
                        fingers[fid] = FingerTrack()
                        continue
                    }
                    seen.insert(fid)

                    let lp = kb.simdConvertPosition(wp, from: nil)
                    var track = fingers[fid] ?? FingerTrack()

                    // Dedupe: HandTracker's snapshot repeats between Vision updates
                    // (Vision is throttled well below the 60fps render loop) — only
                    // grow the regression buffer on genuinely new samples so the fit
                    // isn't biased toward "flat" by repeated identical values.
                    let isNew = track.samples.last.map { abs($0.y - lp.y) > 0.00002 } ?? true
                    if isNew {
                        track.samples.append((lp.y, time))
                        if track.samples.count > historySize { track.samples.removeFirst() }
                    }

                    let vel = regressionSlope(track.samples)
                    let key = findKey(localX: lp.x, localZ: lp.z,
                                      lastKeyIndex: track.lastKeyIndex, keyTuning: keyTuning)
                    let surfaceY = key?.isBlack == true
                        ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
                        : KeyboardLayout.whiteKeyHeight
                    let inEnvelope = abs(lp.y - surfaceY) < envelopeY

                    // Baseline only adapts while genuinely at rest, so a press dip
                    // never drags its own reference point down with it.
                    if track.phase == .idle, abs(vel) < descendVel * 0.4 {
                        track.baseline = track.baseline.isNaN
                            ? lp.y : track.baseline + baselineAlpha * (lp.y - track.baseline)
                    }
                    let dip = track.baseline.isNaN ? 0 : track.baseline - lp.y   // + = below rest

                    switch track.phase {
                    case .idle:
                        if vel < -descendVel, dip > armDip, inEnvelope {
                            track.phase = .descending
                            track.peakDescentVel = vel
                        }

                    case .descending:
                        track.peakDescentVel = min(track.peakDescentVel, vel)
                        if vel > -settleVel, dip > pressDip,
                           time - track.lastPressTime > debounceInterval,
                           let k = key, time - lastKeyPressTime[k.index] > keyLockoutInterval {
                            // ── The valley: descent has stopped right after a real dip ──
                            let dipRatio  = simd_clamp(dip / 0.010, 0, 1)               // 10mm ~ full key travel
                            let sharpness = simd_clamp(abs(track.peakDescentVel) / 0.35, 0, 1)
                            let micBoost  = audioBoost(audioSnapshot, time: time)
                            let confidence: Float = min(1.0, 0.55 * dipRatio + 0.35 * sharpness + micBoost)

                            track.phase          = .pressed
                            track.lastPressTime   = time
                            track.lastValleyTime  = time
                            track.lastKeyIndex     = k.index
                            lastKeyPressTime[k.index] = time

                            visionCandidates.append(PressEvent(
                                keyIndex: k.index, noteName: k.noteName,
                                confidence: confidence, fingerID: fid, timestamp: time
                            ))
                        } else if dip < armDip {
                            // Pulled back up without really pressing — a false start.
                            track.phase = .idle
                            track.peakDescentVel = 0
                        }

                    case .pressed:
                        if dip < releaseDip { track.phase = .idle; track.peakDescentVel = 0 }
                    }

                    fingers[fid] = track
                    debugLines.append(String(format: "%@ dip%+.0fmm v%+.2f %@ [%@]",
                                            fid, dip * 1000, vel, track.phase.rawValue,
                                            key?.noteName ?? "-"))
                }
            }
            for fid in fingers.keys where !seen.contains(fid) { fingers[fid] = FingerTrack() }
        }

        let guided = !expectedKeyIndices.isEmpty
        var finalPresses: [PressEvent]

        if guided, let kb = keyboardNode {
            // Per-key evidence: every expected key must earn its OWN
            // acceptance. Previously one audio onset + a hand hovering
            // anywhere over the keyboard accepted the WHOLE expected group —
            // that's both "detects keys I never touched" and "pressing the
            // right-hand note auto-completed the left hand's chord note".
            var events:  [PressEvent] = []
            var claimed = Set<Int>()

            // A) Vision: a press-shaped valley resolved on (or within 2 keys
            //    of — vision X is good to about one key) an expected key
            //    accepts exactly that key.
            for cand in visionCandidates {
                guard let nearest = expectedKeyIndices
                        .filter({ !claimed.contains($0) })
                        .min(by: { abs($0 - cand.keyIndex) < abs($1 - cand.keyIndex) }),
                      abs(nearest - cand.keyIndex) <= 2 else { continue }
                claimed.insert(nearest)
                lastKeyPressTime[nearest] = time
                events.append(PressEvent(
                    keyIndex: nearest,
                    noteName: KeyboardLayout.keys[nearest].noteName,
                    confidence: min(1.0, cand.confidence * 0.85
                                         + audioBoost(audioSnapshot, time: time)),
                    fingerID: cand.fingerID,
                    timestamp: time))
            }

            // B) Audio: an onset accepts a remaining expected key only if a
            //    directly-tracked fingertip is physically ON that key.
            events += guidedAudioEvents(
                hands: hands, keyboardNode: kb,
                expectedKeyIndices: expectedKeyIndices.subtracting(claimed),
                snapshot: audioSnapshot, time: time)

            finalPresses = events

            if let atk = audioSnapshot?.attack {
                debugLines.append(String(format: "onset conf %.2f score %.2f", atk.confidence, atk.onsetScore))
            }
        } else {
            finalPresses = visionCandidates
        }

        recentPresses.append(contentsOf: finalPresses)
        recentPresses.removeAll { time - $0.timestamp > flashRetain }

        if time - lastDebugUpdate > 0.10 {
            lastDebugUpdate = time
            let detected: String
            if !finalPresses.isEmpty {
                detected = finalPresses.map(\.noteName).joined(separator: " ")
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

        return finalPresses
    }

    func reset() {
        fingers.removeAll()
        recentPresses.removeAll()
        lastKeyPressTime = .init(repeating: -999, count: 88)
        lastGuidedAttackTime = -999
    }

    // MARK: - Guided press detection (per-key evidence)
    //
    // Every expected key must earn its OWN acceptance:
    //   A) a press-shaped vision valley resolved on/next to it (matched by the
    //      caller from visionCandidates), or
    //   B) an audio onset while a directly-tracked fingertip is physically ON
    //      that key (within onKeyXTolKeys white-key widths of its centre, at
    //      surface height, inside the key bed).
    // One onset may accept several chord members at once — but only members
    // that each have their own fingertip on them, which is exactly the
    // "pressed both hands together" case. Sound plus a hand merely hovering
    // somewhere over the keyboard accepts nothing, and a right-hand press can
    // no longer auto-complete the left hand's half of a chord.

    private func guidedAudioEvents(hands: [HandTracker.HandResult],
                                   keyboardNode kb: SCNNode,
                                   expectedKeyIndices: Set<Int>,
                                   snapshot: PitchSnapshot?,
                                   time: TimeInterval) -> [PressEvent] {
        guard !expectedKeyIndices.isEmpty,
              let snap   = snapshot,
              let attack = snap.attack,
              attack.confidence >= guidedMinAttackConf,
              abs(time - attack.timestamp) <= guidedAttackWindow,
              attack.timestamp > lastGuidedAttackTime
        else { return [] }

        let pitchScore = bestPitchScore(expectedKeyIndices: expectedKeyIndices, snapshot: snap)
        let pitchContradict = !snap.activeNotes.isEmpty && pitchScore < 0.07
        guard !pitchContradict else { return [] }

        // Direct (non-reconstructed) fingertips only.
        let tips = collectFingertips(hands: hands, keyboardNode: kb)
        var usedFingers = Set<String>()
        var events: [PressEvent] = []

        let xTol = KeyboardLayout.whiteKeyWidth * onKeyXTolKeys
        let zMax = KeyboardLayout.whiteKeyDepth / 2 + onKeyZExtra

        for keyIndex in expectedKeyIndices.sorted() {
            guard keyIndex >= 0, keyIndex < KeyboardLayout.keys.count else { continue }
            let key = KeyboardLayout.keys[keyIndex]
            let surfaceY = key.isBlack
                ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
                : KeyboardLayout.whiteKeyHeight

            guard let tip = tips
                .filter({ !usedFingers.contains($0.fingerID)
                          && abs($0.localX - key.xCenter) <= xTol
                          && abs($0.localZ) <= zMax
                          && abs($0.localY - surfaceY) <= onKeyYTol })
                .min(by: { abs($0.localX - key.xCenter) < abs($1.localX - key.xCenter) })
            else { continue }

            usedFingers.insert(tip.fingerID)
            lastKeyPressTime[keyIndex] = time
            events.append(PressEvent(
                keyIndex: keyIndex, noteName: key.noteName,
                confidence: min(1.0, attack.confidence * 0.50 + pitchScore * 0.30 + 0.15),
                fingerID: tip.fingerID,
                timestamp: time))
        }

        // Consume the onset only when it actually accepted something, so a
        // slightly-early sound doesn't burn before the finger settles.
        if !events.isEmpty { lastGuidedAttackTime = attack.timestamp }
        return events
    }

    // MARK: - Helpers

    /// Directly-observed fingertips only — an occlusion-reconstructed
    /// (guessed) fingertip must never satisfy the on-key requirement.
    private func collectFingertips(hands: [HandTracker.HandResult],
                                   keyboardNode kb: SCNNode) -> [FingertipLocal] {
        var out: [FingertipLocal] = []
        let leftEdge = -KeyboardLayout.totalWidth / 2
        for hand in hands {
            let side = hand.isLeft ? "L" : "R"
            for (joint, name) in Self.tips {
                guard !hand.estimated.contains(joint),
                      let wp = hand.joints[joint] else { continue }
                let lp = kb.simdConvertPosition(wp, from: nil)
                out.append(FingertipLocal(
                    fingerID: "\(side)_\(name)",
                    localX:   lp.x - leftEdge,
                    localY:   lp.y,
                    localZ:   lp.z
                ))
            }
        }
        return out
    }

    private func bestPitchScore(expectedKeyIndices: Set<Int>, snapshot: PitchSnapshot) -> Float {
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
        guard let snap = snapshot, let attack = snap.attack,
              abs(time - attack.timestamp) <= 0.12 else { return 0 }
        return 0.06 + attack.confidence * 0.10
    }

    /// Least-squares slope of y vs t (m/s). Far more robust to single-frame
    /// noise than a 2-point finite difference — differentiating noisy position
    /// data amplifies that noise, while a short regression window averages it
    /// out with negligible added lag (well under 200ms at Vision's frame rate).
    private func regressionSlope(_ samples: [(y: Float, t: TimeInterval)]) -> Float {
        guard samples.count >= 3 else { return 0 }
        let n = Float(samples.count)
        let t0 = samples[0].t
        var sumT: Float = 0, sumY: Float = 0, sumTT: Float = 0, sumTY: Float = 0
        for s in samples {
            let t = Float(s.t - t0)
            sumT += t; sumY += s.y; sumTT += t * t; sumTY += t * s.y
        }
        let denom = n * sumTT - sumT * sumT
        guard abs(denom) > 1e-9 else { return 0 }
        return (n * sumTY - sumT * sumY) / denom
    }

    // MARK: - Key lookup (non-guided mode / debug display)

    /// Resolves the nearest key, preferring the finger's last-resolved key if
    /// the position is still plausibly within it (expanded tolerance). This
    /// hysteresis stops a finger resting near a key boundary from flickering
    /// between two keys frame to frame.
    private func findKey(localX: Float, localZ: Float,
                         lastKeyIndex: Int? = nil,
                         extraX: Float = 0.004, extraZ: Float = 0.018,
                         keyTuning: KeyTuning? = nil) -> KeyboardLayout.Key? {
        if let li = lastKeyIndex, li >= 0, li < KeyboardLayout.keys.count {
            let k = KeyboardLayout.keys[li]
            let leftEdge = -KeyboardLayout.totalWidth / 2
            let relX = localX - leftEdge
            let halfW = (k.isBlack ? KeyboardLayout.blackKeyWidth : KeyboardLayout.whiteKeyWidth) / 2
            if abs(relX - tunedX(k, keyTuning)) < halfW * 1.4 + tunedWE(k, keyTuning) {
                return k
            }
        }
        return resolveKey(localX: localX, localZ: localZ, extraX: extraX, extraZ: extraZ, keyTuning: keyTuning)
    }

    private func resolveKey(localX: Float, localZ: Float,
                            extraX: Float, extraZ: Float,
                            keyTuning: KeyTuning?) -> KeyboardLayout.Key? {
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

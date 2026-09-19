import SceneKit
import Vision
import simd

struct PressEvent {
    enum Source: String { case vision, audio }

    let keyIndex: Int
    let noteName: String
    let confidence: Float
    let fingerID: String
    let timestamp: TimeInterval
    var source: Source = .vision
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

    // ── Sound-first acceptance (NoteTracker onsets) ─────────────────────
    // The piano itself says which key was struck; hand position plays no
    // part. Every detected strike is used at most once.
    private let earlyWindow:    TimeInterval = 0.6   // strike may precede its group becoming current by this much
    private let wrongDelay:     TimeInterval = 0.15  // let simultaneous expected notes arrive first
    private let wrongStrength:  Float = 5.0          // dB — clear strikes only are called wrong
    private let freePlayStrength: Float = 4.0        // dB — flashes when no song is playing

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
    private var fingers:          [String: FingerTrack] = [:]
    private var recentPresses:    [PressEvent]          = []
    private var lastKeyPressTime: [TimeInterval]        = .init(repeating: -999, count: 88)
    private var lastDebugUpdate:  TimeInterval          = 0

    private var consumedOnsets = Set<Int>()   // NoteOnset ids already used
    private var groupSince: TimeInterval = 0  // when the current song group became current
    private var lastGroupSerial = -1

    private static let tips: [(VNHumanHandPoseObservation.JointName, String)] = [
        (.thumbTip,  "thumb"),
        (.indexTip,  "index"),
        (.middleTip, "middle"),
        (.ringTip,   "ring"),
        (.littleTip, "little"),
    ]

    // MARK: - Render-thread entry

    /// - Parameters:
    ///   - expectedKeyIndices: keys of the current song group still waiting
    ///     to be played (already-accepted chord members excluded).
    ///   - groupKeyIndices: every key of the current group (for wrong-note
    ///     screening).
    ///   - upcomingKeyIndices: keys of the next groups — playing slightly
    ///     ahead is never called wrong, and those strikes stay usable.
    ///   - groupSerial: changes whenever the song advances to a new group.
    func update(hands: [HandTracker.HandResult],
                keyboardNode: SCNNode?,
                time: TimeInterval,
                audioSnapshot: PitchSnapshot? = nil,
                expectedKeyIndices: Set<Int> = [],
                groupKeyIndices: Set<Int> = [],
                upcomingKeyIndices: Set<Int> = [],
                groupSerial: Int = 0,
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

        if let snap = audioSnapshot, snap.listening {
            // The piano's sound decides which keys were played — hand
            // position doesn't matter. Vision only drives the hand overlay.
            finalPresses = soundEvents(snapshot: snap, time: time, guided: guided,
                                       pending: expectedKeyIndices,
                                       groupKeys: groupKeyIndices.union(expectedKeyIndices),
                                       upcoming: upcomingKeyIndices,
                                       groupSerial: groupSerial, debug: &debugLines)
        } else if guided {
            // No microphone: fall back to vision. A press-shaped valley
            // resolved on (or within 2 keys of) an expected key accepts it.
            var events: [PressEvent] = []
            var claimed = Set<Int>()
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
            debugLines.append("mic off: using hand tracking")
            finalPresses = events
        } else {
            finalPresses = visionCandidates
        }

        recentPresses.append(contentsOf: finalPresses)
        recentPresses.removeAll { time - $0.timestamp > flashRetain }

        if time - lastDebugUpdate > 0.10 {
            lastDebugUpdate = time
            if !finalPresses.isEmpty {
                debugLines.insert("pressed " + finalPresses.map {
                    String(format: "%@(%@ %.2f)", $0.noteName, $0.source.rawValue, $0.confidence)
                }.joined(separator: " "), at: 0)
            } else if let last = recentPresses.last, time - last.timestamp < 1.5 {
                debugLines.insert("last " + last.noteName, at: 0)
            }
            debugStore.set(debugLines)
        }

        return finalPresses
    }

    /// Latest debug readout — safe from any thread (render-thread HUD).
    func debugSnapshot() -> [String] { debugStore.get() }
    private let debugStore = Locked<[String]>([])

    func reset() {
        fingers.removeAll()
        recentPresses.removeAll()
        lastKeyPressTime = .init(repeating: -999, count: 88)
        consumedOnsets.removeAll()
        lastGroupSerial = -1
    }

    // MARK: - Sound-first acceptance
    //
    // NoteTracker reports every key whose own partials jumped (a strike).
    // While a song plays, each still-pending key is accepted by the first
    // unused strike of THAT key since shortly before its group became
    // current. So chords (each member is its own strike), playing slightly
    // ahead, and repeated notes (each needs a new strike) all work, and one
    // strike can never count twice.

    private func soundEvents(snapshot snap: PitchSnapshot, time: TimeInterval, guided: Bool,
                             pending: Set<Int>, groupKeys: Set<Int>, upcoming: Set<Int>,
                             groupSerial: Int, debug: inout [String]) -> [PressEvent] {
        if groupSerial != lastGroupSerial {
            lastGroupSerial = groupSerial
            groupSince = time
        }
        // Forget ids that have aged out of the snapshot.
        consumedOnsets.formIntersection(Set(snap.noteOnsets.map { $0.id }))

        var events: [PressEvent] = []
        func emit(_ o: NoteOnset, key: Int) {
            consumedOnsets.insert(o.id)
            lastKeyPressTime[key] = time
            events.append(PressEvent(keyIndex: key, noteName: KeyboardLayout.keys[key].noteName,
                                     confidence: min(1, 0.5 + o.strength / 20),
                                     fingerID: "sound", timestamp: o.time, source: .audio))
        }

        if guided {
            for k in pending.sorted() {
                if let o = snap.noteOnsets.first(where: {
                    $0.key == k && !consumedOnsets.contains($0.id) && $0.time >= groupSince - earlyWindow
                }) {
                    emit(o, key: k)
                }
            }
            // Wrong notes: a clear strike a semitone or whole tone away from
            // an expected key, with none of the expected keys struck with it.
            for o in snap.noteOnsets where !consumedOnsets.contains(o.id)
                    && time - o.time >= wrongDelay
                    && o.time >= groupSince - 0.05
                    && !groupKeys.contains(o.key)
                    && !upcoming.contains(o.key) {
                consumedOnsets.insert(o.id)
                guard o.strength >= wrongStrength,
                      groupKeys.contains(where: { abs($0 - o.key) <= 2 }),
                      !snap.noteOnsets.contains(where: {
                          groupKeys.contains($0.key) && abs($0.time - o.time) < 0.12
                      })
                else { continue }
                emit(o, key: o.key)
            }
        } else {
            // Free play: every clearly heard note flashes its key.
            for o in snap.noteOnsets where !consumedOnsets.contains(o.id)
                    && o.strength >= freePlayStrength {
                emit(o, key: o.key)
            }
        }

        let heard = snap.noteOnsets.suffix(8).map {
            String(format: "%@ %.0f", KeyboardLayout.keys[$0.key].noteName, $0.strength)
        }
        debug.append("heard " + (heard.isEmpty ? "-" : heard.joined(separator: " · ")))
        if guided {
            let need = pending.sorted().map { KeyboardLayout.keys[$0].noteName }
            let live = snap.expectedScores.map {
                String(format: "%@ %.1f", KeyboardLayout.keys[$0.key].noteName, $0.score)
            }
            debug.append("need " + need.joined(separator: " ") + "  |  live " + live.joined(separator: " "))
        }
        return events
    }

    // MARK: - Helpers

    /// Onset timestamps are true capture times (they reach the render loop
    /// up to ~0.1 s later), hence the slightly wider window than the old
    /// callback-time stamps needed.
    private func audioBoost(_ snapshot: PitchSnapshot?, time: TimeInterval) -> Float {
        guard let snap = snapshot, let attack = snap.attack,
              abs(time - attack.timestamp) <= 0.25 else { return 0 }
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

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

    // ── Guided (per-key evidence) ────────────────────────────────────────
    private let guidedAttackWindow:  TimeInterval = 0.35
    // Every onset that reaches here has already cleared SuperFlux's own
    // adaptive threshold, which measured 0.99 precision on a real recording.
    // A second confidence gate on top of that only throws away quiet notes.
    private let guidedMinAttackConf: Float = 0.0
    private let pitchSemitoneWindow: Int   = 3
    // Fast audio path (before the note verifier has spoken): a fingertip
    // must be physically ON the key it accepts — within this many white-key
    // widths of the key centre, inside the key bed's depth, at surface height.
    private let onKeyXTolKeys:  Float = 1.5
    private let onKeyZExtra:    Float = 0.025
    private let onKeyYTol:      Float = 0.050

    // ── Chord-aware strike acceptance (audio note verification) ─────────
    // One piano onset stays usable for `strikeWindow` seconds and may accept
    // every expected key whose own partials rose at that onset. It is no
    // longer "consumed" by the first key it accepts — that was why the
    // second and third notes of a chord never registered.
    private let strikeWindow:  TimeInterval = 0.9
    private let wrongRise:     Float = 0.65   // confidently heard (S ≥ ~5 dB), but not expected
    private let handReachKeys: Float = 6.0    // "a hand is near this key" in white-key widths
    // A verified note this clear (score ≥ ~5.6 dB, and not explained by some
    // other key) counts even when hand tracking has lost the hand.
    private let strongRise: Float = 0.7
    /// How far ahead of the app a note may be played and still count.
    private let earlyPlayWindow: TimeInterval = 0.30
    private var groupChangedAt: TimeInterval = 0
    private var lastGroupSerial = -1

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

    /// Recent press-shaped fingertip valleys: key → time. Never accepts a
    /// note by itself; only settles sound-ambiguous cases.
    private var recentValleys: [Int: TimeInterval] = [:]

    private var fingers:          [String: FingerTrack] = [:]
    private var recentPresses:    [PressEvent]          = []
    private var lastKeyPressTime: [TimeInterval]        = .init(repeating: -999, count: 88)
    private var lastDebugUpdate:  TimeInterval          = 0

    private struct StrikeState {
        let groupSerial: Int           // the song group that was current when first seen
        var acceptedKeys: Set<Int> = []
        var wrongReported = false
    }
    private var strikes: [Int: StrikeState] = [:]   // audio attack id → state

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
    ///   - groupSerial: changes whenever the song advances to a new group, so
    ///     one strike can never satisfy two consecutive identical chords.
    func update(hands: [HandTracker.HandResult],
                keyboardNode: SCNNode?,
                time: TimeInterval,
                audioSnapshot: PitchSnapshot? = nil,
                expectedKeyIndices: Set<Int> = [],
                groupKeyIndices: Set<Int> = [],
                upcomingKeyIndices: Set<Int> = [],
                struggling: Bool = false,
                groupSerial: Int = 0,
                keyTuning: KeyTuning? = nil) -> [PressEvent] {

        var visionCandidates: [PressEvent] = []
        var seen = Set<String>()
        var debugLines = [String]()

        if groupSerial != lastGroupSerial {
            lastGroupSerial = groupSerial
            groupChangedAt = time
        }

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
                            recentValleys[k.index] = time
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

        recentValleys = recentValleys.filter { time - $0.value < 0.6 }
        let guided = !expectedKeyIndices.isEmpty
        var finalPresses: [PressEvent]

        if guided, let kb = keyboardNode {
            var events: [PressEvent] = []

            if audioSnapshot?.listening == true {
                // THE PIANO DECIDES. A finger dip on its own never accepts a
                // note any more — that is what made notes count before they
                // were played (a finger moving toward a key, or resting on it
                // while something else sounded, looked like a press). Hand
                // tracking now only settles what the sound genuinely cannot
                // tell apart, e.g. the upper note of an octave.
                let strike = guidedStrikeEvents(
                    hands: hands, keyboardNode: kb,
                    pendingKeys: expectedKeyIndices,
                    groupKeys: groupKeyIndices.union(expectedKeyIndices),
                    upcoming: upcomingKeyIndices, struggling: struggling,
                    snapshot: audioSnapshot, time: time, groupSerial: groupSerial,
                    valleys: recentValleys)
                events = strike.events
                debugLines += strike.debug
            } else {
                // No microphone: vision valleys are all there is.
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
                        confidence: min(1.0, cand.confidence * 0.85),
                        fingerID: cand.fingerID,
                        timestamp: time))
                }
                debugLines.append("mic off — hand tracking only")
            }

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
        strikes.removeAll()
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

    private func guidedStrikeEvents(hands: [HandTracker.HandResult],
                                    keyboardNode kb: SCNNode,
                                    pendingKeys: Set<Int>,
                                    groupKeys: Set<Int>,
                                    upcoming: Set<Int>,
                                    struggling: Bool,
                                    snapshot: PitchSnapshot?,
                                    time: TimeInterval,
                                    groupSerial: Int,
                                    valleys: [Int: TimeInterval]) -> (events: [PressEvent], debug: [String]) {
        guard let snap = snapshot else { return ([], []) }

        // Forget strikes that have aged out of the audio snapshot.
        let live = Set(snap.recentAttacks.map(\.id))
        strikes = strikes.filter { live.contains($0.key) }

        let direct = collectFingertips(hands: hands, keyboardNode: kb, includeEstimated: false)
        let onBoard = collectFingertips(hands: hands, keyboardNode: kb, includeEstimated: true)
            .filter(isOverKeyboard)
        let reach = KeyboardLayout.whiteKeyWidth * handReachKeys

        var remaining = pendingKeys
        var events: [PressEvent] = []
        var debug: [String] = []

        for attack in snap.recentAttacks {
            let age = time - attack.timestamp
            guard age >= -0.05, age <= strikeWindow,
                  attack.confidence >= guidedMinAttackConf else { continue }
            var st = strikes[attack.id] ?? StrikeState(groupSerial: groupSerial)
            if st.groupSerial != groupSerial {
                // A strike that satisfied nothing while an earlier group was
                // current can still land this note — you played slightly
                // ahead of the app. But only just ahead: an onset from well
                // before this note came up belongs to the previous note, and
                // letting it through is precisely how a note you never played
                // lights up the moment the song advances.
                guard st.acceptedKeys.isEmpty,
                      attack.timestamp >= groupChangedAt - earlyPlayWindow else { continue }
                st = StrikeState(groupSerial: groupSerial)
            }
            let verification = snap.verification(for: attack.id)

            // While stuck, also listen for the notes just ahead, so a player
            // who has carried on with the piece can be caught up with rather
            // than played at.
            var look = remaining
            if struggling { look.formUnion(upcoming) }
            for k in look.sorted() where k >= 0 && k < KeyboardLayout.keys.count {
                let key = KeyboardLayout.keys[k]
                let handNear = onBoard.contains { abs($0.localX - key.xCenter) <= reach }
                let onKey = direct.contains { tipIsOnKey($0, key) }

                // A press-shaped fingertip dip on this key, just now.
                let valleyNear = valleys.contains { abs($0.key - k) <= 2 && time - $0.value <= 0.35 }

                var confidence: Float? = nil
                if let v = verification, v.evaluated[k] {
                    // An octave-related note of this chord was clearly heard:
                    // the one case where the sound genuinely cannot separate
                    // this key from its partner.
                    let octaveMate = groupKeys.contains {
                        $0 != k && v.status[$0] == .present && abs($0 - k) % 12 == 0
                    }
                    switch v.status[k] {
                    case .present:
                        // Its own partials rose and no other key explains
                        // them: struck. Sound alone decides here. Hand
                        // tracking drops out constantly inside a headset (the
                        // hands sit at the bottom edge of the camera, half
                        // occluded by their own knuckles) and must never veto
                        // a note the microphone clearly heard.
                        confidence = 0.55 + 0.45 * v.rise[k]
                    case .unsure where (valleyNear || octaveMate || struggling) && age <= 0.45:
                        // Masked: this key has fewer than two partials it does
                        // not share with something else already sounding, so
                        // the sound genuinely cannot decide. A finger seen
                        // *pressing* it, or its octave partner heard, settles
                        // it. Deliberately not "a fingertip is on the key" —
                        // a finger resting silently on a key is not evidence
                        // of anything, and accepting on it is how a note gets
                        // marked played while the hand just sits there.
                        confidence = 0.45 + 0.40 * v.rise[k]
                    default:
                        break
                    }
                }

                guard let c = confidence else { continue }
                st.acceptedKeys.insert(k)
                remaining.remove(k)
                _ = upcoming
                lastKeyPressTime[k] = time
                events.append(PressEvent(keyIndex: k, noteName: key.noteName,
                                         confidence: min(1, c), fingerID: "audio",
                                         timestamp: time, source: .audio))
            }

            // Wrong-note feedback, deliberately conservative: nothing that was
            // expected rose at all, one other key rang out clearly, it isn't
            // an octave/fifth partial of an expected key, and a real fingertip
            // is right there.
            if let v = verification, v.complete, !st.wrongReported, st.acceptedKeys.isEmpty,
               !groupKeys.contains(where: { v.status[$0] != .absent }),
               let wrong = v.status.indices
                    .filter({ !groupKeys.contains($0) && !upcoming.contains($0)
                              && v.status[$0] == .present && v.rise[$0] >= wrongRise })
                    .filter({ w in !groupKeys.contains { Self.isHarmonicRelative(w, $0) } })
                    .max(by: { v.rise[$0] < v.rise[$1] }),
               direct.contains(where: { tipIsOnKey($0, KeyboardLayout.keys[wrong]) }) {
                st.wrongReported = true
                events.append(PressEvent(keyIndex: wrong,
                                         noteName: KeyboardLayout.keys[wrong].noteName,
                                         confidence: v.rise[wrong] * 0.8, fingerID: "audio",
                                         timestamp: time, source: .audio))
            }
            strikes[attack.id] = st

            if let v = verification {
                let heard = v.heardKeys().map { KeyboardLayout.keys[$0].noteName }
                debug.append(String(format: "strike #%ld %.2fs heard %@", attack.id, age,
                                    heard.isEmpty ? "-" : heard.joined(separator: " ")))
                // Why each wanted note did or didn't pass, for tuning.
                for k in pendingKeys.sorted() where k >= 0 && k < 88 {
                    guard v.evaluated[k] else { continue }
                    let key = KeyboardLayout.keys[k]
                    let handNear = onBoard.contains { abs($0.localX - key.xCenter) <= reach }
                    debug.append(String(format: "  %@ %@ %.2f hand:%@", key.noteName,
                                        String(describing: v.status[k]), v.rise[k],
                                        handNear ? "y" : "n"))
                }
            } else {
                debug.append(String(format: "strike #%ld %.2fs verifying…", attack.id, age))
            }
        }

        if !pendingKeys.isEmpty {
            let need = pendingKeys.sorted().map { KeyboardLayout.keys[$0].noteName }
            debug.append("need " + need.joined(separator: " "))
        }
        return (events, debug)
    }

    /// Octave / fifth / fourth relationships share strong partials, so a
    /// played note can "light up" such a relative. Those are never called wrong.
    private static func isHarmonicRelative(_ a: Int, _ b: Int) -> Bool {
        let interval = abs(a - b) % 12
        return interval == 0 || interval == 7 || interval == 5
    }

    private func tipIsOnKey(_ tip: FingertipLocal, _ key: KeyboardLayout.Key) -> Bool {
        let surfaceY = key.isBlack
            ? KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight
            : KeyboardLayout.whiteKeyHeight
        return abs(tip.localX - key.xCenter) <= KeyboardLayout.whiteKeyWidth * onKeyXTolKeys
            && abs(tip.localZ) <= KeyboardLayout.whiteKeyDepth / 2 + onKeyZExtra
            && abs(tip.localY - surfaceY) <= onKeyYTol
    }

    /// A fingertip plausibly resting on or playing the keyboard (not a hand
    /// gesturing in the air above it).
    private func isOverKeyboard(_ tip: FingertipLocal) -> Bool {
        tip.localX >= -0.03 && tip.localX <= KeyboardLayout.totalWidth + 0.03
            && abs(tip.localZ) <= KeyboardLayout.whiteKeyDepth / 2 + 0.05
            && tip.localY >= -0.04 && tip.localY <= 0.09
    }

    private func pitchContradicts(expected: Set<Int>, snapshot: PitchSnapshot) -> Bool {
        !snapshot.activeNotes.isEmpty
            && bestPitchScore(expectedKeyIndices: expected, snapshot: snapshot) < 0.07
    }

    // MARK: - Helpers

    /// Fingertips in keyboard-local coordinates (X measured from the left
    /// edge). By default only directly-observed tips — an occlusion-
    /// reconstructed (guessed) fingertip must never satisfy the on-key
    /// requirement — but guessed tips are fine for "is a hand near here".
    private func collectFingertips(hands: [HandTracker.HandResult],
                                   keyboardNode kb: SCNNode,
                                   includeEstimated: Bool = false) -> [FingertipLocal] {
        var out: [FingertipLocal] = []
        let leftEdge = -KeyboardLayout.totalWidth / 2
        for hand in hands {
            let side = hand.isLeft ? "L" : "R"
            for (joint, name) in Self.tips {
                guard includeEstimated || !hand.estimated.contains(joint),
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

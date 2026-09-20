import Foundation
import QuartzCore

/// SETUP › CALIBRATE — a guided note-by-note pass over the keyboard.
///
/// Every tuning decision so far has been made against recordings where what
/// was actually played had to be *guessed* from the audio, which is exactly
/// the thing the detector is supposed to do — so the measurements were only
/// ever as good as the guess. This removes the guess: the app names the note,
/// the player plays it, and both the sound and the name go into the
/// diagnostics log together. Every onset captured this way is a labelled
/// example, so thresholds can be set from data instead of argument.
///
/// It deliberately advances on **any** onset, never on recognition. A
/// calibration that waits to recognise the note cannot record the cases where
/// recognition fails, which are the only ones worth having.
final class PianoCalibration: ObservableObject {
    /// Every C, D#, F# and A from C2 up to C7 — four points per octave, so
    /// each of PianoTuning's registers gets several examples, and both black
    /// and white keys are covered (they differ in how the mic hears them).
    static let defaultKeys: [Int] = {
        var out: [Int] = []
        for k in 15...87 where [3, 6, 9, 0].contains(k % 12) {
            if k >= 15 && k <= 75 { out.append(k) }
        }
        return out
    }()

    @Published private(set) var active = false
    @Published private(set) var index = 0
    private(set) var keys: [Int] = []
    private var lastAttackID = -1
    private var startedAt: TimeInterval = 0
    /// Ignore anything within this of the previous accepted strike: one key
    /// often produces a little key-noise tail.
    private let minGap: TimeInterval = 0.35
    private var lastAdvance: TimeInterval = 0

    var currentKey: Int? { active && index < keys.count ? keys[index] : nil }
    var isComplete: Bool { active && index >= keys.count }

    var prompt: String {
        guard active else { return "" }
        guard let k = currentKey else { return "CALIBRATION DONE — stop the recording" }
        return String(format: "PLAY  %@     (%d of %d)",
                      KeyboardLayout.keys[k].noteName, index + 1, keys.count)
    }

    func start(keys: [Int] = PianoCalibration.defaultKeys) {
        self.keys = keys
        index = 0
        lastAttackID = -1
        startedAt = 0                  // set from the render clock on first use
        lastAdvance = 0
        active = true
    }

    func stop() {
        active = false
        keys = []
        index = 0
    }

    /// Call once per frame with the newest attack. Returns the key that was
    /// just asked for when an onset advances the sequence, so the caller can
    /// log the pair.
    func consume(attack: AudioAttack?, time: TimeInterval) -> Int? {
        guard active, let attack, attack.id != lastAttackID,
              let key = currentKey,
              attack.confidence >= 0.25,      // a real strike, not a knock
              time - lastAdvance >= minGap
        else { return nil }
        if startedAt == 0 { startedAt = time }
        guard time - startedAt > 0.5 else { return nil }
        lastAttackID = attack.id
        lastAdvance = time
        index += 1
        return key
    }
}

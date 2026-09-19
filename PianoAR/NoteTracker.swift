import Accelerate
import Foundation
import simd

/// One detected piano strike: key `key` started sounding at `time`.
struct NoteOnset {
    let id: Int
    let key: Int              // 0...87 (A0...C8)
    let time: TimeInterval    // estimated strike time (CACurrentMediaTime clock)
    let strength: Float       // weighted partial increase, dB
    let expected: Bool        // key was expected by the song when detected
}

/// Hann-windowed magnitude spectrum of the newest `n` samples.
final class SpectrumAnalyzer {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var rp: [Float]
    private var ip: [Float]
    private var power: [Float]
    private(set) var magnitudes: [Float]
    /// Prefix sums of `magnitudes` (length n/2 + 1) for O(1) local means.
    private(set) var prefix: [Float]

    init(n: Int) {
        precondition(n > 0 && n & (n - 1) == 0, "n must be a power of two")
        self.n = n
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = .init(repeating: 0, count: n)
        rp = .init(repeating: 0, count: n / 2)
        ip = .init(repeating: 0, count: n / 2)
        power = .init(repeating: 0, count: n / 2)
        magnitudes = .init(repeating: 0, count: n / 2)
        prefix = .init(repeating: 0, count: n / 2 + 1)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` must hold exactly `n` values, oldest first.
    func analyze(_ samples: [Float]) {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        rp.withUnsafeMutableBufferPointer { rpBuf in
            ip.withUnsafeMutableBufferPointer { ipBuf in
                var split = DSPSplitComplex(realp: rpBuf.baseAddress!, imagp: ipBuf.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                power.withUnsafeMutableBufferPointer { pBuf in
                    vDSP_zvmags(&split, 1, pBuf.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        magnitudes[0] = 0                                  // bin 0 packs DC/Nyquist
        var sum: Float = 0
        prefix[0] = 0
        prefix[1] = 0
        for i in 1..<(n / 2) {
            let m = sqrtf(max(0, power[i]))
            magnitudes[i] = m
            sum += m
            prefix[i + 1] = sum
        }
    }

    /// Mean magnitude over [lo, hi] (inclusive, clamped).
    func mean(_ lo: Int, _ hi: Int) -> Float {
        let a = max(1, lo), b = min(n / 2 - 1, hi)
        guard b >= a else { return 0 }
        return (prefix[b + 1] - prefix[a]) / Float(b - a + 1)
    }
}

/// Per-key note onset detection: "did THIS key just get struck?", asked of
/// all 88 keys on every analysis hop (~11 ms).
///
/// For every key, the levels of its own partials (n·f0·√(1+B·n²), searched
/// ±35 cents) are followed over time; a strike shows up as those partials
/// jumping up together, a per-note spectral flux. Because each key has its
/// own detector, this works with other notes ringing, with the sustain pedal,
/// for chords (each member detected separately) and for repeated notes, and
/// it needs nothing from hand tracking.
///
///  * A partial only counts if it is a real, narrow spectral peak standing
///    at least 6 dB above its surroundings. A hammer thump lifts every bin
///    equally and fails that, so it can't fake notes that weren't played.
///  * Partials shared with another note the song expects at the same time
///    are skipped (C4's 3rd ~ G4's 2nd), so each chord member is judged on
///    its own evidence. At least two partials must rise (one for treble).
///  * Keys the song expects use a lower threshold than other keys, the same
///    bias commercial trainers use for the note they asked for.
///  * Bass keys use the 8192-point spectrum (semitones there are only a few
///    Hz apart); everything else the 4096-point one.
final class NoteTracker {
    private struct Partial {
        let lo: Int
        let hi: Int
        let freq: Float
        let weight: Float
    }
    private struct KeyModel {
        let f0: Float
        let long: Bool
        let partials: [Partial]
    }

    static let longSplitHz: Float = 130
    private static let ringLen = 8

    // Tunables (dB)
    private let expectedThreshold: Float = 2.5
    private let expectedThresholdBass: Float = 2.0
    private let otherThreshold: Float = 4.0
    private let partialRise: Float = 2.0
    private let minProminence: Float = 6.0
    private let refractory: TimeInterval = 0.07
    private let centsTol: Float = 35

    private let shortN: Int
    private let longN: Int
    private var sampleRate: Float = 0
    private var models: [KeyModel] = []

    // Partial level history, flattened: levelBase[key] + partial * ringLen + slot.
    private var levelBase: [Int] = []
    private var levels: [Float] = []
    private var slot = 0
    private var hopsSeen = 0

    private var prevScore = [Float](repeating: 0, count: 88)
    private var prevScore2 = [Float](repeating: 0, count: 88)
    private var prevRising = [Int](repeating: 0, count: 88)
    private var lastOnsetTime = [TimeInterval](repeating: -1, count: 88)
    /// Latest per-key score (dB), for the debug readout.
    private(set) var liveScore = [Float](repeating: 0, count: 88)

    private var expected: Set<Int> = []
    private var excluded: [Int: Set<Int>] = [:]
    private var recent: [NoteOnset] = []
    private var nextID = 1

    init(shortN: Int = 4096, longN: Int = 8192) {
        self.shortN = shortN
        self.longN = longN
    }

    static func f0(ofKey k: Int) -> Float { 440 * powf(2, Float(k + 21 - 69) / 12) }

    /// Rebuilds the per-key partial windows for a sample rate.
    func configure(sampleRate: Float) {
        guard sampleRate > 0, sampleRate != self.sampleRate else { return }
        self.sampleRate = sampleRate
        models = (0..<88).map { buildModel($0) }
        levelBase = []
        var total = 0
        for m in models {
            levelBase.append(total)
            total += m.partials.count * Self.ringLen
        }
        levels = [Float](repeating: 0, count: total)
        expected = []
        excluded = [:]
        reset()
    }

    func reset() {
        // "Very loud" history: nothing can look like a rise until real
        // levels have filled the ring.
        for i in levels.indices { levels[i] = 1_000 }
        prevScore = .init(repeating: 0, count: 88)
        prevScore2 = .init(repeating: 0, count: 88)
        prevRising = .init(repeating: 0, count: 88)
        lastOnsetTime = .init(repeating: -1, count: 88)
        hopsSeen = 0
        recent = []
    }

    /// Call once per analysis hop with both spectra freshly analysed.
    func process(short: SpectrumAnalyzer, long: SpectrumAnalyzer,
                 hopEnd: TimeInterval, hopDuration: TimeInterval,
                 expected keys: Set<Int>) -> [NoteOnset] {
        guard !models.isEmpty else { return [] }
        updateExpected(keys)
        slot = (slot + 1) % Self.ringLen
        hopsSeen += 1

        var found: [NoteOnset] = []
        for k in 0..<88 {
            let m = models[k]
            let spec = m.long ? long : short
            let mags = spec.magnitudes
            let lag = m.long ? 5 : 3
            let lagSlot = (slot - lag + 2 * Self.ringLen) % Self.ringLen
            let isExpected = expected.contains(k)
            let ex = isExpected ? (excluded[k] ?? []) : []
            let base = levelBase[k]

            var num: Float = 0
            var den: Float = 0
            var rising = 0
            for (pi, p) in m.partials.enumerated() {
                var peak = p.lo
                if p.hi > p.lo {
                    for b in (p.lo + 1)...p.hi where mags[b] > mags[peak] { peak = b }
                }
                let a = mags[peak]
                let level = 20 * log10f(a + 1e-9)
                let idx = base + pi * Self.ringLen
                let before = levels[idx + lagSlot]
                levels[idx + slot] = level

                guard !ex.contains(pi), a >= mags[peak - 1], a >= mags[peak + 1] else { continue }
                let bg = (spec.mean(peak - 12, peak - 3) + spec.mean(peak + 3, peak + 12)) * 0.5
                guard level - 20 * log10f(bg + 1e-9) >= minProminence else { continue }

                let inc = level - before
                num += p.weight * simd_clamp(inc, 0, 15)
                den += p.weight
                if inc >= partialRise { rising += 1 }
            }
            let score = den > 0 ? num / den : 0
            liveScore[k] = score

            // Peak-pick the previous hop (one hop of look-ahead).
            let p1 = prevScore[k], p2 = prevScore2[k]
            let theta: Float = isExpected ? (m.long ? expectedThresholdBass : expectedThreshold)
                                          : otherThreshold
            let needRising = m.f0 >= 1000 ? 1 : 2
            let prevHopEnd = hopEnd - hopDuration
            if hopsSeen > Self.ringLen, p1 >= theta, p1 >= p2, p1 > score,
               prevRising[k] >= needRising, prevHopEnd - lastOnsetTime[k] > refractory {
                lastOnsetTime[k] = prevHopEnd
                let windowDur = Double(m.long ? longN : shortN) / Double(sampleRate)
                found.append(NoteOnset(id: nextID, key: k, time: prevHopEnd - windowDur / 2,
                                       strength: p1, expected: isExpected))
                nextID += 1
            }
            prevScore2[k] = p1
            prevScore[k] = score
            prevRising[k] = rising
        }
        return suppressHarmonics(found, now: hopEnd)
    }

    // MARK: - Helpers

    private func buildModel(_ k: Int) -> KeyModel {
        let f0 = Self.f0(ofKey: k)
        let long = f0 < Self.longSplitHz
        let n = long ? longN : shortN
        let binHz = sampleRate / Float(n)
        let B = Self.inharmonicity(f0: f0)
        let maxPartial = f0 < 130 ? 16 : (f0 < 500 ? 12 : 8)
        let maxHz = min(sampleRate / 2 - 300, f0 >= 1000 ? 10_000 : 6_000)
        var parts: [Partial] = []
        for p in 1...maxPartial {
            if p == 1 && f0 < 80 { continue }              // phone mics barely capture it
            let pf = Float(p)
            let fc = pf * f0 * sqrtf(1 + B * pf * pf)
            if fc > maxHz { break }
            if fc < 60 { continue }
            let fLo = pf * f0 * powf(2, -centsTol / 1200) * sqrtf(1 + 0.5 * B * pf * pf)
            let fHi = pf * f0 * powf(2, centsTol / 1200) * sqrtf(1 + 2.0 * B * pf * pf)
            let c = Int((fc / binHz).rounded())
            let lo = max(2, min(Int((fLo / binHz).rounded(.down)), c))
            let hi = min(n / 2 - 3, max(Int((fHi / binHz).rounded(.up)), c))
            guard hi >= lo else { continue }
            parts.append(Partial(lo: lo, hi: hi, freq: fc, weight: (f0 + 52) / (pf * f0 + 320)))
        }
        return KeyModel(f0: f0, long: long, partials: parts)
    }

    /// Piano string stiffness by register (wound bass strings are less stiff).
    private static func inharmonicity(f0: Float) -> Float {
        if f0 < 130 { return 1.5e-4 }
        if f0 < 523 { return 3e-4 }
        if f0 < 1047 { return 1e-3 }
        return 2e-3
    }

    /// Marks partials of each expected key that coincide with a partial of
    /// another expected key (within 35 cents or 2 bins).
    private func updateExpected(_ keys: Set<Int>) {
        guard keys != expected else { return }
        expected = keys
        excluded = [:]
        let valid = keys.filter { $0 >= 0 && $0 < 88 }
        for k in valid {
            let binHz = sampleRate / Float(models[k].long ? longN : shortN)
            var ex = Set<Int>()
            for (pi, p) in models[k].partials.enumerated() {
                let tol = max(p.freq * (powf(2, centsTol / 1200) - 1), 2 * binHz)
                for o in valid where o != k {
                    if models[o].partials.contains(where: { abs($0.freq - p.freq) <= tol }) {
                        ex.insert(pi)
                        break
                    }
                }
            }
            if !ex.isEmpty { excluded[k] = ex }
        }
    }

    /// A struck note also lights up the keys of its own harmonics (octave,
    /// twelfth, double octave). Unexpected onsets sitting exactly there, at
    /// the same moment as a comparable onset, are dropped.
    private func suppressHarmonics(_ onsets: [NoteOnset], now: TimeInterval) -> [NoteOnset] {
        recent.removeAll { now - $0.time > 0.5 }
        guard !onsets.isEmpty else { return [] }
        let pool = recent + onsets
        let ghostIntervals: Set<Int> = [12, 19, 24, 28, 31]
        var kept: [NoteOnset] = []
        for o in onsets {
            let ghost = !o.expected && pool.contains { other in
                other.id != o.id && abs(other.time - o.time) < 0.08
                    && ghostIntervals.contains(o.key - other.key)
                    && other.strength >= o.strength * 0.6
            }
            if !ghost { kept.append(o) }
        }
        recent += kept
        return kept
    }
}

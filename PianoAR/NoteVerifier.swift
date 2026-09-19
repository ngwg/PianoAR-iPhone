import Accelerate
import Foundation
import simd

/// Audio verdict for one key at one strike.
enum NoteStatus: UInt8, Comparable {
    case absent = 0     // its partials did not rise — not struck
    case unsure = 1     // masked: too few partials it doesn't share with something else
    case present = 2    // its own partials rose clearly — struck

    static func < (a: NoteStatus, b: NoteStatus) -> Bool { a.rawValue < b.rawValue }
}

/// Score-informed note verification from the microphone.
///
/// The song always says which notes SHOULD sound next, so the mic never has
/// to answer "which notes are these?" (blind polyphonic transcription — out
/// of scope). It only answers "did THESE notes just get struck?", per note:
/// the spectrum just before an onset is compared with the spectrum just
/// after it, at that note's own (inharmonic) partials. A struck note's
/// partials jump up; a note merely still ringing decays; an unplayed note
/// shows nothing. This is how commercial trainers verify too (expected-note
/// salience rather than free transcription).
///
/// Method (Klapuri-weighted partial rise):
///  * partial n of note f0 at n·f0·√(1+B·n²), where f0 carries the real
///    piano's measured stretch (PianoTuning) and the window is that key's
///    learned search width — tight where the tuning is known;
///  * a partial only counts if it is a real spectral peak (not a Hann side
///    lobe of a much louder neighbour) and is actually above the local
///    background — a partial buried in noise carries no information;
///  * partials shared with ANOTHER expected chord note are skipped (C4's 3rd
///    partial ≈ G4's 2nd …), so each chord member is judged on its own;
///  * rise r = 20·log10((after+NF)/(before+NF)) with NF the local background,
///    so loud and soft notes score alike;
///  * S = Σ w·clip(r,0,15)/Σ w with w = (f0+52)/(n·f0+320).
///
/// The verdict is deliberately two-sided with no middle: **present** when the
/// key's own partials rose, **unsure** only when the key has fewer than two
/// partials it doesn't share with something else already sounding (the octave
/// case — sound genuinely cannot decide, and the caller may look at the
/// hands), **absent** otherwise. A "weak but maybe" band is what makes a
/// trainer accept notes nobody played, so there isn't one.
final class NoteVerifier {
    let fftN: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var rp: [Float]
    private var ip: [Float]
    private var power: [Float]

    /// Generous tolerance for "these two keys share this partial" tests.
    private let centsTol: Float = 35
    private let presentDB: Float = 3.5
    private let partialRiseDB: Float = 3
    private let partialSNRDB: Float = 6
    private let sideLobeDB: Float = 25
    /// Bracket on the inharmonicity estimate, and how much positional
    /// uncertainty a partial may carry before it stops being evidence.
    private let inharmLo: Float = 0.7
    private let inharmHi: Float = 1.4
    private let maxSlopCents: Float = 25
    /// How far a shared partial must stand above the lower note's smooth
    /// envelope before it counts as a second note rather than the first.
    private let smoothExcess: Float = 0.6

    /// This piano's tuning, read once per strike (see PianoTuning.snapshot).
    /// Each NoteVerifier is only ever used from the audio thread.
    private var f0Table = (0..<88).map { NoteVerifier.nominalF0(ofKey: $0) }
    private var searchTable = [Float](repeating: 35, count: 88)

    init(fftN: Int) {
        precondition(fftN > 0 && fftN & (fftN - 1) == 0, "fftN must be a power of two")
        self.fftN = fftN
        log2n = vDSP_Length(fftN.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        windowed = .init(repeating: 0, count: fftN)
        rp = .init(repeating: 0, count: fftN / 2)
        ip = .init(repeating: 0, count: fftN / 2)
        power = .init(repeating: 0, count: fftN / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Equal temperament at A4 = 440.
    static func nominalF0(ofKey k: Int) -> Float { 440 * powf(2, Float(k + 21 - 69) / 12) }

    /// What this key actually sounds at on the piano in the room.
    static func f0(ofKey k: Int) -> Float {
        nominalF0(ofKey: k) * powf(2, PianoTuning.shared.offsetCents(forKey: k) / 1200)
    }

    /// One usable partial measured at a strike.
    private struct PartialObs {
        let n: Int
        let freq: Float      // where we predicted it
        let weight: Float
        let rise: Float      // dB, after vs before
        let snr: Float       // dB above the local background
        let residual: Float  // cents from the prediction to the real peak
        let amp: Float       // measured level at the peak
    }

    /// Evaluates `keys` (0…87). `pre`/`post` must each hold `fftN` samples,
    /// oldest first. `chord` = every key currently expected together.
    /// - Parameter ringing: keys already sounding when this attack happened.
    ///   They are judged against a different null hypothesis — see `verdict`.
    func evaluate(pre: [Float], post: [Float], sampleRate: Float,
                  keys: [Int], chord: Set<Int>,
                  ringing: Set<Int> = []) -> [(key: Int, rise: Float, status: NoteStatus)] {
        guard pre.count == fftN, post.count == fftN, sampleRate > 0 else { return [] }
        let tuning = PianoTuning.shared.snapshot()
        for k in 0..<88 {
            f0Table[k] = Self.nominalF0(ofKey: k) * powf(2, tuning.offset[k] / 1200)
        }
        searchTable = tuning.search
        let before = magnitudeSpectrum(pre)
        let after  = magnitudeSpectrum(post)
        // Nothing more than 50 dB under the loudest thing in the frame is a
        // peak worth believing.
        let globalFloor = (after.max() ?? 0) * powf(10, -50 / 20)
        let binHz  = sampleRate / Float(fftN)
        var floorCache: [Int: Float] = [:]

        func noiseFloor(_ b: Int) -> Float {
            if let v = floorCache[b] { return v }
            // 20th percentile of the pre-onset spectrum around the bin: the
            // background under any ringing partials.
            let lo = max(1, b - 16), hi = min(before.count - 1, b + 16)
            var vals = Array(before[lo...hi])
            vals.sort()
            let v = max(vals[vals.count / 5], 1e-7)
            floorCache[b] = v
            return v
        }

        // Every key's usable partials, measured once (competitors reuse them).
        var cache: [Int: [PartialObs]] = [:]
        func measure(_ k: Int) -> [PartialObs] {
            if let c = cache[k] { return c }
            let f0 = f0Table[k]
            let B = Self.inharmonicity(f0: f0)
            let tol = searchTable[k]
            let maxN = f0 < 130 ? 16 : 12
            let maxHz: Float = min(sampleRate / 2 - 200, f0 >= 1000 ? 10_000 : 6_000)
            var obs: [PartialObs] = []
            for n in 1...maxN {
                if n == 1 && f0 < 80 { continue }          // phone mics barely capture it
                let nf = Float(n)
                let fc = nf * f0 * sqrtf(1 + B * nf * nf)
                if fc > maxHz { break }
                // Below ~75 Hz there is nothing worth reading: the soundboard
                // stops radiating efficiently under its first mode (~49 Hz)
                // and the phone's own microphone rolls the rest away. Bass
                // keys are identified from partials 3-8 regardless.
                if fc < 75 { continue }

                // How badly the inharmonicity guess smears this partial. B is
                // a per-register estimate, not a measurement, and its effect
                // grows as n²: by partial 8 in the treble the resulting window
                // is wider than a semitone, so the "peak" found in it is as
                // likely to belong to a neighbouring key as to this one. Such
                // a partial always finds something and therefore proves
                // nothing — drop it rather than let it vote.
                let slopLo = sqrtf(1 + inharmLo * B * nf * nf)
                let slopHi = sqrtf(1 + inharmHi * B * nf * nf)
                if 1200 * log2f(slopHi / slopLo) > maxSlopCents { continue }

                let fLo = nf * f0 * powf(2, -tol / 1200) * slopLo
                let fHi = nf * f0 * powf(2,  tol / 1200) * slopHi
                let c = Int((fc / binHz).rounded())
                let lo = max(1, min(Int((fLo / binHz).rounded(.down)), c))
                let hi = min(after.count - 2, max(Int((fHi / binHz).rounded(.up)), c))
                guard hi > lo else { continue }

                var peakBin = lo
                for b in lo...hi where after[b] > after[peakBin] { peakBin = b }
                let aAfter = after[peakBin]
                // Must be a genuine peak, not the flank of something outside.
                guard aAfter >= after[peakBin - 1], aAfter >= after[peakBin + 1] else { continue }
                if aAfter < globalFloor { continue }
                if loudNeighbour(after, peak: aAfter, lo: lo, hi: hi) { continue }

                var aBefore: Float = 0
                for b in lo...hi { aBefore = max(aBefore, before[b]) }
                let nfl = noiseFloor(peakBin)
                // Sub-bin peak position: at 4096/48k one bin is ~12 Hz, which
                // is 20 cents up at A4 — far too coarse to learn a tuning from.
                let y0 = after[peakBin - 1], y1 = aAfter, y2 = after[peakBin + 1]
                let denom = y0 - 2 * y1 + y2
                let shift = abs(denom) > 1e-12 ? simd_clamp(0.5 * (y0 - y2) / denom, -0.5, 0.5) : 0
                let peakHz = (Float(peakBin) + shift) * binHz
                obs.append(PartialObs(n: n,
                                      freq: fc,
                                      weight: (f0 + 52) / (nf * f0 + 320),
                                      rise: 20 * log10f((aAfter + nfl) / (aBefore + nfl)),
                                      snr: 20 * log10f(aAfter / nfl),
                                      residual: 1200 * log2f(max(peakHz, 1) / fc),
                                      amp: aAfter))
            }
            cache[k] = obs
            return obs
        }

        /// Verdict from a key's partials, skipping those `skip` rejects.
        ///
        /// `struck` = this key was already sounding, so the question changes.
        /// Striking a key that is still ringing cannot produce much of a rise:
        /// the partials are already occupied, and adding a second sound of
        /// equal amplitude to one that has barely decayed is at most about
        /// +3 dB — and if the new hammer arrives out of phase with what is
        /// there, the partial can *drop* by 10 dB or more. So for a ringing
        /// key the null hypothesis is not silence but **decay**: at 3-8 dB
        /// per second, over the 40 ms measured here a note left alone falls
        /// slightly. A rise of even 1.2 dB is already inconsistent with that,
        /// and holding re-strikes to the same 3.5 dB bar as fresh notes is
        /// why repeated notes went unheard.
        func verdict(_ obs: [PartialObs], f0: Float, struck: Bool = false,
                     skip: (Float) -> Bool) -> (score: Float, status: NoteStatus) {
            let presentBar = struck ? 1.2 : presentDB
            let riseBar    = struck ? 1.0 : partialRiseDB
            var sum: Float = 0, wSum: Float = 0
            var rising = 0, usable = 0
            var best: (r: Float, snr: Float) = (0, 0)
            for p in obs where !skip(p.freq) {
                usable += 1
                // Below the background there is nothing to see: including it
                // would let the noise floor vote.
                guard p.snr >= 0 else { continue }
                sum  += p.weight * simd_clamp(p.rise, 0, 15)
                wSum += p.weight
                if p.rise >= riseBar && p.snr >= partialSNRDB { rising += 1 }
                if p.rise > best.r, p.snr > 0 { best = (p.rise, p.snr) }
            }
            let s = wSum > 0 ? sum / wSum : 0
            // Masked — fewer than two partials this key doesn't share with
            // something else already sounding. Only here does sound abstain.
            if usable < 2 { return (s, .unsure) }
            if s >= presentBar && rising >= 2 { return (s, .present) }
            // A soft note spreads a small rise over many partials: the
            // weighted mean dilutes it, but four clean rising partials at
            // once is not something a decaying or sympathetic string does.
            if rising >= 4 && s >= 2 { return (s, .present) }
            // Top octave: two or three partials is all there is up there.
            if f0 >= 1000 && usable <= 3 && best.r >= 9 && best.snr >= 12 { return (s, .present) }
            return (s, .absent)
        }

        func coincides(_ f: Float, _ list: [PartialObs]) -> Bool {
            let tol = max(f * (powf(2, centsTol / 1200) - 1), 2 * binHz)
            return list.contains { abs($0.freq - f) <= tol }
        }

        var out: [(key: Int, rise: Float, status: NoteStatus)] = []
        for k in keys where k >= 0 && k < 88 {
            let f0 = f0Table[k]
            let others = chord.subtracting([k])
            let obsK = measure(k)
            let reStruck = ringing.contains(k)
            var (score, status) = verdict(obsK, f0: f0, struck: reStruck) {
                self.sharesPartial($0, withAnyOf: others, binHz: binHz)
            }

            // Explain-away (expected keys only). Many keys share partials with
            // other keys — play A3 and E4's 2nd and 4th partials rise too. If a
            // nearby key that is NOT expected was clearly struck and accounts
            // for this key's rising partials, this key only counts if its OWN
            // partials (the ones that key doesn't have) rose as well.
            if chord.contains(k), status != .absent {
                for j in max(0, k - 24)...min(87, k + 24) where j != k && !chord.contains(j) {
                    let obsJ = measure(j)
                    guard obsK.contains(where: { coincides($0.freq, obsJ) }) else { continue }
                    let jOwn = verdict(obsJ, f0: f0Table[j]) {
                        coincides($0, obsK) || self.sharesPartial($0, withAnyOf: chord, binHz: binHz)
                    }
                    guard jOwn.status == .present, jOwn.score >= 4 else { continue }
                    let kOwn = verdict(obsK, f0: f0, struck: reStruck) {
                        coincides($0, obsJ) || self.sharesPartial($0, withAnyOf: others, binHz: binHz)
                    }
                    if kOwn.status == .present { continue }      // k has its own proof
                    // k has no partials of its own — the octave case. Its
                    // frequencies cannot settle this: a note's 2nd partial and
                    // the octave above it differ by well under a tenth of one
                    // FFT bin, and stretch tuning deliberately closes even
                    // that. But the *amplitudes* can. A single note's partials
                    // fall away smoothly; two notes an octave apart make every
                    // even partial of the lower one stick up above that smooth
                    // curve. So ask whether the shared partials are louder
                    // than j alone could account for (Klapuri).
                    if kOwn.status == .unsure,
                       excessOverSmooth(obsK, of: obsJ) >= smoothExcess {
                        continue                                 // genuinely both
                    }
                    status = kOwn.status == .unsure ? .unsure : .absent
                    score = kOwn.score
                    break
                }
            }

            // A note we are sure about is also a tuning measurement: where its
            // low partials really sat tells us how this register is tuned.
            if status == .present, score >= 5 { learnTuning(key: k, from: obsK) }
            out.append((k, simd_clamp(score / 8, 0, 1), status))
        }
        return out
    }

    /// How far the partials this key shares with `other` stand above the
    /// smooth envelope of `other` alone, as a fraction of that envelope.
    ///
    /// Klapuri's spectral-smoothness argument: one string's partial envelope
    /// is a smooth, mostly falling curve, so replacing every partial with the
    /// smaller of itself and the local mean of its neighbours gives what that
    /// note alone would look like. Whatever stands above that belongs to
    /// something else. This is what separates "C3 was played" from "C3 and C4
    /// were played" — in the second case C3's even partials are lifted, and
    /// its odd ones are not.
    private func excessOverSmooth(_ obs: [PartialObs], of other: [PartialObs]) -> Float {
        guard other.count >= 3 else { return 0 }
        var best: Float = 0
        for (i, o) in other.enumerated() {
            // Octave-wide window in partial number, i.e. n/2 ... 2n.
            var sum: Float = 0, wsum: Float = 0
            for (j, q) in other.enumerated() where j != i {
                guard q.n * 2 >= o.n, q.n <= o.n * 2 else { continue }
                let w = 1 / (1 + abs(Float(q.n - o.n)))
                sum += q.amp * w; wsum += w
            }
            guard wsum > 0 else { continue }
            let smooth = min(o.amp, sum / wsum)          // a_j <- min(a_j, g_j)
            guard smooth > 1e-7 else { continue }
            // Only partials this key actually shares with `other` say anything.
            let tol = max(o.freq * 0.02, 1)
            guard obs.contains(where: { abs($0.freq - o.freq) <= tol }) else { continue }
            best = max(best, (o.amp - smooth) / smooth)
        }
        return best
    }

    /// Median residual of the low partials — median, because one of them may
    /// be sitting on another note's partial and be pulled off.
    private func learnTuning(key k: Int, from obs: [PartialObs]) {
        var res = obs.filter { $0.n <= 2 && $0.snr >= 12 && $0.rise >= partialRiseDB }
            .map(\.residual)
        guard !res.isEmpty else { return }
        res.sort()
        PianoTuning.shared.observe(key: k, residualCents: res[res.count / 2],
                                   confidence: min(1, Float(res.count) * 0.5))
    }

    /// Stiffness of piano strings by register (defaults from the literature;
    /// bass strings are wound and much less stiff than the treble).
    private static func inharmonicity(f0: Float) -> Float {
        if f0 < 130 { return 1.5e-4 }
        if f0 < 523 { return 3e-4 }
        if f0 < 1047 { return 1e-3 }
        return 2e-3
    }

    /// Whether frequency `f` coincides (within 35 cents or 2 bins) with any
    /// partial (1…16) of the given other keys.
    private func sharesPartial(_ f: Float, withAnyOf others: Set<Int>, binHz: Float) -> Bool {
        guard !others.isEmpty else { return false }
        let tolHz = max(f * (powf(2, centsTol / 1200) - 1), 2 * binHz)
        for o in others {
            let g0 = f0Table[o]
            let B = Self.inharmonicity(f0: g0)
            // Only partial numbers near f / g0 can match.
            let guess = Int((f / g0).rounded())
            let lower = max(1, guess - 1), upper = min(16, guess + 1)
            guard lower <= upper else { continue }
            for m in lower...upper {
                let fm = Float(m)
                if abs(fm * g0 * sqrtf(1 + B * fm * fm) - f) <= tolHz { return true }
            }
        }
        return false
    }

    /// True when a peak ≥ 25 dB louder sits within ±4 bins outside the search
    /// window — our "peak" would then just be its side lobe.
    private func loudNeighbour(_ s: [Float], peak: Float, lo: Int, hi: Int) -> Bool {
        let limit = peak * powf(10, sideLobeDB / 20)
        for b in max(1, lo - 4)..<lo where s[b] > limit { return true }
        for b in (hi + 1)...min(s.count - 1, hi + 4) where s[b] > limit { return true }
        return false
    }

    private func magnitudeSpectrum(_ samples: [Float]) -> [Float] {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftN))
        rp.withUnsafeMutableBufferPointer { rpBuf in
            ip.withUnsafeMutableBufferPointer { ipBuf in
                var split = DSPSplitComplex(realp: rpBuf.baseAddress!, imagp: ipBuf.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(fftN / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                power.withUnsafeMutableBufferPointer { pBuf in
                    vDSP_zvmags(&split, 1, pBuf.baseAddress!, 1, vDSP_Length(fftN / 2))
                }
            }
        }
        var mags = [Float](repeating: 0, count: fftN / 2)
        for i in 1..<(fftN / 2) { mags[i] = sqrtf(max(0, power[i])) }   // bin 0 packs DC/Nyquist
        return mags
    }
}

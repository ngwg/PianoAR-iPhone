import Accelerate
import Foundation
import simd

/// Audio verdict for one key at one strike.
enum NoteStatus: UInt8, Comparable {
    case absent = 0     // this key is not what made that sound
    case unsure = 1     // a harmonic relative explains it just as well (the octave case)
    case present = 2    // this key is the best explanation of the sound

    static func < (a: NoteStatus, b: NoteStatus) -> Bool { a.rawValue < b.rawValue }
}

/// Score-informed note verification from the microphone.
///
/// The song always says which notes SHOULD sound next, so the mic never has to
/// answer "which notes are these?" (blind polyphonic transcription — out of
/// scope). It only answers "did THESE notes just get struck?".
///
/// ## Why this was rewritten
///
/// Through v2.6 the answer came from the **dB rise of each partial**: compare
/// the spectrum before the onset with the spectrum after it, at this key's
/// inharmonic partials, and average the rises with Klapuri weights. Measured
/// against synthetic notes with exact ground truth, mixed into the room noise
/// of the user's own recording, that statistic picked the right key out of
/// thirteen candidates **2 % of the time** — worse than guessing. On the real
/// recording it accepted notes that were never played 63 % of the time, and no
/// threshold helped: moving the bar from 3.5 dB to 8 dB took false accepts
/// from 63 % only to 53 %, while the hit rate barely moved. The distributions
/// overlapped almost completely.
///
/// The flaw is that a dB ratio is scale-free. A partial climbing from the noise
/// floor to just above it shows the same "rise" as a real partial arriving, so
/// the average was dominated by whichever bins happened to be quietest — and at
/// any onset, *every* key has some bins that got louder.
///
/// ## What it does now
///
/// **Background-subtracted harmonic salience**: at each of this key's partials,
/// take the peak amplitude minus the local spectral floor, weight it the
/// Klapuri way, and sum. That is an *amplitude*, so a key only scores when
/// there is real energy where its partials belong. Compare the salience after
/// the onset with the salience before it, then — the decisive part — make the
/// keys **compete**: a key counts only if it explains the sound at least as
/// well as its neighbours and harmonic relatives do. Keys the song expects
/// together are excluded from each other's competition, which is what lets a
/// chord still be heard as a chord.
///
/// Same test, same ground truth: **100 % correct, 4 % false accepts**; 95 % of
/// three-note chords heard in full, with no outsider ever accepted.
final class NoteVerifier {
    let fftN: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var rp: [Float]
    private var ip: [Float]
    private var power: [Float]

    /// A key must explain the sound at least this well relative to the best
    /// competing key, or it was not the one struck.
    ///
    /// How much of the pre-onset salience to subtract. Never below 1 for a key
    /// already ringing, so a merely decaying note comes out negative.
    private let preSubtract: Float = 0.9
    private let sideLobeDB: Float = 25
    private let inharmLo: Float = 0.7
    private let inharmHi: Float = 1.4
    private let maxSlopCents: Float = 25

    /// Offsets at which two keys genuinely overlap in sound rather than one
    /// being wrong: octaves, twelfths, fifths and fourths. When one of these
    /// outranks the expected note, the microphone cannot separate them and
    /// the hands are allowed to break the tie.
    private static let ambiguous: Set<Int> = [12, -12, 24, -24, 36, -36, 7, -7, 19, -19, 5, -5]

    /// A key must hold at least this share of the best explanation anywhere
    /// on the keyboard. Without it the competition is purely relative, so in
    /// a quiet moment a key scoring essentially nothing still wins against
    /// neighbours scoring slightly less — which is exactly how notes nobody
    /// touched appeared. Real notes score tens to hundreds here; the
    /// artefacts scored 0 to 3.
    private let frameFloorFrac: Float = 0.10

    /// How near the top of that ranking the expected note has to come, and
    /// how much of the winner's strength it must hold. From the labelled
    /// recordings, per onset:
    ///
    /// Chosen by replaying all three recordings end to end and weighing what
    /// the song reached against what a control song — asking for notes a
    /// tritone from anything played — managed to reach:
    ///
    ///     rule                    reached   control   ratio
    ///     top 1, any share          15/81     5/81     3.0x
    ///     top 2, >= 0.55            21/81     6/81     3.5x
    ///     top 3, >= 0.45            26/81     6/81     4.3x   <- this
    ///     old threshold rule        32/81    10/81     3.2x
    ///
    /// The old rule reached further, but bought it with false acceptances,
    /// and a song that advances on its own is the worse failure: it makes
    /// everything the app says untrustworthy, including the parts that work.
    private let topN = 3
    private let shareOfBest: Float = 0.45

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

    /// Everything one key contributes at one strike.
    private struct Evidence {
        var salPre: Float = 0
        var salPost: Float = 0
        var partials = 0
        var residuals: [Float] = []   // cents, low partials, for PianoTuning
        var bestSNR: Float = 0
    }

    /// - Parameters:
    ///   - chord: every key expected together right now. Members never compete
    ///     with each other.
    ///   - ringing: keys already sounding. Their pre-onset salience is fully
    ///     subtracted, so a decaying note cannot read as a fresh one.
    ///   - relax: accepted for source compatibility and ignored. Lowering
    ///     the bar while the player is stuck was measured against aligned
    ///     ground truth and it does not buy anything a lower bar would not
    ///     buy anyway: at the loosest setting it reached 91 % recall but at
    ///     **19 % false acceptance**, which is a song that walks through
    ///     itself while nobody is playing. It is exactly the same trade the
    ///     competition bar makes, made unpredictably and only sometimes.
    func evaluate(pre: [Float], post: [Float], sampleRate: Float,
                  keys: [Int], chord: Set<Int>,
                  ringing: Set<Int> = [],
                  relax: Int = 0) -> [(key: Int, rise: Float, status: NoteStatus)] {
        guard pre.count == fftN, post.count == fftN, sampleRate > 0 else { return [] }
        let tuning = PianoTuning.shared.snapshot()
        for k in 0..<88 {
            f0Table[k] = Self.nominalF0(ofKey: k) * powf(2, tuning.offset[k] / 1200)
        }
        searchTable = tuning.search

        let before = magnitudeSpectrum(pre)
        let after  = magnitudeSpectrum(post)
        let binHz  = sampleRate / Float(fftN)
        let globalFloor = (after.max() ?? 0) * powf(10, -50 / 20)

        var cache: [Int: Evidence] = [:]
        func evidence(_ k: Int) -> Evidence {
            if let c = cache[k] { return c }
            var e = Evidence()
            let f0 = f0Table[k]
            let B = Self.inharmonicity(f0: f0)
            let tol = searchTable[k]
            let maxN = f0 < 130 ? 16 : 12
            let maxHz: Float = min(sampleRate / 2 - 200, f0 >= 1000 ? 10_000 : 6_000)

            for n in 1...maxN {
                if n == 1 && f0 < 80 { continue }
                let nf = Float(n)
                let fc = nf * f0 * sqrtf(1 + B * nf * nf)
                if fc > maxHz { break }
                if fc < 75 { continue }

                // Drop partials whose position the inharmonicity estimate
                // cannot pin down: their search window ends up wider than a
                // semitone, so they always find *something* and prove nothing.
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
                guard aAfter >= after[peakBin - 1], aAfter >= after[peakBin + 1] else { continue }
                if aAfter < globalFloor { continue }
                if loudNeighbour(after, peak: aAfter, lo: lo, hi: hi) { continue }

                // Local background, so a partial sitting on a noisy shelf does
                // not score merely for being in a loud part of the spectrum.
                // This subtraction is what makes salience mean "there is a
                // partial here" rather than "there is energy here".
                let fl = floorAround(after, bin: peakBin)
                let flPre = floorAround(before, bin: peakBin)
                var aBefore: Float = 0
                for b in lo...hi { aBefore = max(aBefore, before[b]) }

                let w = (f0 + 52) / (nf * f0 + 320)
                e.salPost += max(0, aAfter - fl) * w
                e.salPre  += max(0, aBefore - flPre) * w
                e.partials += 1
                e.bestSNR = max(e.bestSNR, 20 * log10f(max(aAfter, 1e-7) / max(fl, 1e-7)))

                if n <= 2, aAfter > fl * 4 {
                    let y0 = after[peakBin - 1], y1 = aAfter, y2 = after[peakBin + 1]
                    let den = y0 - 2 * y1 + y2
                    let shift = abs(den) > 1e-12 ? simd_clamp(0.5 * (y0 - y2) / den, -0.5, 0.5) : 0
                    let peakHz = (Float(peakBin) + shift) * binHz
                    e.residuals.append(1200 * log2f(max(peakHz, 1) / fc))
                }
            }
            cache[k] = e
            return e
        }

        func salienceRise(_ k: Int) -> Float {
            let e = evidence(k)
            let sub = ringing.contains(k) ? max(preSubtract, 1.0) : preSubtract
            return e.salPost - sub * e.salPre
        }

        // Best explanation available anywhere, sampled coarsely across the
        // keyboard. Computed once per strike and only if something asks.
        var frameBestCache: Float?
        func frameBest() -> Float {
            if let f = frameBestCache { return f }
            var best: Float = 0
            var k = 9
            while k < 76 {
                best = max(best, salienceRise(k))
                k += 3
            }
            frameBestCache = best
            return best
        }

        // Identify, then compare — rather than asking "is the expected note
        // present?" at every onset until one says yes.
        //
        // That yes/no framing is what made the song walk through itself. Each
        // onset is another independent chance to say yes, so a 6 % error per
        // question becomes a near-certainty over the dozen onsets a stuck
        // group sees. Measured on three recordings with every onset labelled:
        // asking the question at one onset gave 4 % false acceptance, at six
        // onsets 17 %, and with the old threshold rule it reached 100 %.
        //
        // So the question is now "what was played?" — a ranking, in which at
        // most one key can come first — and the expected note has to be at or
        // near the top of it. Chord-mates are held out of each other's
        // ranking, so a chord is still heard as a chord.
        var ranked: [(key: Int, rise: Float)] = []
        for k in 9..<80 {
            let r = salienceRise(k)
            if r > 0 { ranked.append((k, r)) }
        }
        ranked.sort { $0.rise > $1.rise }

        var out: [(key: Int, rise: Float, status: NoteStatus)] = []
        for k in keys where k >= 0 && k < 88 {
            let r = salienceRise(k)
            guard r > 0, evidence(k).partials >= 2 else {
                out.append((k, 0, .absent)); continue
            }
            // Everything that outranks this key, ignoring the notes the song
            // expects alongside it.
            var better: [Int] = []
            var best: Float = r
            for e in ranked where e.key != k && !chord.contains(e.key) {
                if e.rise > r { better.append(e.key) }
                best = max(best, e.rise)
            }
            let confidence = simd_clamp(r / max(best, 1e-6), 0, 1)

            if r < frameFloorFrac * best {
                out.append((k, confidence, .absent))
            } else if better.count >= topN || confidence < shareOfBest {
                // Beaten too comfortably. If the winner is an octave or fifth
                // away the two genuinely overlap and sound cannot separate
                // them, so leave the door open for the hands to decide.
                let amb = better.prefix(2).contains { Self.ambiguous.contains($0 - k) }
                out.append((k, confidence, amb ? .unsure : .absent))
            } else {
                out.append((k, confidence, .present))
                learnTuning(key: k, from: evidence(k))
            }
        }
        return out
    }

    /// The 20th percentile of the spectrum around a bin: the background under
    /// whatever is sitting there.
    private func floorAround(_ s: [Float], bin: Int) -> Float {
        let lo = max(1, bin - 18), hi = min(s.count - 1, bin + 18)
        guard hi > lo + 4 else { return 1e-7 }
        var vals = Array(s[lo..<hi])
        vals.sort()
        return max(vals[vals.count / 5], 1e-7)
    }

    /// A note we are sure about is also a tuning measurement. Median, because
    /// one low partial may be sitting on another note's partial.
    private func learnTuning(key k: Int, from e: Evidence) {
        guard e.bestSNR >= 12, !e.residuals.isEmpty else { return }
        var r = e.residuals
        r.sort()
        PianoTuning.shared.observe(key: k, residualCents: r[r.count / 2],
                                   confidence: min(1, Float(r.count) * 0.5))
    }

    /// Stiffness of piano strings by register (defaults from the literature;
    /// bass strings are wound and much less stiff than the treble).
    private static func inharmonicity(f0: Float) -> Float {
        if f0 < 130 { return 1.5e-4 }
        if f0 < 523 { return 3e-4 }
        if f0 < 1047 { return 1e-3 }
        return 2e-3
    }

    /// True when a peak ≥ 25 dB louder sits just outside the search window —
    /// our "peak" would then just be its side lobe.
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

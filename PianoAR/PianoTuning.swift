import Foundation

/// What the *actual* piano in the room is tuned to.
///
/// No acoustic piano sits on textbook equal temperament at A4 = 440.000:
///  * the whole instrument drifts — a few cents after a week, 10–20 cents
///    after a year without a tuning;
///  * every piano is *stretched* (the Railsback curve). Tuners set octaves by
///    matching partials, and because real strings are stiff, partial 2 sits
///    above 2·f0. The result is a bass that runs flat and a treble that runs
///    sharp — a couple of cents around A4, ±30 cents or more at the ends.
///
/// Searching a fixed ±35 cents around the textbook frequency therefore fails
/// twice over: too wide in the middle, where it lets a neighbouring key's
/// partial into the window and makes a note look played when it wasn't, and
/// too narrow at the ends, where the real partial has moved further than that
/// and the note looks unplayed when it was.
///
/// So: start from the average Railsback curve, then learn the real one from
/// the notes the verifier is *sure* about, per register, and tighten the
/// search window as the estimate settles. Nothing is asked of the player, and
/// what it learns is kept for next time — it is the same piano tomorrow.
final class PianoTuning {
    static let shared = PianoTuning()

    /// 8 bands of 11 keys: fine enough to follow the stretch curve, coarse
    /// enough that a handful of notes teaches a whole register.
    private static let bandCount = 8
    private static let bandSize = 11
    private static let maxOffset: Float = 70        // cents, runaway guard

    private let lock = NSLock()
    private var cents: [Float]
    private var weight: [Float]
    private var dirty = false

    /// Average measured stretch of an upright/small grand, in cents from
    /// equal temperament, at the A of each octave (A0…A7) and the top C.
    private static let railsback: [(key: Int, cents: Float)] = [
        (0, -30), (12, -13), (24, -6), (36, -2), (48, 0),
        (60, 4), (72, 11), (84, 22), (87, 30),
    ]

    private init() {
        let saved = UserDefaults.standard.array(forKey: "tuning.cents") as? [Double]
        if let saved, saved.count == Self.bandCount {
            cents = saved.map(Float.init)
            weight = [Float](repeating: 2, count: Self.bandCount)   // trust, but keep adapting
        } else {
            cents = (0..<Self.bandCount).map { Self.prior(forKey: $0 * Self.bandSize + 5) }
            weight = [Float](repeating: 0, count: Self.bandCount)
        }
    }

    /// Railsback stretch at one key, linearly interpolated between the anchors.
    static func prior(forKey k: Int) -> Float {
        let k = min(87, max(0, k))
        for i in 1..<railsback.count {
            let a = railsback[i - 1], b = railsback[i]
            if k <= b.key {
                let t = Float(k - a.key) / Float(max(1, b.key - a.key))
                return a.cents + (b.cents - a.cents) * t
            }
        }
        return railsback[railsback.count - 1].cents
    }

    /// How far this key really is from equal temperament, in cents.
    /// Interpolated between band centres so neighbouring keys stay smooth.
    func offsetCents(forKey k: Int) -> Float {
        let pos = (Float(min(87, max(0, k))) - Float(Self.bandSize) / 2) / Float(Self.bandSize)
        let i = Int(floor(pos))
        let t = pos - Float(i)
        lock.lock(); defer { lock.unlock() }
        let lo = cents[min(Self.bandCount - 1, max(0, i))]
        let hi = cents[min(Self.bandCount - 1, max(0, i + 1))]
        return lo + (hi - lo) * t
    }

    /// Half-width of the partial search window, in cents.
    ///
    /// Starts at ±65 cents and closes to ±19 as the register is heard. The
    /// wide start is not slack, it is the way out of a deadlock: a household
    /// piano 30–50 cents flat is entirely ordinary, and with a fixed ±35-cent
    /// window every partial of every note falls outside it, so nothing ever
    /// verifies — and because the tuning is learned from notes that verify,
    /// nothing is ever learned either. The app would simply never work on
    /// that piano and would give no hint why. ±65 cents still cannot reach
    /// the neighbouring semitone (100 cents away), so the worst case is a few
    /// generous notes in the first bars, and it tightens within a handful.
    func searchCents(forKey k: Int) -> Float {
        lock.lock(); defer { lock.unlock() }
        return Self.width(weight[Self.band(k)])
    }

    private static func width(_ w: Float) -> Float { 19 + 46 * expf(-w / 4) }

    /// Every key's offset and search width in one lock acquisition.
    ///
    /// `evaluate` runs on the realtime audio thread and touches these for
    /// every partial of every candidate key — thousands of times per strike.
    /// Taking a lock that often on that thread risks a priority inversion and
    /// a dropout, so it is taken exactly once per strike instead.
    func snapshot() -> (offset: [Float], search: [Float]) {
        lock.lock(); defer { lock.unlock() }
        var offset = [Float](repeating: 0, count: 88)
        var search = [Float](repeating: 0, count: 88)
        for k in 0..<88 {
            let pos = (Float(k) - Float(Self.bandSize) / 2) / Float(Self.bandSize)
            let i = Int(floor(pos)), t = pos - Float(Int(floor(pos)))
            let lo = cents[min(Self.bandCount - 1, max(0, i))]
            let hi = cents[min(Self.bandCount - 1, max(0, i + 1))]
            offset[k] = lo + (hi - lo) * t
            search[k] = Self.width(weight[Self.band(k)])
        }
        return (offset, search)
    }

    /// Feed back the residual measured on a note we are sure about.
    /// `c` is how far the real partial sat from where we predicted it
    /// (already including the current offset), `confidence` ≈ 0…1.
    func observe(key k: Int, residualCents c: Float, confidence: Float) {
        guard abs(c) < 55, confidence > 0 else { return }       // outlier / octave slip
        let b = Self.band(k)
        lock.lock()
        let rate = min(0.25, 0.30 * confidence / (1 + weight[b] * 0.35))
        cents[b] = min(Self.maxOffset, max(-Self.maxOffset, cents[b] + c * rate))
        weight[b] = min(40, weight[b] + confidence)
        dirty = true
        lock.unlock()
    }

    /// Cheap enough to call once a second from the render loop.
    func saveIfNeeded() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = cents.map(Double.init)
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: "tuning.cents")
    }

    /// Back to the textbook stretch curve — for a different piano, or when a
    /// bad session has pulled a register off.
    func reset() {
        lock.lock()
        cents = (0..<Self.bandCount).map { Self.prior(forKey: $0 * Self.bandSize + 5) }
        weight = [Float](repeating: 0, count: Self.bandCount)
        dirty = true
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: "tuning.cents")
    }

    /// One line for the debug panel: learned offset per register.
    func readout() -> String {
        lock.lock(); defer { lock.unlock() }
        let parts = zip(cents, weight).map { String(format: "%+.0f%@", $0.0, $0.1 >= 3 ? "" : "?") }
        return "tune " + parts.joined(separator: " ")
    }

    private static func band(_ k: Int) -> Int {
        min(bandCount - 1, max(0, k / bandSize))
    }
}

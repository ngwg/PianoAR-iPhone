import AVFoundation
import Accelerate
import Combine
import Foundation
import QuartzCore

struct DetectedNote {
    let keyIndex: Int       // 0...87
    let midiNote: Int       // 21...108
    let magnitude: Float    // 0...1 normalized debug confidence
    let isOnset: Bool       // true when this is the pitch hint nearest an attack
}

struct AudioAttack {
    let id: Int              // monotonically increasing per detector run
    let confidence: Float
    let onsetScore: Float
    let lowBandScore: Float
    let midBandScore: Float
    let highBandScore: Float
    let pitchHintKeyIndex: Int?
    let timestamp: TimeInterval   // capture time of the onset (CACurrentMediaTime clock)
}

/// Per-key evidence that each key was freshly struck at one attack — see
/// NoteVerifier. Filled in stages as post-onset audio arrives: middle and
/// treble keys ~0.1 s after the onset, bass keys ~0.19 s, and a second,
/// later look at middle/treble for rolled chords ~0.15 s.
struct StrikeVerification {
    let attackID: Int
    let timestamp: TimeInterval          // onset time, same as the attack's
    var rise: [Float] = .init(repeating: 0, count: 88)            // 0...1
    var status: [NoteStatus] = .init(repeating: .absent, count: 88)
    var evaluated: [Bool] = .init(repeating: false, count: 88)
    var complete = false

    func heardKeys() -> [Int] {
        status.indices.filter { status[$0] == .present }
    }

    mutating func merge(key: Int, rise r: Float, status s: NoteStatus) {
        rise[key] = max(rise[key], r)
        status[key] = max(status[key], s)
        evaluated[key] = true
    }
}

struct PitchSnapshot {
    let activeNotes: [DetectedNote]           // debug pitch hints for the latest attack
    let attack: AudioAttack?                  // most recent attack — sticky until replaced
    let recentAttacks: [AudioAttack]          // oldest first, last ~1.5 s
    let verifications: [StrikeVerification]   // oldest first, last ~2 s
    let listening: Bool                       // microphone running
    let timestamp: TimeInterval

    static let empty = PitchSnapshot(activeNotes: [], attack: nil, recentAttacks: [],
                                     verifications: [], listening: false, timestamp: 0)

    func verification(for attackID: Int) -> StrikeVerification? {
        verifications.last { $0.attackID == attackID }
    }
}

/// Microphone-side piano attack detector + expected-note verifier.
///
/// Audio answers two questions: "did a piano-like attack happen, and when?"
/// (spectral-flux onset detection on a short window) and, per attack, "which
/// keys got freshly struck?" (NoteVerifier, long window). The press detector
/// only ever asks the second question about the keys the song expects next.
final class AudioPitchDetector: ObservableObject {
    // Debug readout for the in-headset panel. Lock-protected instead of
    // @Published: publishing from the audio thread ~12×/s re-rendered the
    // whole SwiftUI tree for text nobody could see.
    private let debugStore = Locked<[String]>([])
    private let micState = Locked<String>("mic off")

    /// Safe from any thread.
    func debugSnapshot() -> [String] { [micState.get()] + debugStore.get() }

    // Short-window STFT for onset timing. 2048 @ 48 kHz is ~43 ms, hop 512 is
    // ~11 ms.
    private let fftN = 2048
    private let hop = 512
    private let log2n: vDSP_Length = 11

    // More sensitive than v2 (0.0015 / 3.0 / 0.24 / 3.0 / 0.13 s) so soft and
    // fast notes get an onset at all. Extra onsets are harmless: each one
    // only counts if the expected note itself is verified in the sound.
    private let minRMS: Float = 0.0010
    private let ambientRMSRatio: Float = 2.5
    private let minFluxScore: Float = 0.18
    private let ambientFluxRatio: Float = 2.5
    // 0.05 s = 20 notes/s, comfortably past the ~14 notes/s a trill reaches
    // (and past what a grand's double escapement allows at ~8 per finger).
    // It used to be 0.09 s, which quietly ate trills; it could only come down
    // once onsets were peak-picked properly rather than fired on the first
    // frame over threshold.
    private let minAttackInterval: TimeInterval = 0.05
    private let maxPitchHints = 3

    // Where the onset sits relative to the newest sample when flux fires: the
    // Hann window barely weights its newest quarter, so detection happens
    // once the attack is ~1.5 hops into the frame.
    private var onsetLagSamples: Int { hop * 3 / 2 }

    /// SuperFlux onset detection — see OnsetDetector for why the old band
    /// flux had to go (it found 31 % of real notes at 2.2 false onsets/s).
    private var onset: OnsetDetector?

    private var sampleRate: Double = 48_000
    private var binRes: Float = 48_000 / 2048
    private var keyBins: [Int] = []
    private var inputLatency: TimeInterval = 0

    private static let keyFreqs: [Float] = (0..<88).map {
        440.0 * powf(2.0, Float(21 + $0 - 69) / 12.0)
    }

    private var fftSetup: FFTSetup!
    private var window: [Float]
    private var frame: [Float]
    private var rp: [Float]
    private var ip: [Float]
    private var power: [Float]
    private var spectrum: [Float]
    private var prevSpectrum: [Float]

    // Long ring buffer: holds enough history for the verifier's pre-onset
    // window plus its post-onset window (0.68 s @ 48 kHz).
    private static let ringN = 32_768
    private var ring: [Float]
    private var written: Int = 0          // total samples ever written
    private var hopFill = 0

    // Expected-note verification
    private let verifier4k = NoteVerifier(fftN: 4096)   // 85 ms: middle + treble
    private let verifier8k = NoteVerifier(fftN: 8192)   // 171 ms: bass semitones need the resolution
    private struct PendingVerification {
        let attackID: Int
        let onsetSample: Int
        let timestamp: TimeInterval
        /// The notes the song wanted when this attack happened. Frozen here
        /// on purpose: a stage runs 10-60 ms later, by which time accepting
        /// the note may already have advanced the song, and judging this
        /// sound against the NEXT chord is how a note nobody played gets
        /// marked as played.
        let chord: Set<Int>
        var stagesDone: Set<Int> = []
    }

    private var pending: [PendingVerification] = []
    /// Keys the song expects together right now (set by the render loop):
    /// the verifier ignores partials shared between them.
    private let expectedKeys = Locked<Set<Int>>([])
    private let listening = Locked<Bool>(false)
    /// Diagnostics (SETUP › RECORD): raw microphone + every verdict.
    weak var recorder: SessionRecorder?

    func setExpectedKeys(_ keys: Set<Int>) { expectedKeys.set(keys) }

    /// Verification stages: (post-onset delay in s, verifier, low-register keys?).
    /// Two looks at middle/treble cover chords that are rolled or slightly
    /// spread; the bass waits for the long window.
    private static let bassSplitKey = 27   // C3 (~131 Hz) and above use the 4k window
    /// Delays start *after* the hammer transient. A piano attack is 20-40 ms
    /// of broadband noise: inside it every key in the register shows energy,
    /// which both inflates the keys that were not struck and saturates the
    /// reference the rise is measured against. Waiting 35 ms costs nothing
    /// that matters (the onset timestamp is back-dated to the real strike)
    /// and measures the steady partials instead of the thump.
    private var stages: [(delay: Double, verifier: NoteVerifier, bass: Bool)] {
        [(0.035, verifier4k, false), (0.030, verifier8k, true), (0.120, verifier4k, false)]
    }
    /// When each key was last heard clearly. A key heard within the last
    /// couple of seconds is very likely still ringing, which changes how a
    /// fresh strike on it has to be judged (see NoteVerifier.verdict).
    private var lastHeard: [TimeInterval] = .init(repeating: -1, count: 88)
    private let ringingFor: TimeInterval = 2.5
    private var verifications: [StrikeVerification] = []
    private var recentAttacks: [AudioAttack] = []
    private var nextAttackID = 1

    // Debug pitch hints.
    private var keyEnergy: [Float] = .init(repeating: 0, count: 88)
    private var lastHints: [DetectedNote] = []

    // Adaptive attack gates. Start low so the first few real attacks are not missed
    // while the ambient estimate converges upward from actual environment noise.
    private var ambientRMS: Float = 0.0008
    private var ambientFlux: Float = 0.04
    private var lastAttackTime: TimeInterval = 0
    private var lastAttackScore: Float = 0
    private var fluxDipped = true
    private var hasPreviousSpectrum = false

    private let engine = AVAudioEngine()
    private let stateQueue = DispatchQueue(label: "com.pianoar.audio-detector.state")
    private var tapInstalled = false
    private var running = false
    private var interruptionObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var _snap = PitchSnapshot.empty
    private var lastUI: TimeInterval = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        window = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))

        frame = .init(repeating: 0, count: fftN)
        rp = .init(repeating: 0, count: fftN / 2)
        ip = .init(repeating: 0, count: fftN / 2)
        power = .init(repeating: 0, count: fftN / 2)
        spectrum = .init(repeating: 0, count: fftN / 2)
        prevSpectrum = .init(repeating: 0, count: fftN / 2)
        ring = .init(repeating: 0, count: Self.ringN)
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Start / Stop

    func start() {
        // Register for audio session interruption (phone call, Siri, etc.) so the
        // mic restarts automatically when the interruption ends.
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: nil
            ) { [weak self] notification in
                guard let self,
                      let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
                else { return }
                if type == .ended {
                    self.stateQueue.async {
                        self.running = false   // the engine was stopped by the interruption
                        self.configureAndStart()
                    }
                }
            }
        }

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            stateQueue.async { [weak self] in self?.configureAndStart() }
        case .denied:
            publishState("mic denied")
            clearSnapshot()
        case .undetermined:
            publishState("mic permission")
            session.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.stateQueue.async { self.configureAndStart() }
                } else {
                    self.publishState("mic denied")
                    self.clearSnapshot()
                }
            }
        @unknown default:
            publishState("mic unavailable")
            clearSnapshot()
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            self.engine.stop()
            self.running = false
            self.listening.set(false)
            self.resetAudioState()
            self.clearSnapshot()
            self.publishState("mic off")
        }
    }

    func snapshot() -> PitchSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return _snap
    }

    private func configureAndStart() {
        guard !running else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .mixWithOthers]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(Double(hop) / 48_000.0)
            try session.setActive(true)
            inputLatency = session.inputLatency
            selectRawMicrophone(session)

            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }

            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
                publishState("mic unavailable")
                return
            }

            sampleRate = fmt.sampleRate
            binRes = Float(fmt.sampleRate) / Float(fftN)
            keyBins = Self.keyFreqs.map { Int(($0 / binRes).rounded()) }
            onset = OnsetDetector(fftBins: fftN / 2, sampleRate: Float(fmt.sampleRate))
            resetAudioState()

            // iOS may hand the tap far larger buffers than requested (often
            // ~100 ms); ingest() walks every buffer in hop-sized steps, so
            // onset timing doesn't depend on the delivered size.
            input.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(hop),
                format: fmt
            ) { [weak self] buf, when in
                self?.ingest(buf, when: when)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            running = true
            listening.set(true)
            let io = Int(AVAudioSession.sharedInstance().ioBufferDuration * 1000)
            let src = AVAudioSession.sharedInstance().currentRoute.inputs.first?
                .selectedDataSource?.dataSourceName ?? "default"
            publishState(String(format: "mic listening %@ %d ms", src, io))
        } catch {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            running = false
            listening.set(false)
            publishState("mic error")
            clearSnapshot()
        }
    }

    /// Takes the microphone as raw as iOS will give it.
    ///
    /// Every piece of system audio processing works directly against this
    /// detector, because the whole verdict is "did these partials get louder
    /// than they were 40 ms ago":
    ///  * automatic gain control pulls a loud note down and pushes a quiet
    ///    room up, which is exactly the rise being measured — a struck note
    ///    can end up looking flat, and the silence after it looking like an
    ///    attack;
    ///  * voice processing adds echo cancellation and a speech EQ that mangle
    ///    harmonic amplitude ratios;
    ///  * the cardioid/stereo polar patterns are not microphones at all but
    ///    multi-mic beamformers, i.e. more DSP. Only omnidirectional is a
    ///    single physical capsule.
    ///
    /// `.measurement` mode (set above) does most of this; the rest is
    /// belt-and-braces, and all of it is best-effort — every setter here is a
    /// *preference* that iOS may ignore.
    private func selectRawMicrophone(_ session: AVAudioSession) {
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic })
        else { return }
        try? session.setPreferredInput(mic)
        if let source = mic.dataSources?.first(where: {
            $0.supportedPolarPatterns?.contains(.omnidirectional) == true
        }) {
            try? source.setPreferredPolarPattern(.omnidirectional)
            try? mic.setPreferredDataSource(source)
        }
    }

    // MARK: - Audio ingest (audio thread)

    private func ingest(_ buf: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }

        // Capture time of this buffer's first sample, on the same clock as
        // CACurrentMediaTime() / the SceneKit render loop.
        let bufferStart: TimeInterval
        if when.isHostTimeValid {
            bufferStart = AVAudioTime.seconds(forHostTime: when.hostTime) - inputLatency
        } else {
            bufferStart = CACurrentMediaTime() - Double(n) / sampleRate
        }

        recorder?.writeAudio(buf)

        let s = ch[0]
        let mask = Self.ringN - 1
        var i = 0
        while i < n {
            let take = min(hop - hopFill, n - i)
            for j in 0..<take { ring[(written + j) & mask] = s[i + j] }
            written += take
            i += take
            hopFill += take
            if hopFill == hop {
                hopFill = 0
                analyze(frameEndTime: bufferStart + Double(i) / sampleRate)
            }
        }
        runDueVerifications()
        publishSnapshot(timestamp: bufferStart + Double(n) / sampleRate)
    }

    // MARK: - Onset analysis (one call per hop)

    private func analyze(frameEndTime: TimeInterval) {
        let start = written - fftN
        guard start >= 0 else { return }
        let mask = Self.ringN - 1
        for k in 0..<fftN { frame[k] = ring[(start + k) & mask] }

        let rms = rootMeanSquare(frame)
        for k in 0..<fftN { frame[k] *= window[k] }
        performFFT()
        computeSpectrumMagnitude()

        let low = bandStats(fromHz: 24, toHz: 360, weight: 0.95)
        let mid = bandStats(fromHz: 360, toHz: 1_900, weight: 1.05)
        let high = bandStats(fromHz: 1_900, toHz: 10_500, weight: 1.75)
        // Band flux is kept only for the debug readout now; it no longer
        // gates anything (see OnsetDetector).
        let onsetScore = low.flux + mid.flux + high.flux
        computeKeyEnergies()

        var attack: AudioAttack? = nil
        if let peak = onset?.push(spectrum: spectrum, rms: rms,
                                  sample: written - onsetLagSamples,
                                  time: frameEndTime - Double(onsetLagSamples) / sampleRate),
           let a = makeAttack(peak: peak) {
            attack = a
            lastHints = pitchHints(for: a)
            recentAttacks.append(a)
            recorder?.log("attack", ["id": a.id, "onset": a.timestamp,
                                     "conf": a.confidence, "score": a.onsetScore,
                                     "thr": peak.threshold])
            pending.append(PendingVerification(attackID: a.id,
                                               onsetSample: peak.sample,
                                               timestamp: a.timestamp,
                                               chord: expectedKeys.get()))
        }

        publishUI(attack: attack, rms: rms, onsetScore: onsetScore,
                  lowScore: low.flux, midScore: mid.flux, highScore: high.flux,
                  timestamp: frameEndTime)
        prevSpectrum = spectrum
        hasPreviousSpectrum = true
    }

    // MARK: - Expected-note verification

    /// Runs every verification stage whose post-onset window has fully
    /// arrived, merging results into that attack's StrikeVerification.
    private func runDueVerifications() {
        guard !pending.isEmpty else { return }
        let mask = Self.ringN - 1
        let preGap = hop                  // keep the attack itself out of "before"
        let stageList = stages
        var remaining: [PendingVerification] = []

        for var p in pending {
            let chord = p.chord
            for (si, stage) in stageList.enumerated() where !p.stagesDone.contains(si) {
                let vN = stage.verifier.fftN
                let preStart  = p.onsetSample - preGap - vN
                let postStart = p.onsetSample + Int(stage.delay * sampleRate)
                guard written >= postStart + vN else { continue }      // not recorded yet
                p.stagesDone.insert(si)
                // Not enough history, or already overwritten: skip the stage.
                guard preStart >= 0, written - preStart <= Self.ringN else { continue }

                var pre  = [Float](repeating: 0, count: vN)
                var post = [Float](repeating: 0, count: vN)
                for k in 0..<vN {
                    pre[k]  = ring[(preStart + k) & mask]
                    post[k] = ring[(postStart + k) & mask]
                }
                let keys = stage.bass ? Array(0..<Self.bassSplitKey) : Array(Self.bassSplitKey..<88)
                var ringing = Set<Int>()
                for k in 0..<88 where lastHeard[k] > 0
                    && p.timestamp - lastHeard[k] <= ringingFor
                    && p.timestamp - lastHeard[k] > 0.04 {
                    ringing.insert(k)
                }
                let results = stage.verifier.evaluate(pre: pre, post: post,
                                                      sampleRate: Float(sampleRate),
                                                      keys: keys, chord: chord,
                                                      ringing: ringing)
                for r in results where r.status == .present {
                    lastHeard[r.key] = max(lastHeard[r.key], p.timestamp)
                }
                let idx = verifications.firstIndex { $0.attackID == p.attackID }
                var v = idx.map { verifications[$0] }
                    ?? StrikeVerification(attackID: p.attackID, timestamp: p.timestamp)
                for r in results { v.merge(key: r.key, rise: r.rise, status: r.status) }
                recorder?.log("verify", [
                    "id": p.attackID, "onset": p.timestamp, "stage": si,
                    "keys": results.filter { $0.status != .absent || chord.contains($0.key) }
                        .map { ["k": $0.key, "s": String(describing: $0.status), "r": $0.rise] },
                ])
                v.complete = p.stagesDone.count == stageList.count
                if let idx { verifications[idx] = v } else { verifications.append(v) }
            }
            if p.stagesDone.count < stageList.count { remaining.append(p) }
        }
        pending = remaining
    }

    // MARK: - DSP helpers

    private func rootMeanSquare(_ values: [Float]) -> Float {
        var sum: Float = 0
        for v in values {
            sum += v * v
        }
        return sqrtf(sum / Float(max(values.count, 1)))
    }

    private func performFFT() {
        rp.withUnsafeMutableBufferPointer { rpBuf in
            ip.withUnsafeMutableBufferPointer { ipBuf in
                var split = DSPSplitComplex(
                    realp: rpBuf.baseAddress!,
                    imagp: ipBuf.baseAddress!
                )

                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!,
                        2,
                        &split,
                        1,
                        vDSP_Length(self.fftN / 2)
                    )
                }

                vDSP_fft_zrip(
                    self.fftSetup,
                    &split,
                    1,
                    self.log2n,
                    FFTDirection(kFFTDirection_Forward)
                )

                power.withUnsafeMutableBufferPointer { pBuf in
                    vDSP_zvmags(
                        &split,
                        1,
                        pBuf.baseAddress!,
                        1,
                        vDSP_Length(self.fftN / 2)
                    )
                }
            }
        }
    }

    private func computeSpectrumMagnitude() {
        for i in 0..<power.count {
            spectrum[i] = sqrtf(max(0, power[i]))
        }
    }

    private func bandStats(fromHz: Float, toHz: Float, weight: Float) -> (flux: Float, energy: Float) {
        let start = max(1, Int((fromHz / binRes).rounded(.down)))
        let end = min(spectrum.count - 1, Int((toHz / binRes).rounded(.up)))
        guard end > start else { return (0, 0) }

        var positiveDelta: Float = 0
        var currentEnergy: Float = 0
        var previousEnergy: Float = 0

        for i in start...end {
            let current = spectrum[i]
            let previous = prevSpectrum[i]
            currentEnergy += current
            previousEnergy += previous
            positiveDelta += max(0, current - previous)
        }

        let reference = max(previousEnergy, currentEnergy * 0.12, 1e-6)
        return (positiveDelta / reference * weight, currentEnergy)
    }

    /// The peak-picker has already decided; this only stamps an identity on
    /// it. All the rejection now lives in OnsetDetector, where it is measured.
    private func makeAttack(peak: OnsetDetector.Peak) -> AudioAttack? {
        guard hasPreviousSpectrum else { return nil }
        lastAttackTime = peak.time
        lastAttackScore = peak.odf
        // How far clear of its own adaptive threshold the peak stood.
        let confidence = min(1.0, max(0.05, (peak.odf - peak.threshold)
                                             / max(peak.threshold, 0.5)))
        let id = nextAttackID
        nextAttackID += 1
        return AudioAttack(
            id: id,
            confidence: confidence,
            onsetScore: peak.odf,
            lowBandScore: 0,
            midBandScore: 0,
            highBandScore: peak.threshold,
            pitchHintKeyIndex: strongestPitchHintIndex(),
            timestamp: peak.time
        )
    }

    private func updateAmbient(rms: Float, onsetScore: Float, isAttack: Bool) {
        guard !isAttack else { return }
        let clampedRMS = min(rms, ambientRMS * 2.0 + 0.0004)
        let clampedFlux = min(onsetScore, ambientFlux * 2.0 + 0.02)
        ambientRMS = ambientRMS * 0.985 + clampedRMS * 0.015
        ambientFlux = ambientFlux * 0.985 + clampedFlux * 0.015
    }

    // MARK: - Pitch hints for debugging only

    private func computeKeyEnergies() {
        let halfN = fftN / 2
        for i in 0..<88 {
            guard i < keyBins.count else {
                keyEnergy[i] = 0
                continue
            }

            let bin = keyBins[i]
            guard bin > 1, bin < halfN - 2 else {
                keyEnergy[i] = 0
                continue
            }

            var e = spectrum[bin - 1] + spectrum[bin] + spectrum[bin + 1]
            for (h, w) in [(2, Float(0.45)), (3, Float(0.28)), (4, Float(0.15))] {
                let hb = bin * h
                guard hb > 1, hb < halfN - 2 else { continue }
                e += (spectrum[hb - 1] + spectrum[hb] + spectrum[hb + 1]) * w
            }

            keyEnergy[i] = e
        }
    }

    private func strongestPitchHintIndex() -> Int? {
        guard let maxEnergy = keyEnergy.max(), maxEnergy > 0 else { return nil }
        return keyEnergy.firstIndex(of: maxEnergy)
    }

    private func pitchHints(for attack: AudioAttack) -> [DetectedNote] {
        let strongest = keyEnergy.max() ?? 0
        guard strongest > 0 else { return [] }

        let threshold = strongest * 0.20
        return keyEnergy.enumerated()
            .filter { $0.element >= threshold }
            .sorted { $0.element > $1.element }
            .prefix(maxPitchHints)
            .map { idx, energy in
                DetectedNote(
                    keyIndex: idx,
                    midiNote: 21 + idx,
                    magnitude: min(1.0, energy / strongest),
                    isOnset: idx == attack.pitchHintKeyIndex
                )
            }
            .sorted { $0.keyIndex < $1.keyIndex }
    }

    // MARK: - Publishing

    private func publishSnapshot(timestamp: TimeInterval) {
        recentAttacks.removeAll { timestamp - $0.timestamp > 1.5 }
        verifications.removeAll { timestamp - $0.timestamp > 2.0 }
        if recentAttacks.isEmpty { lastHints = [] }
        let snap = PitchSnapshot(activeNotes: lastHints,
                                 attack: recentAttacks.last,
                                 recentAttacks: recentAttacks,
                                 verifications: verifications,
                                 listening: listening.get(),
                                 timestamp: timestamp)
        lock.lock()
        _snap = snap
        lock.unlock()
    }

    private func clearSnapshot() {
        lock.lock()
        _snap = .empty
        lock.unlock()
    }

    private func publishUI(attack: AudioAttack?,
                           rms: Float,
                           onsetScore: Float,
                           lowScore: Float,
                           midScore: Float,
                           highScore: Float,
                           timestamp: TimeInterval) {
        guard attack != nil || timestamp - lastUI > 0.08 else { return }
        lastUI = timestamp

        var debug: [String] = []
        if let attack {
            debug.append(String(format: "ATTACK #%ld conf %.2f odf %.2f thr %.2f",
                                attack.id, attack.confidence, attack.onsetScore,
                                attack.highBandScore))
        } else {
            debug.append(String(format: "flux %.2f (debug only)", onsetScore))
        }
        debug.append(String(format: "rms %.4f bands %d", rms, onset?.bandCount ?? 0))
        if let v = verifications.last {
            let names = v.heardKeys().map { KeyboardLayout.keys[$0].noteName }
            debug.append("heard " + (names.isEmpty ? "-" : names.joined(separator: " ")))
        }

        debugStore.set(debug)
    }

    private func publishState(_ value: String) {
        micState.set(value)
    }

    private func resetAudioState() {
        ring = .init(repeating: 0, count: Self.ringN)
        frame = .init(repeating: 0, count: fftN)
        power = .init(repeating: 0, count: fftN / 2)
        spectrum = .init(repeating: 0, count: fftN / 2)
        prevSpectrum = .init(repeating: 0, count: fftN / 2)
        keyEnergy = .init(repeating: 0, count: 88)
        written = 0
        hopFill = 0
        pending = []
        verifications = []
        recentAttacks = []
        lastHints = []
        ambientRMS  = 0.0008
        ambientFlux = 0.04
        lastHeard = .init(repeating: -1, count: 88)
        lastAttackTime = 0
        lastAttackScore = 0
        fluxDipped = true
        onset?.reset()
        hasPreviousSpectrum = false
    }
}

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

struct PitchSnapshot {
    let activeNotes: [DetectedNote]           // debug pitch hints for the latest attack
    let attack: AudioAttack?                  // most recent attack — sticky until replaced
    let recentAttacks: [AudioAttack]          // oldest first, last ~1.5 s
    let noteOnsets: [NoteOnset]               // per-key strikes, oldest first, last ~2 s
    let expectedScores: [(key: Int, score: Float)]   // live NoteTracker scores (debug)
    let listening: Bool                       // mic running
    let timestamp: TimeInterval

    static let empty = PitchSnapshot(activeNotes: [], attack: nil, recentAttacks: [],
                                     noteOnsets: [], expectedScores: [], listening: false,
                                     timestamp: 0)
}

/// Microphone-side piano detector: global attack detection (debug) plus the
/// per-key NoteTracker that decides which keys were actually struck.
///
/// Audio answers two questions: "did a piano-like attack happen, and when?"
/// (spectral-flux onset detection on a short window) and, per attack, "which
/// keys got freshly struck?" (NoteTracker, per key, every hop). The press detector
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

    private let minRMS: Float = 0.0015
    private let ambientRMSRatio: Float = 3.0
    private let minFluxScore: Float = 0.24
    private let ambientFluxRatio: Float = 3.0
    private let minAttackInterval: TimeInterval = 0.13
    private let maxPitchHints = 3

    // Where the onset sits relative to the newest sample when flux fires: the
    // Hann window barely weights its newest quarter, so detection happens
    // once the attack is ~1.5 hops into the frame.
    private var onsetLagSamples: Int { hop * 3 / 2 }

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

    // Ring buffer of recent samples (0.68 s @ 48 kHz) feeding all analyses.
    private static let ringN = 32_768
    private var ring: [Float]
    private var written: Int = 0          // total samples ever written
    private var hopFill = 0

    // Per-key note detection (see NoteTracker): two spectra every hop.
    private let shortSpec = SpectrumAnalyzer(n: 4096)   // 85 ms: middle + treble
    private let longSpec  = SpectrumAnalyzer(n: 8192)   // 171 ms: bass semitones need the resolution
    private var shortBuf = [Float](repeating: 0, count: 4096)
    private var longBuf  = [Float](repeating: 0, count: 8192)
    private let tracker = NoteTracker(shortN: 4096, longN: 8192)
    private var noteOnsets: [NoteOnset] = []
    /// Keys the song expects together right now (set by the render loop):
    /// they get the lower "expected" threshold and ignore shared partials.
    private let expectedKeys = Locked<Set<Int>>([])
    private let listening = Locked<Bool>(false)

    func setExpectedKeys(_ keys: Set<Int>) { expectedKeys.set(keys) }

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
            tracker.configure(sampleRate: Float(fmt.sampleRate))
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
            publishState("mic listening")
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
        let onsetScore = low.flux + mid.flux + high.flux
        computeKeyEnergies()
        let attack = makeAttack(
            rms: rms,
            onsetScore: onsetScore,
            lowScore: low.flux,
            midScore: mid.flux,
            highScore: high.flux,
            timestamp: frameEndTime - Double(onsetLagSamples) / sampleRate
        )

        if let attack {
            lastHints = pitchHints(for: attack)
            recentAttacks.append(attack)
        }

        // Per-key note detection on the longer windows.
        if written >= longBuf.count {
            let longStart = written - longBuf.count
            for k in 0..<longBuf.count { longBuf[k] = ring[(longStart + k) & mask] }
            let shortStart = written - shortBuf.count
            for k in 0..<shortBuf.count { shortBuf[k] = ring[(shortStart + k) & mask] }
            shortSpec.analyze(shortBuf)
            longSpec.analyze(longBuf)
            let found = tracker.process(short: shortSpec, long: longSpec,
                                        hopEnd: frameEndTime,
                                        hopDuration: Double(hop) / sampleRate,
                                        expected: expectedKeys.get())
            if !found.isEmpty { noteOnsets += found }
        }

        publishUI(attack: attack, rms: rms, onsetScore: onsetScore,
                  lowScore: low.flux, midScore: mid.flux, highScore: high.flux,
                  timestamp: frameEndTime)

        updateAmbient(rms: rms, onsetScore: onsetScore, isAttack: attack != nil)
        prevSpectrum = spectrum
        hasPreviousSpectrum = true
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

    private func makeAttack(rms: Float,
                            onsetScore: Float,
                            lowScore: Float,
                            midScore: Float,
                            highScore: Float,
                            timestamp: TimeInterval) -> AudioAttack? {
        let rmsGate = max(minRMS, ambientRMS * ambientRMSRatio)
        let fluxGate = max(minFluxScore, ambientFlux * ambientFluxRatio)
        let hasHistory = hasPreviousSpectrum
        let enoughLevel = rms >= rmsGate
        let enoughChange = onsetScore >= fluxGate
        let enoughTrebleOrMid = highScore >= fluxGate * 0.14
            || midScore >= fluxGate * 0.22
            || (lowScore >= fluxGate * 0.80 && rms >= rmsGate * 1.15)
        let cooledDown = timestamp - lastAttackTime >= minAttackInterval

        guard hasHistory, enoughLevel, enoughChange, enoughTrebleOrMid, cooledDown else {
            return nil
        }

        lastAttackTime = timestamp
        let confidence = min(1.0, max(0.05, onsetScore / max(fluxGate * 2.8, 1e-6)))
        let id = nextAttackID
        nextAttackID += 1
        return AudioAttack(
            id: id,
            confidence: confidence,
            onsetScore: onsetScore,
            lowBandScore: lowScore,
            midBandScore: midScore,
            highBandScore: highScore,
            pitchHintKeyIndex: strongestPitchHintIndex(),
            timestamp: timestamp
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
        noteOnsets.removeAll { timestamp - $0.time > 2.0 }
        if recentAttacks.isEmpty { lastHints = [] }
        let expected = expectedKeys.get().sorted()
        let scores = expected.filter { $0 >= 0 && $0 < 88 }.map { (key: $0, score: tracker.liveScore[$0]) }
        let snap = PitchSnapshot(activeNotes: lastHints,
                                 attack: recentAttacks.last,
                                 recentAttacks: recentAttacks,
                                 noteOnsets: noteOnsets,
                                 expectedScores: scores,
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
            debug.append(String(format: "ATTACK #%ld conf %.2f score %.2f",
                                attack.id, attack.confidence, attack.onsetScore))
        } else {
            debug.append(String(format: "score %.2f gate %.2f", onsetScore, max(minFluxScore, ambientFlux * ambientFluxRatio)))
        }
        debug.append(String(format: "rms %.4f amb %.4f", rms, ambientRMS))
        debug.append(String(format: "bands L %.2f M %.2f H %.2f", lowScore, midScore, highScore))
        let heard = noteOnsets.suffix(6).map {
            String(format: "%@%.0f", KeyboardLayout.keys[$0.key].noteName, $0.strength)
        }
        debug.append("heard " + (heard.isEmpty ? "-" : heard.joined(separator: " ")))

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
        noteOnsets = []
        tracker.reset()
        recentAttacks = []
        lastHints = []
        ambientRMS  = 0.0008
        ambientFlux = 0.04
        lastAttackTime = 0
        hasPreviousSpectrum = false
    }
}

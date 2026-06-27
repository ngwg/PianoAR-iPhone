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
    let confidence: Float
    let onsetScore: Float
    let lowBandScore: Float
    let midBandScore: Float
    let highBandScore: Float
    let pitchHintKeyIndex: Int?
    let timestamp: TimeInterval
}

struct PitchSnapshot {
    let activeNotes: [DetectedNote]  // Debug pitch hints only; vision owns note identity.
    let attack: AudioAttack?
    let timestamp: TimeInterval
}

/// Microphone-side piano attack detector.
///
/// The mic path intentionally avoids being the source of truth for note names.
/// Acoustic piano transcription from a phone mic is a hard problem; in this app
/// calibrated key geometry + fingertip position should identify the key, while
/// audio answers "did a piano-like attack happen right now?"
final class AudioPitchDetector: ObservableObject {
    @Published var lastDetected: String = ""
    @Published var fingerDebugLines: [String] = []
    @Published private(set) var microphoneState: String = "mic off"

    // Short-window STFT for onset timing. 2048 @ 48 kHz is ~43 ms, hop 512 is
    // ~11 ms, which is much better for treble attacks than the old 8192 window.
    private let fftN = 2048
    private let hop = 512
    private let log2n: vDSP_Length = 11

    private let minRMS: Float = 0.0015           // raised: ignore very quiet ambient taps
    private let ambientRMSRatio: Float = 3.0      // raised: need 3× ambient to confirm onset
    private let minFluxScore: Float = 0.24        // raised: stricter spectral change gate
    private let ambientFluxRatio: Float = 3.0     // raised: matches ambientRMSRatio
    private let minAttackInterval: TimeInterval = 0.13
    private let maxPitchHints = 3

    private var binRes: Float = 48_000 / 2048
    private var keyBins: [Int] = []

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

    private var ring: [Float]
    private var ringW = 0
    private var hopAcc = 0

    // Debug pitch hints.
    private var keyEnergy: [Float] = .init(repeating: 0, count: 88)

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
    private var _snap = PitchSnapshot(activeNotes: [], attack: nil, timestamp: 0)
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
        ring = .init(repeating: 0, count: fftN)
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
                    self.stateQueue.async { self.configureAndStart() }
                }
            }
        }

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            stateQueue.async { [weak self] in self?.configureAndStart() }
        case .denied:
            publishState("mic denied")
            publishSnapshot(hints: [], attack: nil, timestamp: CACurrentMediaTime())
        case .undetermined:
            publishState("mic permission")
            session.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.stateQueue.async { self.configureAndStart() }
                } else {
                    self.publishState("mic denied")
                    self.publishSnapshot(hints: [], attack: nil, timestamp: CACurrentMediaTime())
                }
            }
        @unknown default:
            publishState("mic unavailable")
            publishSnapshot(hints: [], attack: nil, timestamp: CACurrentMediaTime())
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
            self.resetAudioState()
            self.publishSnapshot(hints: [], attack: nil, timestamp: CACurrentMediaTime())
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

            binRes = Float(fmt.sampleRate) / Float(fftN)
            keyBins = Self.keyFreqs.map { Int(($0 / binRes).rounded()) }
            resetAudioState()

            input.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(hop),
                format: fmt
            ) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            running = true
            publishState("mic listening")
        } catch {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            running = false
            publishState("mic error")
            publishSnapshot(hints: [], attack: nil, timestamp: CACurrentMediaTime())
        }
    }

    // MARK: - Audio ingest

    private func ingest(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }

        let s = ch[0]
        for i in 0..<n {
            ring[ringW] = s[i]
            ringW = (ringW + 1) % fftN
        }

        hopAcc += n
        if hopAcc >= hop {
            hopAcc = 0
            analyze()
        }
    }

    // MARK: - Analysis

    private func analyze() {
        for i in 0..<fftN {
            frame[i] = ring[(ringW + i) % fftN]
        }

        let rms = rootMeanSquare(frame)
        let now = CACurrentMediaTime()

        for i in 0..<fftN {
            frame[i] *= window[i]
        }
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
            timestamp: now
        )

        let hints = pitchHints(for: attack)

        publishSnapshot(hints: hints, attack: attack, timestamp: now)
        publishUI(
            hints: hints,
            attack: attack,
            rms: rms,
            onsetScore: onsetScore,
            lowScore: low.flux,
            midScore: mid.flux,
            highScore: high.flux,
            timestamp: now
        )

        updateAmbient(rms: rms, onsetScore: onsetScore, isAttack: attack != nil)
        prevSpectrum = spectrum
        hasPreviousSpectrum = true
    }

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
        return AudioAttack(
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

    private func pitchHints(for attack: AudioAttack?) -> [DetectedNote] {
        guard let attack else { return [] }
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

    private func publishSnapshot(hints: [DetectedNote],
                                 attack: AudioAttack?,
                                 timestamp: TimeInterval) {
        let snap = PitchSnapshot(activeNotes: hints, attack: attack, timestamp: timestamp)
        lock.lock()
        _snap = snap
        lock.unlock()
    }

    private func publishUI(hints: [DetectedNote],
                           attack: AudioAttack?,
                           rms: Float,
                           onsetScore: Float,
                           lowScore: Float,
                           midScore: Float,
                           highScore: Float,
                           timestamp: TimeInterval) {
        guard timestamp - lastUI > 0.08 else { return }
        lastUI = timestamp

        let hintText = hints.map { note -> String in
            let name = KeyboardLayout.keys[note.keyIndex].noteName
            return "\(name):\(String(format: "%.2f", note.magnitude))"
        }.joined(separator: " ")

        var debug: [String] = []
        let label: String
        if let attack {
            label = "attack"
            debug.append(String(format: "ATTACK conf %.2f score %.2f", attack.confidence, attack.onsetScore))
        } else {
            label = ""
            debug.append(String(format: "score %.2f gate %.2f", onsetScore, max(minFluxScore, ambientFlux * ambientFluxRatio)))
        }
        debug.append(String(format: "rms %.4f amb %.4f", rms, ambientRMS))
        debug.append(String(format: "bands L %.2f M %.2f H %.2f", lowScore, midScore, highScore))
        if !hintText.isEmpty {
            debug.append("pitch hint \(hintText)")
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastDetected = label
            self?.fingerDebugLines = debug
        }
    }

    private func publishState(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.microphoneState = value
        }
    }

    private func resetAudioState() {
        ring = .init(repeating: 0, count: fftN)
        frame = .init(repeating: 0, count: fftN)
        power = .init(repeating: 0, count: fftN / 2)
        spectrum = .init(repeating: 0, count: fftN / 2)
        prevSpectrum = .init(repeating: 0, count: fftN / 2)
        keyEnergy = .init(repeating: 0, count: 88)
        ringW = 0
        hopAcc = 0
        ambientRMS  = 0.0008
        ambientFlux = 0.04
        lastAttackTime = 0
        hasPreviousSpectrum = false
    }
}

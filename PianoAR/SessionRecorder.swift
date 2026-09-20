import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Diagnostics recorder (SETUP › RECORD).
///
/// Detection thresholds can only be tuned properly against the real piano in
/// the real room. This writes, side by side:
///  * `session-<time>.wav` — exactly what the microphone heard, and
///  * `session-<time>.jsonl` — one JSON line per event: which notes the song
///    wanted, every onset, the verifier's verdict per key, what was accepted
///    or called wrong, on the same clock as the audio.
///
/// Both land in the app's Documents folder, which shows up in the Files app
/// (and in iTunes › File Sharing on a PC), so a real session can be pulled
/// off the phone and replayed offline.
final class SessionRecorder: ObservableObject {
    /// Safe to read from any thread.
    private let active = Locked<Bool>(false)
    var isRecording: Bool { active.get() }

    @Published private(set) var lastFileName: String = ""
    @Published private(set) var seconds: Int = 0

    private let queue = DispatchQueue(label: "com.pianoar.recorder", qos: .utility)
    private var wav: FileHandle?
    private var wavBytes = 0
    private var wavURL: URL?
    private var logHandle: FileHandle?
    private var startTime: TimeInterval = 0
    private var monoBuffer: AVAudioPCMBuffer?
    private let maxSeconds: TimeInterval = 240

    static var folder: URL {
        let url = SongLibrary.documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Control (main thread)

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        let stamp = Self.stamp()
        let base = Self.folder.appendingPathComponent("session-\(stamp)")
        let logURL = base.appendingPathExtension("jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        queue.sync {
            logHandle = try? FileHandle(forWritingTo: logURL)
            startTime = CACurrentMediaTime()
        }
        lastFileName = "session-\(stamp)"
        seconds = 0
        active.set(true)
        log("session", ["start": CACurrentMediaTime(), "file": lastFileName])
    }

    func stop() {
        guard isRecording else { return }
        log("session", ["stop": CACurrentMediaTime(), "wavBytes": wavBytes,
                        "wavOpen": wav != nil])
        active.set(false)
        queue.async { [weak self] in
            guard let self else { return }
            try? self.logHandle?.close()
            self.logHandle = nil
            self.finishWAV()
        }
    }

    /// Call once per frame from the render loop to keep the elapsed counter
    /// (and the safety cut-off) up to date.
    func tick() {
        guard isRecording else { return }
        let elapsed = CACurrentMediaTime() - startTime
        if elapsed > maxSeconds { stop(); return }
        let whole = Int(elapsed)
        if whole != seconds { seconds = whole }
    }

    // MARK: - Writing

    /// Audio-thread safe: the first buffer opens the file with its format.
    func writeAudio(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let channel = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let rate = buffer.format.sampleRate
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = channel[0][i] }

        queue.async { [weak self] in
            guard let self, self.isRecording else { return }
            // Written by hand rather than through AVAudioFile. Asked for
            // linear PCM in a .wav, AVAudioFile handed back **AAC in a
            // QuickTime container** — which only came to light when the first
            // real recording could not be opened as a WAV. A diagnostics file
            // that silently changes format is worse than none, so the header
            // is written explicitly here and the samples go down as raw
            // 16-bit little-endian.
            if self.wav == nil { self.openWAV(rate: rate) }
            guard let h = self.wav else { return }
            var pcm = Data(capacity: samples.count * 2)
            for v in samples {
                let c = Int16(max(-1, min(1, v)) * 32767)
                pcm.append(UInt8(truncatingIfNeeded: c))
                pcm.append(UInt8(truncatingIfNeeded: c >> 8))
            }
            h.write(pcm)
            self.wavBytes += pcm.count
        }
    }

    /// Any thread. `fields` must hold JSON-encodable values.
    func log(_ event: String, _ fields: [String: Any]) {
        guard isRecording || event == "session" else { return }
        var payload = fields
        payload["t"] = CACurrentMediaTime()
        payload["e"] = event
        queue.async { [weak self] in
            guard let self, let handle = self.logHandle,
                  let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys])
            else { return }
            handle.write(data)
            handle.write(Data("\n".utf8))
        }
    }

    // MARK: - WAV (written by hand; see writeAudio)

    private func openWAV(rate: Double) {
        let url = Self.folder.appendingPathComponent(lastFileName).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.write(Self.wavHeader(rate: rate, dataBytes: 0))   // patched on stop
        wav = h; wavURL = url; wavBytes = 0
    }

    /// Rewrites the two length fields now that the size is known, so the file
    /// is valid even though it was streamed.
    private func finishWAV() {
        guard let h = wav else { return }
        let total = UInt32(36 + wavBytes), data = UInt32(wavBytes)
        try? h.seek(toOffset: 4);  h.write(withUnsafeBytes(of: total.littleEndian) { Data($0) })
        try? h.seek(toOffset: 40); h.write(withUnsafeBytes(of: data.littleEndian)  { Data($0) })
        try? h.close()
        wav = nil
    }

    private static func wavHeader(rate: Double, dataBytes: Int) -> Data {
        let sr = UInt32(rate), ch: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sr * UInt32(ch) * UInt32(bits / 8)
        var d = Data()
        func u32(_ v: UInt32) { d.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        func u16(_ v: UInt16) { d.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(ch)
        u32(sr); u32(byteRate); u16(ch * bits / 8); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmmss"
        return f.string(from: Date())
    }
}

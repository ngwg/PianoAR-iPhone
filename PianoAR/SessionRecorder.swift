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
    private var audioFile: AVAudioFile?
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
        log("session", ["stop": CACurrentMediaTime()])
        active.set(false)
        queue.async { [weak self] in
            guard let self else { return }
            try? self.logHandle?.close()
            self.logHandle = nil
            self.audioFile = nil
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
            do {
                if self.audioFile == nil {
                    let url = Self.folder
                        .appendingPathComponent(self.lastFileName)
                        .appendingPathExtension("wav")
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: rate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ]
                    self.audioFile = try AVAudioFile(forWriting: url, settings: settings)
                }
                guard let file = self.audioFile,
                      let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(samples.count)),
                      let dst = out.floatChannelData else { return }
                out.frameLength = AVAudioFrameCount(samples.count)
                for i in 0..<samples.count { dst[0][i] = samples[i] }
                try file.write(from: out)
            } catch {
                self.audioFile = nil
            }
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

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmmss"
        return f.string(from: Date())
    }
}

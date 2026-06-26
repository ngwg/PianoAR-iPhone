import SwiftUI
import UniformTypeIdentifiers

enum AppMode { case virtualPiano, realPiano }

struct ContentView: View {
    @StateObject private var session     = ARSessionModel()
    @StateObject private var placement   = PlacementManager()
    @StateObject private var calibration = CalibrationManager()
    @StateObject private var handTracker = HandTracker()
    @StateObject private var songPlayer    = SongPlayer()
    @StateObject private var pressDetector = PressDetector()
    @StateObject private var audioDetector = AudioPitchDetector()
    @StateObject private var keyTuning     = KeyTuning()
    @State       private var mode: AppMode = .virtualPiano
    @State       private var showDebug = false
    @State       private var showMIDIImporter = false
    @State       private var showSongPicker = false
    @State       private var importedSongs: [Song] = []

    var body: some View {
        ZStack {
            ARPassthroughView(
                session:       session,
                placement:     placement,
                calibration:   calibration,
                handTracker:   handTracker,
                songPlayer:    songPlayer,
                pressDetector: pressDetector,
                audioDetector: audioDetector,
                keyTuning:     keyTuning,
                onTap:         handleTap,
                onMenuAction:  handleMenuAction
            )
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if !detectionText.isEmpty {
                    detectedNoteLabel
                }
                if keyTuning.panelVisible {
                    tuningPanel
                }
                songControls
                bottomInstructions
            }
            if showDebug { debugOverlay }
        }
        .background(Color.black)
        .onAppear {
            if songPlayer.song == nil { loadBuiltInLesson() }
            audioDetector.start()
        }
        .onDisappear {
            audioDetector.stop()
        }
        .fileImporter(
            isPresented: $showMIDIImporter,
            allowedContentTypes: Self.midiTypes,
            allowsMultipleSelection: false,
            onCompletion: importMIDI
        )
        .sheet(isPresented: $showSongPicker) {
            SongPickerView(
                importedSongs: importedSongs,
                loadBuiltIn: {
                    loadBuiltInLesson()
                    showSongPicker = false
                },
                loadImported: { song in
                    songPlayer.load(song)
                    showSongPicker = false
                },
                importMIDI: {
                    showSongPicker = false
                    showMIDIImporter = true
                }
            )
        }
    }

    private static var midiTypes: [UTType] {
        [
            UTType(filenameExtension: "mid") ?? .data,
            UTType(filenameExtension: "midi") ?? .data,
        ]
    }

    // MARK: Detected note label

    private var detectedNoteLabel: some View {
        Text(detectionText)
            .font(.title2.bold())
            .foregroundStyle(.green)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6))
            .cornerRadius(8)
            .padding(.bottom, 4)
    }

    private var detectionText: String {
        let base: String
        if !songPlayer.feedbackLine.isEmpty {
            base = songPlayer.feedbackLine
        } else if !pressDetector.lastDetected.isEmpty {
            base = "Vision \(pressDetector.lastDetected)"
        } else if !audioDetector.lastDetected.isEmpty {
            base = "Mic \(audioDetector.lastDetected)"
        } else {
            base = ""
        }

        guard !songPlayer.chordLine.isEmpty else { return base }
        if base.isEmpty {
            return songPlayer.chordLine
        }
        return "\(base)\n\(songPlayer.chordLine)"
    }

    // MARK: Song controls

    private var songControls: some View {
        HStack(spacing: 8) {
            Button {
                if songPlayer.isPlaying { songPlayer.stop() } else { songPlayer.play() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: songPlayer.isPlaying ? "stop.fill" : "play.fill")
                    Text(songPlayer.isPlaying ? "Stop" : "Practice")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(songPlayer.isPlaying
                    ? Color.red.opacity(0.75)
                    : Color(red: 0.1, green: 0.5, blue: 0.9).opacity(0.85))
                .foregroundStyle(.white)
                .cornerRadius(10)
            }

            Button {
                showMIDIImporter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("MIDI")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.16))
                .foregroundStyle(.white)
                .cornerRadius(10)
            }

            Button {
                showSongPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                    Text("Songs")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.16))
                .foregroundStyle(.white)
                .cornerRadius(10)
            }

            Button {
                keyTuning.panelVisible.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Tune")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(keyTuning.panelVisible ? Color.green.opacity(0.45) : Color.white.opacity(0.16))
                .foregroundStyle(.white)
                .cornerRadius(10)
            }
        }
        .padding(.bottom, 8)
    }

    private var tuningPanel: some View {
        let keyIndex = songPlayer.expectedKeyIndexNow()
        return VStack(spacing: 6) {
            Text(keyTuning.status(for: keyIndex))
                .font(.caption.bold())
            HStack(spacing: 6) {
                tuneButton("Left") { keyTuning.adjustX(for: keyIndex, by: -0.002) }
                tuneButton("Right") { keyTuning.adjustX(for: keyIndex, by: 0.002) }
                tuneButton("Narrow") { keyTuning.adjustWidth(for: keyIndex, by: -0.0015) }
                tuneButton("Wider") { keyTuning.adjustWidth(for: keyIndex, by: 0.0015) }
                tuneButton("Reset") { keyTuning.reset(keyIndex: keyIndex) }
            }
        }
        .padding(8)
        .background(.black.opacity(0.65))
        .foregroundStyle(.white)
        .cornerRadius(8)
        .padding(.bottom, 6)
    }

    private func tuneButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.16))
                .foregroundStyle(.white)
                .cornerRadius(6)
        }
    }

    private func importMIDI(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: url)
            let title = url.deletingPathExtension().lastPathComponent
            let song = try MIDIFileImporter.song(from: data, title: title)
            importedSongs.append(song)
            songPlayer.load(song)
        } catch {
            songPlayer.feedbackLine = error.localizedDescription
        }
    }

    private func loadBuiltInLesson() {
        let bundledSong = MIDIFileImporter.loadBundled(
            named: "right_hand_practice",
            title: "Right Hand Primer"
        )
        let fallbackSong = Song.load(named: "right_hand_practice")
            ?? Song.load(named: "sample_song")
        if let song = bundledSong ?? fallbackSong {
            songPlayer.load(song)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            HUDPanel(session: session, placement: placement,
                     calibration: calibration, handTracker: handTracker,
                     songPlayer: songPlayer, audioDetector: audioDetector,
                     keyTuning: keyTuning, mode: mode)
                .padding(12)
            Spacer()
            VStack(spacing: 8) {
                modeToggle
                debugToggle
            }
            .padding(12)
        }
    }

    private var debugToggle: some View {
        Button { showDebug.toggle() } label: {
            Text(showDebug ? "Debug ON" : "Debug")
                .font(.caption2.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(showDebug ? Color.green.opacity(0.6) : Color.white.opacity(0.15))
                .foregroundStyle(.white)
                .cornerRadius(6)
        }
    }

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Press Detection Debug")
                .font(.caption.bold())
            ForEach(pressDetector.fingerDebugLines, id: \.self) { line in
                Text(line).font(.system(size: 9, design: .monospaced))
            }
            Text("Mic Detection Debug")
                .font(.caption.bold())
                .padding(.top, 6)
            ForEach(audioDetector.fingerDebugLines, id: \.self) { line in
                Text(line).font(.system(size: 9, design: .monospaced))
            }
        }
        .padding(8)
        .background(.black.opacity(0.7))
        .foregroundStyle(.green)
        .cornerRadius(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 12)
        .padding(.bottom, 100)
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeButton("Virtual", active: mode == .virtualPiano) {
                mode = .virtualPiano
            }
            modeButton("Real Piano", active: mode == .realPiano) {
                mode = .realPiano
                if calibration.state == .idle { calibration.startCalibration() }
            }
        }
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.3), lineWidth: 1))
    }

    private func modeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Color.white.opacity(0.25) : Color.clear)
                .foregroundStyle(.white)
        }
    }

    // MARK: Bottom instructions

    @ViewBuilder
    private var bottomInstructions: some View {
        switch mode {
        case .virtualPiano: virtualPianoInstructions
        case .realPiano:    realPianoInstructions
        }
    }

    @ViewBuilder
    private var virtualPianoInstructions: some View {
        switch placement.state {
        case .scanning:     EmptyView()
        case .readyToPlace: instructionLabel("Tap a flat surface to place the keyboard")
        case .placed:       resetButton("Remove keyboard") { placement.reset(session: session) }
        }
    }

    @ViewBuilder
    private var realPianoInstructions: some View {
        switch calibration.state {
        case .idle:
            resetButton("Start calibration") { calibration.startCalibration() }
        case .collecting(let count):
            let labels = [
                "Tap corner 1 of 4 — near-left (front-left of your keyboard)",
                "Tap corner 2 of 4 — near-right (front-right)",
                "Tap corner 3 of 4 — far-right (back-right)",
                "Tap corner 4 of 4 — far-left (back-left)",
            ]
            instructionLabel(labels[min(count, 3)])
        case .done:
            resetButton("Redo calibration") { calibration.reset() }
        }
    }

    private func instructionLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.black.opacity(0.6))
            .cornerRadius(10)
            .padding(.bottom, 40)
    }

    private func resetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.red.opacity(0.7))
                .foregroundStyle(.white)
                .cornerRadius(8)
        }
        .padding(.bottom, 40)
    }

    // MARK: Tap routing

    private func handleTap(at point: CGPoint) {
        switch mode {
        case .virtualPiano: placement.handleTap(at: point)
        case .realPiano:    calibration.handleTap(at: point)
        }
    }

    // MARK: AR menu gesture routing

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .playStop:
            if songPlayer.isPlaying { songPlayer.stop() } else { songPlayer.play() }
        case .restart:
            songPlayer.restart()
        case .nextSong:
            advanceToNextSong()
        }
    }

    private func advanceToNextSong() {
        // Cycle through: built-in, then imported songs in order, then loop back.
        let allSongs: [Song?] = [nil] + importedSongs.map { Optional($0) }
        let currentTitle = songPlayer.song?.title
        let currentIdx = allSongs.firstIndex {
            $0?.title == currentTitle
        } ?? 0
        let nextIdx = (currentIdx + 1) % allSongs.count
        if let next = allSongs[nextIdx] {
            songPlayer.load(next)
        } else {
            loadBuiltInLesson()
        }
    }
}

// MARK: - Song picker

private struct SongPickerView: View {
    let importedSongs: [Song]
    let loadBuiltIn: () -> Void
    let loadImported: (Song) -> Void
    let importMIDI: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Built in") {
                    Button("Right Hand Primer") {
                        loadBuiltIn()
                    }
                }

                Section("Imported MIDI") {
                    if importedSongs.isEmpty {
                        Text("No imported MIDI yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(importedSongs.enumerated()), id: \.offset) { item in
                            Button(item.element.title ?? "Imported MIDI") {
                                loadImported(item.element)
                            }
                        }
                    }
                    Button {
                        importMIDI()
                    } label: {
                        Label("Import MIDI", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("Songs")
        }
    }
}

// MARK: - HUD

private struct HUDPanel: View {
    @ObservedObject var session:     ARSessionModel
    @ObservedObject var placement:   PlacementManager
    @ObservedObject var calibration: CalibrationManager
    @ObservedObject var handTracker: HandTracker
    @ObservedObject var songPlayer: SongPlayer
    @ObservedObject var audioDetector: AudioPitchDetector
    @ObservedObject var keyTuning: KeyTuning
    let mode: AppMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PianoAR — Phase 5")
                .font(.caption.bold())
            Text("Tracking: \(session.trackingStateDescription)")
                .font(.caption2)
            Text("LiDAR: \(session.lidarAvailable ? "yes" : "no")")
                .font(.caption2)
            Text(statusLine)
                .font(.caption2)
            Text("Hands: \(handTracker.detectedHandCount)")
                .font(.caption2)
                .foregroundStyle(handTracker.detectedHandCount > 0 ? .green : .secondary)
            Text("Mic: \(audioDetector.microphoneState)")
                .font(.caption2)
                .foregroundStyle(audioDetector.microphoneState == "mic listening" ? .green : .secondary)
            Text("Lesson: \(songPlayer.acceptedCount)/\(songPlayer.notes.count)  Misses: \(songPlayer.mistakeCount)")
                .font(.caption2)
            if !songPlayer.scoreLine.isEmpty {
                Text(songPlayer.scoreLine)
                    .font(.caption2)
            }
            if keyTuning.panelVisible {
                Text(keyTuning.status(for: songPlayer.expectedKeyIndexNow()))
                    .font(.caption2)
            }
        }
        .padding(8)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
        .cornerRadius(8)
    }

    private var statusLine: String {
        switch mode {
        case .virtualPiano:
            switch placement.state {
            case .scanning:     return "Scanning for surfaces…"
            case .readyToPlace: return "Surface found — tap to place"
            case .placed:       return "Keyboard placed"
            }
        case .realPiano:
            switch calibration.state {
            case .idle:                  return "Calibration not started"
            case .collecting(let count): return "Corner \(count + 1)/4…"
            case .done:                  return "Calibrated"
            }
        }
    }
}

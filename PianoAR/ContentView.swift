import SwiftUI

enum AppMode { case virtualPiano, realPiano }

struct ContentView: View {
    @StateObject private var session     = ARSessionModel()
    @StateObject private var placement   = PlacementManager()
    @StateObject private var calibration = CalibrationManager()
    @State       private var mode: AppMode = .virtualPiano

    var body: some View {
        ZStack {
            ARPassthroughView(
                session:     session,
                placement:   placement,
                calibration: calibration,
                onTap:       handleTap
            )
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomInstructions
            }
        }
        .background(Color.black)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            HUDPanel(session: session, placement: placement, calibration: calibration, mode: mode)
                .padding(12)
            Spacer()
            modeToggle
                .padding(12)
        }
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
        case .virtualPiano:
            virtualPianoInstructions
        case .realPiano:
            realPianoInstructions
        }
    }

    @ViewBuilder
    private var virtualPianoInstructions: some View {
        switch placement.state {
        case .scanning:
            EmptyView()
        case .readyToPlace:
            instructionLabel("Tap a flat surface to place the keyboard")
        case .placed:
            resetButton("Remove keyboard") { placement.reset(session: session) }
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
}

// MARK: - HUD

private struct HUDPanel: View {
    @ObservedObject var session:     ARSessionModel
    @ObservedObject var placement:   PlacementManager
    @ObservedObject var calibration: CalibrationManager
    let mode: AppMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PianoAR — Phase 2")
                .font(.caption.bold())
            Text("Tracking: \(session.trackingStateDescription)")
                .font(.caption2)
            Text("LiDAR: \(session.lidarAvailable ? "yes" : "no")")
                .font(.caption2)
            Text(statusLine)
                .font(.caption2)
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
            case .idle:                   return "Calibration not started"
            case .collecting(let count):  return "Corner \(count + 1)/4…"
            case .done:                   return "Calibrated"
            }
        }
    }
}

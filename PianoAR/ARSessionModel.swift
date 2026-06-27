import ARKit
import Combine

/// Owns the ARSession and publishes lightweight state for SwiftUI HUD.
/// The session itself is passed to ARPassthroughView so the renderer can attach.
final class ARSessionModel: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var trackingStateDescription: String = "starting"
    @Published var lidarAvailable: Bool = false
    @Published var frameCount: Int = 0

    override init() {
        super.init()
        session.delegate = self
        lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        start()
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        config.isAutoFocusEnabled = true

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: ARSessionDelegate

    private var rawFrameCount: Int = 0

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Throttle UI updates — frame callback runs at ~60Hz.
        rawFrameCount &+= 1
        let snapshot = rawFrameCount
        if snapshot % 30 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.frameCount = snapshot
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let desc: String
        switch camera.trackingState {
        case .normal: desc = "normal"
        case .notAvailable: desc = "not available"
        case .limited(let reason):
            switch reason {
            case .initializing: desc = "limited (initializing)"
            case .excessiveMotion: desc = "limited (motion)"
            case .insufficientFeatures: desc = "limited (features)"
            case .relocalizing: desc = "limited (relocalizing)"
            @unknown default: desc = "limited (?)"
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.trackingStateDescription = desc
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.trackingStateDescription = "failed: \(error.localizedDescription)"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            self?.trackingStateDescription = "interrupted"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Resume tracking without removing existing anchors — the keyboard placement
        // must survive interruptions (notifications, screen lock, etc.).
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        config.isAutoFocusEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        session.run(config, options: [])   // no resetTracking, no removeExistingAnchors
    }
}

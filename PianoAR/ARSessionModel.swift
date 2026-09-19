import ARKit
import Combine

/// Owns the ARSession and publishes lightweight state for the HUD.
/// The session itself is passed to the AR view so the renderer can attach.
final class ARSessionModel: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var trackingStateDescription: String = "starting"
    @Published var lidarAvailable: Bool = false

    /// Latest thermal state — the HUD warns before iOS starts throttling
    /// frame rate (a sudden frame-rate drop is itself a motion-sickness cue).
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var thermalObserver: NSObjectProtocol?

    override init() {
        super.init()
        session.delegate = self
        lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }
        start()
    }

    deinit {
        if let obs = thermalObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func start() {
        session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    /// World tracking at the camera's fastest format (60 fps — ARKit offers
    /// nothing faster, even on ProMotion phones), horizontal planes for the
    /// keyboard surface, and LiDAR depth for fingertips.
    ///
    /// No scene-mesh reconstruction: `.estimatedPlane` + `.horizontal`
    /// raycasts never use the mesh, and meshing is one of the heaviest
    /// always-on ARKit workloads — heat that ends in iOS throttling the
    /// frame rate mid-practice.
    static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        config.isAutoFocusEnabled = true

        if let fastest = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.imageResolution.width >= 1920 })
            .max(by: { lhs, rhs in
                if lhs.framesPerSecond != rhs.framesPerSecond {
                    return lhs.framesPerSecond < rhs.framesPerSecond
                }
                // Prefer 4:3 (1920×1440): taller image = more vertical view per eye.
                return lhs.imageResolution.height < rhs.imageResolution.height
            }) {
            config.videoFormat = fastest
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        return config
    }

    // MARK: ARSessionDelegate

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
        session.run(Self.makeConfiguration(), options: [])
    }
}

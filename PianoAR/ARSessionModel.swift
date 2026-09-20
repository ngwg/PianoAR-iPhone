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

    /// What ARKit actually gave us, so the debug readout can say the real
    /// number instead of the one we hoped for.
    static var cameraFormatDescription = "—"

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

    /// World tracking at the camera's fastest available format, horizontal
    /// planes for the keyboard surface, and LiDAR depth for fingertips.
    ///
    /// Whatever ARKit offers is what we take — the chosen format is published
    /// in `cameraFormatDescription` and shown in the debug readout, so the
    /// real capture rate is a measurement rather than an assumption. In
    /// practice world tracking has been 60 fps on every device so far; the
    /// display is 120, and MotionWarp is what bridges the two.
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

        // Rate beats resolution, and the old filter had them the wrong way
        // round: it threw away everything under 1920 wide *before* comparing
        // frame rates, so a faster format at a smaller size could never win.
        //
        // 4K is excluded deliberately. Each eye is about 1300 px of a
        // half-screen, so a 3840-wide capture is downscaled to under a third
        // of itself — paid for in bandwidth, power and heat, and heat is what
        // ends up costing frames.
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.imageResolution.width >= 1280 && $0.imageResolution.width <= 2000 })
            .max(by: { lhs, rhs in
                if lhs.framesPerSecond != rhs.framesPerSecond {
                    return lhs.framesPerSecond < rhs.framesPerSecond
                }
                // Same rate: prefer the taller image (4:3 over 16:9), which is
                // more vertical view per eye — you are looking down at keys.
                let la = lhs.imageResolution.height / lhs.imageResolution.width
                let ra = rhs.imageResolution.height / rhs.imageResolution.width
                if abs(la - ra) > 0.01 { return la < ra }
                return lhs.imageResolution.width < rhs.imageResolution.width
            }) {
            config.videoFormat = best
            cameraFormatDescription = String(format: "%.0f×%.0f @ %d fps",
                                             best.imageResolution.width,
                                             best.imageResolution.height,
                                             best.framesPerSecond)
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

import ARKit
import SceneKit
import UIKit

// MARK: - Stereo container (phone-in-headset rendering)
//
// The Cardboard-style shell shows each eye one half of the screen through
// its own lens. The phone camera is mono, so both eyes intentionally get the
// same image; what matters for comfort is WHERE and HOW BIG each eye's image
// is drawn:
//
//  * each eye's image is centred on its lens (lens spacing, in mm, converted
//    with the display's physical pixel density), so the eyes never have to
//    diverge or cross to fuse the two images;
//  * each eye's image is drawn at a user-tunable size (view scale) instead of
//    filling the half-screen, so the world appears life-size through the
//    lenses and holds still when you turn your head;
//  * MotionWarp re-aims the image at 120 Hz from the gyro between camera
//    frames.
//
// Only `left` has the scene-renderer delegate and receives raycasts. In
// `.dual` mode a second ARSCNView renders the shared scene for the right eye;
// in `.replicated` mode the container's CAReplicatorLayer draws the left
// eye's layer a second time, shifted by the lens spacing, at no render cost.

final class StereoARContainer: UIView {
    override class var layerClass: AnyClass { CAReplicatorLayer.self }

    let left: ARSCNView
    private(set) var right: ARSCNView?
    private let leftHost = UIView()
    private let rightHost = UIView()
    private let session: ARSession
    let warp = MotionWarp()

    private(set) var comfort = ComfortSnapshot.default
    private var lensSpacingPoints: CGFloat = 374

    /// Physical density of every current iPhone Pro/Max/base panel (460 ppi).
    private static let screenPPI: CGFloat = 460

    init(session: ARSession) {
        self.session = session
        left = Self.makeARView(session: session)
        super.init(frame: .zero)
        backgroundColor = .black
        for host in [leftHost, rightHost] {
            host.clipsToBounds = true
            host.backgroundColor = .black
            host.isUserInteractionEnabled = false
            addSubview(host)
        }
        leftHost.addSubview(left)
        applyStereoMode()
        warp.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { warp.stop() }

    private static func makeARView(session: ARSession) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        // Overlay materials are all constant-lit; skip light-estimate work.
        v.automaticallyUpdatesLighting = false
        v.rendersContinuously = true
        // Camera-bound: ARKit delivers 60 fps, so rendering faster would only
        // re-draw identical frames. Smoothness above 60 comes from MotionWarp.
        v.preferredFramesPerSecond = 60
        v.contentMode = .scaleAspectFill
        v.debugOptions = []
        v.isUserInteractionEnabled = false
        return v
    }

    func apply(_ settings: ComfortSnapshot) {
        let modeChanged = settings.stereoMode != comfort.stereoMode
        comfort = settings
        warp.enabled = settings.motionSmoothing
        if modeChanged { applyStereoMode() }
        setNeedsLayout()
    }

    private func applyStereoMode() {
        guard let rep = layer as? CAReplicatorLayer else { return }
        switch comfort.stereoMode {
        case .replicated:
            right?.removeFromSuperview()
            right = nil
            rightHost.isHidden = true
            rep.instanceCount = 2
        case .dual:
            rep.instanceCount = 1
            rightHost.isHidden = false
            if right == nil {
                let r = Self.makeARView(session: session)
                r.scene = left.scene          // one shared scene graph → identical content
                rightHost.addSubview(r)
                right = r
            }
        }
        warp.targets = [left.layer] + (right.map { [$0.layer] } ?? [])
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        let scale = window?.screen.nativeScale ?? 3
        let pointsPerMM = Self.screenPPI / scale / 25.4
        let spacing = min(CGFloat(comfort.lensSpacingMM) * pointsPerMM, b.width - 8)
        lensSpacingPoints = spacing

        // Camera image aspect (1920×1440 → 4:3).
        let res = session.configuration?.videoFormat.imageResolution ?? CGSize(width: 1920, height: 1440)
        let camAspect = res.width / max(res.height, 1)

        let h = (CGFloat(comfort.viewScale) * b.height).rounded()
        // Width: the camera's own aspect, but never wider than the lens pitch
        // (eyes must not overlap) — aspect-fill then just trims the sides.
        let w = min(h * camAspect, spacing - 4).rounded()

        let cy = b.midY
        let lx = b.midX - spacing / 2
        let rx = b.midX + spacing / 2
        leftHost.frame  = CGRect(x: lx - w / 2, y: cy - h / 2, width: w, height: h)
        rightHost.frame = CGRect(x: rx - w / 2, y: cy - h / 2, width: w, height: h)

        // bounds + center (not frame): the views carry the warp transform.
        for (view, host) in [(left, leftHost)] + (right.map { [($0, rightHost)] } ?? []) {
            view.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            view.center = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        }

        if let rep = layer as? CAReplicatorLayer {
            rep.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
        }
        warp.pointsPerPixel = max(w / res.width, h / res.height)
        warp.flipped = window?.windowScene?.interfaceOrientation == .landscapeLeft
    }

    /// A tap anywhere maps into the driving (left) view: a tap on the right
    /// eye's image lands on the same scene point.
    func leftViewPoint(for p: CGPoint) -> CGPoint {
        var q = p
        if p.x > bounds.midX { q.x -= lensSpacingPoints }
        return convert(q, to: left)
    }
}

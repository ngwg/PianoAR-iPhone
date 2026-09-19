import ARKit
import CoreMotion
import QuartzCore
import UIKit
import simd

/// Late rotational re-projection ("timewarp") for video passthrough.
///
/// The camera runs at 60 fps and each image reaches the screen roughly
/// 40–60 ms after it was captured, so during a head turn the whole world
/// visibly lags and "swims" behind the motion — the classic passthrough
/// motion-sickness trigger. ARKit can't capture faster than 60 fps, but the
/// gyro runs at 100 Hz and the ProMotion display at 120 Hz: on every display
/// refresh this measures how far the head has rotated since the frame on
/// screen was captured and shifts/rolls that frame by exactly that much, so
/// the image stays locked to the world between (and despite) camera frames.
/// Camera image and AR overlay move together, so alignment is untouched.
///
/// Small-angle 2-D model: rotation about the camera's Y axis → horizontal
/// shift, about X → vertical shift, about Z (view axis) → roll. Exact enough
/// for the few degrees a head turns in ~50 ms.
final class MotionWarp: NSObject {
    var enabled = true {
        didSet { if !enabled { resetTransforms() } }
    }

    /// Layers to warp (each eye's AR view) — set on main.
    var targets: [CALayer] = []
    /// Aspect-fill scale of the camera image in the eye view (points per
    /// camera pixel) and whether the interface is landscapeLeft (image
    /// shown rotated 180°). Main thread.
    var pointsPerPixel: CGFloat = 0.2
    var flipped = false

    private let motion = CMMotionManager()
    private var link: CADisplayLink?

    // Gyro history (device frame, rad/s) — main thread only.
    private struct GyroSample { let t: TimeInterval; let w: SIMD3<Double> }
    private var gyro: [GyroSample] = []

    // Frame the AR view most recently drew — written on the render thread.
    private struct RenderedFrame {
        let timestamp: TimeInterval
        let fx: Double
        let rotation: simd_float3x3
    }
    private let lock = NSLock()
    private var rendered: RenderedFrame?
    private var previousRendered: RenderedFrame?

    // Per-axis sign self-check against ARKit's own frame-to-frame rotation
    // (a safety net for the device→camera axis mapping).
    private var axisSign = SIMD3<Double>(1, 1, 1)
    private var axisCorr = SIMD3<Double>(0, 0, 0)
    private var pendingChecks: [(t0: TimeInterval, t1: TimeInterval, arkit: SIMD3<Double>)] = []

    private let maxShiftFraction: CGFloat = 0.25   // of the eye view height
    private let maxRoll: CGFloat = 0.20            // rad
    private let displayLead: TimeInterval = 0.004  // compositor → glass

    func start() {
        guard link == nil else { return }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 100.0
            motion.startDeviceMotionUpdates()
        }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        motion.stopDeviceMotionUpdates()
        resetTransforms()
    }

    /// Render thread: call from renderer(_:didRenderScene:atTime:) with the
    /// frame that was just drawn.
    func noteRendered(frame: ARFrame) {
        let cam = frame.camera
        let c = cam.transform
        let r = simd_float3x3(columns: (SIMD3(c.columns.0.x, c.columns.0.y, c.columns.0.z),
                                        SIMD3(c.columns.1.x, c.columns.1.y, c.columns.1.z),
                                        SIMD3(c.columns.2.x, c.columns.2.y, c.columns.2.z)))
        let info = RenderedFrame(timestamp: frame.timestamp,
                                 fx: Double(cam.intrinsics[0][0]),
                                 rotation: r)
        lock.lock()
        if rendered?.timestamp != info.timestamp {
            previousRendered = rendered
            rendered = info
        }
        lock.unlock()
    }

    // MARK: - Display link (main thread, up to 120 Hz)

    private var lastCheckedFrame: TimeInterval = 0

    @objc private func tick(_ l: CADisplayLink) {
        pollGyro()
        lock.lock()
        let frame = rendered
        let prev = previousRendered
        lock.unlock()
        guard let frame else { return }

        if let prev, frame.timestamp != lastCheckedFrame {
            lastCheckedFrame = frame.timestamp
            queueSignCheck(from: prev, to: frame)
        }
        runSignChecks()

        guard enabled, !targets.isEmpty else { return }

        // Head rotation from the displayed frame's capture instant to the
        // moment this refresh reaches the glass.
        let θdev = integrate(from: frame.timestamp, to: l.targetTimestamp + displayLead)
        let θcam = SIMD3<Double>(-θdev.y, θdev.x, θdev.z) * axisSign

        let pointsPerRadian = frame.fx * Double(pointsPerPixel)
        var dx = CGFloat(pointsPerRadian * θcam.y)   // camera pans left → world slides right
        var dy = CGFloat(pointsPerRadian * θcam.x)   // camera pans up   → world slides down
        var roll = CGFloat(θcam.z)
        if flipped { dx = -dx; dy = -dy }            // image shown rotated 180°

        let limit = maxShiftFraction * (targets.first?.bounds.height ?? 300)
        let mag = (dx * dx + dy * dy).squareRoot()
        if mag > limit { dx *= limit / mag; dy *= limit / mag }
        roll = max(-maxRoll, min(maxRoll, roll))

        let t = CGAffineTransform(translationX: dx, y: dy).rotated(by: roll)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in targets { layer.setAffineTransform(t) }
        CATransaction.commit()
    }

    private func resetTransforms() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in targets { layer.setAffineTransform(.identity) }
        CATransaction.commit()
    }

    // MARK: - Gyro

    private func pollGyro() {
        guard let dm = motion.deviceMotion else { return }
        if let last = gyro.last, dm.timestamp <= last.t { return }
        let r = dm.rotationRate      // bias-corrected, device frame, right-hand rule
        gyro.append(GyroSample(t: dm.timestamp, w: SIMD3<Double>(r.x, r.y, r.z)))
        let cutoff = dm.timestamp - 0.6
        if let first = gyro.first, first.t < cutoff { gyro.removeAll { $0.t < cutoff } }
    }

    /// ∫ω dt over [t0, t1] in the device frame. Past the newest sample the
    /// latest rate is extrapolated (≤ 40 ms).
    private func integrate(from t0: TimeInterval, to t1: TimeInterval) -> SIMD3<Double> {
        guard t1 > t0, !gyro.isEmpty else { return .zero }
        var sum = SIMD3<Double>(repeating: 0)
        var covered = t0
        for s in gyro where s.t > t0 {
            let end = min(s.t, t1)
            if end > covered { sum += s.w * (end - covered) }
            covered = max(covered, end)
            if s.t >= t1 { break }
        }
        if covered < t1, let last = gyro.last {
            sum += last.w * min(t1 - covered, 0.04)
        }
        return sum
    }

    // MARK: - Axis self-check

    /// ARKit's own rotation between two drawn frames, in camera coordinates.
    private func queueSignCheck(from a: RenderedFrame, to b: RenderedFrame) {
        let dt = b.timestamp - a.timestamp
        guard dt > 0, dt < 0.1 else { return }
        let m = a.rotation.transpose * b.rotation          // cam_a → cam_b, in cam_a coords
        let w = SIMD3<Double>(Double(m[1][2] - m[2][1]) / 2,
                              Double(m[2][0] - m[0][2]) / 2,
                              Double(m[0][1] - m[1][0]) / 2)
        pendingChecks.append((a.timestamp, b.timestamp, w))
        if pendingChecks.count > 30 { pendingChecks.removeFirst() }
    }

    /// Correlates gyro-predicted rotation with ARKit's measured rotation per
    /// axis; flips an axis whose sign consistently disagrees.
    private func runSignChecks() {
        guard let newest = gyro.last?.t else { return }
        var keep: [(t0: TimeInterval, t1: TimeInterval, arkit: SIMD3<Double>)] = []
        for c in pendingChecks {
            guard c.t1 <= newest else { keep.append(c); continue }
            let g = integrate(from: c.t0, to: c.t1)
            let gCam = SIMD3<Double>(-g.y, g.x, g.z)
            axisCorr += c.arkit * gCam
        }
        pendingChecks = keep
        for i in 0..<3 where abs(axisCorr[i]) > 0.02 {    // ~ plenty of real head motion
            axisSign[i] = axisCorr[i] >= 0 ? 1 : -1
        }
    }
}

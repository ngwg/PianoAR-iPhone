import Foundation
import simd

/// A per-user "3D model" of each hand: the 20 finger-chain bone lengths
/// (wrist→thumb×4, wrist→index×4, …), measured once at first launch and saved
/// to device storage. The rendered AR hand is then driven through these fixed
/// lengths (forward-kinematics pass in Hand3DOverlay), which makes it look and
/// move like a rigid model of *your* hand instead of a jelly of independently
/// jittering points — per-frame Vision noise can shift a joint along its bone,
/// but it can no longer stretch or shrink the bone itself.
final class HandProfile {
    /// Number of chain bones (the first 20 entries of
    /// `HandTracker.boneConnections`; the last 3 are palm cross-links).
    static let chainBoneCount = 20
    private static let storeKey = "handProfile.v1"

    /// "L"/"R" → 20 bone lengths in metres.
    private(set) var lengths: [String: [Float]]

    init(lengths: [String: [Float]]) { self.lengths = lengths }

    func lengths(isLeft: Bool) -> [Float]? { lengths[isLeft ? "L" : "R"] }

    // MARK: - Persistence (UserDefaults — tiny payload, survives relaunch)

    static func load() -> HandProfile? {
        guard let dict = UserDefaults.standard.dictionary(forKey: storeKey)
                as? [String: [Double]] else { return nil }
        var l: [String: [Float]] = [:]
        for (k, v) in dict where v.count == chainBoneCount {
            l[k] = v.map(Float.init)
        }
        guard l["L"] != nil, l["R"] != nil else { return nil }
        return HandProfile(lengths: l)
    }

    func save() {
        var dict: [String: [Double]] = [:]
        for (k, v) in lengths { dict[k] = v.map(Double.init) }
        UserDefaults.standard.set(dict, forKey: Self.storeKey)
    }
}

/// First-launch hand scan: asks the user to hold their hands open in view,
/// collects bone-length samples from frames where the whole chain was
/// *genuinely detected* (no reconstructed joints), and produces a HandProfile
/// from per-bone medians. If only one hand ever shows up, the other side is
/// mirrored from it after a grace period so the scan can't stall forever.
final class HandScanner {
    static let samplesNeeded = 25
    private static let mirrorGrace: TimeInterval = 4.0

    private var samples: [String: [[Float]]] = ["L": [], "R": []]
    private var firstCompleteTime: TimeInterval? = nil
    private(set) var profile: HandProfile? = nil

    var isDone: Bool { profile != nil }

    /// Progress line for the hint bar.
    var hintText: String {
        let l = min(samples["L"]!.count, Self.samplesNeeded)
        let r = min(samples["R"]!.count, Self.samplesNeeded)
        let pct = Int(Float(l + r) / Float(Self.samplesNeeded * 2) * 100)
        return "Hold both hands open in view — scanning your hands… \(pct)%"
    }

    /// Feed every frame's hands. Returns true the moment the profile completes.
    @discardableResult
    func ingest(hands: [HandTracker.HandResult], time: TimeInterval) -> Bool {
        guard profile == nil else { return false }

        for hand in hands {
            let side = hand.isLeft ? "L" : "R"
            guard samples[side]!.count < Self.samplesNeeded else { continue }

            // Only fully-genuine frames: every chain joint present AND none of
            // them occlusion-reconstructed — a guessed joint would poison the
            // measured length.
            var lens: [Float] = []
            lens.reserveCapacity(HandProfile.chainBoneCount)
            var ok = true
            for i in 0..<HandProfile.chainBoneCount {
                let (a, b) = HandTracker.boneConnections[i]
                let na = HandTracker.allJoints[a], nb = HandTracker.allJoints[b]
                guard let pa = hand.joints[na], let pb = hand.joints[nb],
                      !hand.estimated.contains(na), !hand.estimated.contains(nb)
                else { ok = false; break }
                let l = simd_length(pb - pa)
                guard l > 0.005, l < 0.15 else { ok = false; break }   // sanity per bone
                lens.append(l)
            }
            if ok { samples[side]!.append(lens) }
        }

        let lDone = samples["L"]!.count >= Self.samplesNeeded
        let rDone = samples["R"]!.count >= Self.samplesNeeded

        if (lDone || rDone), firstCompleteTime == nil { firstCompleteTime = time }

        if lDone && rDone {
            finish(mirror: nil)
        } else if let t0 = firstCompleteTime, time - t0 > Self.mirrorGrace {
            // One hand never showed — mirror the scanned one so we don't stall.
            finish(mirror: lDone ? "R" : "L")
        }
        return profile != nil
    }

    private func finish(mirror: String?) {
        func median(_ side: String) -> [Float]? {
            let s = samples[side]!
            guard !s.isEmpty else { return nil }
            var out: [Float] = []
            for bone in 0..<HandProfile.chainBoneCount {
                let vals = s.map { $0[bone] }.sorted()
                out.append(vals[vals.count / 2])
            }
            return out
        }
        var l = median("L")
        var r = median("R")
        if mirror == "R" { r = l }
        if mirror == "L" { l = r }
        guard let lv = l, let rv = r else { return }
        profile = HandProfile(lengths: ["L": lv, "R": rv])
    }
}

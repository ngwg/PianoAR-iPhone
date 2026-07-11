import Foundation
import simd

/// A single Vision/LiDAR joint measurement in world space.
///
/// `isDepthMeasured` is false when Vision saw the 2D landmark but LiDAR had a
/// hole and the point had to borrow the hand's median depth. Those points are
/// useful for keeping the model continuous, but are still reported as
/// estimated so they can never be treated as press ground truth.
struct HandJointObservation {
    let position: SIMD3<Float>
    let confidence: Float
    let isDepthMeasured: Bool
}

struct HandPoseObservation {
    let isLeft: Bool
    let joints: [Int: HandJointObservation]

    var centroid: SIMD3<Float> {
        let palmIndices = [0, 5, 9, 13, 17]
        let palm = palmIndices.compactMap { joints[$0]?.position }
        let points = palm.count >= 2 ? palm : joints.values.map(\.position)
        guard !points.isEmpty else { return .zero }
        return points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
    }
}

struct StabilizedHandPose {
    /// Stable renderer/gesture slot (0 or 1), independent of Vision result order.
    let trackID: Int
    /// Stabilized label chosen when the spatial track is created.
    let isLeft: Bool
    let joints: [Int: SIMD3<Float>]
    let estimated: Set<Int>
    let visibility: Float
    let sampleTime: TimeInterval
}

/// Stateful hand-pose tracking layered on top of Vision's independent frames.
///
/// The stabilizer deliberately knows nothing about ARKit or Vision types, which
/// keeps the temporal/anatomical behavior deterministic and unit-testable.
final class HandPoseStabilizer {
    private struct JointState {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var lastMeasurementTime: TimeInterval
        var confidence: Float
    }

    private struct PalmFrame {
        let origin: SIMD3<Float>
        let rotation: simd_float3x3
    }

    private struct Track {
        let id: Int
        let isLeft: Bool
        var joints: [Int: JointState] = [:]
        var localPose: [Int: SIMD3<Float>] = [:]
        /// Length keyed by the child joint index. Every finger-chain joint has
        /// exactly one parent, so this is sufficient and avoids tuple keys.
        var boneLengths: [Int: Float] = [:]
        var lastMeasurementTime: TimeInterval
    }

    private static let fingerChains: [[Int]] = [
        [0, 1, 2, 3, 4],
        [0, 5, 6, 7, 8],
        [0, 9, 10, 11, 12],
        [0, 13, 14, 15, 16],
        [0, 17, 18, 19, 20],
    ]

    private static let maxTracks = 2
    private static let associationDistance: Float = 0.20
    private static let chiralityPenalty: Float = 0.035
    private static let jointPredictionEnd: TimeInterval = 0.22
    private static let fullHandHoldEnd: TimeInterval = 0.14
    private static let fullHandFadeEnd: TimeInterval = 0.26
    private static let velocityDecay: TimeInterval = 0.18
    private static let maxJointSpeed: Float = 2.2

    private var tracks: [Int: Track] = [:]

    func reset() {
        tracks.removeAll()
    }

    func update(observations: [HandPoseObservation],
                at time: TimeInterval) -> [StabilizedHandPose] {
        // Once the visual fade is over, retaining the track only risks matching
        // a newly-entered hand to an old identity.
        let expired = tracks.compactMap { id, track in
            time - track.lastMeasurementTime > Self.fullHandFadeEnd ? id : nil
        }
        for id in expired { tracks.removeValue(forKey: id) }

        let assignments = match(observations: observations, at: time)
        var updated = Set<Int>()
        var output: [StabilizedHandPose] = []

        for (observationIndex, observation) in observations.enumerated() {
            let trackID: Int
            if let matched = assignments[observationIndex] {
                trackID = matched
            } else if let created = createTrack(for: observation, at: time) {
                trackID = created
            } else {
                continue
            }

            guard var track = tracks[trackID] else { continue }
            output.append(update(track: &track, with: observation, at: time))
            tracks[trackID] = track
            updated.insert(trackID)
        }

        // A completely missed hand is predicted for a few frames, then fades.
        // Unlike the old chirality-keyed static holdover, this is bounded,
        // velocity-damped, and attached to a spatially matched track ID.
        for id in tracks.keys.sorted() where !updated.contains(id) {
            guard let track = tracks[id],
                  let predicted = predictedPose(for: track, at: time) else { continue }
            output.append(predicted)
        }

        return output.sorted { $0.trackID < $1.trackID }
    }

    // MARK: - Stable hand association

    private func match(observations: [HandPoseObservation],
                       at time: TimeInterval) -> [Int?] {
        guard !observations.isEmpty, !tracks.isEmpty else {
            return Array(repeating: nil, count: observations.count)
        }

        struct Candidate {
            let observationIndex: Int
            let trackID: Int
            let score: Float
        }

        var candidates: [Candidate] = []
        for (oi, observation) in observations.enumerated() {
            for (id, track) in tracks {
                let center = predictedCentroid(of: track, at: time)
                let distance = simd_length(observation.centroid - center)
                guard distance <= Self.associationDistance else { continue }
                let penalty: Float = observation.isLeft == track.isLeft
                    ? 0 : Self.chiralityPenalty
                candidates.append(Candidate(observationIndex: oi, trackID: id,
                                            score: distance + penalty))
            }
        }
        candidates.sort { $0.score < $1.score }

        var result = Array<Int?>(repeating: nil, count: observations.count)
        var claimedTracks = Set<Int>()
        for candidate in candidates {
            guard result[candidate.observationIndex] == nil,
                  !claimedTracks.contains(candidate.trackID) else { continue }
            result[candidate.observationIndex] = candidate.trackID
            claimedTracks.insert(candidate.trackID)
        }
        return result
    }

    private func createTrack(for observation: HandPoseObservation,
                             at time: TimeInterval) -> Int? {
        guard let id = (0..<Self.maxTracks).first(where: { tracks[$0] == nil }) else {
            return nil
        }

        var stableIsLeft = observation.isLeft
        if tracks.values.contains(where: { $0.isLeft == stableIsLeft }) {
            stableIsLeft.toggle()
        }
        tracks[id] = Track(id: id, isLeft: stableIsLeft,
                           lastMeasurementTime: time)
        return id
    }

    private func predictedCentroid(of track: Track,
                                   at time: TimeInterval) -> SIMD3<Float> {
        let palmIndices = [0, 5, 9, 13, 17]
        var points = palmIndices.compactMap { index -> SIMD3<Float>? in
            guard let state = track.joints[index] else { return nil }
            return predictedPosition(of: state, at: time)
        }
        if points.count < 2 {
            points = track.joints.values.map { predictedPosition(of: $0, at: time) }
        }
        guard !points.isEmpty else { return .zero }
        return points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
    }

    // MARK: - Measurement update and gap filling

    private func update(track: inout Track,
                        with observation: HandPoseObservation,
                        at time: TimeInterval) -> StabilizedHandPose {
        track.lastMeasurementTime = time

        var directPositions: [Int: SIMD3<Float>] = [:]
        var directIndices = Set<Int>()
        var reliableIndices = Set<Int>()
        var estimated = Set<Int>()

        for (index, measurement) in observation.joints {
            let filtered = updateJoint(track.joints[index],
                                       measurement: measurement,
                                       at: time)
            track.joints[index] = filtered
            directPositions[index] = filtered.position
            directIndices.insert(index)
            if measurement.isDepthMeasured {
                reliableIndices.insert(index)
            } else {
                estimated.insert(index)
            }
        }

        learnBoneLengths(track: &track, observation: observation,
                         directPositions: directPositions)

        let reliablePositions = directPositions.filter { reliableIndices.contains($0.key) }
        let livePalm = palmFrame(from: reliablePositions)
            ?? palmFrame(from: directPositions)

        if let palm = livePalm {
            let inverse = palm.rotation.transpose
            for (index, position) in reliablePositions {
                guard observation.joints[index]?.confidence ?? 0 >= 0.55 else { continue }
                let local = inverse * (position - palm.origin)
                if let old = track.localPose[index] {
                    track.localPose[index] = old * 0.90 + local * 0.10
                } else {
                    track.localPose[index] = local
                }
            }
        }

        var joints = directPositions
        var temporal: [Int: SIMD3<Float>] = [:]

        // First recover every possible gap from the current palm pose and/or
        // the joint's short velocity history. This also works when the wrist is
        // missing because palmFrame can be built from live MCP/PIP geometry.
        for index in 0..<21 where joints[index] == nil {
            let predicted: SIMD3<Float>? = track.joints[index].flatMap { state in
                time - state.lastMeasurementTime <= Self.jointPredictionEnd
                    ? predictedPosition(of: state, at: time) : nil
            }
            temporal[index] = predicted

            let anatomical = livePalm.flatMap { palm in
                track.localPose[index].map { palm.origin + palm.rotation * $0 }
            }

            if let predicted, let anatomical {
                let age = time - (track.joints[index]?.lastMeasurementTime ?? time)
                let temporalWeight = Float(simd_clamp(1.0 - age / Self.jointPredictionEnd,
                                                      0.25, 0.70))
                joints[index] = predicted * temporalWeight
                    + anatomical * (1 - temporalWeight)
                estimated.insert(index)
            } else if let anatomical {
                joints[index] = anatomical
                estimated.insert(index)
            } else if let predicted {
                joints[index] = predicted
                estimated.insert(index)
            }
        }

        // Refine inferred joints from live neighboring bones. A missing tip is
        // extrapolated from PIP->DIP using the learned distal length; an
        // interior gap is placed between its two directly seen neighbors using
        // the learned length ratio. Measured joints are never hard-snapped.
        for chain in Self.fingerChains {
            for chainIndex in 1..<chain.count {
                let joint = chain[chainIndex]
                guard !directIndices.contains(joint) else { continue }

                var boneGuess: SIMD3<Float>?
                if chainIndex == chain.count - 1 {
                    let parent = chain[chainIndex - 1]
                    let grandparent = chain[chainIndex - 2]
                    if directIndices.contains(parent), directIndices.contains(grandparent),
                       let parentPosition = joints[parent],
                       let grandparentPosition = joints[grandparent] {
                        let direction = parentPosition - grandparentPosition
                        let directionLength = simd_length(direction)
                        if directionLength > 1e-4 {
                            let learned = track.boneLengths[joint]
                                ?? directionLength * (joint == 4 ? 0.82 : 0.72)
                            boneGuess = parentPosition + direction / directionLength * learned
                        }
                    }
                } else {
                    let parent = chain[chainIndex - 1]
                    let child = chain[chainIndex + 1]
                    if directIndices.contains(parent), directIndices.contains(child),
                       let parentPosition = joints[parent],
                       let childPosition = joints[child] {
                        let before = track.boneLengths[joint]
                        let after = track.boneLengths[child]
                        let ratio: Float
                        if let before, let after, before + after > 1e-4 {
                            ratio = before / (before + after)
                        } else {
                            ratio = 0.5
                        }
                        boneGuess = parentPosition + (childPosition - parentPosition) * ratio
                    }
                }

                if let boneGuess {
                    if let predicted = temporal[joint] {
                        joints[joint] = boneGuess * 0.72 + predicted * 0.28
                    } else {
                        joints[joint] = boneGuess
                    }
                    estimated.insert(joint)
                }
            }
        }

        return StabilizedHandPose(trackID: track.id, isLeft: track.isLeft,
                                  joints: joints, estimated: estimated,
                                  visibility: 1, sampleTime: time)
    }

    private func updateJoint(_ old: JointState?,
                             measurement: HandJointObservation,
                             at time: TimeInterval) -> JointState {
        guard let old else {
            return JointState(position: measurement.position, velocity: .zero,
                              lastMeasurementTime: time,
                              confidence: measurement.confidence)
        }

        let dt = max(1.0 / 120.0, min(0.25, time - old.lastMeasurementTime))
        let dtFloat = Float(dt)
        let decay = Float(exp(-dt / Self.velocityDecay))
        let predictedVelocity = old.velocity * decay
        let predicted = predictedPosition(of: old, at: time)

        var residual = measurement.position - predicted
        var residualLength = simd_length(residual)
        let speed = simd_length(predictedVelocity)
        // Generous clamp: it exists to stop teleports from a bad LiDAR pixel,
        // not to slow real motion — a playing hand easily moves 3-5cm between
        // Vision samples and must be followed within a single update.
        let residualLimit = min(0.18, max(0.05, 0.05 + speed * dtFloat * 2.5))
        if residualLength > residualLimit, residualLength > 1e-5 {
            residual *= residualLimit / residualLength
            residualLength = residualLimit
        }

        let normalizedConfidence = simd_clamp((measurement.confidence - 0.30) / 0.70,
                                              0, 1)
        // Fast ramp: anything beyond ~2.5cm of residual snaps nearly all the
        // way to the measurement (alpha 0.95). Smoothing only really applies
        // to sub-centimetre jitter at rest.
        let motion = simd_clamp(residualLength / 0.025, 0, 1)
        let alpha = simd_clamp(0.10 + 0.80 * motion + 0.08 * normalizedConfidence,
                               0.14, 0.95)
        let beta = 0.05 + 0.18 * motion

        let position = predicted + residual * alpha
        var velocity = predictedVelocity * 0.72 + residual * (beta / dtFloat)
        let velocityLength = simd_length(velocity)
        if velocityLength > Self.maxJointSpeed {
            velocity *= Self.maxJointSpeed / velocityLength
        }

        return JointState(position: position, velocity: velocity,
                          lastMeasurementTime: time,
                          confidence: measurement.confidence)
    }

    private func predictedPosition(of state: JointState,
                                   at time: TimeInterval) -> SIMD3<Float> {
        let dt = max(0, min(Self.fullHandFadeEnd,
                            time - state.lastMeasurementTime))
        // Integral of an exponentially decaying velocity. It coasts naturally
        // for one or two misses, then converges instead of drifting forever.
        let travel = Self.velocityDecay * (1 - exp(-dt / Self.velocityDecay))
        return state.position + state.velocity * Float(travel)
    }

    private func predictedPose(for track: Track,
                               at time: TimeInterval) -> StabilizedHandPose? {
        let age = time - track.lastMeasurementTime
        guard age >= 0, age <= Self.fullHandFadeEnd else { return nil }

        var joints: [Int: SIMD3<Float>] = [:]
        for (index, state) in track.joints
        where time - state.lastMeasurementTime <= Self.fullHandFadeEnd {
            joints[index] = predictedPosition(of: state, at: time)
        }
        guard !joints.isEmpty else { return nil }

        let visibility: Float
        if age <= Self.fullHandHoldEnd {
            visibility = 1
        } else {
            visibility = Float(simd_clamp(
                (Self.fullHandFadeEnd - age)
                    / (Self.fullHandFadeEnd - Self.fullHandHoldEnd), 0, 1
            ))
        }

        return StabilizedHandPose(trackID: track.id, isLeft: track.isLeft,
                                  joints: joints, estimated: Set(joints.keys),
                                  visibility: visibility, sampleTime: time)
    }

    // MARK: - Anatomy learning

    private func learnBoneLengths(track: inout Track,
                                  observation: HandPoseObservation,
                                  directPositions: [Int: SIMD3<Float>]) {
        for chain in Self.fingerChains {
            for i in 1..<chain.count {
                let parent = chain[i - 1]
                let child = chain[i]
                guard let parentObservation = observation.joints[parent],
                      let childObservation = observation.joints[child],
                      parentObservation.isDepthMeasured,
                      childObservation.isDepthMeasured,
                      parentObservation.confidence >= 0.55,
                      childObservation.confidence >= 0.55,
                      let a = directPositions[parent],
                      let b = directPositions[child] else { continue }

                var measured = simd_length(b - a)
                guard measured > 0.004, measured < 0.10 else { continue }
                if let old = track.boneLengths[child] {
                    measured = simd_clamp(measured, old * 0.70, old * 1.30)
                    track.boneLengths[child] = old * 0.92 + measured * 0.08
                } else {
                    track.boneLengths[child] = measured
                }
            }
        }
    }

    /// Builds a palm-local frame from wrist+MCPs when possible, or MCPs plus
    /// their live PIP direction when the wrist itself is occluded.
    private func palmFrame(from positions: [Int: SIMD3<Float>]) -> PalmFrame? {
        let mcpIndices = [5, 9, 13, 17].filter { positions[$0] != nil }
        guard mcpIndices.count >= 2 else { return nil }

        let mcpPoints = mcpIndices.compactMap { positions[$0] }
        let origin = mcpPoints.reduce(SIMD3<Float>(repeating: 0), +)
            / Float(mcpPoints.count)

        let acrossRaw: SIMD3<Float>
        if let indexMCP = positions[5], let littleMCP = positions[17] {
            acrossRaw = littleMCP - indexMCP
        } else {
            guard let first = mcpPoints.first, let last = mcpPoints.last else { return nil }
            acrossRaw = last - first
        }

        var forwardRaw: SIMD3<Float>?
        if let wrist = positions[0] {
            forwardRaw = origin - wrist
        } else {
            var directions: [SIMD3<Float>] = []
            for mcp in mcpIndices {
                if let base = positions[mcp], let pip = positions[mcp + 1] {
                    directions.append(pip - base)
                }
            }
            if directions.count >= 2 {
                forwardRaw = directions.reduce(SIMD3<Float>(repeating: 0), +)
                    / Float(directions.count)
            }
        }

        guard var forward = forwardRaw, simd_length(forward) > 1e-4 else { return nil }
        forward = simd_normalize(forward)
        var across = acrossRaw - forward * simd_dot(acrossRaw, forward)
        guard simd_length(across) > 1e-4 else { return nil }
        across = simd_normalize(across)

        let normal = simd_cross(forward, across)
        guard simd_length(normal) > 1e-4 else { return nil }
        let up = simd_normalize(normal)
        let correctedAcross = simd_cross(up, forward)
        return PalmFrame(origin: origin,
                         rotation: simd_float3x3(columns: (correctedAcross, up, forward)))
    }
}

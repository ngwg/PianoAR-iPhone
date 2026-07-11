import XCTest
import simd
@testable import PianoAR

final class HandPoseStabilizerTests: XCTestCase {
    private func joint(_ x: Float, _ y: Float, _ z: Float,
                       depth: Bool = true) -> HandJointObservation {
        HandJointObservation(position: SIMD3<Float>(x, y, z),
                             confidence: 0.92,
                             isDepthMeasured: depth)
    }

    private func hand(centerX: Float = 0,
                      isLeft: Bool = true,
                      omitting omitted: Set<Int> = []) -> HandPoseObservation {
        let raw: [Int: HandJointObservation] = [
            0:  joint(centerX,       0.00, 0.00),
            5:  joint(centerX - 0.03, 0.06, 0.00),
            6:  joint(centerX - 0.03, 0.09, 0.00),
            7:  joint(centerX - 0.03, 0.115, 0.00),
            8:  joint(centerX - 0.03, 0.133, 0.00),
            9:  joint(centerX - 0.01, 0.065, 0.00),
            10: joint(centerX - 0.01, 0.10, 0.00),
            13: joint(centerX + 0.015, 0.060, 0.00),
            14: joint(centerX + 0.015, 0.090, 0.00),
            17: joint(centerX + 0.035, 0.050, 0.00),
            18: joint(centerX + 0.035, 0.075, 0.00),
        ]
        return HandPoseObservation(isLeft: isLeft,
                                   joints: raw.filter { !omitted.contains($0.key) })
    }

    func testMissingTipUsesLiveBonesAndIsEstimated() throws {
        let stabilizer = HandPoseStabilizer()
        _ = stabilizer.update(observations: [hand()], at: 1.00)

        let output = try XCTUnwrap(stabilizer.update(
            observations: [hand(omitting: [8])], at: 1.05
        ).first)
        let tip = try XCTUnwrap(output.joints[8])
        let dip = try XCTUnwrap(output.joints[7])

        XCTAssertTrue(output.estimated.contains(8))
        XCTAssertTrue(tip.x.isFinite && tip.y.isFinite && tip.z.isFinite)
        XCTAssertGreaterThan(tip.y, dip.y)
    }

    func testMissingInteriorJointInterpolatesBetweenLiveNeighbors() throws {
        let stabilizer = HandPoseStabilizer()
        _ = stabilizer.update(observations: [hand()], at: 1.50)

        let output = try XCTUnwrap(stabilizer.update(
            observations: [hand(omitting: [7])], at: 1.55
        ).first)
        let pip = try XCTUnwrap(output.joints[6])
        let dip = try XCTUnwrap(output.joints[7])
        let tip = try XCTUnwrap(output.joints[8])

        XCTAssertTrue(output.estimated.contains(7))
        XCTAssertGreaterThan(dip.y, pip.y)
        XCTAssertLessThan(dip.y, tip.y)
    }

    func testLandmarkWithoutLiDARRemainsEstimated() throws {
        let stabilizer = HandPoseStabilizer()
        var joints = hand().joints
        joints[8] = joint(-0.03, 0.133, 0, depth: false)
        let output = try XCTUnwrap(stabilizer.update(
            observations: [HandPoseObservation(isLeft: true, joints: joints)],
            at: 1.75
        ).first)

        XCTAssertTrue(output.estimated.contains(8))
    }

    func testWholeHandMissPredictsThenExpires() throws {
        let stabilizer = HandPoseStabilizer()
        _ = stabilizer.update(observations: [hand()], at: 2.00)

        let held = try XCTUnwrap(stabilizer.update(observations: [], at: 2.08).first)
        XCTAssertEqual(held.estimated, Set(held.joints.keys))
        XCTAssertEqual(held.visibility, 1, accuracy: 0.001)

        let fading = try XCTUnwrap(stabilizer.update(observations: [], at: 2.20).first)
        XCTAssertGreaterThan(fading.visibility, 0)
        XCTAssertLessThan(fading.visibility, 1)

        XCTAssertTrue(stabilizer.update(observations: [], at: 2.27).isEmpty)
    }

    func testChiralityFlapKeepsSpatialIdentity() throws {
        let stabilizer = HandPoseStabilizer()
        let first = try XCTUnwrap(stabilizer.update(
            observations: [hand(isLeft: true)], at: 3.00
        ).first)
        let second = try XCTUnwrap(stabilizer.update(
            observations: [hand(isLeft: false)], at: 3.05
        ).first)

        XCTAssertEqual(second.trackID, first.trackID)
        XCTAssertEqual(second.isLeft, first.isLeft)
    }

    func testObservationOrderDoesNotSwapTwoTracks() throws {
        let stabilizer = HandPoseStabilizer()
        let first = stabilizer.update(observations: [
            hand(centerX: -0.12, isLeft: true),
            hand(centerX:  0.12, isLeft: false),
        ], at: 4.00)
        let leftID = try XCTUnwrap(first.min {
            $0.joints[0]!.x < $1.joints[0]!.x
        }?.trackID)

        let second = stabilizer.update(observations: [
            hand(centerX:  0.12, isLeft: false),
            hand(centerX: -0.12, isLeft: true),
        ], at: 4.05)
        let newLeftID = try XCTUnwrap(second.min {
            $0.joints[0]!.x < $1.joints[0]!.x
        }?.trackID)

        XCTAssertEqual(newLeftID, leftID)
    }

    func testLargeJointOutlierIsBounded() throws {
        let stabilizer = HandPoseStabilizer()
        let first = try XCTUnwrap(stabilizer.update(
            observations: [hand()], at: 5.00
        ).first)
        let oldTip = try XCTUnwrap(first.joints[8])

        var outlierJoints = hand().joints
        outlierJoints[8] = joint(0.90, 0.90, -0.90)
        let outlier = HandPoseObservation(isLeft: true, joints: outlierJoints)
        let second = try XCTUnwrap(stabilizer.update(
            observations: [outlier], at: 5.05
        ).first)
        let newTip = try XCTUnwrap(second.joints[8])

        XCTAssertLessThan(simd_length(newTip - oldTip), 0.09)
    }
}

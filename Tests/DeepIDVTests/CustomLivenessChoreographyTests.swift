import Foundation
import Testing

@testable import DeepIDV
@testable import DeepIDVCore

struct CustomLivenessChoreographyTests {
    @Test func centeringRequiresCenteredAdequateFaceHeld() {
        var choreo = LivenessChoreography(script: .movement)
        // too small → not centered
        #expect(choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.10, centerOffset: 0.05)).centeringDone == false)
        // off-center → not centered (and resets the hold)
        #expect(choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.40, centerOffset: 0.50)).centeringDone == false)
        // adequate + centered, held for the required frames → centeringDone
        var done = false
        for _ in 0..<LivenessChoreography.holdCenteredFrames {
            done = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.40, centerOffset: 0.05)).centeringDone
        }
        #expect(done == true)
    }

    @Test func multipleFacesBlockCentering() {
        var choreo = LivenessChoreography(script: .movement)
        for _ in 0..<LivenessChoreography.holdCenteredFrames {
            _ = choreo.ingest(FaceQuality(faceCount: 2, faceWidthRatio: 0.40, centerOffset: 0.05))
        }
        #expect(choreo.centeringDone == false)
    }

    @Test func movementCheckpointsFireOnceAsProximityGrows() {
        var choreo = LivenessChoreography(script: .movement)
        for _ in 0..<LivenessChoreography.holdCenteredFrames {
            _ = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.30, centerOffset: 0.05))
        }
        // grow from start(0.30) toward target(0.55): collect every checkpoint fired
        var fires: [Double] = []
        for ratio in stride(from: 0.30, through: 0.56, by: 0.02) {
            fires += choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: ratio, centerOffset: 0.05)).checkpointsToCapture
        }
        #expect(Set(fires) == Set(LivenessChoreography.movementCheckpoints))  // each checkpoint exactly once
        #expect(choreo.movementComplete == true)
    }

    // MARK: Start distance (movement challenge)

    @Test func movementCenteringWaitsForTheFaceToMoveBack() {
        var choreo = LivenessChoreography(script: .movement)
        var tick = LivenessChoreography.Tick(centeringDone: false, progress: 0, checkpointsToCapture: [])
        for _ in 0..<LivenessChoreography.holdCenteredFrames * 2 {
            tick = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.55, centerOffset: 0.05))
        }
        #expect(tick.centeringDone == false)
        #expect(tick.tooClose == true)

        for _ in 0..<LivenessChoreography.holdCenteredFrames {
            tick = choreo.ingest(
                FaceQuality(
                    faceCount: 1, faceWidthRatio: LivenessChoreography.maxStartFaceWidthRatio,
                    centerOffset: 0.05))
        }
        #expect(tick.centeringDone == true)
        #expect(tick.tooClose == false)
    }

    @Test func movingTooCloseResetsTheCenteringHold() {
        var choreo = LivenessChoreography(script: .movement)
        for _ in 0..<(LivenessChoreography.holdCenteredFrames - 1) {
            _ = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.35, centerOffset: 0.05))
        }
        _ = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.50, centerOffset: 0.05))
        let tick = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.35, centerOffset: 0.05))
        #expect(tick.centeringDone == false)
    }

    @Test func lightChallengeHasNoStartDistanceLimit() {
        let light = ChallengeScript(
            challengeType: .faceMovementAndLight, durationMs: 4000,
            steps: [ChallengeStep(kind: "color", atMs: 0, color: "#FF0000")])
        var choreo = LivenessChoreography(script: light)
        var tick = LivenessChoreography.Tick(centeringDone: false, progress: 0, checkpointsToCapture: [])
        for _ in 0..<LivenessChoreography.holdCenteredFrames {
            tick = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: 0.60, centerOffset: 0.05))
        }
        #expect(tick.centeringDone == true)
        #expect(tick.tooClose == false)
    }

    /// The server passes a movement capture only when the mean face size of the
    /// last two frames is at least 1.15× the first two (`PASS_GROWTH`). From the
    /// widest allowed start, a steady approach must clear that with room to spare.
    @Test func widestAllowedStartStillClearsTheServerGrowthGate() {
        var choreo = LivenessChoreography(script: .movement)
        let start = LivenessChoreography.maxStartFaceWidthRatio
        for _ in 0..<LivenessChoreography.holdCenteredFrames {
            _ = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: start, centerOffset: 0.05))
        }

        var capturedWidths: [Double] = []
        var ratio = start
        while !choreo.movementComplete, ratio <= 0.60 {
            let tick = choreo.ingest(FaceQuality(faceCount: 1, faceWidthRatio: ratio, centerOffset: 0.05))
            capturedWidths += tick.checkpointsToCapture.map { _ in ratio }
            ratio += 0.005
        }

        #expect(capturedWidths.count == LivenessChoreography.movementCheckpoints.count)
        let first = (capturedWidths[0] + capturedWidths[1]) / 2
        let last = (capturedWidths[2] + capturedWidths[3]) / 2
        #expect(last / first >= 1.2)
    }
}

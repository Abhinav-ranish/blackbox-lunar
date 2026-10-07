import CoreVideo
import Foundation
import Vision

/// One sample of what Apple Vision sees in a frame: is a human there, and did they move.
struct HumanSample {
    var humanPresent: Bool
    var moved: Bool
    var motionScore: Double
    var box: CGRect?
}

/// Real-time presence + motion detection. Fuses Apple's on-device upper-body, face and
/// body-pose detectors, and measures motion as luma change inside the person's region plus
/// body-pose drift. The last known region is kept through detector dropouts.
final class HumanMonitor {
    private var previousLuma: [UInt8] = []
    private var previousJoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    private var lastBox: CGRect?
    private var lastBoxDate = Date.distantPast
    private let gridW = 64, gridH = 48

    /// Fraction of grid cells inside the person region whose brightness changed noticeably.
    var pixelMotionThreshold = 0.03
    /// Average joint displacement (normalized image coords) that counts as movement.
    var poseMotionThreshold = 0.015
    /// How long the last known region is used for motion after detectors lose the person.
    var regionHold: TimeInterval = 10

    func analyze(_ pixelBuffer: CVPixelBuffer) -> HumanSample {
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = true
        let faces = VNDetectFaceRectanglesRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([humans, faces, pose])

        let luma = downsampledLuma(pixelBuffer)
        defer { previousLuma = luma }

        // Body pose joints, and their bounding box as a fallback region.
        var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        if let points = try? pose.results?.first?.recognizedPoints(.all) {
            joints = points.filter { $0.value.confidence > 0.3 }.mapValues { $0.location }
        }

        let bodyBox = humans.results?.filter { $0.confidence > 0.3 }
            .max(by: { $0.boundingBox.area < $1.boundingBox.area })?.boundingBox
        let faceBox = faces.results?.filter { $0.confidence > 0.5 }
            .max(by: { $0.boundingBox.area < $1.boundingBox.area })
            .map { face -> CGRect in
                // A face implies a head + torso below it.
                let b = face.boundingBox
                return CGRect(x: b.minX - b.width, y: b.minY - b.height * 3, width: b.width * 3, height: b.height * 4)
            }
        let poseBox = joints.count >= 3 ? boundingBox(of: Array(joints.values)) : nil

        let detected = bodyBox ?? faceBox ?? poseBox
        let now = Date()
        if let detected {
            lastBox = detected
            lastBoxDate = now
        }

        // Use the last known region through short dropouts so a still person keeps being measured.
        let region = detected ?? (now.timeIntervalSince(lastBoxDate) < regionHold ? lastBox : nil)
        guard let region else {
            previousJoints = [:]
            return HumanSample(humanPresent: false, moved: false, motionScore: 0, box: nil)
        }

        var poseScore = 0.0
        let shared = joints.keys.filter { previousJoints[$0] != nil }
        if shared.count >= 4 {
            poseScore = shared.map { hypot(joints[$0]!.x - previousJoints[$0]!.x,
                                           joints[$0]!.y - previousJoints[$0]!.y) }
                .reduce(0, +) / Double(shared.count)
        }
        if !joints.isEmpty { previousJoints = joints }

        let pixelScore = changedFraction(current: luma, previous: previousLuma,
                                         portraitRegion: region.insetBy(dx: -0.05, dy: -0.05))
        let moved = pixelScore > pixelMotionThreshold || poseScore > poseMotionThreshold
        return HumanSample(humanPresent: detected != nil, moved: moved,
                           motionScore: max(pixelScore, poseScore), box: region)
    }

    private func boundingBox(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Downsamples the Y (luma) plane of the landscape sensor buffer to a small grid.
    private func downsampledLuma(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Average a 4x4 sample inside each cell so sensor noise doesn't read as motion.
        var out = [UInt8](repeating: 0, count: gridW * gridH)
        let cellW = w / gridW, cellH = h / gridH
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                var sum = 0
                for sy in 0..<4 {
                    let row = (gy * cellH + sy * cellH / 4) * stride
                    for sx in 0..<4 { sum += Int(ptr[row + gx * cellW + sx * cellW / 4]) }
                }
                out[gy * gridW + gx] = UInt8(sum / 16)
            }
        }
        return out
    }

    private func changedFraction(current: [UInt8], previous: [UInt8], portraitRegion r: CGRect) -> Double {
        guard current.count == previous.count, !current.isEmpty else { return 0 }
        var changed = 0, total = 0
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                // Sensor (landscape) -> portrait with .right orientation:
                // portrait x = 1 - sensorY, portrait y (Vision, bottom-left origin) = 1 - sensorX.
                let sx = (Double(gx) + 0.5) / Double(gridW), sy = (Double(gy) + 0.5) / Double(gridH)
                let p = CGPoint(x: 1 - sy, y: 1 - sx)
                guard r.contains(p) else { continue }
                total += 1
                let i = gy * gridW + gx
                if abs(Int(current[i]) - Int(previous[i])) > 18 { changed += 1 }
            }
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

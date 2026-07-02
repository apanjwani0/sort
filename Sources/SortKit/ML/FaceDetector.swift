import Foundation
import Vision
import CoreGraphics

/// One detected face. `boundingBox` is in Vision's normalized space (origin bottom-left), which is
/// what `FaceAligner` consumes directly. Pose angles are radians. `landmarks5` (eye/eye/nose/
/// mouth/mouth, top-left-normalized) is best-effort and used by the 5-point ArcFace alignment (M8).
public struct DetectedFace: Sendable, Equatable {
    public var boundingBox: CGRect
    public var roll: Double?
    public var yaw: Double?
    public var pitch: Double?
    public var quality: Float?
    public var landmarks5: [CGPoint]?

    public init(boundingBox: CGRect, roll: Double? = nil, yaw: Double? = nil, pitch: Double? = nil,
                quality: Float? = nil, landmarks5: [CGPoint]? = nil) {
        self.boundingBox = boundingBox
        self.roll = roll
        self.yaw = yaw
        self.pitch = pitch
        self.quality = quality
        self.landmarks5 = landmarks5
    }
}

/// Apple Vision face detection: rectangles + landmarks + pose + capture quality, on the Neural Engine.
public struct FaceDetector: Sendable {
    public init() {}

    public func detect(in image: CGImage,
                       orientation: CGImagePropertyOrientation = .up) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])

        let landmarksReq = VNDetectFaceLandmarksRequest()
        try handler.perform([landmarksReq])
        let observations = landmarksReq.results ?? []
        guard !observations.isEmpty else { return [] }

        // Capture quality is a second pass seeded with the detected faces (order preserved).
        let qualityReq = VNDetectFaceCaptureQualityRequest()
        qualityReq.inputFaceObservations = observations
        try? handler.perform([qualityReq])
        let qualityResults = qualityReq.results ?? []

        return observations.enumerated().map { index, obs in
            let quality = index < qualityResults.count
                ? qualityResults[index].faceCaptureQuality
                : obs.faceCaptureQuality
            return DetectedFace(
                boundingBox: obs.boundingBox,
                roll: obs.roll?.doubleValue,
                yaw: obs.yaw?.doubleValue,
                pitch: obs.pitch?.doubleValue,
                quality: quality,
                landmarks5: Self.fivePoints(from: obs)
            )
        }
    }

    /// Best-effort 5-point landmarks in top-left-normalized image coordinates.
    private static func fivePoints(from obs: VNFaceObservation) -> [CGPoint]? {
        guard let lm = obs.landmarks else { return nil }
        let bb = obs.boundingBox
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
            let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
            return mapToImage(CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count)), bb: bb)
        }
        func corner(_ region: VNFaceLandmarkRegion2D?, leftmost: Bool) -> CGPoint? {
            guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
            let p = leftmost ? pts.min { $0.x < $1.x } : pts.max { $0.x < $1.x }
            return p.map { mapToImage($0, bb: bb) }
        }
        guard let le = centroid(lm.leftEye), let re = centroid(lm.rightEye) else { return nil }
        let nose = centroid(lm.nose) ?? CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
        let ml = corner(lm.outerLips, leftmost: true) ?? le
        let mr = corner(lm.outerLips, leftmost: false) ?? re
        return [le, re, nose, ml, mr]
    }

    /// Map a face-local normalized point into top-left-normalized image coordinates.
    private static func mapToImage(_ p: CGPoint, bb: CGRect) -> CGPoint {
        let ix = bb.minX + p.x * bb.width
        let iyBottom = bb.minY + p.y * bb.height
        return CGPoint(x: ix, y: 1 - iyBottom)   // Vision is bottom-left; flip to top-left
    }
}

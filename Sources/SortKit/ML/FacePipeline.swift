import Foundation
import CoreGraphics

/// Detect → gate → align → embed for a single image. Quality/pose gating drops blurry or extreme
/// faces before the (relatively expensive) embedding step.
public struct FacePipeline: Sendable {
    public var detector: FaceDetector
    public var aligner: FaceAligner
    public var embedder: FaceEmbedder
    /// Drop faces below this Vision capture-quality score (0…1). Nil disables the gate.
    public var minQuality: Float?
    /// Longest edge to downsample to for detection (full-res isn't needed to find faces).
    public var detectMaxPixel: Int

    public init(embedder: FaceEmbedder,
                detector: FaceDetector = .init(),
                aligner: FaceAligner = .init(),
                minQuality: Float? = 0.3,
                detectMaxPixel: Int = 1600) {
        self.embedder = embedder
        self.detector = detector
        self.aligner = aligner
        self.minQuality = minQuality
        self.detectMaxPixel = detectMaxPixel
    }

    public struct FaceResult: Sendable {
        public var face: DetectedFace
        public var embedding: [Float]
    }

    public func process(imageAt url: URL) throws -> [FaceResult] {
        let image = try ImageLoader.load(url, maxPixelSize: detectMaxPixel)
        return try process(image: image)
    }

    public func process(image: CGImage) throws -> [FaceResult] {
        let faces = try detector.detect(in: image)
        var results: [FaceResult] = []
        results.reserveCapacity(faces.count)
        for face in faces {
            if let minQuality, let q = face.quality, q < minQuality { continue }
            guard let crop = aligner.embeddingCrop(from: image, face: face) else { continue }
            let embedding = try embedder.embed(crop)
            results.append(FaceResult(face: face, embedding: embedding))
        }
        return results
    }
}

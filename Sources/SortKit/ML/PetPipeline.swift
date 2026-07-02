import Foundation
import Vision
import CoreGraphics

/// Per-individual pet face pipeline: find animals + their head joints with Apple Vision, align on the
/// eyes+nose (the only on-device pet landmarks), and embed the aligned crop. Pets are embedded with a
/// general feature-print embedder (no pet-specific model bundled) and clustered in their own namespace.
public struct PetPipeline: Sendable {
    public var embedder: FaceEmbedder
    public var aligner: FaceAligner
    public var detectMaxPixel: Int
    /// Min joint confidence to trust an eye/nose point for alignment.
    public var minJointConfidence: Float

    public init(embedder: FaceEmbedder = VisionFeaturePrintEmbedder(),
                aligner: FaceAligner = .init(outputSize: 160),
                detectMaxPixel: Int = 1600,
                minJointConfidence: Float = 0.2) {
        self.embedder = embedder
        self.aligner = aligner
        self.detectMaxPixel = detectMaxPixel
        self.minJointConfidence = minJointConfidence
    }

    public struct PetResult: Sendable {
        public var bbox: CGRect      // head box, Vision-normalized (origin bottom-left), for display
        public var embedding: [Float]
    }

    public func process(image: CGImage) throws -> [PetResult] {
        let request = VNDetectAnimalBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }

        var results: [PetResult] = []
        for obs in observations {
            guard let le = try? obs.recognizedPoint(.leftEye),
                  let re = try? obs.recognizedPoint(.rightEye),
                  let nose = try? obs.recognizedPoint(.nose),
                  le.confidence >= minJointConfidence,
                  re.confidence >= minJointConfidence,
                  nose.confidence >= minJointConfidence,
                  let crop = aligner.petCrop(from: image, leftEye: le.location,
                                             rightEye: re.location, nose: nose.location)
            else { continue }
            let embedding = try embedder.embed(crop)
            results.append(PetResult(bbox: Self.headBox(le.location, re.location, nose.location),
                                     embedding: embedding))
        }
        return results
    }

    /// A padded head bounding box (Vision-normalized, bottom-left) around the 3 joints, for the cover crop.
    static func headBox(_ pts: CGPoint...) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let w = max(maxX - minX, 0.01), h = max(maxY - minY, 0.01)
        let padX = w * 0.9, padY = h * 1.1   // eyes/nose span only the face center → pad generously
        let x = max(0, minX - padX), y = max(0, minY - padY)
        return CGRect(x: x, y: y,
                      width: min(1 - x, w + 2 * padX), height: min(1 - y, h + 2 * padY))
    }
}

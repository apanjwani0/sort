import Foundation
import Vision
import CoreGraphics

public enum MLError: Error, CustomStringConvertible {
    case noFeaturePrint
    case unsupportedFeaturePrintType
    case modelOutputMissing(String)

    public var description: String {
        switch self {
        case .noFeaturePrint: return "Vision returned no feature print"
        case .unsupportedFeaturePrintType: return "Unsupported feature-print element type"
        case .modelOutputMissing(let n): return "Core ML output '\(n)' missing"
        }
    }
}

/// Turns an aligned face crop into an identity embedding vector. The vector length is whatever the
/// model produces; callers record it as `embeddingDim`. Embedders are swappable behind this protocol
/// (D1): Vision feature print today, bundled Core ML ArcFace (buffalo_l) at M8.
public protocol FaceEmbedder: Sendable {
    /// Stable identifier persisted alongside each embedding so a model swap is detectable.
    var modelIdentifier: String { get }
    func embed(_ alignedFace: CGImage) throws -> [Float]
}

/// Default embedder: Apple Vision's general image feature print. NOT face-specialized, but fully
/// on-device with zero model bundling — it proves the whole pipeline end-to-end. Swapped for an
/// ArcFace Core ML model (M8) for production-grade identity grouping.
public struct VisionFeaturePrintEmbedder: FaceEmbedder {
    public let modelIdentifier = "vision.featureprint"
    public init() {}

    public func embed(_ alignedFace: CGImage) throws -> [Float] {
        let handler = VNImageRequestHandler(cgImage: alignedFace, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        try handler.perform([request])
        guard let obs = request.results?.first as? VNFeaturePrintObservation else {
            throw MLError.noFeaturePrint
        }
        return try Self.floats(from: obs)
    }

    static func floats(from obs: VNFeaturePrintObservation) throws -> [Float] {
        let count = obs.elementCount
        switch obs.elementType {
        case .float:
            return obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            let doubles = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Double.self).prefix(count)) }
            return doubles.map(Float.init)
        default:
            throw MLError.unsupportedFeaturePrintType
        }
    }
}

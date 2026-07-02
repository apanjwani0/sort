import Foundation
import CoreML
import CoreGraphics
import CoreVideo

/// Bundled Core ML face embedder (D1/D6: ArcFace buffalo_l, 512-d). Generic over input/output
/// feature names and input side so the same class serves any converted face model. Validated end-to-end
/// in M8 when the .mlmodelc ships; until then it's exercised only with an explicit model URL.
public final class CoreMLEmbedder: FaceEmbedder, @unchecked Sendable {
    private let model: MLModel
    public let modelIdentifier: String
    private let inputName: String
    private let outputName: String
    private let inputSize: Int

    public init(modelURL: URL, identifier: String,
                inputName: String, outputName: String, inputSize: Int = 112) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all   // prefer the Neural Engine
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.modelIdentifier = identifier
        self.inputName = inputName
        self.outputName = outputName
        self.inputSize = inputSize
    }

    public func embed(_ alignedFace: CGImage) throws -> [Float] {
        guard let buffer = Self.pixelBuffer(from: alignedFace, size: inputSize) else {
            throw ImageError.cannotCreatePixelBuffer
        }
        let input = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
            throw MLError.modelOutputMissing(outputName)
        }
        return Self.floats(from: array)
    }

    static func floats(from array: MLMultiArray) -> [Float] {
        let count = array.count
        if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        return (0..<count).map { Float(truncating: array[$0]) }
    }

    static func pixelBuffer(from image: CGImage, size: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}

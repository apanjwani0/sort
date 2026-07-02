import XCTest
import CoreGraphics
@testable import SortKit

final class MLPipelineTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sort-ml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testImageLoaderRoundTripAndDownsample() throws {
        let url = tmp.appendingPathComponent("p.png")
        try ImageLoader.writePNG(TestImage.make(width: 64, height: 64, rgb: (1, 0, 0)), to: url)

        let full = try ImageLoader.load(url)
        XCTAssertEqual(full.width, 64)
        XCTAssertEqual(full.height, 64)

        let small = try ImageLoader.load(url, maxPixelSize: 32)
        XCTAssertLessThanOrEqual(max(small.width, small.height), 32)
    }

    func testVisionFeaturePrintEmbedderSeparatesImages() throws {
        let imageA = TestImage.make(width: 224, height: 224, rgb: (0.9, 0.1, 0.1),
                                    block: (CGRect(x: 0, y: 0, width: 80, height: 80), (0.1, 0.1, 0.9)))
        let imageACopy = TestImage.make(width: 224, height: 224, rgb: (0.9, 0.1, 0.1),
                                        block: (CGRect(x: 0, y: 0, width: 80, height: 80), (0.1, 0.1, 0.9)))
        let imageB = TestImage.make(width: 224, height: 224, rgb: (0.1, 0.8, 0.2),
                                    block: (CGRect(x: 140, y: 140, width: 80, height: 80), (0.9, 0.1, 0.1)))

        let embedder = VisionFeaturePrintEmbedder()
        let va = try embedder.embed(imageA)
        let vaCopy = try embedder.embed(imageACopy)
        let vb = try embedder.embed(imageB)

        XCTAssertFalse(va.isEmpty)
        XCTAssertEqual(va.count, vb.count)

        let dSame = Vector.cosineDistance(va, vaCopy)
        let dDiff = Vector.cosineDistance(va, vb)
        XCTAssertLessThan(dSame, 0.05, "identical pixels should embed almost identically")
        XCTAssertGreaterThan(dDiff, dSame, "different images should be farther apart than identical ones")
    }

    func testAlignerProducesFixedSquareCrop() {
        let image = TestImage.make(width: 200, height: 200, rgb: (0.5, 0.5, 0.5))
        let face = DetectedFace(boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                roll: nil, yaw: nil, pitch: nil, quality: nil, landmarks5: nil)
        let crop = FaceAligner(outputSize: 112).alignedCrop(from: image, face: face)
        XCTAssertNotNil(crop)
        XCTAssertEqual(crop?.width, 112)
        XCTAssertEqual(crop?.height, 112)
    }

    func testDetectorReturnsNoFacesForNonFaceImage() throws {
        let image = TestImage.make(width: 256, height: 256, rgb: (0.3, 0.6, 0.9))
        XCTAssertTrue(try FaceDetector().detect(in: image).isEmpty)
    }

    func testPipelineProducesNoResultsWithoutFaces() throws {
        let url = tmp.appendingPathComponent("plain.png")
        try ImageLoader.writePNG(TestImage.make(width: 256, height: 256, rgb: (0.2, 0.2, 0.2)), to: url)
        let pipeline = FacePipeline(embedder: VisionFeaturePrintEmbedder())
        XCTAssertTrue(try pipeline.process(imageAt: url).isEmpty)
    }
}

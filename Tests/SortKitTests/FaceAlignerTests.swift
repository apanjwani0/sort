import XCTest
import CoreGraphics
@testable import SortKit

/// The 5-point similarity alignment is what makes ArcFace embeddings discriminative, so its math
/// (least-squares similarity transform) is worth a direct check.
final class FaceAlignerTests: XCTestCase {

    func testSimilarityTransformRecoversKnownTransform() throws {
        let src = [CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 25),
                   CGPoint(x: 45, y: 60), CGPoint(x: 20, y: 95), CGPoint(x: 75, y: 92)]
        // Known similarity: scale 1.7, rotate 25°, translate (12, -8). No reflection/shear.
        let known = CGAffineTransform(rotationAngle: 25 * .pi / 180)
            .concatenating(CGAffineTransform(scaleX: 1.7, y: 1.7))
            .concatenating(CGAffineTransform(translationX: 12, y: -8))
        let dst = src.map { $0.applying(known) }

        let t = FaceAligner.similarityTransform(from: src, to: dst)
        let recovered = try XCTUnwrap(t)
        for p in src {
            let got = p.applying(recovered), want = p.applying(known)
            XCTAssertEqual(got.x, want.x, accuracy: 1e-4)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-4)
        }
    }

    func testSimilarityTransformIgnoresUniformScaleErrorFromNoise() throws {
        // Exact correspondences must map exactly onto the ArcFace template.
        let src = FaceAligner.template112.map { CGPoint(x: $0.x * 2 + 5, y: $0.y * 2 + 7) }
        let t = try XCTUnwrap(FaceAligner.similarityTransform(from: src, to: FaceAligner.template112))
        for (s, d) in zip(src, FaceAligner.template112) {
            let got = s.applying(t)
            XCTAssertEqual(got.x, d.x, accuracy: 1e-3)
            XCTAssertEqual(got.y, d.y, accuracy: 1e-3)
        }
    }

    func testDegenerateLandmarksReturnNil() {
        let same = Array(repeating: CGPoint(x: 5, y: 5), count: 5)
        XCTAssertNil(FaceAligner.similarityTransform(from: same, to: FaceAligner.template112))
    }
}

import XCTest
@testable import SortKit

final class VectorTests: XCTestCase {
    func testL2NormalizedHasUnitNorm() {
        let v: [Float] = [3, 4, 0, 0]
        let n = Vector.l2normalized(v)
        XCTAssertEqual(sqrt(Vector.dot(n, n)), 1, accuracy: 1e-5)
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-5)
    }

    func testL2NormalizeZeroVectorIsSafe() {
        let z: [Float] = [0, 0, 0]
        XCTAssertEqual(Vector.l2normalized(z), z)
    }

    func testCosineSimilarityBounds() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let c: [Float] = [-1, 0, 0]
        let d: [Float] = [0, 1, 0]
        XCTAssertEqual(Vector.cosineSimilarity(a, b), 1, accuracy: 1e-6)
        XCTAssertEqual(Vector.cosineSimilarity(a, c), -1, accuracy: 1e-6)
        XCTAssertEqual(Vector.cosineSimilarity(a, d), 0, accuracy: 1e-6)
        XCTAssertEqual(Vector.cosineDistance(a, b), 0, accuracy: 1e-6)
    }

    func testMeanCentroid() {
        let m = Vector.mean([[0, 0], [2, 4], [4, 8]])
        XCTAssertEqual(m, [2, 4])
    }

    func testBlobRoundTrip() {
        let v: [Float] = (0..<512).map { Float($0) * 0.01 }
        let restored = [Float](blob: v.blob)
        XCTAssertEqual(v, restored)
        XCTAssertEqual(v.blob.count, 512 * 4)
    }

    // Mismatched dimensions must NOT trap — they used to precondition-crash the whole clustering pass
    // when a library mixed embedding models/dimensions.
    func testMismatchedLengthsDoNotTrap() {
        XCTAssertEqual(Vector.dot([1, 2, 3], [1, 2]), 0)
        XCTAssertEqual(Vector.cosineSimilarity([1, 2, 3], [1, 2]), 0)
        XCTAssertEqual(Vector.cosineDistance([1, 2, 3], [1, 2]), 1, accuracy: 1e-6)   // maximally distant
    }

    func testMeanSkipsWrongLengthVectors() {
        XCTAssertEqual(Vector.mean([[2, 4], [6, 8], [0, 0, 0]]), [4, 6])   // odd-length ignored, not fatal
    }

    // A truncated/misaligned BLOB (e.g. a write interrupted by a crash) decodes to empty, not a trap.
    func testBlobFromCorruptDataIsEmpty() {
        XCTAssertTrue([Float](blob: Data([1, 2, 3])).isEmpty)   // 3 bytes, not a multiple of 4
        XCTAssertTrue([Float](blob: Data()).isEmpty)
    }
}

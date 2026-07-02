import XCTest
@testable import SortKit

/// The centroid-merge post-pass is what collapses a person's over-split sub-groups, so verify it
/// merges centroid-close groups, leaves distinct ones alone, and honors cannot-link.
final class CentroidMergeTests: XCTestCase {
    // Two near-identical groups (A1, A2) and one far group (B).
    private let vectors: [[Float]] = [
        [1, 0, 0, 0], [0.99, 0.1, 0, 0],     // A1 → indices 0,1
        [0.98, 0, 0.1, 0], [1, 0, 0.05, 0],  // A2 → indices 2,3
        [0, 1, 0, 0], [0, 0.99, 0.1, 0],     // B  → indices 4,5
    ]

    func testMergesCloseCentroidsKeepsFarApart() {
        let merged = AgglomerativeClustering.centroidMerge(
            groups: [[0, 1], [2, 3], [4, 5]], vectors: vectors, threshold: 0.3, cannotLink: [])
        XCTAssertEqual(merged.count, 2, "A1+A2 should collapse; B stays separate")
        XCTAssertTrue(merged.contains { Set($0) == [0, 1, 2, 3] })
        XCTAssertTrue(merged.contains { Set($0) == [4, 5] })
    }

    func testCannotLinkBlocksMerge() {
        let merged = AgglomerativeClustering.centroidMerge(
            groups: [[0, 1], [2, 3], [4, 5]], vectors: vectors, threshold: 0.3, cannotLink: [(0, 2)])
        XCTAssertEqual(merged.count, 3, "a cannot-link between A1 and A2 must keep them apart")
    }
}

import XCTest
@testable import SortKit

final class IndexServiceTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sort-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Plain (face-free) images exercise the full coordinator deterministically.
        for rel in ["one.png", "nested/two.png", "nested/three.png"] {
            let url = tmp.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try ImageLoader.writePNG(TestImage.make(width: 48, height: 48, rgb: (0.4, 0.4, 0.4)), to: url)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testFullIndexPassPlumbing() throws {
        let db = try AppDatabase.inMemory()
        let service = IndexService(db: db)

        let report = try service.index(rootPath: tmp.path, now: 1)
        XCTAssertEqual(report.scan.discovered, 3)
        XCTAssertEqual(report.photosProcessed, 3)
        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.facesAdded, 0)              // no faces in plain images
        XCTAssertEqual(report.recluster.people, 0)
        XCTAssertTrue(try service.people().isEmpty)

        // Every photo reached the embedded state.
        XCTAssertTrue(try PhotoRepository(db).all().allSatisfy { $0.state == PhotoState.embedded.rawValue })
    }

    func testReindexIsIncremental() throws {
        let db = try AppDatabase.inMemory()
        let service = IndexService(db: db)
        _ = try service.index(rootPath: tmp.path, now: 1)

        let second = try service.index(rootPath: tmp.path, now: 2)
        XCTAssertEqual(second.scan.unchanged, 3)
        XCTAssertEqual(second.scan.discovered, 0)
        XCTAssertEqual(second.photosProcessed, 0, "unchanged photos must not be reprocessed")
    }
}

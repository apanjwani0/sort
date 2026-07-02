import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SortKit

/// Perceptual-hash duplicate detection: the hash is deterministic, Hamming distance is correct, and
/// `duplicateSets` groups within the threshold while leaving distinct photos alone.
final class DuplicateTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sort-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func writeJPEG(_ name: String, _ image: CGImage) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testHashIsDeterministicForTheSameImage() throws {
        let img = TestImage.make(width: 128, height: 128, rgb: (0.6, 0.6, 0.6),
                                 block: (CGRect(x: 6, y: 6, width: 46, height: 46), (0, 0, 0)))
        let h1 = try XCTUnwrap(ImageLoader.dHash(writeJPEG("a1.jpg", img)))
        let h2 = try XCTUnwrap(ImageLoader.dHash(writeJPEG("a2.jpg", img)))
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(ImageLoader.hammingDistance(h1, h2), 0)
    }

    func testHammingDistance() {
        XCTAssertEqual(ImageLoader.hammingDistance(0, 0), 0)
        XCTAssertEqual(ImageLoader.hammingDistance(0, 0b1011), 3)
        XCTAssertEqual(ImageLoader.hammingDistance(Int64(bitPattern: ~0), 0), 64)
    }

    func testDuplicateSetsGroupsWithinThresholdOnly() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let repo = PhotoRepository(db)
        func add(_ name: String, _ phash: Int64) throws {
            let p = try repo.upsert(Photo(rootId: root.id!, relativePath: name, mtime: 1, size: 1)).photo
            try repo.setPhash(phash, id: p.id!)
        }
        try add("a1.jpg", 0)
        try add("a2.jpg", 0b111)                      // 3 bits from a1 → ≤6 → duplicate
        try add("b.jpg", Int64(bitPattern: ~0))       // 64 bits → distinct

        let sets = try IndexService(db: db).duplicateSets()
        XCTAssertEqual(sets.count, 1, "the two near-equal hashes group; the distant one is alone")
        XCTAssertEqual(Set(sets[0].map(\.relativePath)), ["a1.jpg", "a2.jpg"])
    }

    // VB2: the set order (and within-set order) must be FULLY DETERMINISTIC across calls — the old
    // dict-iteration order reshuffled equal-count sets, so the list jumped after closing the viewer.
    func testDuplicateSetsOrderIsDeterministic() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let repo = PhotoRepository(db)
        func add(_ name: String, _ phash: Int64) throws {
            let p = try repo.upsert(Photo(rootId: root.id!, relativePath: name, mtime: 1, size: 1)).photo
            try repo.setPhash(phash, id: p.id!)
        }
        try add("a1.jpg", 0)
        try add("a2.jpg", 0b11)                                  // group A (ids 1,2)
        try add("b1.jpg", Int64(bitPattern: ~0))
        try add("b2.jpg", Int64(bitPattern: ~0) ^ 0b11)          // group B (ids 3,4), distinct from A

        let svc = IndexService(db: db)
        let order = try svc.duplicateSets().map { $0.map(\.relativePath) }
        // Two count-2 sets, tiebroken by first-photo id asc; within a set, id asc on the resolution/size tie.
        XCTAssertEqual(order, [["a1.jpg", "a2.jpg"], ["b1.jpg", "b2.jpg"]])
        for _ in 0..<5 { XCTAssertEqual(try svc.duplicateSets().map { $0.map(\.relativePath) }, order) }
    }
}

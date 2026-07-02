import XCTest
@testable import SortKit

final class ScannerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sort-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func write(_ rel: String, _ contents: String = "x") throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeScanner() throws -> (PhotoScanner, ScannedRoot, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: tmp.path, volumeUUID: nil, bookmark: nil, now: 0)
        return (PhotoScanner(db: db), root, db)
    }

    func testFindsNestedImagesAndSkipsNonImagesHiddenAndPackages() throws {
        try write("a.jpg")
        try write("sub/b.jpg")
        try write("sub/deep/c.png")
        try write("notes.txt")                    // not an image
        try write(".secret.jpg")                  // hidden
        try write("Archive.app/inside.jpg")       // inside a package bundle

        let (scanner, root, db) = try makeScanner()
        let report = try scanner.scan(root: root, rootURL: tmp, now: 1)

        XCTAssertEqual(report.discovered, 3)
        XCTAssertEqual(report.unchanged, 0)
        XCTAssertEqual(report.missing, 0)
        XCTAssertEqual(try PhotoRepository(db).all().count, 3)

        // Every indexed photo carries a filesystem inode.
        XCTAssertTrue(try PhotoRepository(db).all().allSatisfy { $0.fileID != nil })
    }

    func testIncrementalRescanSkipsUnchanged() throws {
        try write("a.jpg")
        try write("b.jpg")
        let (scanner, root, db) = try makeScanner()

        let first = try scanner.scan(root: root, rootURL: tmp, now: 1)
        XCTAssertEqual(first.discovered, 2)

        // Reload root so scanGeneration advances correctly.
        let root2 = try RootRepository(db).all().first { $0.displayPath == tmp.path }!
        let second = try scanner.scan(root: root2, rootURL: tmp, now: 2)
        XCTAssertEqual(second.discovered, 0)
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(second.unchanged, 2)
    }

    func testDetectsChangeAdditionAndDeletion() throws {
        try write("keep.jpg", "short")
        try write("edit.jpg", "short")
        try write("gone.jpg", "short")
        let (scanner, root, db) = try makeScanner()
        let roots = RootRepository(db)
        _ = try scanner.scan(root: root, rootURL: tmp, now: 1)

        // Edit one (length changes → size differs), delete one, add one.
        try write("edit.jpg", "a much longer body that changes the file size")
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("gone.jpg"))
        try write("fresh.jpg")

        let root2 = try roots.all().first { $0.displayPath == tmp.path }!
        let report = try scanner.scan(root: root2, rootURL: tmp, now: 2)

        XCTAssertEqual(report.discovered, 1, "fresh.jpg")
        XCTAssertEqual(report.changed, 1, "edit.jpg")
        XCTAssertEqual(report.unchanged, 1, "keep.jpg")
        XCTAssertEqual(report.missing, 1, "gone.jpg")

        let gone = try PhotoRepository(db).find(rootId: root.id!, relativePath: "gone.jpg")
        XCTAssertEqual(gone?.state, PhotoState.missing.rawValue)
    }
}

import XCTest
@testable import SortKit

/// Export copies originals OUT; it must never modify/move the source (the read-only invariant) and
/// must not overwrite existing files at the destination.
final class ExportTests: XCTestCase {
    func testExportCopiesOriginalAndLeavesSourceUntouched() throws {
        let fm = FileManager.default
        let srcDir = fm.temporaryDirectory.appendingPathComponent("sort-exp-src-\(UUID().uuidString)")
        let destDir = fm.temporaryDirectory.appendingPathComponent("sort-exp-dst-\(UUID().uuidString)")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: srcDir); try? fm.removeItem(at: destDir) }

        let bytes = Data("hello-photo".utf8)
        let srcFile = srcDir.appendingPathComponent("a.jpg")
        try bytes.write(to: srcFile)

        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: srcDir.path, volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "a.jpg", mtime: 0, size: Int64(bytes.count))).photo

        let report = try IndexService(db: db).exportPhotos(ids: [photo.id!], to: destDir)
        XCTAssertEqual(report.exported, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try Data(contentsOf: destDir.appendingPathComponent("a.jpg")), bytes)  // copied
        XCTAssertEqual(try Data(contentsOf: srcFile), bytes)                                  // source intact
    }

    func testExportSuffixesNameCollisions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sort-exp-collide-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))   // already there
        XCTAssertEqual(IndexService.uniqueDestination(for: "a.jpg", in: dir, fm: fm).lastPathComponent,
                       "a (2).jpg")
    }

    func testExportCountsMissingSource() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db)
            .add(displayPath: "/no-such-dir-\(UUID().uuidString)", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "gone.jpg", mtime: 0, size: 0)).photo
        let report = try IndexService(db: db)
            .exportPhotos(ids: [photo.id!], to: FileManager.default.temporaryDirectory)
        XCTAssertEqual(report.missing, 1)
        XCTAssertEqual(report.exported, 0)
    }
}

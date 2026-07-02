import XCTest
import CryptoKit
@testable import SortKit

/// A trasher that moves files into a temp directory instead of the real Trash, so tests can verify
/// deletion behavior without polluting the user's Trash.
private struct FakeTrash: FileTrashing {
    let dest: URL
    func trash(_ url: URL) throws -> URL? {
        let target = dest.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

final class TrashTests: XCTestCase {
    private var tmp: URL!
    private var trashDir: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sort-trash-\(UUID().uuidString)")
        trashDir = tmp.appendingPathComponent("_trash")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: tmp.appendingPathComponent("a.jpg"))
        try Data("bravo".utf8).write(to: tmp.appendingPathComponent("b.jpg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDeleteMovesFileToTrashAndUpdatesIndex() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: tmp.path, volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let faces = FaceRepository(db)
        let persons = PersonRepository(db)

        let a = try photos.upsert(Photo(rootId: root.id!, relativePath: "a.jpg", mtime: 0, size: 5)).photo
        _ = try photos.upsert(Photo(rootId: root.id!, relativePath: "b.jpg", mtime: 0, size: 5)).photo
        let person = try persons.create(now: 0)
        _ = try faces.insert(Face(photoId: a.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                  embedding: ([1, 0, 0, 0] as [Float]).blob, embeddingModel: "t",
                                  embeddingDim: 4, personId: person.id, createdAt: 0))

        let bHashBefore = SHA256.hash(data: try Data(contentsOf: tmp.appendingPathComponent("b.jpg")))

        let report = try IndexService(db: db)
            .deletePhotos(ids: [a.id!], trasher: FakeTrash(dest: trashDir), now: 1)

        // File moved to "trash", removed from source; sibling untouched (read-only except trashing).
        XCTAssertEqual(report.trashed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("a.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashDir.appendingPathComponent("a.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("b.jpg").path))
        let bHashAfter = SHA256.hash(data: try Data(contentsOf: tmp.appendingPathComponent("b.jpg")))
        XCTAssertEqual(bHashBefore, bHashAfter, "sibling file changed — only the target should move")

        // Index updated: photo + its faces gone, now-empty person pruned.
        XCTAssertNil(try photos.find(a.id!))
        XCTAssertEqual(try faces.forPhoto(a.id!).count, 0)
        XCTAssertEqual(report.removedPeople, 1)
        XCTAssertNil(try persons.find(person.id!))
    }

    func testDeleteMissingFileStillRemovesIndexRow() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: tmp.path, volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let ghost = try photos.upsert(Photo(rootId: root.id!, relativePath: "gone.jpg", mtime: 0, size: 1)).photo

        let report = try IndexService(db: db)
            .deletePhotos(ids: [ghost.id!], trasher: FakeTrash(dest: trashDir), now: 1)

        XCTAssertEqual(report.missing, 1)
        XCTAssertEqual(report.trashed, 0)
        XCTAssertNil(try photos.find(ghost.id!))
    }
}

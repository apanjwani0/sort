import XCTest
@testable import SortKit

final class DataLayerTests: XCTestCase {
    private func makeRoot(_ db: AppDatabase, now: Double = 1000) throws -> ScannedRoot {
        try RootRepository(db).add(displayPath: "/Volumes/SSD/Photos", volumeUUID: "VOL-1",
                                   bookmark: nil, now: now)
    }

    func testMigrationAndPersonRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let people = PersonRepository(db)
        let p = try people.create(now: 1000)
        XCTAssertNotNil(p.id)
        try people.rename(p.id!, to: "Muskan", now: 1001)
        let fetched = try people.find(p.id!)
        XCTAssertEqual(fetched?.displayName, "Muskan")
    }

    func testPhotoUpsertIncrementalSemantics() throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot(db)
        let photos = PhotoRepository(db)

        let base = Photo(rootId: root.id!, relativePath: "a/b.jpg", volumeUUID: "VOL-1",
                         fileID: 42, mtime: 100, size: 2048, state: .discovered, scanGeneration: 1)

        // First sight → must process.
        let r1 = try photos.upsert(base)
        XCTAssertTrue(r1.needsProcessing)

        // Pretend the pipeline finished.
        try photos.setState(.embedded, id: r1.photo.id!, indexedAt: 200)

        // Re-scan, unchanged file → skip.
        var same = base; same.scanGeneration = 2
        let r2 = try photos.upsert(same)
        XCTAssertFalse(r2.needsProcessing)

        // Re-scan, file edited (mtime changed) → reprocess + state reset.
        var edited = base; edited.mtime = 150; edited.scanGeneration = 3
        let r3 = try photos.upsert(edited)
        XCTAssertTrue(r3.needsProcessing)
        XCTAssertEqual(r3.photo.state, PhotoState.discovered.rawValue)
    }

    func testMarkMissingByGeneration() throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot(db)
        let photos = PhotoRepository(db)
        try photos.upsert(Photo(rootId: root.id!, relativePath: "gone.jpg", mtime: 1, size: 1,
                                state: .embedded, scanGeneration: 1))
        let changed = try photos.markMissing(rootId: root.id!, generation: 2)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try photos.find(rootId: root.id!, relativePath: "gone.jpg")?.state,
                       PhotoState.missing.rawValue)
    }

    func testFaceInsertAssignAndFetch() throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot(db)
        let photos = PhotoRepository(db)
        let faces = FaceRepository(db)
        let people = PersonRepository(db)

        let photo = try photos.upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 1, size: 1)).photo
        let emb: [Float] = (0..<512).map { _ in 0.1 }
        let f = try faces.insert(Face(photoId: photo.id!, bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.2,
                                      embedding: emb.blob, embeddingModel: "test", embeddingDim: 512,
                                      createdAt: 10))
        XCTAssertEqual(try faces.withEmbeddings().count, 1)
        XCTAssertEqual(f.vector.count, 512)

        let person = try people.create(now: 10)
        try faces.assign(personId: person.id!, faceIds: [f.id!])
        XCTAssertEqual(try faces.forPerson(person.id!).count, 1)
    }

    func testConstraintCanonicalAndIdempotent() throws {
        let db = try AppDatabase.inMemory()
        let root = try makeRoot(db)
        let photos = PhotoRepository(db)
        let faces = FaceRepository(db)
        let photo = try photos.upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 1, size: 1)).photo
        let a = try faces.insert(Face(photoId: photo.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1, createdAt: 1))
        let b = try faces.insert(Face(photoId: photo.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1, createdAt: 1))
        let cons = ConstraintRepository(db)
        // Same pair in both orders + a duplicate must collapse to one row.
        try cons.add(faceA: a.id!, faceB: b.id!, kind: .mustLink, now: 1)
        try cons.add(faceA: b.id!, faceB: a.id!, kind: .mustLink, now: 2)
        let all = try cons.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].faceAId, min(a.id!, b.id!))
        XCTAssertEqual(all[0].faceBId, max(a.id!, b.id!))
    }
}

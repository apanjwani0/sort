import XCTest
@testable import SortKit

/// Regression tests for the review/correction bugs found in real-library testing.
final class ReviewFixTests: XCTestCase {
    private func mk() throws -> (AppDatabase, Int64) {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        return (db, root.id!)
    }
    private func addFace(_ db: AppDatabase, root: Int64, person: Int64?, _ vec: [Float]) throws -> (photo: Int64, face: Int64) {
        let p = try PhotoRepository(db).upsert(Photo(rootId: root, relativePath: "\(UUID().uuidString).jpg",
                                                     mtime: 0, size: 0)).photo
        let f = try FaceRepository(db).insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                                   embedding: vec.blob, embeddingModel: "t",
                                                   embeddingDim: vec.count, personId: person, createdAt: 0))
        return (p.id!, f.id!)
    }

    // "Same" must merge directly and STICK — the smaller group's faces move onto the larger, the
    // empty person is removed, and there's exactly one person left (no re-split).
    func testConfirmSameMergesAndSticks() throws {
        let (db, root) = try mk()
        let persons = PersonRepository(db)
        let a = try persons.create(now: 0).id!, b = try persons.create(now: 0).id!
        _ = try addFace(db, root: root, person: a, [1, 0, 0, 0])
        _ = try addFace(db, root: root, person: a, [1, 0.01, 0, 0])   // A has 2
        _ = try addFace(db, root: root, person: b, [1, 0.02, 0, 0])   // B has 1
        try persons.recomputeFaceCounts()

        try ReviewService(db: db).confirmSame(persons.find(a)!, persons.find(b)!, now: 1)

        XCTAssertNil(try persons.find(b))                       // B absorbed + removed
        XCTAssertEqual(try FaceRepository(db).forPerson(a).count, 3)
        XCTAssertEqual(try persons.all().count, 1)
    }

    // "Remove from this group" must detach ALL selected photos (the bug removed 2 of 3) and clear a
    // cover that pointed at a removed photo.
    func testMarkNotPersonDetachesAllAndFixesCover() throws {
        let (db, root) = try mk()
        let persons = PersonRepository(db)
        let faceRepo = FaceRepository(db)
        let p = try persons.create(now: 0).id!
        var faceOfPhoto: [Int64: Int64] = [:], photos: [Int64] = []
        for _ in 0..<4 {                                        // 4 identical faces → would re-merge under the old path
            let (photo, face) = try addFace(db, root: root, person: p, [1, 0, 0, 0])
            faceOfPhoto[photo] = face; photos.append(photo)
        }
        try persons.recomputeFaceCounts()
        let detach = Array(photos.prefix(3))
        try persons.setCoverFace(p, faceId: faceOfPhoto[detach[0]], now: 0)   // cover is a detached photo

        let removed = try IndexService(db: db).markNotPerson(photoIds: detach, personId: p, now: 1)

        XCTAssertEqual(removed, 3)                              // all three, not two
        XCTAssertEqual(try faceRepo.forPerson(p).count, 1)     // only the kept one remains
        for ph in detach { XCTAssertNotEqual(try faceRepo.find(faceOfPhoto[ph]!)!.personId, p) }
        XCTAssertNil(try persons.find(p)!.coverFaceId)         // stale cover cleared
    }
}

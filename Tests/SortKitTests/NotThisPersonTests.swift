import XCTest
@testable import SortKit

final class NotThisPersonTests: XCTestCase {
    func testMarkNotPersonDetachesAndPersistsAcrossRescan() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let faces = FaceRepository(db)

        func addFace(_ rel: String, _ v: [Float]) throws -> (photo: Int64, face: Int64) {
            let p = try photos.upsert(Photo(rootId: root.id!, relativePath: rel, mtime: 0, size: 1)).photo
            let f = try faces.insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                          embedding: v.blob, embeddingModel: "t", embeddingDim: 4, createdAt: 0))
            return (p.id!, f.id!)
        }
        // Three near-identical faces → cluster into one person.
        let a = try addFace("a.jpg", [1, 0, 0, 0])
        _ = try addFace("b.jpg", [0.99, 0.02, 0, 0])
        let c = try addFace("c.jpg", [0.98, 0.03, 0, 0])

        let index = IndexService(db: db)
        try ClusteringService(db: db).recluster(now: 1)
        XCTAssertEqual(try PersonRepository(db).all().count, 1)
        let personA = try XCTUnwrap(faces.find(a.face)?.personId)
        XCTAssertEqual(faces.personId(of: c.face), personA)   // c started with a

        // "Not this person" for photo c → it must leave a's group and stay out.
        let moved = try index.markNotPerson(photoIds: [c.photo], personId: personA, now: 2)
        XCTAssertEqual(moved, 1)
        XCTAssertNotEqual(faces.personId(of: c.face), faces.personId(of: a.face))

        // Persists: a fresh re-cluster keeps them apart (the correction was learned).
        try ClusteringService(db: db).recluster(now: 3)
        XCTAssertNotEqual(faces.personId(of: c.face), faces.personId(of: a.face))
        XCTAssertEqual(try index.learnedCorrections(), 1)
    }
}

private extension FaceRepository {
    func personId(of id: Int64) -> Int64? { ((try? find(id)) ?? nil)?.personId }
}

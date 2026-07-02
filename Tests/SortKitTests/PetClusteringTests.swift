import XCTest
@testable import SortKit

/// Pets cluster in their own namespace: even with byte-identical embeddings, a "pet" face must never
/// land in the same person as a "human" face. Guards the per-kind clustering split.
final class PetClusteringTests: XCTestCase {
    func testPetsAndHumansNeverShareAPerson() throws {
        let db = try AppDatabase.inMemory()
        let photos = PhotoRepository(db), faces = FaceRepository(db), persons = PersonRepository(db)
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)

        func addFace(_ rel: String, kind: String?) throws {
            let p = try photos.upsert(Photo(rootId: root.id!, relativePath: rel, mtime: 1, size: 1)).photo
            let vec: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]   // identical across all faces on purpose
            _ = try faces.insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                      embedding: vec.blob, embeddingModel: "m", embeddingDim: vec.count,
                                      kind: kind, createdAt: 0))
        }
        try addFace("h1.jpg", kind: nil); try addFace("h2.jpg", kind: nil)        // humans
        try addFace("p1.jpg", kind: "pet"); try addFace("p2.jpg", kind: "pet")    // pets

        _ = try ClusteringService(db: db).recluster(now: 1)

        let all = try persons.all()
        XCTAssertEqual(all.count, 2, "identical vectors still split by kind → one human person, one pet person")
        XCTAssertEqual(all.filter { $0.kind == "pet" }.count, 1)
        XCTAssertEqual(all.filter { $0.kind == nil }.count, 1)
        XCTAssertTrue(all.allSatisfy { $0.faceCount == 2 })
    }
}

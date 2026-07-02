import XCTest
@testable import SortKit

/// The incremental scan-clustering path: new faces attach to the nearest existing person, leftovers
/// form new people, and already-assigned faces never move.
final class IncrementalClusterTests: XCTestCase {
    private func a(_ j: Float = 0) -> [Float] { [1, j, 0, 0, 0, 0, 0, 0] }
    private func b(_ j: Float = 0) -> [Float] { [0, 1, j, 0, 0, 0, 0, 0] }

    func testIncrementalAttachesAndCreates() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photoRepo = PhotoRepository(db)
        let faceRepo = FaceRepository(db)
        func addFace(_ vec: [Float]) throws -> Int64 {
            let p = try photoRepo.upsert(Photo(rootId: root.id!, relativePath: "\(UUID().uuidString).jpg",
                                               mtime: 0, size: 0)).photo
            return try faceRepo.insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                            embedding: vec.blob, embeddingModel: "t",
                                            embeddingDim: vec.count, createdAt: 0)).id!
        }

        // Establish person A via a full recluster.
        _ = try addFace(a(0)); _ = try addFace(a(0.02))
        let svc = ClusteringService(db: db)   // default human threshold 0.4
        _ = try svc.recluster(now: 1)
        let aPersonId = try PersonRepository(db).all().first!.id!

        // New faces arrive unclustered: one near A, two of a new identity B.
        let near = try addFace(a(0.01))
        let b1 = try addFace(b(0)); let b2 = try addFace(b(0.01))

        // Force the incremental path (limit 0 ⇒ never full-recluster).
        let report = try svc.clusterAfterScan(now: 2, fullReclusterLimit: 0)

        XCTAssertEqual(report.people, 2)                                   // A + new B
        XCTAssertEqual(try faceRepo.find(near)!.personId, aPersonId)       // near face joined existing A
        let bp1 = try faceRepo.find(b1)!.personId
        XCTAssertNotNil(bp1)
        XCTAssertEqual(bp1, try faceRepo.find(b2)!.personId)              // B faces grouped together
        XCTAssertNotEqual(bp1, aPersonId)                                  // …as a NEW person
    }

    // A new face near-equidistant from two distinct people must NOT be grabbed by either — it falls
    // through to its own group (the confident-match gate; over-split is one-tap-fixable, B4/D4).
    func testAmbiguousFaceDoesNotAttachToEitherLookAlike() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photoRepo = PhotoRepository(db)
        let faceRepo = FaceRepository(db)
        func addFace(_ vec: [Float]) throws -> Int64 {
            let p = try photoRepo.upsert(Photo(rootId: root.id!, relativePath: "\(UUID().uuidString).jpg",
                                               mtime: 0, size: 0)).photo
            return try faceRepo.insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                            embedding: vec.blob, embeddingModel: "t",
                                            embeddingDim: vec.count, createdAt: 0)).id!
        }
        // Person P at 0°, person Q at 60° (centroid distance 0.5 > 0.4 ⇒ stay separate).
        let p0 = try addFace([1, 0, 0, 0, 0, 0, 0, 0]); _ = try addFace([0.999, 0.045, 0, 0, 0, 0, 0, 0])
        let q0 = try addFace([0.5, 0.866, 0, 0, 0, 0, 0, 0]); _ = try addFace([0.52, 0.854, 0, 0, 0, 0, 0, 0])
        let svc = ClusteringService(db: db)   // default threshold 0.4
        _ = try svc.recluster(now: 1)
        let pPerson = try faceRepo.find(p0)!.personId
        let qPerson = try faceRepo.find(q0)!.personId
        XCTAssertNotEqual(pPerson, qPerson)

        // New face at 30°: 0.134 from both ⇒ gap ≈ 0 < margin ⇒ must not join P or Q.
        let mid = try addFace([0.866, 0.5, 0, 0, 0, 0, 0, 0])
        _ = try svc.clusterAfterScan(now: 2, fullReclusterLimit: 0)
        let midPerson = try faceRepo.find(mid)!.personId
        XCTAssertNotNil(midPerson)
        XCTAssertNotEqual(midPerson, pPerson)
        XCTAssertNotEqual(midPerson, qPerson)
    }

    // A small/first library must still take the full path (identical quality, byte-for-byte behavior).
    func testSmallLibraryUsesFullRecluster() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photoRepo = PhotoRepository(db)
        let faceRepo = FaceRepository(db)
        for v in [a(0), a(0.02), b(0)] {
            let p = try photoRepo.upsert(Photo(rootId: root.id!, relativePath: "\(UUID().uuidString).jpg",
                                               mtime: 0, size: 0)).photo
            _ = try faceRepo.insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                         embedding: v.blob, embeddingModel: "t", embeddingDim: v.count, createdAt: 0))
        }
        // Default limit 2000 ≫ 3 faces ⇒ full recluster ⇒ A and B separated.
        let report = try ClusteringService(db: db).clusterAfterScan(now: 1)
        XCTAssertEqual(report.people, 2)
    }
}

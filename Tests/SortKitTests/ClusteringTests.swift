import XCTest
@testable import SortKit

final class ClusteringTests: XCTestCase {
    // Three well-separated synthetic identities in 8-d space.
    private func a(_ jitter: Float = 0) -> [Float] { [1, jitter, 0, 0, 0, 0, 0, 0] }
    private func b(_ jitter: Float = 0) -> [Float] { [0, 1, jitter, 0, 0, 0, 0, 0] }
    private func c(_ jitter: Float = 0) -> [Float] { [0, 0, 1, jitter, 0, 0, 0, 0] }

    // MARK: - Pure algorithm

    func testSeparatesThreeIdentities() {
        let vectors = [a(0), a(0.02), b(0), b(0.01), c(0), c(0.03)]
        let labels = AgglomerativeClustering.cluster(vectors: vectors, threshold: 0.4)
        XCTAssertEqual(labels[0], labels[1])           // a's together
        XCTAssertEqual(labels[2], labels[3])           // b's together
        XCTAssertEqual(labels[4], labels[5])           // c's together
        XCTAssertEqual(Set(labels).count, 3)           // exactly three people
    }

    func testCannotLinkKeepsClosePairApart() {
        let vectors = [a(0), a(0.01)]                  // nearly identical → would merge
        let labels = AgglomerativeClustering.cluster(
            vectors: vectors, threshold: 0.4,
            constraints: .init(cannotLink: [(0, 1)]))
        XCTAssertNotEqual(labels[0], labels[1])
    }

    func testMustLinkMergesFarPair() {
        let vectors = [a(0), b(0)]                      // far apart → would split
        let labels = AgglomerativeClustering.cluster(
            vectors: vectors, threshold: 0.4,
            constraints: .init(mustLink: [(0, 1)]))
        XCTAssertEqual(labels[0], labels[1])
    }

    // MARK: - DB-integrated service

    private func makeFixture() throws -> (AppDatabase, Int64) {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 0, size: 0)).photo
        return (db, photo.id!)
    }

    @discardableResult
    private func addFace(_ db: AppDatabase, photo: Int64, _ vec: [Float]) throws -> Face {
        try FaceRepository(db).insert(Face(photoId: photo, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                           embedding: vec.blob, embeddingModel: "t",
                                           embeddingDim: vec.count, createdAt: 0))
    }

    func testReclusterAssignsPeopleAndFaceCounts() throws {
        let (db, photo) = try makeFixture()
        try addFace(db, photo: photo, a(0))
        try addFace(db, photo: photo, a(0.02))
        try addFace(db, photo: photo, b(0))

        let report = try ClusteringService(db: db).recluster(now: 1)
        XCTAssertEqual(report.faces, 3)
        XCTAssertEqual(report.people, 2)

        let people = try PersonRepository(db).all()
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(Set(people.map(\.faceCount)), [2, 1])
        XCTAssertTrue(people.allSatisfy { $0.centroid != nil })
    }

    func testMinGroupDropsSmallClusters() throws {
        let (db, photo) = try makeFixture()
        try addFace(db, photo: photo, a(0))
        try addFace(db, photo: photo, a(0.02))   // a-cluster has 2 faces
        try addFace(db, photo: photo, b(0))      // b-cluster has 1 face → dropped at minGroup 2

        let report = try ClusteringService(db: db, config: .init(minGroup: 2)).recluster(now: 1)
        XCTAssertEqual(report.faces, 3)
        XCTAssertEqual(report.people, 1)         // only the 2-face cluster becomes a person

        let people = try PersonRepository(db).all()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.faceCount, 2)
    }

    func testStableIDsAndNamePreservedAcrossRescan() throws {
        let (db, photo) = try makeFixture()
        let faces = FaceRepository(db)
        let persons = PersonRepository(db)
        let service = ClusteringService(db: db)

        let a1 = try addFace(db, photo: photo, a(0))
        try addFace(db, photo: photo, a(0.02))
        try addFace(db, photo: photo, b(0))

        try service.recluster(now: 1)

        // The person owning a1, named by the user.
        let aPersonId = try faces.all().first { $0.id == a1.id }!.personId!
        try persons.rename(aPersonId, to: "Alice", now: 2)

        // A new photo of the same person arrives; re-cluster.
        try addFace(db, photo: photo, a(0.03))
        try service.recluster(now: 3)

        let a1After = try faces.all().first { $0.id == a1.id }!
        XCTAssertEqual(a1After.personId, aPersonId, "person id must stay stable across rescans")
        XCTAssertEqual(try persons.find(aPersonId)?.displayName, "Alice", "name must survive re-clustering")
        XCTAssertEqual(try persons.find(aPersonId)?.faceCount, 3)
        XCTAssertEqual(try persons.all().count, 2, "no spurious new people")
    }

    func testMarkDifferentSplitsAcrossRescan() throws {
        let (db, photo) = try makeFixture()
        let faces = FaceRepository(db)
        let service = ClusteringService(db: db)

        let f1 = try addFace(db, photo: photo, a(0))
        let f2 = try addFace(db, photo: photo, a(0.01))   // would cluster with f1
        try service.recluster(now: 1)
        XCTAssertEqual(try PersonRepository(db).all().count, 1)

        // User says "Different" → must split on next cluster.
        try service.markDifferent(faceA: f1.id!, faceB: f2.id!, now: 2)
        try service.recluster(now: 3)

        let p1 = try faces.all().first { $0.id == f1.id }!.personId
        let p2 = try faces.all().first { $0.id == f2.id }!.personId
        XCTAssertNotEqual(p1, p2)
        XCTAssertEqual(try PersonRepository(db).all().count, 2)
    }
}

import XCTest
@testable import SortKit

final class ReviewTests: XCTestCase {
    func testSuggestMergesReturnsOnlyCloseCentroidPairs() throws {
        let db = try AppDatabase.inMemory()
        let pr = PersonRepository(db)

        let a = try pr.create(now: 0)
        try pr.updateCentroid(a.id!, centroid: ([1, 0, 0, 0] as [Float]).blob, now: 0)
        let b = try pr.create(now: 0)
        try pr.updateCentroid(b.id!, centroid: ([0.96, 0.1, 0, 0] as [Float]).blob, now: 0)  // ~same as a
        let c = try pr.create(now: 0)
        try pr.updateCentroid(c.id!, centroid: ([0, 1, 0, 0] as [Float]).blob, now: 0)        // far

        let suggestions = try ReviewService(db: db).suggestMerges(maxDistance: 0.2)
        XCTAssertEqual(suggestions.count, 1)
        let pair = Set([suggestions[0].personA.id, suggestions[0].personB.id])
        XCTAssertEqual(pair, Set([a.id, b.id]))
        XCTAssertLessThan(suggestions[0].distance, 0.2)
    }

    func testConfirmSameMergesTwoPeople() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 0, size: 0)).photo
        let faces = FaceRepository(db)
        func add(_ v: [Float]) throws -> Face {
            try faces.insert(Face(photoId: photo.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                  embedding: v.blob, embeddingModel: "t", embeddingDim: v.count, createdAt: 0))
        }
        _ = try add([1, 0, 0, 0])
        _ = try add([0, 1, 0, 0])   // far apart → two separate people

        try ClusteringService(db: db).recluster(now: 1)
        let people = try PersonRepository(db).all()
        XCTAssertEqual(people.count, 2)

        // User confirms they are the same → must-link + re-cluster collapses to one person.
        try ReviewService(db: db).confirmSame(people[0], people[1], now: 2)
        XCTAssertEqual(try PersonRepository(db).all().count, 1)
    }

    func testConfirmDifferentRemovesPairFromSuggestions() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 0, size: 0)).photo
        let faces = FaceRepository(db)
        let persons = PersonRepository(db)

        // Two separate people with near-identical centroids → suggested as a possible merge.
        func makePerson(_ v: [Float]) throws {
            let p = try persons.create(now: 0)
            _ = try faces.insert(Face(photoId: photo.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                      embedding: v.blob, embeddingModel: "t", embeddingDim: v.count,
                                      personId: p.id, createdAt: 0))
            try persons.updateCentroid(p.id!, centroid: v.blob, now: 0)
        }
        try makePerson([1, 0, 0, 0])
        try makePerson([0.96, 0.1, 0, 0])

        let review = ReviewService(db: db)
        XCTAssertEqual(try review.suggestMerges(maxDistance: 0.2).count, 1)

        // "Different" → the pair must drop out of the queue (the #5 bug: it used to re-suggest).
        let people = try persons.all()
        try review.confirmDifferent(people[0], people[1], now: 1)
        XCTAssertEqual(try review.suggestMerges(maxDistance: 0.2).count, 0)
    }
}

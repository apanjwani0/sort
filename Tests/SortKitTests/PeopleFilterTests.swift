import XCTest
@testable import SortKit

/// Multi-person filter: photos containing ALL selected people (AND), and the "only them" variant.
final class PeopleFilterTests: XCTestCase {
    func testIntersectionAndOnlyThem() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let faces = FaceRepository(db)
        let persons = PersonRepository(db)
        let a = try persons.create(now: 0).id!
        let b = try persons.create(now: 0).id!
        let c = try persons.create(now: 0).id!

        func photo(_ name: String, _ people: [Int64]) throws -> Int64 {
            let p = try photos.upsert(Photo(rootId: root.id!, relativePath: name, mtime: 0, size: 0)).photo
            for pid in people {
                _ = try faces.insert(Face(photoId: p.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                          personId: pid, createdAt: 0))
            }
            return p.id!
        }
        let ab = try photo("ab.jpg", [a, b])        // a + b only
        let abc = try photo("abc.jpg", [a, b, c])   // a + b + c
        _ = try photo("a.jpg", [a])                 // a only

        let index = IndexService(db: db)
        // AND-intersection: photos with both a and b → ab.jpg and abc.jpg.
        XCTAssertEqual(Set(try index.photos(forPeople: [a, b], exclusive: false).compactMap(\.id)), [ab, abc])
        // "Only them": exactly a and b, no other known person → ab.jpg only (abc has c).
        XCTAssertEqual(try index.photos(forPeople: [a, b], exclusive: true).compactMap(\.id), [ab])
        // A single id still works (degenerates to "that person's photos").
        XCTAssertEqual(Set(try index.photos(forPeople: [c], exclusive: false).compactMap(\.id)), [abc])
        // Empty selection → nothing.
        XCTAssertTrue(try index.photos(forPeople: [], exclusive: false).isEmpty)
    }
}

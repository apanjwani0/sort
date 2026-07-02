import XCTest
@testable import SortKit

final class RemoveRootTests: XCTestCase {
    func testRemoveRootDropsPhotosFacesAndEmptyPeople() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "a.jpg", mtime: 0, size: 1)).photo
        let person = try PersonRepository(db).create(now: 0)
        _ = try FaceRepository(db).insert(Face(photoId: photo.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                               personId: person.id, createdAt: 0))

        let removed = try IndexService(db: db).removeRoot(root.id!, now: 1)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try PhotoRepository(db).all().count, 0)
        XCTAssertEqual(try FaceRepository(db).all().count, 0, "faces should cascade with the photos")
        XCTAssertEqual(try RootRepository(db).all().count, 0)
        XCTAssertNil(try PersonRepository(db).find(person.id!), "person with no faces should be pruned")
    }
}

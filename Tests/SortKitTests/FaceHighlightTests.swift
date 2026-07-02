import XCTest
@testable import SortKit

/// Backend for the face-highlight overlay (#6): given a photo and (optionally) a person, return the
/// faces — including normalized bounding boxes — to draw on top of the image.
final class FaceHighlightTests: XCTestCase {
    func testFacesInPhotoFilteredByPerson() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "group.jpg", mtime: 0, size: 0)).photo
        let faces = FaceRepository(db)
        let persons = PersonRepository(db)

        let p1 = try persons.create(now: 0)
        let p2 = try persons.create(now: 0)
        _ = try faces.insert(Face(photoId: photo.id!, bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.2,
                                  personId: p1.id, createdAt: 0))
        _ = try faces.insert(Face(photoId: photo.id!, bboxX: 0.6, bboxY: 0.6, bboxW: 0.2, bboxH: 0.2,
                                  personId: p2.id, createdAt: 0))

        let index = IndexService(db: db)
        XCTAssertEqual(try index.faces(inPhoto: photo.id!).count, 2)

        let onlyP1 = try index.faces(inPhoto: photo.id!, person: p1.id!)
        XCTAssertEqual(onlyP1.count, 1)
        let face = try XCTUnwrap(onlyP1.first)
        XCTAssertEqual(face.bboxX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(face.personId, p1.id)
    }
}

import XCTest
@testable import SortKit

final class CategoryTests: XCTestCase {
    func testCategoryCountsAndBrowse() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)

        let shot = try photos.upsert(Photo(rootId: root.id!, relativePath: "s.png", mtime: 0, size: 1)).photo
        try photos.setCategory("screenshot", id: shot.id!)
        let doc = try photos.upsert(Photo(rootId: root.id!, relativePath: "d.jpg", mtime: 0, size: 1)).photo
        try photos.setCategory("document", id: doc.id!)
        let place = try photos.upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 0, size: 1,
                                            gpsLat: 12.3, gpsLon: 45.6)).photo
        _ = try photos.upsert(Photo(rootId: root.id!, relativePath: "n.jpg", mtime: 0, size: 1)).photo  // no faces

        // Give the place photo a face so it is NOT counted as "no faces".
        let person = try PersonRepository(db).create(now: 0)
        _ = try FaceRepository(db).insert(Face(photoId: place.id!, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                               personId: person.id, createdAt: 0))

        let index = IndexService(db: db)
        let counts = try index.categoryCounts()
        XCTAssertEqual(counts.screenshots, 1)
        XCTAssertEqual(counts.documents, 1)
        XCTAssertEqual(counts.places, 1)
        XCTAssertEqual(counts.noFaces, 3)   // s.png, d.jpg, n.jpg
        XCTAssertEqual(counts.people, 1)

        XCTAssertEqual(try index.photos(inCategory: .screenshots).map(\.id), [shot.id])
        XCTAssertEqual(try index.photos(inCategory: .places).map(\.id), [place.id])
        XCTAssertEqual(try index.photos(inCategory: .documents).map(\.id), [doc.id])
        XCTAssertEqual(try index.photos(inCategory: .noFaces).count, 3)
    }

    func testScreenshotFilenameHeuristic() {
        XCTAssertTrue(PhotoClassifier.looksLikeScreenshot(URL(fileURLWithPath: "/x/Screenshot 2026.png")))
        XCTAssertTrue(PhotoClassifier.looksLikeScreenshot(URL(fileURLWithPath: "/x/CleanShot foo.png")))
        XCTAssertFalse(PhotoClassifier.looksLikeScreenshot(URL(fileURLWithPath: "/x/IMG_1234.jpg")))
    }

    // The classification priority that fixes "general screenshots leaking into Documents":
    // identity > screenshot > document > other.
    func testCategoryPriority() {
        typealias C = PhotoClassifier
        // A general screenshot whose full frame reads as a "document" rectangle stays a screenshot.
        XCTAssertEqual(C.category(isScreenshot: true, isDocLike: true, hasIdentity: false), "screenshot")
        // A plain screenshot.
        XCTAssertEqual(C.category(isScreenshot: true, isDocLike: false, hasIdentity: false), "screenshot")
        // An ID document wins even when it's a screenshot of one.
        XCTAssertEqual(C.category(isScreenshot: true, isDocLike: true, hasIdentity: true), "identity")
        // A photographed document (not a screenshot).
        XCTAssertEqual(C.category(isScreenshot: false, isDocLike: true, hasIdentity: false), "document")
        // A photographed ID document.
        XCTAssertEqual(C.category(isScreenshot: false, isDocLike: true, hasIdentity: true), "identity")
        // A regular photo.
        XCTAssertEqual(C.category(isScreenshot: false, isDocLike: false, hasIdentity: false), "other")
    }
}

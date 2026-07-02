import XCTest
@testable import SortKit

/// Regression tests for the scan crash + mass "No faces" fixes: failed photos must be retried, and
/// clustering must never trap on a mixed-dimension or corrupt embedding.
final class ScanRobustnessTests: XCTestCase {
    private func fixture() throws -> (AppDatabase, Int64) {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photo = try PhotoRepository(db)
            .upsert(Photo(rootId: root.id!, relativePath: "p.jpg", mtime: 0, size: 0)).photo
        return (db, photo.id!)
    }

    @discardableResult
    private func addFace(_ db: AppDatabase, photo: Int64, _ vec: [Float],
                         model: String, dim: Int) throws -> Face {
        try FaceRepository(db).insert(Face(photoId: photo, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                                           embedding: vec.blob, embeddingModel: model,
                                           embeddingDim: dim, createdAt: 0))
    }

    // A photo that failed in a prior (crashed) scan must be re-queued, not stranded forever in the
    // "No faces" bucket. Before the fix, needingProcessing() returned only .discovered.
    func testNeedingProcessingRetriesFailedPhotos() throws {
        let (db, photoId) = try fixture()
        let photos = PhotoRepository(db)
        try photos.setState(.failed, id: photoId)
        XCTAssertEqual(try photos.needingProcessing().compactMap(\.id), [photoId])
    }

    // .embedded photos are done and must NOT be reprocessed; .missing is handled by the scanner.
    func testNeedingProcessingSkipsEmbedded() throws {
        let (db, photoId) = try fixture()
        let photos = PhotoRepository(db)
        try photos.setState(.embedded, id: photoId)
        XCTAssertTrue(try photos.needingProcessing().isEmpty)
    }

    // Two human faces with DIFFERENT embedding dimensions used to precondition-trap when compared.
    // Now they're partitioned by (kind, model, dim) and cluster independently — no crash.
    func testReclusterToleratesMixedEmbeddingDimensions() throws {
        let (db, photoId) = try fixture()
        try addFace(db, photo: photoId, [Float](repeating: 0.1, count: 512), model: "arcface", dim: 512)
        try addFace(db, photo: photoId, [Float](repeating: 0.2, count: 768), model: "vision", dim: 768)
        let report = try ClusteringService(db: db).recluster(now: 1)   // must not crash
        XCTAssertEqual(report.faces, 2)
        XCTAssertEqual(report.people, 2)
    }

    // A renamed/moved file (same volumeUUID+fileID, new relativePath) must re-home the existing row —
    // keeping its id + faces — instead of inserting a fresh row and orphaning the faces (B3).
    func testRenamedFileKeepsFacesViaFileID() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let orig = try photos.upsert(Photo(rootId: root.id!, relativePath: "old/name.jpg",
                                           volumeUUID: "VOL", fileID: 42, mtime: 1, size: 100,
                                           scanGeneration: 1)).photo
        let face = try addFace(db, photo: orig.id!, [Float](repeating: 0.1, count: 8), model: "t", dim: 8)

        // Next scan (generation 2): same file, new path.
        let moved = try photos.upsert(Photo(rootId: root.id!, relativePath: "new/name.jpg",
                                            volumeUUID: "VOL", fileID: 42, mtime: 1, size: 100,
                                            scanGeneration: 2))
        XCTAssertFalse(moved.wasInserted)                       // re-homed, not inserted
        XCTAssertEqual(moved.photo.id, orig.id)                 // same row id
        XCTAssertEqual(moved.photo.relativePath, "new/name.jpg")
        XCTAssertEqual(try FaceRepository(db).find(face.id!)?.photoId, orig.id)   // face preserved
        XCTAssertEqual(try photos.all().count, 1)              // no orphan row
    }

    // A copy (same path-space but a DIFFERENT inode) must NOT collapse onto the original's row.
    func testCopyWithDifferentFileIDInsertsFresh() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        _ = try photos.upsert(Photo(rootId: root.id!, relativePath: "a.jpg", volumeUUID: "VOL",
                                    fileID: 1, mtime: 1, size: 100, scanGeneration: 1)).photo
        let copy = try photos.upsert(Photo(rootId: root.id!, relativePath: "b.jpg", volumeUUID: "VOL",
                                           fileID: 2, mtime: 1, size: 100, scanGeneration: 2))
        XCTAssertTrue(copy.wasInserted)
        XCTAssertEqual(try photos.all().count, 2)
    }

    // A corrupt/truncated embedding BLOB must be dropped, not crash clustering or poison the matrix.
    func testReclusterDropsCorruptEmbedding() throws {
        let (db, photoId) = try fixture()
        let faces = FaceRepository(db)
        try faces.insert(Face(photoId: photoId, bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
                              embedding: Data([1, 2, 3]),   // not a multiple of 4 → decodes empty
                              embeddingModel: "arcface", embeddingDim: 512, createdAt: 0))
        try addFace(db, photo: photoId, [Float](repeating: 0.1, count: 512), model: "arcface", dim: 512)
        let report = try ClusteringService(db: db).recluster(now: 1)   // must not crash
        XCTAssertEqual(report.people, 1)   // corrupt face dropped; one valid face → one person
    }

    // A hearted photo must keep its favourite across a rescan: the flag lives in a column the Photo
    // record doesn't encode, so the scan's upsert `update` must leave it untouched (F2).
    func testFavoriteSurvivesRescanUpsert() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let p = try photos.upsert(Photo(rootId: root.id!, relativePath: "p.jpg", volumeUUID: "VOL",
                                        fileID: 7, mtime: 1, size: 100, scanGeneration: 1)).photo
        try photos.setFavorite(true, id: p.id!)
        XCTAssertEqual(try photos.favoriteIDs(), [p.id!])
        XCTAssertEqual(try photos.favorites().compactMap(\.id), [p.id!])

        // Rescan (generation 2): same file, bytes changed → forces the upsert update branch.
        let again = try photos.upsert(Photo(rootId: root.id!, relativePath: "p.jpg", volumeUUID: "VOL",
                                            fileID: 7, mtime: 2, size: 200, scanGeneration: 2))
        XCTAssertFalse(again.wasInserted)
        XCTAssertEqual(try photos.favoriteIDs(), [p.id!])   // flag NOT clobbered by the rescan

        try photos.setFavorite(false, id: p.id!)
        XCTAssertTrue(try photos.favoriteIDs().isEmpty)
    }

    // A scanned video (category "video", marked terminal) is browsable in the Videos bucket but must
    // NEVER enter the face pipeline, and must NOT leak into the face-absence "No faces" bucket (F4).
    func testVideoIsBucketedAndSkipsFacePipeline() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: "/x", volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)
        let v = try photos.upsert(Photo(rootId: root.id!, relativePath: "clip.mov", mtime: 0, size: 0)).photo
        try photos.setCategory("video", id: v.id!)            // what PhotoScanner stamps for a movie file
        try photos.setState(.embedded, id: v.id!, indexedAt: 1)

        XCTAssertTrue(try photos.needingProcessing().isEmpty)                  // face pipeline skips it
        XCTAssertEqual(try photos.inCategory("video").compactMap(\.id), [v.id!])
        XCTAssertEqual(try photos.categoryCounts().videos, 1)
        XCTAssertEqual(try photos.categoryCounts().noFaces, 0)                 // not counted as "No faces"
        XCTAssertTrue(try photos.inCategory("noFaces").isEmpty)
    }
}

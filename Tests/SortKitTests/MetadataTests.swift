import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SortKit

/// Covers the EXIF GPS/date extraction that powers the Places category and date sorting. Builds a
/// real GPS-tagged JPEG with ImageIO (no external tooling), so it exercises the actual read path.
final class MetadataTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sort-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func writeJPEG(_ name: String, gps: [CFString: Any]? = nil, exif: [CFString: Any]? = nil) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let image = TestImage.make(width: 64, height: 48, rgb: (0.5, 0.5, 0.5))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let gps { props[kCGImagePropertyGPSDictionary] = gps }
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testExtractsSignedGPSAndCaptureDate() throws {
        let url = try writeJPEG("geo.jpg",
            gps: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "S",
                  kCGImagePropertyGPSLongitude: 77.25, kCGImagePropertyGPSLongitudeRef: "W"],
            exif: [kCGImagePropertyExifDateTimeOriginal: "2021:07:15 10:30:00"])

        let m = ImageLoader.metadata(url)
        // S/W refs must flip the sign; N/E stay positive.
        XCTAssertEqual(m.gpsLat ?? 0, -12.5, accuracy: 1e-4)
        XCTAssertEqual(m.gpsLon ?? 0, -77.25, accuracy: 1e-4)
        XCTAssertNotNil(m.takenAt)
        XCTAssertEqual(m.width, 64)
        XCTAssertEqual(m.height, 48)
    }

    func testNoGPSReturnsNil() throws {
        let m = ImageLoader.metadata(try writeJPEG("plain.jpg"))
        XCTAssertNil(m.gpsLat)
        XCTAssertNil(m.gpsLon)
    }

    /// A photo with GPS lands in Places (count + listing); one without does not.
    func testPlacesCategoryReflectsStoredGPS() throws {
        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: tmp.path, volumeUUID: nil, bookmark: nil, now: 0)
        let photos = PhotoRepository(db)

        let geo = try photos.upsert(Photo(rootId: root.id!, relativePath: "geo.jpg", mtime: 1, size: 1)).photo
        _ = try photos.upsert(Photo(rootId: root.id!, relativePath: "plain.jpg", mtime: 1, size: 1))

        try photos.setMetadata(id: geo.id!, ImageLoader.Metadata(takenAt: nil, gpsLat: -12.5, gpsLon: -77.25,
                                                                 width: nil, height: nil))

        XCTAssertEqual(try photos.categoryCounts().places, 1)
        XCTAssertEqual(try photos.inCategory("places").map(\.relativePath), ["geo.jpg"])

        // COALESCE: a later metadata read with no GPS must not wipe the stored coordinates.
        try photos.setMetadata(id: geo.id!, ImageLoader.Metadata())
        XCTAssertEqual(try photos.categoryCounts().places, 1)
    }
}

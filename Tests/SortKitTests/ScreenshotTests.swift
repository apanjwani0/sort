import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SortKit

/// Mobile-screenshot detection: a phone-aspect image with no camera metadata is a screenshot, the
/// same shape WITH camera metadata is a real photo, and a filename marker always wins.
final class ScreenshotTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sort-ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func writeJPEG(_ name: String, w: Int, h: Int, camera: Bool) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let img = TestImage.make(width: w, height: h, rgb: (0.5, 0.5, 0.5))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if camera { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "TestCam"] }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testPhoneAspectNoCameraIsScreenshot() throws {
        let url = try writeJPEG("xyz_001.jpg", w: 108, h: 234, camera: false)   // ~2.17 portrait
        XCTAssertTrue(PhotoClassifier.looksLikeScreenshot(url))
    }

    func testPhoneAspectWithCameraIsNotScreenshot() throws {
        let url = try writeJPEG("xyz_002.jpg", w: 108, h: 234, camera: true)
        XCTAssertFalse(PhotoClassifier.looksLikeScreenshot(url))
    }

    func testFilenameMarkerWins() throws {
        let url = try writeJPEG("Screenshot_20240101.jpg", w: 100, h: 100, camera: true)
        XCTAssertTrue(PhotoClassifier.looksLikeScreenshot(url))
    }
}

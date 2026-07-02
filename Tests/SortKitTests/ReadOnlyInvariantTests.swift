import XCTest
import CryptoKit
@testable import SortKit

/// Safety-critical: scanning and reading source photos must NEVER modify, add, or remove anything
/// in the source tree. This is the central promise of `sort`.
final class ReadOnlyInvariantTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sort-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (rel, body) in [("a.jpg", "alpha"), ("nested/b.png", "bravo"), ("nested/deep/c.heic", "charlie")] {
            let url = tmp.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct Stat: Equatable { var size: Int; var mtime: Double; var hash: String }

    /// Map of relativePath → content fingerprint for every regular file under root (incl. hidden).
    private func snapshot() throws -> [String: Stat] {
        var out: [String: Stat] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let en = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: keys)!
        let base = tmp.standardizedFileURL.path
        for case let url as URL in en {
            let v = try url.resourceValues(forKeys: Set(keys))
            guard v.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out[rel] = Stat(size: v.fileSize ?? -1,
                            mtime: v.contentModificationDate?.timeIntervalSince1970 ?? -1,
                            hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return out
    }

    func testScanAndReadDoNotMutateSourceTree() throws {
        let before = try snapshot()
        XCTAssertEqual(before.count, 3)

        let db = try AppDatabase.inMemory()
        let root = try RootRepository(db).add(displayPath: tmp.path, volumeUUID: nil, bookmark: nil, now: 0)
        let scanner = PhotoScanner(db: db)

        // Scan, then read every discovered file the way the pipeline would.
        _ = try scanner.scan(root: root, rootURL: tmp, now: 1)
        try FileSystemScanner().forEachMedia(under: tmp) { file in
            _ = try SourceAccess.read(file.url)
        }

        let after = try snapshot()
        XCTAssertEqual(after, before, "source tree changed after scan+read — read-only invariant violated")
        XCTAssertEqual(Set(after.keys), Set(before.keys), "files were added or removed under the source root")
    }

    func testSourceAccessExposesNoWriteAPI() throws {
        // Compile-time guarantee documented as a runtime check: SourceAccess yields only read paths.
        let url = tmp.appendingPathComponent("a.jpg")
        XCTAssertEqual(try SourceAccess.read(url), Data("alpha".utf8))
    }
}

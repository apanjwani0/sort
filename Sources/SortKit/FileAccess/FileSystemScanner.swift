import Foundation
import UniformTypeIdentifiers

/// A single media file discovered on disk (no contents read yet).
public struct ScannedFile: Sendable, Equatable {
    public var url: URL
    public var relativePath: String
    public var volumeUUID: String?
    public var fileID: Int64?
    public var mtime: Double
    public var size: Int64
    public var isVideo: Bool = false   // a movie file — indexed for browsing, never face-processed (F4)
}

/// Concrete read-only filesystem scanner backed by `FileManager`.
public struct FileSystemScanner: Sendable {
    public init() {}

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
        .contentModificationDateKey, .contentTypeKey, .volumeUUIDStringKey,
    ]

    public func forEachMedia(under root: URL, _ body: (ScannedFile) throws -> Void) throws {
        let rootPath = root.standardizedFileURL.path
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root.standardizedFileURL,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.notEnumerable(root)
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Self.resourceKeys)
            guard values.isRegularFile == true else { continue }
            guard let type = values.contentType else { continue }
            let isVideo: Bool
            if type.conforms(to: .image) { isVideo = false }
            else if type.conforms(to: .movie) { isVideo = true }   // .mov/.mp4/.m4v
            else { continue }

            let full = url.standardizedFileURL.path
            let relativePath = full.hasPrefix(rootPath + "/")
                ? String(full.dropFirst(rootPath.count + 1))
                : url.lastPathComponent

            // inode for future move detection; cheap extra stat, fine for v1.
            var fileID: Int64?
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let ino = attrs[.systemFileNumber] as? Int {
                fileID = Int64(ino)
            }

            let file = ScannedFile(
                url: url,
                relativePath: relativePath,
                volumeUUID: values.volumeUUIDStringValue,
                fileID: fileID,
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: Int64(values.fileSize ?? 0),
                isVideo: isVideo
            )
            try body(file)
        }
    }
}

public enum ScanError: Error, CustomStringConvertible {
    case notEnumerable(URL)
    case notADirectory(URL)

    public var description: String {
        switch self {
        case .notEnumerable(let u): return "Cannot enumerate \(u.path)"
        case .notADirectory(let u): return "Not a directory: \(u.path)"
        }
    }
}

private extension URLResourceValues {
    /// `URLResourceValues` has no typed property for the volume UUID; read it from the bag.
    var volumeUUIDStringValue: String? {
        allValues[.volumeUUIDStringKey] as? String
    }
}

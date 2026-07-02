import Foundation

/// Tally of one scan pass.
public struct ScanReport: Sendable, Equatable {
    public var discovered = 0   // brand-new files
    public var changed = 0      // existing files whose bytes changed (mtime/size)
    public var unchanged = 0    // existing files skipped (incremental win)
    public var missing = 0      // previously-indexed files no longer present
    public var videos = 0       // of the files seen, how many are videos (F4)
    public var generation = 0
}

/// Orchestrates a read-only recursive scan into the index, doing incremental diffing so re-opening
/// a known folder is fast (only new/changed files are surfaced for processing).
public struct PhotoScanner {
    let photos: PhotoRepository
    let roots: RootRepository
    private let fs = FileSystemScanner()

    public init(db: AppDatabase) {
        self.photos = PhotoRepository(db)
        self.roots = RootRepository(db)
    }

    /// Scan `rootURL` for `root`. `progress` is called periodically with the running counts
    /// (total media seen, of which are videos).
    @discardableResult
    public func scan(root: ScannedRoot, rootURL: URL, now: Double,
                     progress: ((Int, Int) -> Void)? = nil) throws -> ScanReport {
        guard let rootId = root.id else { throw ScanError.notADirectory(rootURL) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError.notADirectory(rootURL)
        }

        let generation = root.scanGeneration + 1
        var report = ScanReport()
        report.generation = generation
        var seen = 0
        var videos = 0

        try fs.forEachMedia(under: rootURL) { file in
            let incoming = Photo(
                rootId: rootId,
                relativePath: file.relativePath,
                volumeUUID: file.volumeUUID,
                fileID: file.fileID,
                mtime: file.mtime,
                size: file.size,
                state: .discovered,
                scanGeneration: generation
            )
            let result = try photos.upsert(incoming)
            if file.isVideo {
                videos += 1
                report.videos += 1
                if result.needsProcessing, let id = result.photo.id {
                    // Index videos for the Collections "Videos" bucket, but never run the face pipeline
                    // on them: tag the category + mark terminal so needingProcessing() skips them (F4).
                    try photos.setCategory("video", id: id)
                    try photos.setState(.embedded, id: id, indexedAt: now)
                }
            }
            if result.wasInserted {
                report.discovered += 1
            } else if result.bytesChanged {
                report.changed += 1
            } else {
                report.unchanged += 1
            }
            seen += 1
            if seen % 200 == 0 { progress?(seen, videos) }
        }

        report.missing = try photos.markMissing(rootId: rootId, generation: generation)
        progress?(seen, videos)

        var updated = root
        updated.scanGeneration = generation
        updated.lastScannedAt = now
        try roots.update(updated)

        return report
    }
}

import Foundation

/// High-level façade over the whole engine: scan → detect → embed → persist → cluster, plus the
/// browse queries. Both the `sort` CLI and the macOS GUI drive this one type so behavior is identical.
public struct IndexService: Sendable {
    let db: AppDatabase
    let roots: RootRepository
    let photos: PhotoRepository
    let faces: FaceRepository
    let persons: PersonRepository

    public init(db: AppDatabase) {
        self.db = db
        self.roots = RootRepository(db)
        self.photos = PhotoRepository(db)
        self.faces = FaceRepository(db)
        self.persons = PersonRepository(db)
    }

    /// Register (or fetch) a scanned root by path. The security-scoped bookmark is created by the GUI
    /// from the NSOpenPanel grant (sandbox) and persisted there; the CLI runs unsandboxed by path, so
    /// this never creates/overwrites a bookmark (passing nil preserves any existing one).
    @discardableResult
    public func ensureRoot(path: String, now: Double) throws -> ScannedRoot {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return try roots.add(displayPath: url.path, volumeUUID: nil, bookmark: nil, now: now)
    }

    public struct IndexReport: Sendable {
        public var scan = ScanReport()
        public var photosProcessed = 0
        public var facesAdded = 0
        public var failures = 0
        public var recluster = ReclusterReport()
    }

    public struct Progress: Sendable {
        public enum Phase: String, Sendable { case scanning, processing, classifying, clustering }
        public var phase: Phase
        public var done: Int
        public var total: Int
        public var videos = 0   // scanning phase: how many of `done` are videos (F4)
    }

    /// Full incremental index pass over `rootPath`.
    @discardableResult
    public func index(rootPath: String,
                      embedder: FaceEmbedder = VisionFeaturePrintEmbedder(),
                      classifier: PhotoClassifier = PhotoClassifier(),
                      clustering: ClusteringConfig = .init(),
                      pipeline: FacePipeline? = nil,
                      now: Double,
                      onProgress: ((Progress) -> Void)? = nil) throws -> IndexReport {
        let url = URL(fileURLWithPath: rootPath).standardizedFileURL
        var report = IndexReport()

        let root = try ensureRoot(path: url.path, now: now)
        let scanner = PhotoScanner(db: db)
        report.scan = try scanner.scan(root: root, rootURL: url, now: now) { seen, videos in
            onProgress?(.init(phase: .scanning, done: seen, total: seen, videos: videos))
        }

        let pending = try photos.needingProcessing()
        let pipe = pipeline ?? FacePipeline(embedder: embedder)
        let petPipe = PetPipeline()   // detect + embed individual pet faces (separate namespace)
        // Detect + embed each photo concurrently across cores — independent work, and Vision/Core ML
        // are thread-safe. DB writes go through GRDB's serialized writer, so concurrent inserts are
        // safe. This is the main scan speedup on large libraries.
        let progress = ScanProgress(total: pending.count, sink: onProgress)
        DispatchQueue.concurrentPerform(iterations: pending.count) { i in
            // Each iteration is wrapped in autoreleasepool: a worker thread runs many iterations back
            // to back, and without an explicit pool the autoreleased CGImage/CVPixelBuffer/Vision
            // allocations don't drain until the whole pass ends — peak memory grows unbounded across a
            // large scan and OOM-crashes the app (the ~500-of-1600 crash). The pool caps live memory to
            // roughly core-count photos.
            autoreleasepool {
                let photo = pending[i]
                guard let photoId = photo.id else { return }
                let fileURL = url.appendingPathComponent(photo.relativePath)
                do {
                    // Read + decode the file ONCE and reuse it for face detect, pet detect, classify,
                    // metadata and dHash. Previously each photo was read/decoded ~3–4× (the main
                    // per-photo CPU/I/O cost on big libraries).
                    let source = try ImageLoader.source(for: fileURL)
                    let image = try ImageLoader.decode(source, maxPixelSize: pipe.detectMaxPixel)

                    let results = try pipe.process(image: image)
                    // ponytail: these per-photo writes aren't one transaction, so a mid-photo throw can
                    // leave a partial face set — but the catch marks the photo .failed and the next scan
                    // reprocesses it from scratch (deleteForPhoto is idempotent), so it self-heals. Wrap
                    // in a single db.writer.write only if a partial-state window ever actually bites.
                    try faces.deleteForPhoto(photoId)   // idempotent re-process
                    for r in results {
                        let bb = r.face.boundingBox
                        _ = try faces.insert(Face(
                            photoId: photoId,
                            bboxX: Double(bb.minX), bboxY: Double(bb.minY),
                            bboxW: Double(bb.width), bboxH: Double(bb.height),
                            roll: r.face.roll, yaw: r.face.yaw, pitch: r.face.pitch,
                            quality: r.face.quality.map(Double.init),
                            embedding: r.embedding.blob,
                            embeddingModel: embedder.modelIdentifier,
                            embeddingDim: r.embedding.count,
                            createdAt: now))
                    }
                    try? photos.setCategory(
                        classifier.classify(image: image, source: source,
                                            filename: fileURL.lastPathComponent), id: photoId)
                    try? photos.setMetadata(id: photoId, ImageLoader.metadata(source: source))
                    try? photos.setPhash(ImageLoader.dHash(source: source), id: photoId)   // dup detection
                    let petKind = PhotoClassifier.detectPet(image: image)
                    try? photos.setPetKind(petKind, id: photoId)
                    if petKind != nil {   // only run the heavier pose+embed when an animal is present
                        for pet in (try? petPipe.process(image: image)) ?? [] {
                            _ = try? faces.insert(Face(
                                photoId: photoId,
                                bboxX: Double(pet.bbox.minX), bboxY: Double(pet.bbox.minY),
                                bboxW: Double(pet.bbox.width), bboxH: Double(pet.bbox.height),
                                embedding: pet.embedding.blob,
                                embeddingModel: petPipe.embedder.modelIdentifier,
                                embeddingDim: pet.embedding.count,
                                kind: "pet", createdAt: now))
                        }
                    }
                    try photos.setState(.embedded, id: photoId, indexedAt: now)
                    progress.success(faces: results.count)
                } catch {
                    // Mark failed (so a later scan retries it — see needingProcessing) and log why, so a
                    // mass failure is diagnosable instead of silently surfacing as "No faces".
                    try? photos.setState(.failed, id: photoId, indexedAt: now)
                    fputs("sort: skipped \(photo.relativePath): \(error)\n", stderr)
                    progress.failure()
                }
            }
        }
        report.photosProcessed = progress.processed
        report.facesAdded = progress.facesAdded
        report.failures = progress.failures

        // Backlog: classify any photos still missing a category (incl. those indexed before F4).
        _ = try classifyUncategorized(classifier: classifier) { done, total in
            onProgress?(.init(phase: .classifying, done: done, total: total))
        }

        onProgress?(.init(phase: .clustering, done: 0, total: 1))
        // Incremental at scale (large existing library → assign only new faces); full recluster for a
        // first scan or a small library, where it's cheap and gives the best grouping.
        report.recluster = try ClusteringService(db: db, config: clustering).clusterAfterScan(now: now)
        onProgress?(.init(phase: .clustering, done: 1, total: 1))
        return report
    }

    /// Classify already-indexed photos that have no category yet (across all roots). Files whose
    /// volume is currently unavailable are skipped and retried on a later pass.
    @discardableResult
    public func classifyUncategorized(classifier: PhotoClassifier = PhotoClassifier(),
                                      onProgress: ((Int, Int) -> Void)? = nil) throws -> Int {
        let rootPaths = Dictionary(uniqueKeysWithValues:
            try roots.all().compactMap { r in r.id.map { ($0, r.displayPath) } })
        let pending = try photos.uncategorized()
        var done = 0
        for (i, photo) in pending.enumerated() {
            defer { onProgress?(i + 1, pending.count) }
            guard let id = photo.id, let base = rootPaths[photo.rootId] else { continue }
            let url = URL(fileURLWithPath: base).appendingPathComponent(photo.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? photos.setCategory(classifier.classify(url: url), id: id)
            done += 1
        }
        return done
    }

    // MARK: - Browse

    public func people(includeHidden: Bool = false) throws -> [Person] {
        try persons.all(includeHidden: includeHidden)
    }

    public func photos(forPerson id: Int64) throws -> [Photo] {
        try photos.forPerson(id)
    }

    /// Photos containing ALL of `ids` (AND). `exclusive` = "only them" (no other known person present).
    public func photos(forPeople ids: [Int64], exclusive: Bool) throws -> [Photo] {
        try photos.forPeople(ids, exclusive: exclusive)
    }

    public func renamePerson(_ id: Int64, to name: String?, now: Double) throws {
        try persons.rename(id, to: name, now: now)
    }

    public func scannedRoots() throws -> [ScannedRoot] {
        try roots.all()
    }

    // MARK: - Categories (F4)

    public enum PhotoCategory: String, Sendable, CaseIterable {
        // Raw values match the strings the classifier stores, so browse queries pass `rawValue` straight
        // through (screenshots/documents are singular in the DB; the rest match their case names).
        case screenshots = "screenshot", documents = "document", identity, places, noFaces, pets, videos = "video"
    }

    public struct CategoryCounts: Sendable {
        public var people: Int
        public var screenshots: Int
        public var documents: Int
        public var identity: Int
        public var places: Int
        public var noFaces: Int
        public var pets: Int
        public var videos: Int
        public init(people: Int = 0, screenshots: Int = 0, documents: Int = 0,
                    identity: Int = 0, places: Int = 0, noFaces: Int = 0, pets: Int = 0, videos: Int = 0) {
            self.people = people; self.screenshots = screenshots; self.documents = documents
            self.identity = identity; self.places = places; self.noFaces = noFaces; self.pets = pets
            self.videos = videos
        }
    }

    public func categoryCounts() throws -> CategoryCounts {
        let c = try photos.categoryCounts()
        let people = try persons.all(includeHidden: false).count
        return CategoryCounts(people: people, screenshots: c.screenshots, documents: c.documents,
                              identity: c.identity, places: c.places, noFaces: c.noFaces, pets: c.pets,
                              videos: c.videos)
    }

    /// Groups of near-identical photos by perceptual-hash Hamming distance. Default ≤6 of 64 bits
    /// ≈ "90%+ identical" — tight on purpose so distinct photos aren't grouped (the user trashes from
    /// here, so precision matters; they still verify side-by-side). ponytail: O(n²) pairwise union-find
    /// — fine for v1; a BK-tree/LSH is the upgrade at 6-figure photo counts.
    public func duplicateSets(maxHamming: Int = 6) throws -> [[Photo]] {
        let items = try photos.withPhash()
        let n = items.count
        guard n > 1 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for i in 0..<n {
            guard let hi = items[i].phash else { continue }
            for j in (i + 1)..<n {
                guard let hj = items[j].phash else { continue }
                if ImageLoader.hammingDistance(hi, hj) <= maxHamming { parent[find(i)] = find(j) }
            }
        }
        var groups: [Int: [Photo]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(items[i]) }
        // Sets of ≥2, biggest first; within a set, highest-resolution (then largest file) first so the
        // "best" candidate to keep leads. Ties broken by photo id so the order is FULLY DETERMINISTIC —
        // otherwise dict iteration reshuffles equal-count sets on every reload (VB2: the list jumped).
        func area(_ p: Photo) -> Int { (p.width ?? 0) * (p.height ?? 0) }
        return groups.values.filter { $0.count > 1 }
            .map { $0.sorted {
                if area($0) != area($1) { return area($0) > area($1) }
                if $0.size != $1.size { return $0.size > $1.size }
                return ($0.id ?? 0) < ($1.id ?? 0)
            } }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : ($0.first?.id ?? 0) < ($1.first?.id ?? 0)
            }
    }

    public func photos(inCategory category: PhotoCategory) throws -> [Photo] {
        try photos.inCategory(category.rawValue)
    }

    /// One representative photo for a category card's thumbnail (newest first) — LIMIT 1, so a card
    /// doesn't load the whole category.
    public func firstPhoto(inCategory category: PhotoCategory) throws -> Photo? {
        try photos.firstInCategory(category.rawValue)
    }

    // MARK: - Favourites (F2)
    public func setFavorite(_ on: Bool, id: Int64) throws { try photos.setFavorite(on, id: id) }
    public func favoriteIDs() throws -> Set<Int64> { try photos.favoriteIDs() }
    public func favorites() throws -> [Photo] { try photos.favorites() }
    /// Most-recently-indexed photos, capped — for the "Recently added" quick list.
    public func recentlyAdded(limit: Int = 300) throws -> [Photo] {
        Array(try photos.allByIndexedAt().prefix(limit))
    }

    /// User correction: "these photos are NOT this person." Records cannot-link constraints between
    /// the detached faces and a face that stays, then re-clusters so the system re-evaluates them
    /// (they move to the right person or form a new group). The constraint persists, so the decision
    /// is permanent and feeds every future re-cluster — this is how the grouping learns over time.
    @discardableResult
    public func markNotPerson(photoIds: [Int64], personId: Int64,
                              clustering: ClusteringConfig = .init(), now: Double) throws -> Int {
        let personFaces = try faces.forPerson(personId)
        let detachPhotos = Set(photoIds)
        let detach = personFaces.filter { detachPhotos.contains($0.photoId) }
        let keep = personFaces.filter { !detachPhotos.contains($0.photoId) }
        let detachIds = detach.compactMap(\.id)
        guard !detachIds.isEmpty else { return 0 }

        // Persist the decision: cannot-link each detached face to a kept anchor so a future full
        // re-cluster won't pull them back in.
        let constraintsRepo = ConstraintRepository(db)
        if let anchor = keep.first?.id {
            for fid in detachIds where fid != anchor {
                try constraintsRepo.add(faceA: fid, faceB: anchor, kind: .cannotLink, now: now)
            }
        }

        // Apply directly: move the detached faces OUT of this person, clustering them among themselves
        // into new group(s). Direct reassignment removes ALL selected faces reliably — the old
        // single-anchor cannot-link + full re-cluster let some faces re-merge with a non-anchor face
        // (the "removed 2 of 3" bug), and the full re-cluster was the lag.
        let kind = try persons.find(personId)?.kind
        let threshold = (kind == "pet") ? clustering.petThreshold : clustering.threshold
        let usable = detach.filter { $0.id != nil && !$0.vector.isEmpty }
        if usable.isEmpty {
            try faces.assign(personId: nil, faceIds: detachIds)   // no embeddings → just unassign
        } else {
            let vectors = usable.map { Vector.l2normalized($0.vector) }
            let labels = AgglomerativeClustering.cluster(vectors: vectors, threshold: threshold)
            var groups: [Int: [Int]] = [:]
            for (i, l) in labels.enumerated() { groups[l, default: []].append(i) }
            for idxs in groups.values {
                let pid = try persons.create(kind: kind, now: now).id!
                try faces.assign(personId: pid, faceIds: idxs.compactMap { usable[$0].id })
                try persons.updateCentroid(pid, centroid: Vector.centroidBlob(idxs.map { vectors[$0] }), now: now)
            }
            let embedded = Set(usable.compactMap(\.id))
            let leftover = detachIds.filter { !embedded.contains($0) }
            if !leftover.isEmpty { try faces.assign(personId: nil, faceIds: leftover) }
        }

        // Refresh the source person: counts, cover (it may have been the detached photo), and centroid.
        try persons.recomputeFaceCounts()
        if let cover = try persons.find(personId)?.coverFaceId,
           (try faces.find(cover))?.personId != personId {
            try persons.setCoverFace(personId, faceId: nil, now: now)   // fall back to a member face
        }
        let keepVecs = try faces.forPerson(personId).compactMap { $0.embedding }
            .map { [Float](blob: $0) }.filter { !$0.isEmpty }
        try persons.updateCentroid(personId, centroid: Vector.centroidBlob(keepVecs), now: now)
        _ = try persons.pruneEmpty()
        return detachIds.count
    }

    /// How many corrections (Same / Different / Not-this-person) the grouping has learned from.
    public func learnedCorrections() throws -> Int {
        try ConstraintRepository(db).all().count
    }

    /// Stop tracking a folder/drive: remove it and its photos/faces from the index, then refresh
    /// people. Files on disk are NEVER touched (this is not a delete — just untracking).
    @discardableResult
    public func removeRoot(_ rootId: Int64, now: Double) throws -> Int {
        let removed = try photos.deleteForRoot(rootId)
        try roots.delete(rootId)
        try persons.recomputeFaceCounts()
        _ = try persons.pruneEmpty()
        return removed
    }

    /// Faces detected in a photo, optionally filtered to one person — drives the face-highlight
    /// overlay (#6). Bounding boxes are normalized (origin bottom-left, Vision convention).
    public func faces(inPhoto photoId: Int64, person personId: Int64? = nil) throws -> [Face] {
        let all = try faces.forPhoto(photoId)
        guard let personId else { return all }
        return all.filter { $0.personId == personId }
    }

    // MARK: - Delete (the one sanctioned write — D7)

    public struct DeleteReport: Sendable {
        public var trashed = 0       // file moved to Trash + removed from index
        public var missing = 0       // file already gone; index row removed
        public var failed = 0        // trash failed; index row kept
        public var removedPeople = 0 // people left with zero photos, pruned
    }

    /// Move photos to the Trash (recoverable) and remove them from the index. Never edits files in
    /// place. Affected people have their counts/centroids refreshed and are pruned if now empty.
    @discardableResult
    public func deletePhotos(ids: [Int64], trasher: FileTrashing = SystemTrash(), now: Double) throws -> DeleteReport {
        var report = DeleteReport()
        let rootMap = Dictionary(uniqueKeysWithValues:
            try roots.all().compactMap { r in r.id.map { ($0, r.displayPath) } })
        var affected = Set<Int64>()

        for id in ids {
            guard let photo = try photos.find(id) else { continue }
            for face in try faces.forPhoto(id) { if let p = face.personId { affected.insert(p) } }
            guard let base = rootMap[photo.rootId] else { report.failed += 1; continue }
            let url = URL(fileURLWithPath: base).appendingPathComponent(photo.relativePath)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try trasher.trash(url)
                    report.trashed += 1
                } else {
                    report.missing += 1
                }
                try photos.delete(id)   // cascades faces
            } catch {
                report.failed += 1      // file still on disk → keep the index row
            }
        }

        // Refresh affected people: recompute counts + centroids, drop any now empty.
        try persons.recomputeFaceCounts()
        for pid in affected {
            let vectors = try faces.forPerson(pid).compactMap { $0.embedding }.map { [Float](blob: $0) }
            try persons.updateCentroid(pid, centroid: Vector.centroidBlob(vectors), now: now)
        }
        report.removedPeople = try persons.pruneEmpty()
        return report
    }

    // MARK: - Export (copy out — never modifies the source tree)

    public struct ExportReport: Sendable {
        public var exported = 0   // original copied to the destination
        public var missing = 0    // source file no longer on disk
        public var failed = 0     // copy failed (e.g. destination not writable)
    }

    /// Copy the given photos' ORIGINAL files out to `destinationDir` (a user-picked folder). This
    /// reads the source and writes to a SEPARATE destination — it never modifies, moves, or writes
    /// into the scanned source tree, so the read-only invariant (D7) holds. Filename collisions get a
    /// " (n)" suffix so nothing is overwritten.
    @discardableResult
    public func exportPhotos(ids: [Int64], to destinationDir: URL) throws -> ExportReport {
        var report = ExportReport()
        let rootMap = Dictionary(uniqueKeysWithValues:
            try roots.all().compactMap { r in r.id.map { ($0, r.displayPath) } })
        let fm = FileManager.default
        for id in ids {
            guard let photo = try photos.find(id), let base = rootMap[photo.rootId] else {
                report.failed += 1; continue
            }
            let src = URL(fileURLWithPath: base).appendingPathComponent(photo.relativePath)
            guard fm.fileExists(atPath: src.path) else { report.missing += 1; continue }
            let dest = Self.uniqueDestination(for: src.lastPathComponent, in: destinationDir, fm: fm)
            do { try fm.copyItem(at: src, to: dest); report.exported += 1 }
            catch { report.failed += 1 }
        }
        return report
    }

    /// A non-colliding destination URL: `name`, then `name (2)`, `name (3)`, … if it already exists.
    static func uniqueDestination(for name: String, in dir: URL, fm: FileManager) -> URL {
        let first = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: first.path) else { return first }
        let ns = name as NSString
        let ext = ns.pathExtension, stem = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(
                ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

/// Thread-safe tallies + progress for the concurrent processing pass. `@unchecked Sendable`: the
/// counters are lock-guarded; the sink is only invoked (callers pass a thread-safe one).
private final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: ((IndexService.Progress) -> Void)?
    let total: Int
    private(set) var processed = 0, facesAdded = 0, failures = 0

    init(total: Int, sink: ((IndexService.Progress) -> Void)?) {
        self.total = total
        self.sink = sink
    }
    func success(faces n: Int) {
        lock.lock(); processed += 1; facesAdded += n; let done = processed; lock.unlock()
        sink?(.init(phase: .processing, done: done, total: total))
    }
    func failure() {
        lock.lock(); processed += 1; failures += 1; let done = processed; lock.unlock()
        sink?(.init(phase: .processing, done: done, total: total))
    }
}

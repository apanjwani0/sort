import Foundation
import GRDB

// Repositories own all reads/writes to the app's OWN database. They never touch source photo
// files — that boundary lives in FileAccess (the read-only invariant).

public struct RootRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    @discardableResult
    public func add(displayPath: String, volumeUUID: String?, bookmark: Data?, now: Double) throws -> ScannedRoot {
        try db.writer.write { dbc in
            if var existing = try ScannedRoot.filter(Column("displayPath") == displayPath).fetchOne(dbc) {
                existing.volumeUUID = volumeUUID
                if let bookmark { existing.bookmark = bookmark }
                try existing.update(dbc)
                return existing
            }
            var root = ScannedRoot(displayPath: displayPath, volumeUUID: volumeUUID,
                                   bookmark: bookmark, addedAt: now)
            try root.insert(dbc)
            return root
        }
    }

    public func all() throws -> [ScannedRoot] {
        try db.writer.read { try ScannedRoot.order(Column("addedAt")).fetchAll($0) }
    }

    public func update(_ root: ScannedRoot) throws {
        try db.writer.write { try root.update($0) }
    }

    /// Stop tracking a root (its photos/faces cascade away). Files on disk are NOT touched.
    public func delete(_ id: Int64) throws {
        try db.writer.write { dbc in _ = try ScannedRoot.deleteOne(dbc, key: id) }
    }
}

public struct PhotoRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Insert a freshly-discovered photo, or refresh an existing row in place. Returns the row
    /// plus whether it is new/changed (so the caller knows to (re)process it).
    public struct UpsertResult: Sendable {
        public var photo: Photo
        /// True if this file is new to the index.
        public var wasInserted: Bool
        /// True if an existing file's bytes changed (mtime/size differ) since last scan.
        public var bytesChanged: Bool
        /// True if the pipeline still has work to do on this photo (new, changed, or never processed).
        public var needsProcessing: Bool
    }

    @discardableResult
    public func upsert(_ incoming: Photo) throws -> UpsertResult {
        try db.writer.write { dbc in
            if var existing = try Photo
                .filter(Column("rootId") == incoming.rootId && Column("relativePath") == incoming.relativePath)
                .fetchOne(dbc) {
                let bytesChanged = existing.mtime != incoming.mtime || existing.size != incoming.size
                existing.mtime = incoming.mtime
                existing.size = incoming.size
                existing.fileID = incoming.fileID
                existing.volumeUUID = incoming.volumeUUID
                existing.scanGeneration = incoming.scanGeneration
                if bytesChanged { existing.state = PhotoState.discovered.rawValue }
                if existing.state == PhotoState.missing.rawValue {
                    existing.state = PhotoState.discovered.rawValue
                }
                try existing.update(dbc)
                let needs = bytesChanged || existing.state == PhotoState.discovered.rawValue
                return UpsertResult(photo: existing, wasInserted: false,
                                    bytesChanged: bytesChanged, needsProcessing: needs)
            }
            // No path match — but a RENAMED/MOVED file keeps its (volumeUUID, fileID) on the same
            // volume (APFS only reassigns the inode on an edit, which we WANT to treat as changed).
            // Re-home the existing row to the new path so its faces/person assignments survive instead
            // of being discarded and re-embedded. Skip rows already seen this generation (a hardlink or
            // copy sharing an inode is a genuinely separate file, not a move).
            if let vol = incoming.volumeUUID, let fid = incoming.fileID,
               var moved = try Photo
                .filter(Column("rootId") == incoming.rootId && Column("volumeUUID") == vol
                        && Column("fileID") == fid && Column("scanGeneration") != incoming.scanGeneration)
                .fetchOne(dbc) {
                let bytesChanged = moved.mtime != incoming.mtime || moved.size != incoming.size
                moved.relativePath = incoming.relativePath
                moved.mtime = incoming.mtime
                moved.size = incoming.size
                moved.scanGeneration = incoming.scanGeneration
                if bytesChanged { moved.state = PhotoState.discovered.rawValue }
                if moved.state == PhotoState.missing.rawValue { moved.state = PhotoState.discovered.rawValue }
                try moved.update(dbc)
                let needs = bytesChanged || moved.state == PhotoState.discovered.rawValue
                return UpsertResult(photo: moved, wasInserted: false,
                                    bytesChanged: bytesChanged, needsProcessing: needs)
            }
            var fresh = incoming
            try fresh.insert(dbc)
            return UpsertResult(photo: fresh, wasInserted: true,
                                bytesChanged: false, needsProcessing: true)
        }
    }

    public func find(rootId: Int64, relativePath: String) throws -> Photo? {
        try db.writer.read {
            try Photo.filter(Column("rootId") == rootId && Column("relativePath") == relativePath).fetchOne($0)
        }
    }

    public func all() throws -> [Photo] {
        try db.writer.read { try Photo.fetchAll($0) }
    }

    /// Photo count per root for the SOURCES list — a COUNT(*) GROUP BY instead of loading every row.
    public func countsByRoot() throws -> [Int64: Int] {
        try db.writer.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: "SELECT rootId, COUNT(*) AS c FROM photo GROUP BY rootId")
            var map: [Int64: Int] = [:]
            for row in rows { map[row["rootId"]] = row["c"] }
            return map
        }
    }

    /// All photos newest-first by capture date (falls back to mtime) — sorted in SQL, not in memory.
    public func allByTakenAt() throws -> [Photo] {
        try db.writer.read { try Photo.order(sql: "COALESCE(takenAt, mtime) DESC").fetchAll($0) }
    }

    /// All photos most-recently-indexed first — sorted in SQL, not in memory.
    public func allByIndexedAt() throws -> [Photo] {
        try db.writer.read { try Photo.order(sql: "COALESCE(indexedAt, 0) DESC").fetchAll($0) }
    }

    /// Distinct photos containing at least one face assigned to `personId`, newest first.
    public func forPerson(_ personId: Int64) throws -> [Photo] {
        try db.writer.read { dbc in
            try Photo.fetchAll(dbc, sql: """
                SELECT photo.* FROM photo
                JOIN face ON face.photoId = photo.id
                WHERE face.personId = ?
                GROUP BY photo.id
                ORDER BY COALESCE(photo.takenAt, photo.mtime) DESC
                """, arguments: [personId])
        }
    }

    /// Photos containing ALL of `personIds` (AND-intersection), newest first. When `exclusive` is true
    /// ("only them"), photos that also contain any OTHER known person are excluded; unassigned/unknown
    /// faces are ignored either way.
    public func forPeople(_ personIds: [Int64], exclusive: Bool) throws -> [Photo] {
        let ids = Array(Set(personIds))
        guard !ids.isEmpty else { return [] }
        return try db.writer.read { dbc in
            let qs = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var sql = """
                SELECT photo.* FROM photo
                WHERE (SELECT COUNT(DISTINCT personId) FROM face
                       WHERE face.photoId = photo.id AND personId IN (\(qs))) = ?
                """
            var args: [DatabaseValueConvertible] = ids.map { $0 }
            args.append(ids.count)
            if exclusive {
                sql += "\n  AND NOT EXISTS (SELECT 1 FROM face WHERE face.photoId = photo.id "
                     + "AND personId IS NOT NULL AND personId NOT IN (\(qs)))"
                args.append(contentsOf: ids.map { $0 })
            }
            sql += "\n  ORDER BY COALESCE(takenAt, mtime) DESC"
            return try Photo.fetchAll(dbc, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func find(_ id: Int64) throws -> Photo? {
        try db.writer.read { try Photo.fetchOne($0, key: id) }
    }

    /// Remove a photo row from the index (cascades its faces via FK). Does NOT touch the file on
    /// disk — the file is trashed separately via FileTrashing.
    public func delete(_ id: Int64) throws {
        try db.writer.write { dbc in _ = try Photo.deleteOne(dbc, key: id) }
    }

    /// Drop all of a root's photos from the index (cascades faces). Files on disk are untouched.
    @discardableResult
    public func deleteForRoot(_ rootId: Int64) throws -> Int {
        try db.writer.write { dbc in
            try Photo.filter(Column("rootId") == rootId).deleteAll(dbc)
        }
    }

    /// Photos the pipeline still needs to process: freshly discovered AND previously failed. Retrying
    /// .failed is essential — a transient failure (e.g. a decode that ran out of memory during a big
    /// scan, or a read that lost folder access) must not strand a face-containing photo permanently in
    /// the "No faces" bucket. Genuinely undecodable files just fail again cheaply.
    public func needingProcessing() throws -> [Photo] {
        try db.writer.read {
            try Photo.filter([PhotoState.discovered.rawValue, PhotoState.failed.rawValue]
                                .contains(Column("state"))).fetchAll($0)
        }
    }

    /// Photos not yet assigned a scene category (e.g. indexed before F4) — for the backlog classify.
    public func uncategorized() throws -> [Photo] {
        try db.writer.read {
            try Photo.filter(Column("category") == nil
                             && Column("state") != PhotoState.missing.rawValue).fetchAll($0)
        }
    }

    public func setCategory(_ category: String?, id: Int64) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE photo SET category = ? WHERE id = ?", arguments: [category, id])
        }
    }

    /// Store EXIF-derived metadata (capture date, GPS, dimensions). COALESCE keeps any existing
    /// value when a field is nil, so a re-read that fails to find GPS doesn't erase it.
    public func setMetadata(id: Int64, _ m: ImageLoader.Metadata) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE photo SET
                    takenAt = COALESCE(?, takenAt), gpsLat = COALESCE(?, gpsLat),
                    gpsLon = COALESCE(?, gpsLon), width = COALESCE(?, width),
                    height = COALESCE(?, height)
                WHERE id = ?
                """, arguments: [m.takenAt, m.gpsLat, m.gpsLon, m.width, m.height, id])
        }
    }

    public func setPhash(_ phash: Int64?, id: Int64) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE photo SET phash = ? WHERE id = ?", arguments: [phash, id])
        }
    }

    public func setPetKind(_ kind: String?, id: Int64) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE photo SET petKind = ? WHERE id = ?", arguments: [kind, id])
        }
    }

    // MARK: Favourites (F2) — kept off the Photo record so the scan upsert's `update` never clobbers
    // it; reads/writes go through raw SQL on the `favorite` column.
    public func setFavorite(_ on: Bool, id: Int64) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE photo SET favorite = ? WHERE id = ?", arguments: [on, id])
        }
    }
    public func favoriteIDs() throws -> Set<Int64> {
        try db.writer.read { try Int64.fetchSet($0, sql: "SELECT id FROM photo WHERE favorite = 1") }
    }
    public func favorites() throws -> [Photo] {
        try db.writer.read {
            try Photo.filter(sql: "favorite = 1").order(sql: "COALESCE(takenAt, mtime) DESC").fetchAll($0)
        }
    }

    /// Present photos that carry a perceptual hash — the candidate set for duplicate detection.
    public func withPhash() throws -> [Photo] {
        try db.writer.read {
            try Photo.filter(sql: "phash IS NOT NULL AND state != ?",
                             arguments: [PhotoState.missing.rawValue]).fetchAll($0)
        }
    }

    /// Counts for the Collections screen categories.
    public func categoryCounts() throws -> (screenshots: Int, documents: Int, identity: Int, places: Int, noFaces: Int, pets: Int, videos: Int) {
        try db.writer.read { dbc in
            let s = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM photo WHERE category = 'screenshot'") ?? 0
            let d = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM photo WHERE category = 'document'") ?? 0
            let idn = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM photo WHERE category = 'identity'") ?? 0
            let p = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM photo WHERE gpsLat IS NOT NULL") ?? 0
            let n = try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM photo WHERE id NOT IN (SELECT DISTINCT photoId FROM face)
                  AND COALESCE(category, '') != 'video'
                """) ?? 0
            let pet = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM photo WHERE petKind IS NOT NULL") ?? 0
            let v = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM photo WHERE category = 'video'") ?? 0
            return (s, d, idn, p, n, pet, v)
        }
    }

    /// Photos in a Collections category (newest first).
    public func inCategory(_ category: String) throws -> [Photo] {
        try db.writer.read { dbc in
            switch category {
            case "places":
                return try Photo.filter(sql: "gpsLat IS NOT NULL")
                    .order(sql: "COALESCE(takenAt, mtime) DESC").fetchAll(dbc)
            case "noFaces":
                return try Photo.fetchAll(dbc, sql: """
                    SELECT * FROM photo WHERE id NOT IN (SELECT DISTINCT photoId FROM face)
                      AND COALESCE(category, '') != 'video'
                    ORDER BY COALESCE(takenAt, mtime) DESC
                    """)
            case "pets":
                return try Photo.filter(sql: "petKind IS NOT NULL")
                    .order(sql: "COALESCE(takenAt, mtime) DESC").fetchAll(dbc)
            default:
                return try Photo.filter(Column("category") == category)
                    .order(sql: "COALESCE(takenAt, mtime) DESC").fetchAll(dbc)
            }
        }
    }

    /// A single representative photo for a category (newest first), via LIMIT 1 — so a category
    /// card's thumbnail doesn't load the whole category just to take the first.
    public func firstInCategory(_ category: String) throws -> Photo? {
        try db.writer.read { dbc in
            switch category {
            case "places":
                return try Photo.filter(sql: "gpsLat IS NOT NULL")
                    .order(sql: "COALESCE(takenAt, mtime) DESC").fetchOne(dbc)
            case "noFaces":
                return try Photo.fetchOne(dbc, sql: """
                    SELECT * FROM photo WHERE id NOT IN (SELECT DISTINCT photoId FROM face)
                      AND COALESCE(category, '') != 'video'
                    ORDER BY COALESCE(takenAt, mtime) DESC LIMIT 1
                    """)
            case "pets":
                return try Photo.filter(sql: "petKind IS NOT NULL")
                    .order(sql: "COALESCE(takenAt, mtime) DESC").fetchOne(dbc)
            default:
                return try Photo.filter(Column("category") == category)
                    .order(sql: "COALESCE(takenAt, mtime) DESC").fetchOne(dbc)
            }
        }
    }

    public func setState(_ state: PhotoState, id: Int64, indexedAt: Double? = nil) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE photo SET state = ?, indexedAt = ? WHERE id = ?",
                            arguments: [state.rawValue, indexedAt, id])
        }
    }

    /// Mark photos not seen in the current generation as missing (file vanished/moved).
    @discardableResult
    public func markMissing(rootId: Int64, generation: Int) throws -> Int {
        try db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE photo SET state = ? WHERE rootId = ? AND scanGeneration < ? AND state != ?
                """, arguments: [PhotoState.missing.rawValue, rootId, generation, PhotoState.missing.rawValue])
            return dbc.changesCount
        }
    }
}

public struct FaceRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    @discardableResult
    public func insert(_ face: Face) throws -> Face {
        try db.writer.write { dbc in
            var f = face
            try f.insert(dbc)
            return f
        }
    }

    public func deleteForPhoto(_ photoId: Int64) throws {
        try db.writer.write { dbc in _ = try Face.filter(Column("photoId") == photoId).deleteAll(dbc) }
    }

    public func withEmbeddings() throws -> [Face] {
        try db.writer.read {
            try Face.filter(Column("embedding") != nil).fetchAll($0)
        }
    }

    public func all() throws -> [Face] {
        try db.writer.read { try Face.fetchAll($0) }
    }

    public func forPerson(_ personId: Int64) throws -> [Face] {
        try db.writer.read { try Face.filter(Column("personId") == personId).fetchAll($0) }
    }

    /// All faces detected in a photo (used for the face-highlight overlay, #6).
    public func forPhoto(_ photoId: Int64) throws -> [Face] {
        try db.writer.read { try Face.filter(Column("photoId") == photoId).fetchAll($0) }
    }

    public func find(_ id: Int64) throws -> Face? {
        try db.writer.read { try Face.fetchOne($0, key: id) }
    }

    /// Assign a batch of faces to a person in one transaction.
    public func assign(personId: Int64?, faceIds: [Int64]) throws {
        guard !faceIds.isEmpty else { return }
        try db.writer.write { dbc in
            _ = try Face.filter(keys: faceIds).updateAll(dbc, Column("personId").set(to: personId))
        }
    }
}

public struct PersonRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    @discardableResult
    public func create(kind: String? = nil, now: Double) throws -> Person {
        try db.writer.write { dbc in
            var p = Person(kind: kind, createdAt: now, updatedAt: now)
            try p.insert(dbc)
            return p
        }
    }

    public func all(includeHidden: Bool = true) throws -> [Person] {
        try db.writer.read { dbc in
            let base = includeHidden ? Person.all() : Person.filter(Column("isHidden") == false)
            return try base.order(Column("faceCount").desc).fetchAll(dbc)
        }
    }

    public func find(_ id: Int64) throws -> Person? {
        try db.writer.read { try Person.fetchOne($0, key: id) }
    }

    public func rename(_ id: Int64, to name: String?, now: Double) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE person SET displayName = ?, updatedAt = ? WHERE id = ?",
                            arguments: [name, now, id])
        }
    }

    /// Update a person's cached centroid (and bump updatedAt). Leaves name/cover untouched so a
    /// reused person keeps its identity across re-clustering.
    public func updateCentroid(_ id: Int64, centroid: Data?, now: Double) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE person SET centroid = ?, updatedAt = ? WHERE id = ?",
                            arguments: [centroid, now, id])
        }
    }

    /// Recompute every person's faceCount from the face table (call after re-clustering).
    public func recomputeFaceCounts() throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE person SET faceCount =
                    (SELECT COUNT(*) FROM face WHERE face.personId = person.id)
                """)
        }
    }

    public func setCoverFace(_ id: Int64, faceId: Int64?, now: Double) throws {
        try db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE person SET coverFaceId = ?, updatedAt = ? WHERE id = ?",
                            arguments: [faceId, now, id])
        }
    }

    /// Distinct photo count per person (a person can appear multiple times in one photo).
    public func photoCounts() throws -> [Int64: Int] {
        try db.writer.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT personId, COUNT(DISTINCT photoId) AS c
                FROM face WHERE personId IS NOT NULL GROUP BY personId
                """)
            var map: [Int64: Int] = [:]
            for row in rows { map[row["personId"]] = row["c"] }
            return map
        }
    }

    /// Remove people that ended up with no faces (after re-clustering).
    @discardableResult
    public func pruneEmpty() throws -> Int {
        try db.writer.write { dbc in
            try dbc.execute(sql: "DELETE FROM person WHERE faceCount = 0")
            return dbc.changesCount
        }
    }

}

public struct ConstraintRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func add(faceA: Int64, faceB: Int64, kind: ConstraintKind, now: Double) throws {
        var c = FaceConstraint(faceAId: faceA, faceBId: faceB, kind: kind, createdAt: now)
        try db.writer.write { dbc in
            // Idempotent: ignore if the same canonical pair+kind already exists.
            try c.insert(dbc, onConflict: .ignore)
        }
    }

    public func all() throws -> [FaceConstraint] {
        try db.writer.read { try FaceConstraint.fetchAll($0) }
    }
}

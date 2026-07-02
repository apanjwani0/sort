import Foundation
import GRDB

/// Owns the SQLite index. The scan writer uses a WAL `DatabasePool` so a long background scan
/// never blocks the browsing UI's reads (D5).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk store at the app's Application Support directory (default production location).
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// Default Application Support location: ~/Library/Application Support/sort/index.sqlite
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent("sort/index.sqlite")
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.schema") { db in
            try db.create(table: "scannedRoot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("displayPath", .text).notNull()
                t.column("volumeUUID", .text)
                t.column("bookmark", .blob)
                t.column("addedAt", .double).notNull()
                t.column("lastScannedAt", .double)
                t.column("scanGeneration", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "photo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rootId", .integer).notNull()
                    .references("scannedRoot", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("volumeUUID", .text)
                t.column("fileID", .integer)
                t.column("mtime", .double).notNull()
                t.column("size", .integer).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("takenAt", .double)
                t.column("gpsLat", .double)
                t.column("gpsLon", .double)
                t.column("state", .text).notNull().defaults(to: PhotoState.discovered.rawValue)
                t.column("scanGeneration", .integer).notNull().defaults(to: 0)
                t.column("indexedAt", .double)
                t.uniqueKey(["rootId", "relativePath"])
            }
            try db.create(indexOn: "photo", columns: ["volumeUUID", "fileID"])
            try db.create(indexOn: "photo", columns: ["state"])

            try db.create(table: "person") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("displayName", .text)
                t.column("coverFaceId", .integer)
                t.column("isHidden", .boolean).notNull().defaults(to: false)
                t.column("centroid", .blob)
                t.column("faceCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }

            try db.create(table: "face") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("photoId", .integer).notNull()
                    .references("photo", onDelete: .cascade)
                t.column("bboxX", .double).notNull()
                t.column("bboxY", .double).notNull()
                t.column("bboxW", .double).notNull()
                t.column("bboxH", .double).notNull()
                t.column("roll", .double)
                t.column("yaw", .double)
                t.column("pitch", .double)
                t.column("quality", .double)
                t.column("embedding", .blob)
                t.column("embeddingModel", .text)
                t.column("embeddingDim", .integer)
                t.column("personId", .integer)
                    .references("person", onDelete: .setNull)
                t.column("createdAt", .double).notNull()
            }
            try db.create(indexOn: "face", columns: ["personId"])
            try db.create(indexOn: "face", columns: ["photoId"])

            try db.create(table: "faceConstraint") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("faceAId", .integer).notNull()
                    .references("face", onDelete: .cascade)
                t.column("faceBId", .integer).notNull()
                    .references("face", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.uniqueKey(["faceAId", "faceBId", "kind"])
            }
        }

        migrator.registerMigration("v2.category") { db in
            try db.alter(table: "photo") { t in
                t.add(column: "category", .text)   // scene category from the classifier (F4)
            }
            try db.create(indexOn: "photo", columns: ["category"])
        }

        migrator.registerMigration("v3.phash") { db in
            try db.alter(table: "photo") { t in
                t.add(column: "phash", .integer)   // 64-bit perceptual difference-hash (near-dup detection)
            }
        }

        migrator.registerMigration("v4.petKind") { db in
            try db.alter(table: "photo") { t in
                t.add(column: "petKind", .text)   // "cat" / "dog" / nil — on-device animal detection
            }
        }

        migrator.registerMigration("v5.kind") { db in
            // Identity kind for faces/people: nil ⇒ "human" (ArcFace); "pet" ⇒ Vision feature-print.
            // Pets cluster in their own namespace (different embedding space) — see ClusteringService.
            try db.alter(table: "face") { t in t.add(column: "kind", .text) }
            try db.alter(table: "person") { t in t.add(column: "kind", .text) }
        }

        migrator.registerMigration("v6.favorite") { db in
            // F2: heart any photo. Kept off the Photo record (raw SQL reads/writes) so the scan
            // upsert's update never clobbers it.
            try db.alter(table: "photo") { t in
                t.add(column: "favorite", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}

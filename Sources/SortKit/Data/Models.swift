import Foundation
import GRDB

// MARK: - ScannedRoot

/// A folder or mounted volume the user granted read access to. The security-scoped bookmark
/// lets access survive relaunches, including external SSDs that get remounted.
public struct ScannedRoot: Codable, Identifiable, Equatable, Sendable,
                           FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var displayPath: String
    public var volumeUUID: String?
    /// Read-only security-scoped bookmark (nil for CLI/dev access by plain path).
    public var bookmark: Data?
    public var addedAt: Double
    public var lastScannedAt: Double?
    /// Monotonic scan counter; bumped each scan so we can detect photos that vanished.
    public var scanGeneration: Int

    public static let databaseTableName = "scannedRoot"

    public init(id: Int64? = nil, displayPath: String, volumeUUID: String? = nil,
                bookmark: Data? = nil, addedAt: Double, lastScannedAt: Double? = nil,
                scanGeneration: Int = 0) {
        self.id = id
        self.displayPath = displayPath
        self.volumeUUID = volumeUUID
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.lastScannedAt = lastScannedAt
        self.scanGeneration = scanGeneration
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Photo

/// One image file on disk. Identity is keyed on (volumeUUID, fileID) so a moved/renamed file keeps
/// its faces (see `PhotoRepository.upsert`). The file is NEVER modified by this app.
public struct Photo: Codable, Identifiable, Equatable, Sendable,
                     FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var rootId: Int64
    public var relativePath: String
    public var volumeUUID: String?
    /// Filesystem file id (inode). Per-volume; APFS safe-save can reassign on edit.
    public var fileID: Int64?
    public var mtime: Double
    public var size: Int64
    public var width: Int?
    public var height: Int?
    public var takenAt: Double?
    public var gpsLat: Double?
    public var gpsLon: Double?
    /// Pipeline stage reached: see PhotoState.
    public var state: String
    public var scanGeneration: Int
    public var indexedAt: Double?
    /// Scene category from the on-device classifier ("screenshot" / "document" / "other"); nil
    /// until classified. People/Places are derived (faces table / GPS), not stored here.
    public var category: String?
    /// 64-bit perceptual difference-hash of the whole image; near-equal hashes ⇒ duplicate photos.
    public var phash: Int64?
    /// Detected animal in the photo ("cat" / "dog"); nil if none. Drives the Pets bucket.
    public var petKind: String?

    public static let databaseTableName = "photo"

    public init(id: Int64? = nil, rootId: Int64, relativePath: String, volumeUUID: String? = nil,
                fileID: Int64? = nil, mtime: Double, size: Int64, width: Int? = nil,
                height: Int? = nil, takenAt: Double? = nil,
                gpsLat: Double? = nil, gpsLon: Double? = nil,
                state: PhotoState = .discovered, scanGeneration: Int = 0,
                indexedAt: Double? = nil, category: String? = nil, phash: Int64? = nil,
                petKind: String? = nil) {
        self.id = id
        self.rootId = rootId
        self.relativePath = relativePath
        self.volumeUUID = volumeUUID
        self.fileID = fileID
        self.mtime = mtime
        self.size = size
        self.width = width
        self.height = height
        self.takenAt = takenAt
        self.gpsLat = gpsLat
        self.gpsLon = gpsLon
        self.state = state.rawValue
        self.scanGeneration = scanGeneration
        self.indexedAt = indexedAt
        self.category = category
        self.phash = phash
        self.petKind = petKind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum PhotoState: String, Codable, Sendable, CaseIterable {
    case discovered   // found by scanner, not yet processed
    case detected     // faces detected
    case embedded     // embeddings computed
    case failed       // decode/detection failed
    case missing      // file no longer present on last scan
}

// MARK: - Face

/// One detected face within a photo, with its identity embedding and assigned person.
public struct Face: Codable, Identifiable, Equatable, Sendable,
                    FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var photoId: Int64
    // Normalized bounding box (origin top-left), each in [0, 1].
    public var bboxX: Double
    public var bboxY: Double
    public var bboxW: Double
    public var bboxH: Double
    public var roll: Double?
    public var yaw: Double?
    public var pitch: Double?
    public var quality: Double?
    /// 512-d Float32 embedding as a little-endian BLOB (2048 bytes).
    public var embedding: Data?
    public var embeddingModel: String?
    public var embeddingDim: Int?
    /// Assigned person (cluster). Nil until clustered.
    public var personId: Int64?
    /// Identity kind: nil ⇒ human (ArcFace embedding); "pet" ⇒ Vision feature-print. Pets cluster
    /// in a separate namespace (different embedding space) so they never mix with human faces.
    public var kind: String?
    public var createdAt: Double

    public static let databaseTableName = "face"

    public init(id: Int64? = nil, photoId: Int64,
                bboxX: Double, bboxY: Double, bboxW: Double, bboxH: Double,
                roll: Double? = nil, yaw: Double? = nil, pitch: Double? = nil,
                quality: Double? = nil, embedding: Data? = nil,
                embeddingModel: String? = nil, embeddingDim: Int? = nil,
                personId: Int64? = nil, kind: String? = nil, createdAt: Double) {
        self.id = id
        self.photoId = photoId
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxW = bboxW
        self.bboxH = bboxH
        self.roll = roll
        self.yaw = yaw
        self.pitch = pitch
        self.quality = quality
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.embeddingDim = embeddingDim
        self.personId = personId
        self.kind = kind
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Convenience: the embedding decoded to a Float vector (empty if absent).
    public var vector: [Float] {
        guard let embedding else { return [] }
        return [Float](blob: embedding)
    }
}

// MARK: - Person

/// A stable identity cluster. `id` is never reissued, so the UI never renumbers people across rescans.
public struct Person: Codable, Identifiable, Equatable, Sendable,
                      FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var displayName: String?
    public var coverFaceId: Int64?
    public var isHidden: Bool
    /// Cached centroid (mean of member embeddings), used for incremental nearest-centroid assignment.
    public var centroid: Data?
    public var faceCount: Int
    /// Identity kind: nil ⇒ "human"; "pet" for animal clusters. Keeps the People grid able to badge
    /// pets and keeps review/clustering from mixing the two embedding spaces.
    public var kind: String?
    public var createdAt: Double
    public var updatedAt: Double

    public static let databaseTableName = "person"

    public init(id: Int64? = nil, displayName: String? = nil, coverFaceId: Int64? = nil,
                isHidden: Bool = false, centroid: Data? = nil, faceCount: Int = 0,
                kind: String? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id
        self.displayName = displayName
        self.coverFaceId = coverFaceId
        self.isHidden = isHidden
        self.centroid = centroid
        self.faceCount = faceCount
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - FaceConstraint

/// A user correction from the "Same or different person?" flow. Re-applied on every clustering
/// pass so a future scan never silently re-merges a person the user split (or vice-versa).
public enum ConstraintKind: String, Codable, Sendable, DatabaseValueConvertible {
    case mustLink     // user said "Same" — these faces must end up in one person
    case cannotLink   // user said "Different" — these faces must stay separate
}

public struct FaceConstraint: Codable, Identifiable, Equatable, Sendable,
                              FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var faceAId: Int64
    public var faceBId: Int64
    public var kind: ConstraintKind
    public var createdAt: Double

    public static let databaseTableName = "faceConstraint"

    public init(id: Int64? = nil, faceAId: Int64, faceBId: Int64,
                kind: ConstraintKind, createdAt: Double) {
        // Store the pair canonically (a < b) so duplicates collapse.
        self.id = id
        self.faceAId = min(faceAId, faceBId)
        self.faceBId = max(faceAId, faceBId)
        self.kind = kind
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

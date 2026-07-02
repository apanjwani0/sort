import Foundation
import Accelerate

/// Float-vector helpers used for face embeddings. All embeddings are 512-d Float32 and are
/// stored in SQLite as raw little-endian BLOBs (4 bytes/element).
public enum Vector {
    /// L2-normalize a vector so cosine similarity reduces to a dot product.
    public static func l2normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm > 1e-12 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        // ponytail: mismatched lengths can't be dotted; return 0 (→ cosine sim 0, max distance) rather
        // than precondition-trapping the whole clustering pass. Clustering already partitions by
        // embedding dim, so this is a defense-in-depth net, not a routine path.
        guard a.count == b.count else { return 0 }
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
        return r
    }

    /// Cosine similarity in [-1, 1]. Safe for non-normalized inputs. Returns 0 (treated as maximally
    /// distant) when the vectors differ in length or either is empty.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let na = sqrt(dot(a, a)), nb = sqrt(dot(b, b))
        guard na > 1e-12, nb > 1e-12 else { return 0 }
        return dot(a, b) / (na * nb)
    }

    /// Cosine distance in [0, 2].
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        1 - cosineSimilarity(a, b)
    }

    /// A person's centroid BLOB: L2-normalized mean of its face vectors, ready for `updateCentroid`.
    /// Returns nil for an empty set (no faces → no centroid) — the one shape every call site needs.
    public static func centroidBlob(_ vectors: [[Float]]) -> Data? {
        vectors.isEmpty ? nil : l2normalized(mean(vectors)).blob
    }

    /// Element-wise mean of a set of vectors of equal length (used for cluster centroids). Vectors
    /// whose length differs from the first are skipped rather than trapping — a corrupt/odd embedding
    /// can't be allowed to abort the clustering pass.
    public static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        var counted = 0
        for v in vectors where v.count == acc.count {
            vDSP_vadd(acc, 1, v, 1, &acc, 1, vDSP_Length(acc.count))
            counted += 1
        }
        guard counted > 0 else { return acc }
        var divisor = Float(counted)
        vDSP_vsdiv(acc, 1, &divisor, &acc, 1, vDSP_Length(acc.count))
        return acc
    }
}

public extension Array where Element == Float {
    /// Pack as a little-endian Float32 BLOB for SQLite storage.
    var blob: Data { withUnsafeBytes { Data($0) } }

    /// Unpack from a little-endian Float32 BLOB. Returns an empty vector for a truncated/misaligned
    /// BLOB (e.g. a write interrupted by a crash) instead of trapping in bindMemory.
    init(blob: Data) {
        let stride = MemoryLayout<Float>.stride
        guard blob.count >= stride, blob.count % stride == 0 else { self = []; return }
        let count = blob.count / stride
        self = blob.withUnsafeBytes { raw in
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBytes { $0.copyBytes(from: raw) }   // tolerates misalignment
            return out
        }
    }
}

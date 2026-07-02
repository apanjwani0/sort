import Foundation

/// User corrections expressed as index pairs into the input vector array.
public struct ClusterConstraints: Sendable {
    public var mustLink: [(Int, Int)]
    public var cannotLink: [(Int, Int)]
    public init(mustLink: [(Int, Int)] = [], cannotLink: [(Int, Int)] = []) {
        self.mustLink = mustLink
        self.cannotLink = cannotLink
    }
    public var isEmpty: Bool { mustLink.isEmpty && cannotLink.isEmpty }
}

/// Constrained UPGMA (average-linkage) agglomerative clustering on cosine distance.
///
/// Auto-discovers the number of people (D3): merge the closest two clusters until the nearest pair
/// exceeds `threshold`. `cannotLink` pairs are never placed together (enforced during every merge),
/// and `mustLink` pairs are pre-merged regardless of distance — this is how the "Same/Different
/// person?" corrections survive re-clustering.
///
/// O(n²) memory / ~O(n³) time — fine for v1 libraries and tests; large-library scaling (nearest-
/// centroid incremental + ANN) is a later milestone.
public enum AgglomerativeClustering {
    /// Returns a contiguous cluster label (0…k-1) for each input vector.
    public static func cluster(vectors: [[Float]], threshold: Float,
                               constraints: ClusterConstraints = .init()) -> [Int] {
        let n = vectors.count
        if n == 0 { return [] }
        if n == 1 { return [0] }

        let norm = vectors.map { Vector.l2normalized($0) }
        var members: [[Int]] = (0..<n).map { [$0] }
        var active = Array(0..<n)

        // UPGMA distance matrix between active clusters (indexed by original cluster id).
        var dist = Array(repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = 1 - Vector.dot(norm[i], norm[j])
                dist[i][j] = d
                dist[j][i] = d
            }
        }

        func key(_ a: Int, _ b: Int) -> Int { let lo = min(a, b), hi = max(a, b); return lo * n + hi }
        var cannot = Set<Int>()
        for (a, b) in constraints.cannotLink where a != b { cannot.insert(key(a, b)) }

        func violates(_ ci: Int, _ cj: Int) -> Bool {
            guard !cannot.isEmpty else { return false }
            for a in members[ci] {
                for b in members[cj] where cannot.contains(key(a, b)) { return true }
            }
            return false
        }

        func merge(_ ci: Int, _ cj: Int) {
            let ni = members[ci].count, nj = members[cj].count
            for ck in active where ck != ci && ck != cj {
                let nd = (Float(ni) * dist[ci][ck] + Float(nj) * dist[cj][ck]) / Float(ni + nj)
                dist[ci][ck] = nd
                dist[ck][ci] = nd
            }
            members[ci].append(contentsOf: members[cj])
            members[cj] = []
            active.removeAll { $0 == cj }
        }

        func clusterOf(_ idx: Int) -> Int? { active.first { members[$0].contains(idx) } }

        // Pre-merge must-link pairs (cannot-link takes precedence on conflict). A pair referencing an
        // index that isn't in any active cluster (e.g. a stale constraint) is skipped, not trapped.
        for (a, b) in constraints.mustLink where a != b {
            guard let ci = clusterOf(a), let cj = clusterOf(b) else { continue }
            if ci != cj && !violates(ci, cj) { merge(ci, cj) }
        }

        // Merge the closest admissible pair until none is below threshold.
        while true {
            var best: (d: Float, ci: Int, cj: Int)?
            for ii in 0..<active.count {
                for jj in (ii + 1)..<active.count {
                    let ci = active[ii], cj = active[jj]
                    let d = dist[ci][cj]
                    if d < threshold, !violates(ci, cj), best == nil || d < best!.d {
                        best = (d, ci, cj)
                    }
                }
            }
            guard let best else { break }
            merge(best.ci, best.cj)
        }

        var labels = [Int](repeating: -1, count: n)
        for (label, ci) in active.enumerated() {
            for m in members[ci] { labels[m] = label }
        }
        return labels
    }

    /// Post-pass: greedily merge clusters whose CENTROIDS are within `threshold`, even when
    /// average-linkage left them split. This is what consolidates the same person across varied
    /// poses (sub-clusters with close centroids but a high average cross-distance). Cannot-link
    /// pairs (user "Different" decisions) block a merge; must-links are already baked into `groups`.
    public static func centroidMerge(groups: [[Int]], vectors: [[Float]], threshold: Float,
                                     cannotLink: [(Int, Int)]) -> [[Int]] {
        var groups = groups
        guard groups.count > 1 else { return groups }
        var centroids = groups.map { Vector.l2normalized(Vector.mean($0.map { vectors[$0] })) }

        let n = vectors.count
        func key(_ a: Int, _ b: Int) -> Int { let lo = min(a, b), hi = max(a, b); return lo * n + hi }
        var cannot = Set<Int>()
        for (a, b) in cannotLink where a != b { cannot.insert(key(a, b)) }
        func blocked(_ gi: Int, _ gj: Int) -> Bool {
            guard !cannot.isEmpty else { return false }
            for a in groups[gi] { for b in groups[gj] where cannot.contains(key(a, b)) { return true } }
            return false
        }

        while groups.count > 1 {
            var best: (d: Float, i: Int, j: Int)?
            for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let d = 1 - Vector.dot(centroids[i], centroids[j])
                    if d < threshold, best == nil || d < best!.d, !blocked(i, j) { best = (d, i, j) }
                }
            }
            guard let b = best else { break }
            groups[b.i].append(contentsOf: groups[b.j])
            centroids[b.i] = Vector.l2normalized(Vector.mean(groups[b.i].map { vectors[$0] }))
            groups.remove(at: b.j)
            centroids.remove(at: b.j)
        }
        return groups
    }
}

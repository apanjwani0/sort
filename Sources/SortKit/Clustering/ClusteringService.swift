import Foundation

public struct ClusteringConfig: Sendable {
    /// Max cosine distance to merge. Lower = more conservative / more over-split (D4).
    /// ArcFace embeddings typically separate identities around 0.35–0.45; tune on real photos.
    public var threshold: Float
    /// Minimum faces a cluster needs to become its own person. Smaller clusters are left unassigned
    /// (their faces stay out of named people — "stay in Unnamed"). Default 1 keeps every cluster.
    public var minGroup: Int
    /// Cosine-distance threshold for PET clustering. Pets cluster in a separate embedding space
    /// (Vision feature-print) that separates individuals less sharply than human ArcFace, so this is
    /// looser than `threshold`; exposed in Settings to tune on real pet photos.
    public var petThreshold: Float
    public init(threshold: Float = 0.4, minGroup: Int = 1, petThreshold: Float = 0.5) {
        self.threshold = threshold
        self.minGroup = minGroup
        self.petThreshold = petThreshold
    }
}

public struct ReclusterReport: Sendable, Equatable {
    public var faces = 0
    public var people = 0
    public var reusedPeople = 0
    public var newPeople = 0
}

/// Ties the clustering algorithm to the database and — critically — keeps `person.id` STABLE across
/// rescans. After a batch re-cluster, each resulting group is mapped back to the existing person that
/// most of its faces already belonged to (claimed once, largest groups first); only genuinely new
/// groups mint new ids. Names, covers, and hidden flags on reused people are preserved. (D3)
public struct ClusteringService: Sendable {
    let faces: FaceRepository
    let persons: PersonRepository
    let constraints: ConstraintRepository
    var config: ClusteringConfig

    public init(db: AppDatabase, config: ClusteringConfig = .init()) {
        self.faces = FaceRepository(db)
        self.persons = PersonRepository(db)
        self.constraints = ConstraintRepository(db)
        self.config = config
    }

    @discardableResult
    public func recluster(now: Double) throws -> ReclusterReport {
        let allFaces = try faces.withEmbeddings()
        var report = ReclusterReport()
        report.faces = allFaces.count

        // No faces: clear out all people.
        guard !allFaces.isEmpty else {
            try faces.assign(personId: nil, faceIds: try faces.all().compactMap(\.id))
            try persons.recomputeFaceCounts()
            _ = try persons.pruneEmpty()
            return report
        }

        let allConstraints = try constraints.all()
        var claimed = Set<Int64>()
        // Cluster each identity-kind in its OWN embedding space (human ArcFace vs pet feature-print),
        // AND never compare embeddings of different model/dimension — a mixed-dimension library (e.g.
        // some faces embedded with ArcFace, some with the Vision fallback) would otherwise feed
        // unequal-length vectors into cosine distance. Partitioning by (kind, model, dim) keeps every
        // comparison commensurable. For a normal single-model library this is exactly one human group,
        // so human grouping behavior is unchanged.
        let partitions = Dictionary(grouping: allFaces) { f in
            "\(f.kind ?? "human")\u{1}\(f.embeddingModel ?? "")\u{1}\(f.embeddingDim ?? 0)"
        }
        for (_, kindFaces) in partitions {
            let isHuman = (kindFaces.first?.kind ?? "human") == "human"
            let r = try assign(kindFaces,
                               threshold: isHuman ? config.threshold : config.petThreshold,
                               minGroup: isHuman ? config.minGroup : 1,
                               personKind: isHuman ? nil : kindFaces.first?.kind,
                               allConstraints: allConstraints, claimed: &claimed, now: now)
            report.reusedPeople += r.reused
            report.newPeople += r.new
        }

        try persons.recomputeFaceCounts()
        _ = try persons.pruneEmpty()
        report.people = report.reusedPeople + report.newPeople   // excludes clusters dropped by minGroup
        return report
    }

    /// Clustering entry point for the scan pipeline. Picks the cheapest correct path:
    ///   • first clustering, or a small library (≤ `fullReclusterLimit` faces) → a full `recluster`
    ///     (cheap at that size, and gives the best grouping — centroid-merge, constraint re-apply);
    ///   • a large existing library → **incremental**: assign only the new (unclustered) faces to the
    ///     nearest existing person centroid within threshold, and cluster the leftovers into new people.
    /// Incremental is O(newFaces × people) instead of the full O(n²) matrix, so adding a few photos to a
    /// 50k-face library no longer rebuilds everything. Existing people stay stable; corrections still go
    /// through the full `recluster` (so constraints and merges are applied globally).
    @discardableResult
    public func clusterAfterScan(now: Double, fullReclusterLimit: Int = 2000) throws -> ReclusterReport {
        let allFaces = try faces.withEmbeddings()
        let havePeople = try !persons.all().isEmpty
        if !havePeople || allFaces.count <= fullReclusterLimit {
            return try recluster(now: now)
        }
        return try assignNewFaces(allFaces, now: now)
    }

    /// Incremental pass: assign each unclustered face to the nearest existing same-kind/-dim person
    /// centroid (within threshold), then cluster whatever's left into new people. Never moves a
    /// face that's already assigned — so every user correction (merge, split, "Different") is
    /// preserved: a scan can only place NEW faces, never re-merge or re-split existing people. Full
    /// constraint re-application (must-/cannot-link) runs in `recluster` (first/small scans and
    /// Settings → Regroup); brand-new faces carry no constraints, so this path has none to apply.
    private func assignNewFaces(_ allFaces: [Face], now: Double) throws -> ReclusterReport {
        var report = ReclusterReport()
        report.faces = allFaces.count
        let usable = allFaces.filter { $0.id != nil && !$0.vector.isEmpty }
        let partitions = Dictionary(grouping: usable) { f in
            "\(f.kind ?? "human")\u{1}\(f.embeddingModel ?? "")\u{1}\(f.embeddingDim ?? 0)"
        }
        let existing = try persons.all()
        for (_, partFaces) in partitions {
            let isHuman = (partFaces.first?.kind ?? "human") == "human"
            let threshold = isHuman ? config.threshold : config.petThreshold
            let personKind: String? = isHuman ? nil : partFaces.first?.kind
            try assignNew(partFaces, existing: existing, threshold: threshold,
                          minGroup: isHuman ? config.minGroup : 1, personKind: personKind,
                          now: now, newPeople: &report.newPeople)
        }
        try persons.recomputeFaceCounts()
        _ = try persons.pruneEmpty()
        report.people = try persons.all(includeHidden: false).count   // global count after the pass
        return report
    }

    private func assignNew(_ partFaces: [Face], existing: [Person], threshold: Float, minGroup: Int,
                           personKind: String?, now: Double, newPeople: inout Int) throws {
        let newFaces = partFaces.filter { $0.personId == nil }
        guard !newFaces.isEmpty else { return }

        // Existing same-kind person centroids to match against.
        let centroids: [(id: Int64, vec: [Float])] = existing.compactMap { p in
            guard p.kind == personKind, let id = p.id, let c = p.centroid else { return nil }
            let v = [Float](blob: c)
            return v.isEmpty ? nil : (id, v)
        }

        // Attach a new face to an existing person only on a CONFIDENT nearest-centroid match: within
        // threshold AND clearly closer than the runner-up. The incremental attach has none of the
        // batch path's average-linkage / centroid-merge safety, so a face near-equidistant from two
        // similar people would otherwise be grabbed by whichever centroid is a hair closer. Ambiguous
        // faces fall through to the leftover pass and form their own group, which the user merges in
        // one tap — the conservative / over-split bias (D4).
        // ponytail: `margin` is a tuned ceiling like `threshold`; lower it if rescans over-split.
        let margin = threshold * 0.25
        var touched = Set<Int64>()
        var unmatched: [Face] = []
        for face in newFaces {
            let v = Vector.l2normalized(face.vector)
            var best: (id: Int64, d: Float)?
            var runnerUp = Float.greatestFiniteMagnitude
            for c in centroids where c.vec.count == v.count {
                let d = 1 - Vector.dot(v, c.vec)
                if best == nil || d < best!.d { runnerUp = best?.d ?? runnerUp; best = (c.id, d) }
                else if d < runnerUp { runnerUp = d }
            }
            if let best, let fid = face.id, best.d < threshold, runnerUp - best.d >= margin {
                try faces.assign(personId: best.id, faceIds: [fid])
                touched.insert(best.id)
            } else {
                unmatched.append(face)
            }
        }

        // Cluster the leftovers among themselves into NEW people.
        if !unmatched.isEmpty {
            let vectors = unmatched.map { Vector.l2normalized($0.vector) }
            let labels = AgglomerativeClustering.cluster(vectors: vectors, threshold: threshold)
            var groups: [Int: [Int]] = [:]
            for (i, l) in labels.enumerated() { groups[l, default: []].append(i) }
            for idxs in groups.values {
                let faceIds = idxs.compactMap { unmatched[$0].id }
                guard idxs.count >= minGroup else { try faces.assign(personId: nil, faceIds: faceIds); continue }
                let pid = try persons.create(kind: personKind, now: now).id!
                try faces.assign(personId: pid, faceIds: faceIds)
                touched.insert(pid)
                newPeople += 1
            }
        }

        // Refresh the centroid of every person that gained a face.
        for pid in touched {
            let vecs = try faces.forPerson(pid).compactMap { $0.embedding }
                .map { [Float](blob: $0) }.filter { !$0.isEmpty }
            try persons.updateCentroid(pid, centroid: Vector.centroidBlob(vecs), now: now)
        }
    }

    /// Cluster one kind's faces and map groups onto persons (reuse-by-majority, stable ids,
    /// centroid-merge, minGroup drop). For human faces this is byte-for-byte the original behavior.
    private func assign(_ rawFaces: [Face], threshold: Float, minGroup: Int, personKind: String?,
                        allConstraints: [FaceConstraint], claimed: inout Set<Int64>,
                        now: Double) throws -> (reused: Int, new: Int) {
        // Only faces with a persisted id and a non-empty (well-formed) embedding can be clustered;
        // a corrupt/truncated BLOB decodes to an empty vector (see Array(blob:)) and is dropped here
        // rather than poisoning the distance matrix.
        let kindFaces = rawFaces.filter { $0.id != nil && !$0.vector.isEmpty }
        guard !kindFaces.isEmpty else { return (0, 0) }
        let vectors = kindFaces.map { Vector.l2normalized($0.vector) }
        let indexOfFace = Dictionary(kindFaces.enumerated().map { ($1.id!, $0) },
                                     uniquingKeysWith: { first, _ in first })

        var cc = ClusterConstraints()
        for c in allConstraints {
            guard let i = indexOfFace[c.faceAId], let j = indexOfFace[c.faceBId] else { continue }
            switch c.kind {
            case .mustLink: cc.mustLink.append((i, j))
            case .cannotLink: cc.cannotLink.append((i, j))
            }
        }

        let labels = AgglomerativeClustering.cluster(vectors: vectors, threshold: threshold, constraints: cc)
        var groups: [Int: [Int]] = [:]
        for (idx, label) in labels.enumerated() { groups[label, default: []].append(idx) }
        // Centroid-merge consolidates a person's over-split sub-groups, but it compares CENTROIDS
        // only — with no linkage safety it can fuse two different people whose centroids drift close.
        // ArcFace separates identities at ≥~0.45 while same-identity sub-clusters sit ≤~0.30, so merge
        // on a TIGHTER threshold than the clustering pass: real over-splits still collapse, the
        // ambiguous 0.3–0.45 band stays split (conservative / over-split bias, D4).
        // ponytail: 0.7 is a tuned ratio; raise toward 1.0 if real photos leave a person over-split.
        let mergeThreshold = threshold * 0.7
        let merged = AgglomerativeClustering.centroidMerge(
            groups: Array(groups.values), vectors: vectors, threshold: mergeThreshold, cannotLink: cc.cannotLink)

        var reused = 0, new = 0
        for group in merged.sorted(by: { $0.count > $1.count }) {
            let faceIds = group.map { kindFaces[$0].id! }
            guard group.count >= minGroup else {
                try faces.assign(personId: nil, faceIds: faceIds)
                continue
            }
            var votes: [Int64: Int] = [:]
            for idx in group { if let pid = kindFaces[idx].personId { votes[pid, default: 0] += 1 } }
            let majority = votes.sorted { $0.value > $1.value }.first?.key

            let personId: Int64
            if let majority, !claimed.contains(majority), try persons.find(majority) != nil {
                personId = majority
                reused += 1
            } else {
                personId = try persons.create(kind: personKind, now: now).id!
                new += 1
            }
            claimed.insert(personId)
            try faces.assign(personId: personId, faceIds: faceIds)
            try persons.updateCentroid(personId, centroid: Vector.centroidBlob(group.map { vectors[$0] }), now: now)
        }
        return (reused, new)
    }

    // MARK: - User corrections (the "Same or different person?" flow)

    /// Record "Same" and immediately reflect it (re-cluster applies the must-link).
    public func markSame(faceA: Int64, faceB: Int64, now: Double) throws {
        try constraints.add(faceA: faceA, faceB: faceB, kind: .mustLink, now: now)
    }

    /// Record "Different".
    public func markDifferent(faceA: Int64, faceB: Int64, now: Double) throws {
        try constraints.add(faceA: faceA, faceB: faceB, kind: .cannotLink, now: now)
    }
}

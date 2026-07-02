import Foundation

/// An order-independent pair of face ids (so a cannot-link recorded as (a,b) matches a lookup of (b,a)).
struct UnorderedPair: Hashable {
    let a: Int64, b: Int64
    init(_ x: Int64, _ y: Int64) { a = min(x, y); b = max(x, y) }
}

/// A borderline pair the UI should ask the user about ("Same or different person?").
public struct MergeSuggestion: Sendable, Equatable {
    public var personA: Person
    public var personB: Person
    public var distance: Float
    public init(personA: Person, personB: Person, distance: Float) {
        self.personA = personA
        self.personB = personB
        self.distance = distance
    }
}

/// Drives the "Same or different person?" review flow. Finds people whose centroids are close enough
/// to *maybe* be the same person (conservative clustering over-splits by design, D4), so the user can
/// confirm a merge with one tap. Confirmations are recorded as must-/cannot-link constraints and
/// survive future re-clustering.
public struct ReviewService: Sendable {
    let persons: PersonRepository
    let faces: FaceRepository
    let constraints: ConstraintRepository
    let clustering: ClusteringService

    public init(db: AppDatabase, config: ClusteringConfig = .init()) {
        self.persons = PersonRepository(db)
        self.faces = FaceRepository(db)
        self.constraints = ConstraintRepository(db)
        self.clustering = ClusteringService(db: db, config: config)
    }

    /// Person pairs whose centroid cosine distance is within `maxDistance`, closest first.
    /// Pairs the user already marked "Different" (a cannot-link on their representative faces) are
    /// excluded, so answering "Different" removes the pair from the queue instead of re-suggesting it.
    public func suggestMerges(maxDistance: Float = 0.5, limit: Int = 20) throws -> [MergeSuggestion] {
        let candidates = try persons.all(includeHidden: false).filter { $0.centroid != nil }

        // Representative face per candidate, and the set of cannot-linked face pairs.
        var rep: [Int64: Int64] = [:]
        for c in candidates {
            if let id = c.id, let face = try representativeFace(of: id)?.id { rep[id] = face }
        }
        let dismissed = Set(try constraints.all()
            .filter { $0.kind == .cannotLink }
            .map { UnorderedPair($0.faceAId, $0.faceBId) })

        var suggestions: [MergeSuggestion] = []
        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                // Never compare across kinds — human ArcFace and pet feature-print centroids live in
                // different (incompatible) vector spaces.
                guard (candidates[i].kind ?? "human") == (candidates[j].kind ?? "human") else { continue }
                // Best-effort "Different" filter: skip only when both reps exist and were dismissed.
                if let ra = candidates[i].id.flatMap({ rep[$0] }),
                   let rb = candidates[j].id.flatMap({ rep[$0] }),
                   dismissed.contains(UnorderedPair(ra, rb)) { continue }
                let d = Vector.cosineDistance([Float](blob: candidates[i].centroid!),
                                              [Float](blob: candidates[j].centroid!))
                if d <= maxDistance {
                    suggestions.append(MergeSuggestion(personA: candidates[i], personB: candidates[j], distance: d))
                }
            }
        }
        return Array(suggestions.sorted { $0.distance < $1.distance }.prefix(limit))
    }

    /// A face to show for a person (its cover, else any member face).
    public func representativeFace(of personId: Int64) throws -> Face? {
        if let cover = try persons.find(personId)?.coverFaceId, let face = try faces.find(cover) {
            return face
        }
        return try faces.forPerson(personId).first
    }

    /// User answered "Same" for two people. Applies the merge DIRECTLY — reassign the smaller group's
    /// faces onto the larger, recompute its centroid, drop the empty one — instead of a full re-cluster.
    /// A full re-cluster re-clustered every face from scratch and, on an over-split library, re-split the
    /// pair right back (and was slow), so the merge never "stuck" and the same pair kept reappearing.
    /// The must-link is still recorded so a future full re-cluster (after a rescan) keeps them together.
    public func confirmSame(_ a: Person, _ b: Person, now: Double) throws {
        guard let aid = a.id, let bid = b.id, aid != bid else { return }
        let survivor = a.faceCount >= b.faceCount ? aid : bid
        let absorbed = survivor == aid ? bid : aid

        if let fa = try representativeFace(of: aid)?.id, let fb = try representativeFace(of: bid)?.id {
            try clustering.markSame(faceA: fa, faceB: fb, now: now)   // persist the decision
        }
        let absorbedFaceIds = try faces.forPerson(absorbed).compactMap(\.id)
        try faces.assign(personId: survivor, faceIds: absorbedFaceIds)
        try persons.recomputeFaceCounts()
        let vecs = try faces.forPerson(survivor).compactMap { $0.embedding }
            .map { [Float](blob: $0) }.filter { !$0.isEmpty }
        try persons.updateCentroid(survivor, centroid: Vector.centroidBlob(vecs), now: now)
        _ = try persons.pruneEmpty()   // `absorbed` now has 0 faces → removed
    }

    /// User answered "Different": record a cannot-link so they stay apart on every future re-cluster.
    /// No re-cluster here — they're already separate people, so the constraint is all that's needed
    /// (and it keeps Review instant instead of running an O(n²) pass per click).
    public func confirmDifferent(_ a: Person, _ b: Person, now: Double) throws {
        guard let aid = a.id, let bid = b.id,
              let fa = try representativeFace(of: aid)?.id,
              let fb = try representativeFace(of: bid)?.id else { return }
        try clustering.markDifferent(faceA: fa, faceB: fb, now: now)
    }
}

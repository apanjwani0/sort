import AppKit
import SwiftUI
import SortKit

/// Observable state for the GUI. Wraps the SortKit engine; all heavy work runs off the main actor
/// and results are published back on the main actor. Originals are never modified.
/// Which top-level screen is showing (matches the wireframe's Photos | Collections toggle).
enum AppScreen: String, Sendable { case collections, photos }

/// Left-sidebar selection on the Library screen (matches wireframe screen A's LIBRARY nav).
enum LibraryNav: String, Sendable, Hashable { case people, allPhotos, recentlyAdded }

@MainActor
final class AppStore: ObservableObject {
    @Published var screen: AppScreen = .photos          // land on Library by default (per product call)
    @Published var libraryNav: LibraryNav = .people     // left-sidebar selection on the Library screen
    @Published var librarySearch = ""                   // sidebar search box
    @Published var sourcePhotoCounts: [Int64: Int] = [:] // photos per root, for the SOURCES list
    @Published var people: [Person] = []
    @Published var selectedPersonID: Int64?
    @Published var photos: [Photo] = []           // photos of the selected person
    @Published var photoCountByPerson: [Int64: Int] = [:]
    @Published var roots: [ScannedRoot] = []      // folders/drives we have access to (#7)
    @Published var offlineRootIDs: Set<Int64> = [] // sources whose volume is currently unmounted
    @Published var categoryCounts = IndexService.CategoryCounts()   // F4
    @Published var browsingCategory: IndexService.PhotoCategory?    // category browse overlay
    @Published var duplicateGroups: [[Photo]] = []                  // near-identical photo sets
    @Published var browsingDuplicates = false                       // Duplicates browse overlay
    @Published var suggestions: [MergeSuggestion] = []
    @Published var learnedCorrections = 0     // Same / Different / Not-this-person decisions learned
    @Published var reviewedCount = 0          // pairs acted on this review session (drives "Pair N of M")
    @Published var isWorking = false
    @Published var statusText = "Open a folder or drive to begin."
    @Published var progressFraction: Double?   // 0…1 for a determinate bar; nil = indeterminate

    /// Person-id pairs the user skipped or acted on this Review session, so a post-action queue
    /// refresh never resurfaces them ("repeating"). Cleared when Review is reopened.
    private var dismissedPairs: Set<String> = []
    private func pairKey(_ a: Person, _ b: Person) -> String {
        let x = a.id ?? -1, y = b.id ?? -1
        return "\(min(x, y))-\(max(x, y))"
    }

    let imageLoader = PhotoImageLoader()

    private let db: AppDatabase
    private let index: IndexService
    private let facesRepo: FaceRepository
    private let photosRepo: PhotoRepository
    private let personsRepo: PersonRepository
    /// Security-scoped folder URLs we hold access to for the app's lifetime (sandbox).
    private var scopedURLs: [URL] = []

    /// Built per use so every review re-cluster uses the same settings (threshold/minGroup) as a
    /// full scan — otherwise corrections re-clustered with different knobs and people "moved" (the
    /// minGroup-3-on-scan vs minGroup-1-on-review bug).
    private var review: ReviewService { ReviewService(db: db, config: Self.clusteringConfigFromSettings()) }

    init() {
        // `SORT_FRESH=1 swift run sort-app` → wipe the index + onboarding flag for a clean test run.
        if ProcessInfo.processInfo.environment["SORT_FRESH"] != nil { Self.wipeForFreshStart() }
        let (database, recoveryNote) = Self.openDatabaseRecovering()
        db = database
        index = IndexService(db: db)
        facesRepo = FaceRepository(db)
        photosRepo = PhotoRepository(db)
        personsRepo = PersonRepository(db)
        startAccessingSavedRoots()   // restore folder access from saved bookmarks (no re-prompt)
        refreshRoots()               // also starts the folder watcher if "watch sources" is on
        Task { await reloadPeople() }
        reloadDuplicates()
        if let recoveryNote { statusText = recoveryNote }
        // Re-evaluate the watcher when the "watch sources" toggle changes (cheap — no-op if unchanged).
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateFolderWatch() }
        }
    }

    /// Open the on-disk index, recovering instead of crashing. A transient lock or a corrupt DB
    /// (e.g. an index whose write was interrupted by an earlier crash) used to `fatalError` here, so
    /// the user couldn't even relaunch to Reset. Now we move the corrupt file (+ its WAL/SHM) aside and
    /// retry, falling back to a temporary in-memory index as a last resort — the app always launches.
    private static func openDatabaseRecovering() -> (AppDatabase, String?) {
        guard let url = try? AppDatabase.defaultURL() else {
            return (try! AppDatabase.inMemory(), "Couldn't locate app storage — using a temporary index.")
        }
        if let db = try? AppDatabase.onDisk(at: url) { return (db, nil) }
        for suffix in ["", "-wal", "-shm"] {
            let f = URL(fileURLWithPath: url.path + suffix)
            try? FileManager.default.moveItem(at: f, to: f.appendingPathExtension("corrupt"))
        }
        if let db = try? AppDatabase.onDisk(at: url) {
            return (db, "The index was corrupted and has been reset — rescan your folders.")
        }
        // ponytail: in-memory open only fails on a code/migration bug (never on the disk states above),
        // so a trap here is a true unrecoverable last resort, not the transient case we're handling.
        return (try! AppDatabase.inMemory(), "Couldn't open the index — using a temporary one. Rescan your folders.")
    }

    /// Re-open security-scoped access to every folder the user previously granted, so reads and
    /// trashing work across launches with no new permission prompt (sandbox).
    private func startAccessingSavedRoots() {
        let repo = RootRepository(db)
        for root in (try? repo.all()) ?? [] {
            guard let data = root.bookmark, let resolved = try? BookmarkStore.resolve(data) else { continue }
            let started = resolved.url.startAccessingSecurityScopedResource()
            if started { scopedURLs.append(resolved.url) }
            // A stale bookmark still often grants access this once; recreate + persist it while we hold
            // the scope so the NEXT launch resolves cleanly instead of silently losing access (which
            // would surface as "0 people / everything in No faces").
            if resolved.isStale, started, let fresh = try? BookmarkStore.makeBookmark(for: resolved.url) {
                var updated = root
                updated.bookmark = fresh
                try? repo.update(updated)
            }
        }
    }

    /// Distinct photos a person appears in (shown in the sidebar — #1).
    func photoCount(_ person: Person) -> Int {
        person.id.flatMap { photoCountByPerson[$0] } ?? 0
    }

    func url(for photo: Photo) -> URL? { imageLoader.url(for: photo) }

    // MARK: - Selection / delete / highlight (detail screen)

    @Published var selection: Set<Int64> = []   // selected photo ids in the person detail
    @Published var selectMode = false            // tap-to-select without modifiers
    @Published var highlightFaces = false        // #6 overlay toggle

    /// Distinct source folders the selected person's photos come from ("from N folders").
    var selectedFolderCount: Int { Set(photos.map { $0.rootId }).count }

    /// Normalized face boxes (Vision bottom-left origin) for a person, grouped by photo (#6).
    func highlightRects(forPerson id: Int64) -> [Int64: [CGRect]] {
        guard let faces = try? facesRepo.forPerson(id) else { return [:] }
        var map: [Int64: [CGRect]] = [:]
        for f in faces {
            map[f.photoId, default: []].append(
                CGRect(x: f.bboxX, y: f.bboxY, width: f.bboxW, height: f.bboxH))
        }
        return map
    }

    /// Move photos to the Trash (recoverable, D7) off the main actor, then refresh.
    func deletePhotos(_ ids: [Int64]) {
        guard !ids.isEmpty, !isWorking else { return }
        isWorking = true
        statusText = "Moving \(ids.count) photo\(ids.count == 1 ? "" : "s") to Trash…"
        let svc = index
        Task {
            let report = try? await Task.detached {
                try svc.deletePhotos(ids: ids, now: Date().timeIntervalSince1970)
            }.value
            clearSelection()
            await reloadPeople()
            await reloadSuggestions()
            reloadDuplicates()
            if let r = report {
                var msg = "Moved \(r.trashed) to Trash"
                if r.failed > 0 { msg += " · \(r.failed) couldn't be moved" }
                statusText = msg
            } else {
                statusText = "Delete failed"
            }
            isWorking = false
        }
    }

    /// Export (copy) the given photos' originals to a folder the user picks, off the main actor. The
    /// open-panel selection IS the sandbox grant for writing there; originals are never moved or
    /// modified. No selection → exports the whole current view.
    func exportPhotos(_ ids: [Int64]) {
        guard !ids.isEmpty, !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to copy \(ids.count) photo\(ids.count == 1 ? "" : "s") into. Originals stay put."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        isWorking = true
        statusText = "Exporting \(ids.count) photo\(ids.count == 1 ? "" : "s")…"
        let svc = index
        Task {
            let report = try? await Task.detached {
                let didStart = dest.startAccessingSecurityScopedResource()
                defer { if didStart { dest.stopAccessingSecurityScopedResource() } }
                return try svc.exportPhotos(ids: ids, to: dest)
            }.value
            clearSelection()
            if let r = report {
                var msg = "Exported \(r.exported) to “\(dest.lastPathComponent)”"
                if r.missing > 0 { msg += " · \(r.missing) missing" }
                if r.failed > 0 { msg += " · \(r.failed) failed" }
                statusText = msg
            } else {
                statusText = "Export failed"
            }
            isWorking = false
        }
    }

    // MARK: - Multi-person filter ("photos with all of N people" + "only them")

    @Published var peopleFilter: Set<Int64> = []        // people ⌘-clicked to compare
    @Published var peopleFilterExclusive = false        // "only them" — no other known person present
    @Published var browsingPeopleFilter = false         // results overlay open

    func togglePersonFilter(_ id: Int64) {
        if peopleFilter.contains(id) { peopleFilter.remove(id) } else { peopleFilter.insert(id) }
    }
    func clearPeopleFilter() { peopleFilter.removeAll(); peopleFilterExclusive = false }

    /// Open the AND-intersection of the filtered people (photos containing ALL of them) as an overlay.
    func openPeopleFilter() {
        guard !peopleFilter.isEmpty else { return }
        loadPeopleFilterPhotos()
        clearSelection(); closeViewer()
        browsingPeopleFilter = true
    }

    func setPeopleFilterExclusive(_ on: Bool) {
        peopleFilterExclusive = on
        if browsingPeopleFilter { loadPeopleFilterPhotos() }   // re-filter live
    }

    private func loadPeopleFilterPhotos() {
        photos = online((try? index.photos(forPeople: Array(peopleFilter),
                                           exclusive: peopleFilterExclusive)) ?? [])
    }

    func closePeopleFilter() {
        browsingPeopleFilter = false
        clearSelection(); closeViewer()
        loadLibraryPhotos()
    }

    /// Display names of the filtered people, in a stable order, for the overlay title.
    var peopleFilterNames: [String] {
        people.filter { $0.id.map(peopleFilter.contains) ?? false }
            .map { $0.displayName ?? "Unnamed" }
    }

    // MARK: - Scanning

    /// Read the clustering knobs the Settings window persists via @AppStorage. Defaults match
    /// SettingsView so an unopened Settings window still produces the documented behavior.
    static func clusteringConfigFromSettings() -> ClusteringConfig {
        let d = UserDefaults.standard
        // 0.45: with 5-point ArcFace alignment, same-identity faces sit ≤0.30 and distinct people
        // ≥~0.45 on real photos; 0.45 heals over-splits without the over-merge that starts at ~0.50.
        let threshold = d.object(forKey: "clusterThreshold") as? Double ?? 0.45
        // Default 1: keep every cluster. minGroup>1 silently unassigns small clusters, which read as
        // "my people disappeared". Let the user merge over-splits in Review instead of hiding them.
        let minGroup = d.object(forKey: "minGroup") as? Int ?? 1
        let petThreshold = d.object(forKey: "petThreshold") as? Double ?? 0.5
        return ClusteringConfig(threshold: Float(threshold), minGroup: max(1, minGroup),
                                petThreshold: Float(petThreshold))
    }

    /// Delete the on-disk index + reset onboarding/settings before the DB opens (env-var test path).
    static func wipeForFreshStart() {
        if let url = try? AppDatabase.defaultURL() {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        for key in ["didOnboard", "groupingModel", "clusterThreshold", "minGroup", "watchSources"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// In-app "start fresh": untrack every folder (cascades photos/faces/people/constraints away),
    /// drop folder access, and return to onboarding. Files on disk are never touched.
    func resetEverything() {
        guard !isWorking else { return }
        for root in roots { if let id = root.id { _ = try? index.removeRoot(id, now: Date().timeIntervalSince1970) } }
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        UserDefaults.standard.set(false, forKey: "didOnboard")
        screen = .photos; libraryNav = .people; selectedPersonID = nil
        browsingCategory = nil; clearSelection(); closeViewer()
        dismissedPairs.removeAll()
        refreshRoots(); Task { await reloadPeople(); await reloadSuggestions() }
        statusText = "Reset — open a folder to start fresh."
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder or drive — Sort gets read & write access to just that folder."
        panel.prompt = "Grant & Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanFolder(at: url)
    }

    /// Grant + scan a folder URL (from the open panel or an onboarding drop). The URL selection IS
    /// the sandbox grant — persist it as a read-write security-scoped bookmark so access survives
    /// relaunches with no further prompts, start using it now, then scan.
    func scanFolder(at url: URL) {
        guard url.hasDirectoryPath else { return }
        let path = url.standardizedFileURL.path
        let bookmark = try? BookmarkStore.makeBookmark(for: url)
        _ = try? RootRepository(db).add(displayPath: path, volumeUUID: nil,
                                        bookmark: bookmark, now: Date().timeIntervalSince1970)
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        scan(path: path)
    }

    func scan(path: String) { runScan(paths: [path]) }

    /// One-click rescan of every tracked source. Offline drives are skipped (their path can't be
    /// read); the rest scan sequentially because the index writes to a single DB.
    func scanAll() {
        runScan(paths: roots.compactMap { r in
            if let id = r.id, offlineRootIDs.contains(id) { return nil }
            return r.displayPath
        })
    }

    private func runScan(paths: [String]) {
        guard !isWorking, !paths.isEmpty else { return }
        isWorking = true
        progressFraction = nil
        let idx = index
        let embedder = EmbedderFactory.makeDefault()
        let clustering = Self.clusteringConfigFromSettings()
        // Bridge the engine's sync onProgress (called off the main actor) to the main actor. The
        // continuation is Sendable, so the detached closure captures only Sendable values.
        let (stream, cont) = AsyncStream.makeStream(of: IndexService.Progress.self)
        let consumer = Task { @MainActor [weak self] in
            for await p in stream { self?.applyProgress(p) }
        }
        Task {
            var people = 0, faces = 0, photos = 0, failures = 0, videos = 0
            var failure: Error?
            for (i, path) in paths.enumerated() {
                let prefix = paths.count > 1 ? "[\(i + 1)/\(paths.count)] " : ""
                statusText = "\(prefix)Scanning \(URL(fileURLWithPath: path).lastPathComponent)…"
                do {
                    let r = try await Task.detached {
                        try idx.index(rootPath: path, embedder: embedder, clustering: clustering,
                                      now: Date().timeIntervalSince1970) { cont.yield($0) }
                    }.value
                    people = r.recluster.people   // global count after reclustering
                    faces += r.facesAdded; photos += r.photosProcessed; failures += r.failures
                    videos += r.scan.videos
                } catch { failure = error }
            }
            cont.finish()
            _ = await consumer.value
            if let failure {
                statusText = "Scan failed: \(failure.localizedDescription)"
            } else {
                var msg = "\(people) people · \(faces) faces · \(photos) photos"
                if videos > 0 { msg += " · \(videos) video\(videos == 1 ? "" : "s")" }
                // Don't report a clean success when photos couldn't be read — they'll be retried, but
                // the user should know (this is the signal that was missing in the "1400 in No faces" run).
                if failures > 0 { msg += " · \(failures) couldn't be read — they'll retry on the next scan" }
                statusText = msg
            }
            progressFraction = nil
            refreshRoots()
            await reloadPeople()
            await reloadSuggestions()
            reloadDuplicates()
            isWorking = false
        }
    }

    /// Map an engine progress tick to user-facing status text + a determinate fraction. Scanning has
    /// no known total (lazy enumerator), so it stays indeterminate and just shows the running count.
    private func applyProgress(_ p: IndexService.Progress) {
        switch p.phase {
        case .scanning:
            let pics = max(0, p.done - p.videos)
            var s = "Scanning… \(pics) photo\(pics == 1 ? "" : "s")"
            if p.videos > 0 { s += " · \(p.videos) video\(p.videos == 1 ? "" : "s")" }
            statusText = s + " found"
            progressFraction = nil
        case .processing:
            statusText = "Finding faces… \(p.done) of \(p.total)"
            progressFraction = p.total > 0 ? Double(p.done) / Double(p.total) : nil
        case .classifying:
            statusText = "Sorting into categories… \(p.done) of \(p.total)"
            progressFraction = p.total > 0 ? Double(p.done) / Double(p.total) : nil
        case .clustering:
            statusText = "Grouping people…"
            progressFraction = nil
        }
    }

    // MARK: - Browse

    /// Refresh the people grid + counts. The DB reads run off the main actor so a big library doesn't
    /// hitch the UI; results are published back here on the main actor. Awaitable so callers that read
    /// `people` right after (e.g. the merge name-carry-over) still see fresh state.
    func reloadPeople() async {
        let idx = index, personRepo = personsRepo, photoRepo = photosRepo
        let loaded = await Task.detached {
            () -> (people: [Person], counts: [Int64: Int], cats: IndexService.CategoryCounts, sources: [Int64: Int], favs: Set<Int64>) in
            ((try? idx.people()) ?? [],
             (try? personRepo.photoCounts()) ?? [:],
             (try? idx.categoryCounts()) ?? IndexService.CategoryCounts(),
             (try? photoRepo.countsByRoot()) ?? [:],
             (try? photoRepo.favoriteIDs()) ?? [])
        }.value
        people = loaded.people
        photoCountByPerson = loaded.counts
        categoryCounts = loaded.cats
        sourcePhotoCounts = loaded.sources
        favoriteIDs = loaded.favs
        if let id = selectedPersonID, !people.contains(where: { $0.id == id }) {
            selectedPersonID = nil   // person gone after re-cluster → fall back to the people grid
        }
        loadLibraryPhotos()
    }

    func select(_ personID: Int64?) {
        libraryNav = .people
        selectedPersonID = personID
        clearSelection(); closeViewer()
        loadLibraryPhotos()
    }

    /// Switch the Library sidebar nav (People / All Photos / Recently Added).
    func selectNav(_ nav: LibraryNav) {
        libraryNav = nav
        if nav != .people { selectedPersonID = nil }
        clearSelection(); closeViewer()
        loadLibraryPhotos()
    }

    /// Drill back from a person's detail to the People grid.
    func backToPeople() {
        selectedPersonID = nil
        clearSelection(); closeViewer()
        loadLibraryPhotos()
    }

    /// Open the People browse screen (from the Collections grid) — shows the people grid.
    func openPeople() {
        screen = .photos
        libraryNav = .people
        selectedPersonID = nil
        loadLibraryPhotos()
    }

    /// Smaller/equal groups whose faces look like `person` — shown inline on the person page so the
    /// user pulls loose look-alikes in instead of merging two abstract groups. Restricted to
    /// faceCount ≤ this person's so the merge always keeps THIS person's identity (stable selection).
    func candidates(for person: Person) -> [MergeSuggestion] {
        guard let pid = person.id else { return [] }
        // Filter the already-loaded `suggestions` (computed off-main in reloadSuggestions, same
        // maxDistance) instead of re-running the O(n²) pairwise scan on the main actor per person view.
        return suggestions.filter { s in
            guard s.personA.id == pid || s.personB.id == pid,
                  !dismissedPairs.contains(pairKey(s.personA, s.personB)) else { return false }
            let other = s.personA.id == pid ? s.personB : s.personA
            return other.faceCount <= person.faceCount
        }
    }

    func otherPerson(in s: MergeSuggestion, than person: Person) -> Person {
        s.personA.id == person.id ? s.personB : s.personA
    }

    /// Pull a look-alike group into `person` (must-link + re-cluster; the system learns).
    func addSimilar(_ candidate: Person, to person: Person) {
        confirmSame(MergeSuggestion(personA: person, personB: candidate, distance: 0))
    }

    /// "Not the same" — keep apart forever (cannot-link), and stop suggesting it.
    func dismissSimilar(_ candidate: Person, of person: Person) {
        confirmDifferent(MergeSuggestion(personA: person, personB: candidate, distance: 0))
    }

    /// People filtered by the sidebar search box.
    var filteredPeople: [Person] {
        let q = librarySearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter { ($0.displayName ?? "Unnamed").lowercased().contains(q) }
    }

    /// Open a non-people category (Screenshots/Documents/Places/No faces) as a browse overlay.
    func openCategory(_ category: IndexService.PhotoCategory) {
        browsingCategory = category
        photos = online((try? index.photos(inCategory: category)) ?? [])
        highlightFaces = false
        clearSelection()
        closeViewer()
    }

    /// A representative photo for a category card's thumbnail (newest first), via a LIMIT-1 query so
    /// the card doesn't load the whole category.
    func firstPhoto(inCategory category: IndexService.PhotoCategory) -> Photo? {
        (try? index.firstPhoto(inCategory: category)) ?? nil
    }

    func closeCategory() {
        browsingCategory = nil
        clearSelection()
        closeViewer()
        loadLibraryPhotos()   // restore the current Library view
    }

    // MARK: - Places (map)

    @Published var browsingPlaces = false
    /// User-assigned names for location buckets (bucket key → name), persisted across launches.
    @Published var placeNames: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "placeNames") as? [String: String]) ?? [:]

    func openPlaces() { clearSelection(); closeViewer(); browsingPlaces = true }
    func closePlaces() { browsingPlaces = false; clearSelection(); closeViewer(); loadLibraryPhotos() }

    func setPlaceName(_ name: String, for key: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { placeNames.removeValue(forKey: key) } else { placeNames[key] = trimmed }
        UserDefaults.standard.set(placeNames, forKey: "placeNames")
    }

    /// Group GPS-tagged photos into map clusters by a coarse coordinate grid (~0.05° ≈ 5 km), each
    /// returned with its averaged center. ponytail: grid bucketing can split points across a cell
    /// boundary — fine for a "places" overview; swap for true geo-clustering if it looks off.
    func placeGroups() -> [(key: String, lat: Double, lon: Double, photos: [Photo])] {
        let located = online((try? index.photos(inCategory: .places)) ?? [])
        var buckets: [String: [Photo]] = [:]
        for p in located {
            guard let la = p.gpsLat, let lo = p.gpsLon else { continue }
            buckets["\(Int((la / 0.05).rounded())),\(Int((lo / 0.05).rounded()))", default: []].append(p)
        }
        return buckets.map { key, ps in
            (key, ps.compactMap(\.gpsLat).reduce(0, +) / Double(ps.count),
             ps.compactMap(\.gpsLon).reduce(0, +) / Double(ps.count), ps)
        }
    }

    // MARK: - Favourites (F2)

    /// Photo ids the user hearted. Loaded on every `reloadPeople` and kept current on toggle, so the
    /// Lightbox heart reflects state instantly from anywhere — not just inside the Favourites list.
    @Published var favoriteIDs: Set<Int64> = []
    func isFavorite(_ photo: Photo) -> Bool { photo.id.map(favoriteIDs.contains) ?? false }
    func toggleFavorite(_ photo: Photo) {
        guard let id = photo.id else { return }
        let on = !favoriteIDs.contains(id)
        if on { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        let svc = index
        Task.detached { try? svc.setFavorite(on, id: id) }
        statusText = on ? "Added to Favourites." : "Removed from Favourites."
    }

    // MARK: - Quick lists (Favourites / Recently added) — a generic photo-list browse overlay

    enum PhotoList: String { case favourites = "Favourites", recents = "Recently added" }
    @Published var browsingList: PhotoList?
    func openFavourites() { openList(.favourites) { (try? $0.favorites()) ?? [] } }
    func openRecents()    { openList(.recents)    { (try? $0.recentlyAdded()) ?? [] } }
    private func openList(_ list: PhotoList, _ fetch: @escaping @Sendable (IndexService) -> [Photo]) {
        clearSelection(); closeViewer()
        let svc = index
        Task {
            let rows = await Task.detached { fetch(svc) }.value
            photos = online(rows); browsingList = list
        }
    }
    func closeList() { browsingList = nil; clearSelection(); closeViewer(); loadLibraryPhotos() }

    // MARK: - Duplicates

    /// Photo ids the user pinned as "best" in a duplicate set (kept when trimming). Persisted.
    @Published var pinnedBest: Set<Int64> =
        Set((UserDefaults.standard.array(forKey: "pinnedBest") as? [Int])?.map(Int64.init) ?? [])
    @Published var viewingDuplicateSet = false   // true while the lightbox shows a duplicate set

    /// Duplicate sets the user ticked for a bulk "Keep best, delete rest". Keyed on each set's
    /// first-photo id — the same stable id the grid's ForEach uses, so ticks survive a reload.
    @Published var selectedDupGroups: Set<Int64> = []

    func reloadDuplicates() {
        let idx = index
        Task {   // the O(n²) phash scan + row load runs off the main actor; results publish back here
            let groups = await Task.detached { (try? idx.duplicateSets()) ?? [] }.value
            duplicateGroups = groups.map { online($0) }.filter { $0.count > 1 }.map { reorderBest($0) }
        }
    }

    /// Put the user-pinned "best" photo first in its set, so "delete all but best" keeps THEIR choice
    /// instead of the default (highest-resolution) pick.
    private func reorderBest(_ group: [Photo]) -> [Photo] {
        guard let i = group.firstIndex(where: { $0.id.map(pinnedBest.contains) ?? false }), i != 0 else { return group }
        var g = group; let best = g.remove(at: i); g.insert(best, at: 0); return g
    }

    /// Mark a photo as the "best" of its duplicate set (one per set — clears other pins in the set).
    /// Viewer path: the current set is `photos`. Grid path: pass the set explicitly so the right pins
    /// are cleared (in the grid, `photos` isn't the set being edited).
    func markBest(_ photo: Photo) { markBest(photo, in: photos) }
    func markBest(_ photo: Photo, in group: [Photo]) {
        guard let id = photo.id else { return }
        for p in group where p.id != id { if let pid = p.id { pinnedBest.remove(pid) } }   // one best per set
        pinnedBest.insert(id)
        UserDefaults.standard.set(pinnedBest.map(Int.init), forKey: "pinnedBest")
        statusText = "Marked as best — kept when trimming duplicates."
        reloadDuplicates()
    }

    /// Photos "Delete all but best" would remove — every group's non-best (non-first) copies.
    var duplicatesToTrim: [Photo] { duplicateGroups.flatMap { $0.dropFirst() } }
    func deleteAllButBest() { deletePhotos(duplicatesToTrim.compactMap(\.id)) }

    // Bulk "Keep best, delete rest" over a user-picked subset of sets.
    private func dupKey(_ group: [Photo]) -> Int64? { group.first?.id }
    func isDupGroupSelected(_ group: [Photo]) -> Bool { dupKey(group).map(selectedDupGroups.contains) ?? false }
    var allDupGroupsSelected: Bool { !duplicateGroups.isEmpty && selectedDupGroups.count == duplicateGroups.count }
    func toggleDupGroup(_ group: [Photo]) {
        guard let k = dupKey(group) else { return }
        if selectedDupGroups.contains(k) { selectedDupGroups.remove(k) } else { selectedDupGroups.insert(k) }
    }
    func selectAllDupGroups() {
        selectedDupGroups = allDupGroupsSelected ? [] : Set(duplicateGroups.compactMap(dupKey))
    }
    /// Non-best copies across the ticked sets — what "Keep best, delete rest" trashes.
    var selectedDupTrim: [Photo] { duplicateGroups.filter(isDupGroupSelected).flatMap { $0.dropFirst() } }
    func deleteSelectedDupGroups() {
        deletePhotos(selectedDupTrim.compactMap(\.id)); selectedDupGroups.removeAll()
    }

    /// Open a set in the lightbox so arrow keys step through just that set (and "Mark best" shows).
    func previewSet(_ photo: Photo, in group: [Photo]) {
        photos = group; viewingDuplicateSet = true; openViewer(photo)
    }
    func openDuplicates() { reloadDuplicates(); clearSelection(); selectedDupGroups.removeAll(); closeViewer(); browsingDuplicates = true }
    func closeDuplicates() { browsingDuplicates = false; clearSelection(); selectedDupGroups.removeAll(); closeViewer() }

    var browsingCategoryTitle: String {
        switch browsingCategory {
        case .screenshots: return "Screenshots"
        case .documents:   return "Documents"
        case .identity:    return "Identity & cards"
        case .places:      return "Places"
        case .noFaces:     return "No faces"
        case .pets:        return "Pets"
        case .videos:      return "Videos"
        case nil:          return ""
        }
    }

    private var photoLoadGen = 0
    /// Load the current Library view's photos off the main actor (sorting/paging pushed into SQL), then
    /// publish on the main actor. Fire-and-forget: no caller reads `photos` synchronously after.
    private func loadLibraryPhotos() {
        photoLoadGen &+= 1
        let gen = photoLoadGen
        let nav = libraryNav, pid = selectedPersonID, idx = index, repo = photosRepo
        Task {
            let loaded = await Task.detached { () -> [Photo] in
                switch nav {
                case .people:        return (pid.flatMap { try? idx.photos(forPerson: $0) }) ?? []
                case .allPhotos:     return (try? repo.allByTakenAt()) ?? []
                case .recentlyAdded: return (try? repo.allByIndexedAt()) ?? []
                }
            }.value
            // ponytail: generation guard drops a stale load if the user switched views mid-read.
            guard gen == photoLoadGen else { return }
            photos = online(loaded)
        }
    }

    /// Make this photo's face the cover for the person currently being viewed.
    func setCover(_ photo: Photo) {
        guard let pid = selectedPersonID, let photoId = photo.id else { return }
        let faces = (try? facesRepo.forPhoto(photoId)) ?? []
        guard let faceId = faces.first(where: { $0.personId == pid })?.id else { return }
        try? personsRepo.setCoverFace(pid, faceId: faceId, now: Date().timeIntervalSince1970)
        statusText = "Cover updated."
        Task { await reloadPeople() }
    }

    /// Re-run clustering on the already-computed embeddings using the current Settings — applies a
    /// threshold change WITHOUT a rescan (no files read, no re-embedding). Off the main actor.
    func regroupNow() {
        guard !isWorking else { return }
        isWorking = true
        statusText = "Regrouping…"
        let database = db
        let config = Self.clusteringConfigFromSettings()
        Task {
            let report = try? await Task.detached {
                try ClusteringService(db: database, config: config).recluster(now: Date().timeIntervalSince1970)
            }.value
            await reloadPeople()
            await reloadSuggestions()
            reloadDuplicates()
            statusText = report.map { "Regrouped — \($0.people) people" } ?? "Regroup failed"
            isWorking = false
        }
    }

    func rename(_ id: Int64, to name: String) {
        try? index.renamePerson(id, to: name.isEmpty ? nil : name, now: Date().timeIntervalSince1970)
        Task { await reloadPeople() }
    }

    /// Manual merge (drag one person onto another): force them into one person regardless of distance —
    /// the user overriding the grouping. Keeps the larger group's identity and carries over a name the
    /// user set, so dragging a stray onto a named person never loses the name.
    func mergePeople(_ sourceId: Int64, into targetId: Int64) {
        guard sourceId != targetId, !isWorking,
              let source = people.first(where: { $0.id == sourceId }),
              let target = people.first(where: { $0.id == targetId }) else { return }
        let keptName = target.displayName ?? source.displayName
        let survivorId = target.faceCount >= source.faceCount ? targetId : sourceId
        isWorking = true
        statusText = "Merging…"
        let rev = review
        let now = Date().timeIntervalSince1970
        Task {
            try? await Task.detached { try rev.confirmSame(target, source, now: now) }.value
            await reloadPeople()
            if let keptName, people.first(where: { $0.id == survivorId })?.displayName == nil {
                try? index.renamePerson(survivorId, to: keptName, now: now)
            }
            await reloadPeople(); await reloadSuggestions(); reloadDuplicates()
            statusText = "Merged."
            isWorking = false
        }
    }

    // MARK: - Review ("Same or different person?")

    /// How loose look-alike suggestions are (max cosine distance; higher = more, looser matches).
    /// Exposed in Settings so the user can crank it up when they're confidently merging everything.
    static var suggestReach: Float {
        Float(UserDefaults.standard.object(forKey: "suggestReach") as? Double ?? 0.6)
    }

    /// Recompute the Review queue. The pairwise suggestMerges scan runs off the main actor; the cheap
    /// dismissed-pair filter is applied back here against the current dismissals.
    func reloadSuggestions() async {
        let rev = review, idx = index, reach = Self.suggestReach
        let loaded = await Task.detached { () -> (raw: [MergeSuggestion], learned: Int?) in
            ((try? rev.suggestMerges(maxDistance: reach)) ?? [], try? idx.learnedCorrections())
        }.value
        suggestions = loaded.raw.filter { !dismissedPairs.contains(pairKey($0.personA, $0.personB)) }
        learnedCorrections = loaded.learned ?? learnedCorrections
    }

    /// Open the Review queue fresh: clear this session's dismissals, reset progress, reload pairs.
    func beginReview() {
        dismissedPairs.removeAll()
        reviewedCount = 0
        Task { await reloadSuggestions() }
    }

    @Published var reviewRequestID = 0   // bumped from the menu bar to ask the main window to open Review

    /// Ask the main window to surface the Review sheet (used from the menu-bar panel, a separate scene).
    func requestReview() {
        activateMainWindow()
        beginReview()
        reviewRequestID += 1
    }

    /// Bring the app + main window to the front (from the menu-bar panel).
    func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        // ponytail: focuses an existing window; reopening a fully-closed WindowGroup is a v2 concern.
    }

    /// User correction: the selected photos are NOT the current person → re-evaluate them.
    func markNotThisPerson(_ photoIds: [Int64]) {
        guard let pid = selectedPersonID, !photoIds.isEmpty, !isWorking else { return }
        isWorking = true
        statusText = "Re-evaluating \(photoIds.count) photo\(photoIds.count == 1 ? "" : "s")…"
        let svc = index
        let clustering = Self.clusteringConfigFromSettings()
        Task {
            _ = try? await Task.detached {
                try svc.markNotPerson(photoIds: photoIds, personId: pid,
                                      clustering: clustering, now: Date().timeIntervalSince1970)
            }.value
            clearSelection()
            await reloadPeople()
            await reloadSuggestions()
            statusText = "Re-evaluated — sort learned from your correction."
            isWorking = false
        }
    }

    func confirmSame(_ s: MergeSuggestion) {
        guard !isWorking else { return }
        dismissedPairs.insert(pairKey(s.personA, s.personB))
        runReview(s.personA, s.personB, same: true)
    }

    func confirmDifferent(_ s: MergeSuggestion) {
        guard !isWorking else { return }
        dismissedPairs.insert(pairKey(s.personA, s.personB))
        runReview(s.personA, s.personB, same: false)
    }

    func skipCurrentSuggestion() {
        guard let s = suggestions.first else { return }
        dismissedPairs.insert(pairKey(s.personA, s.personB))
        suggestions.removeFirst()
        reviewedCount += 1
    }

    /// Apply a Same/Different decision OFF the main actor — the re-cluster it triggers is O(n³), so
    /// running it inline froze the UI on large libraries. Shows a spinner and reloads when done.
    private func runReview(_ a: Person, _ b: Person, same: Bool) {
        isWorking = true
        statusText = same ? "Merging…" : "Keeping separate…"
        let rev = review
        let now = Date().timeIntervalSince1970
        Task {
            let applied: Bool
            do {
                try await Task.detached {
                    if same { try rev.confirmSame(a, b, now: now) } else { try rev.confirmDifferent(a, b, now: now) }
                }.value
                applied = true
            } catch { applied = false }
            if applied { reviewedCount += 1 }   // only count a correction that actually landed
            await reloadPeople(); await reloadSuggestions(); reloadDuplicates()
            statusText = applied ? (same ? "Merged." : "Kept separate.") : "Couldn't apply — try again."
            isWorking = false
        }
    }

    // MARK: - Images

    /// Person cover face. DB lookup stays on the main actor; the decode + alignment run off-main so the
    /// people grid / avatars don't hitch while loading.
    func coverImage(for person: Person, side: Int = 96) async -> NSImage? {
        guard let face = try? review.representativeFace(of: person.id ?? -1),
              let photo = try? photosRepo.find(face.photoId),
              let url = imageLoader.url(for: photo) else { return nil }
        let box = CGRect(x: face.bboxX, y: face.bboxY, width: face.bboxW, height: face.bboxH)
        return await Task.detached(priority: .utility) {
            guard let cg = try? ImageLoader.load(url, maxPixelSize: 1200) else { return nil }
            let detected = DetectedFace(boundingBox: box, roll: nil, yaw: nil, pitch: nil,
                                        quality: nil, landmarks5: nil)
            guard let crop = FaceAligner(outputSize: side, margin: 0.4).alignedCrop(from: cg, face: detected)
            else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: side, height: side))
        }.value
    }

    // MARK: - Lightbox + native selection

    // Identity is the photo id, NOT an index: a background `photos` reload (folder-watch rescan,
    // place sheet, etc.) must never leave the viewer showing one photo while Trash/Reveal act on a
    // different photo that slid into the same slot.
    @Published var viewerPhotoID: Int64?   // id of the open photo (nil = closed)
    var selectionAnchor: Int64?            // for shift-range selection

    /// Index of the open photo in the current `photos`, or nil if closed / no longer present.
    var viewerIndex: Int? {
        guard let id = viewerPhotoID else { return nil }
        return photos.firstIndex { $0.id == id }
    }
    var viewerPhoto: Photo? {
        guard let id = viewerPhotoID else { return nil }
        return photos.first { $0.id == id }   // nil if the photo was removed → overlay auto-closes
    }
    func openViewer(_ photo: Photo) { viewerPhotoID = photo.id }
    func closeViewer() { viewerPhotoID = nil; viewingDuplicateSet = false }
    func viewerStep(_ delta: Int) {
        guard let i = viewerIndex else { return }
        let n = i + delta
        if photos.indices.contains(n) { viewerPhotoID = photos[n].id }
    }

    func toggleSelect(_ photo: Photo) {
        guard let id = photo.id else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        selectionAnchor = id
    }
    func rangeSelect(_ photo: Photo) {
        guard let id = photo.id else { return }
        guard let anchor = selectionAnchor,
              let a = photos.firstIndex(where: { $0.id == anchor }),
              let b = photos.firstIndex(where: { $0.id == id }) else { toggleSelect(photo); return }
        for p in photos[min(a, b)...max(a, b)] { if let pid = p.id { selection.insert(pid) } }
    }
    func clearSelection() { selection.removeAll(); selectionAnchor = nil }

    /// Stop tracking a folder/drive (files untouched), then refresh.
    func removeRoot(_ id: Int64) {
        guard !isWorking else { return }   // don't untrack a root mid-scan/regroup
        // Release this root's security scope before forgetting it (balances startAccessingSavedRoots).
        if let root = try? RootRepository(db).all().first(where: { $0.id == id }),
           let data = root.bookmark, let resolved = try? BookmarkStore.resolve(data),
           let i = scopedURLs.firstIndex(of: resolved.url) {
            resolved.url.stopAccessingSecurityScopedResource()
            scopedURLs.remove(at: i)
        }
        _ = try? index.removeRoot(id, now: Date().timeIntervalSince1970)
        refreshRoots()
        Task { await reloadPeople() }
    }

    private func refreshRoots() {
        let scanned = (try? index.scannedRoots()) ?? []
        roots = scanned
        // A source is "offline" when its path isn't reachable (drive unplugged / folder moved). We
        // keep the index but stop showing its photos, which would otherwise be unloadable thumbnails.
        offlineRootIDs = Set(scanned.compactMap { r in
            r.id.flatMap { FileManager.default.fileExists(atPath: r.displayPath) ? nil : $0 }
        })
        imageLoader.roots = Dictionary(uniqueKeysWithValues: scanned.compactMap { r in r.id.map { ($0, r.displayPath) } })
        updateFolderWatch()
    }

    /// Re-check which sources are mounted (e.g. when returning to the Library after plugging/unplugging
    /// a drive) and refresh the visible photos accordingly.
    func recheckSources() {
        refreshRoots()
        loadLibraryPhotos()
    }

    private func online(_ list: [Photo]) -> [Photo] {
        offlineRootIDs.isEmpty ? list : list.filter { !offlineRootIDs.contains($0.rootId) }
    }

    // MARK: - Watch sources (FSEvents auto-rescan)

    private var folderWatcher: FolderWatcher?
    private var watchedPaths: [String] = []

    /// Start/stop watching the online roots to match the "watch sources" setting. A no-op when the
    /// watch set is unchanged, so it's cheap to call on every refresh / defaults change.
    private func updateFolderWatch() {
        let enabled = UserDefaults.standard.object(forKey: "watchSources") as? Bool ?? true
        let paths = enabled
            ? roots.compactMap { r in r.id.flatMap { offlineRootIDs.contains($0) ? nil : r.displayPath } }
            : []
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        guard !paths.isEmpty else { folderWatcher?.stop(); folderWatcher = nil; return }
        if folderWatcher == nil {
            folderWatcher = FolderWatcher { [weak self] changed in
                Task { @MainActor in self?.handleWatchedChange(changed) }
            }
        }
        folderWatcher?.start(paths: paths)
    }

    /// A watched folder changed on disk → incrementally rescan the affected root(s). Skipped while a
    /// scan is already running (the next manual/auto pass picks up the change).
    private func handleWatchedChange(_ changedPaths: [String]) {
        guard !isWorking, !watchedPaths.isEmpty else { return }
        let affected = watchedPaths.filter { root in changedPaths.contains { $0.hasPrefix(root) } }
        let toScan = affected.isEmpty ? watchedPaths : affected
        statusText = "Detected changes — rescanning…"
        runScan(paths: toScan)
    }
}

import SwiftUI
import AppKit
import SortKit

/// Forces a regular foreground activation policy. Without this, launching via `swift run` (no .app
/// bundle) can leave the process in an accessory state where the window shows but text fields never
/// take keyboard focus — i.e. "I can't type in the name field". A packaged .app gets this from its
/// Info.plist; here we set it explicitly so both launch paths behave the same.
final class SortAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SortApp: App {
    @NSApplicationDelegateAdaptor(SortAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 620)
                .tint(Theme.accent)
                .preferredColorScheme(.light)   // the warm palette is a light theme — pin it so
                                                // system surfaces don't flip to Dark Mode (consistency)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder to Scan…") { store.chooseFolderAndScan() }
                    .keyboardShortcut("o")
            }
        }

        MenuBarExtra("Sort", systemImage: "person.2.crop.square.stack") {
            MenuBarPanel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)   // a rich panel, matching the wireframe

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var showingReview = false
    @State private var showingDirectories = false
    @State private var showingAbout = false

    var body: some View {
        if !didOnboard && store.roots.isEmpty {
            OnboardingView()
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        Group {
            switch store.screen {
            case .collections: CollectionsView()
            case .photos: LibraryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.chooseFolderAndScan() } label: { Label("Open Folder", systemImage: "folder.badge.plus") }
                    .disabled(store.isWorking)
            }
            ToolbarItem {
                Button { showingDirectories = true } label: { Label("Folders", systemImage: "externaldrive") }
                    .help("Folders & drives sort can access")
            }
            ToolbarItem {
                Button { store.beginReview(); showingReview = true } label: {
                    Label("Review", systemImage: "person.2.badge.gearshape")
                }
                .help("Review borderline groups (Same or different person?)")
            }
            ToolbarItem {
                Button { showingAbout = true } label: { Label("About", systemImage: "info.circle") }
                    .help("About Sort")
            }
        }
        .sheet(isPresented: $showingReview) { ReviewView() }
        .sheet(isPresented: $showingDirectories) { DirectoriesView() }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .onChange(of: store.reviewRequestID) { _, _ in showingReview = true }
        .overlay(alignment: .bottom) {
            if store.isWorking {
                ScanningStatusBar()
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.isWorking)
    }
}

/// Bottom status pill shown during a scan: the live progress line + a slowly-rotating reassurance
/// (privacy / on-device / what's happening) to ease "what is it doing with my photos?" anxiety.
private struct ScanningStatusBar: View {
    @EnvironmentObject var store: AppStore
    private static let reassurances = [
        "🔒 Runs entirely on your Mac — nothing is uploaded",
        "Your photos are never moved, renamed, or changed",
        "Grouping faces on-device with Core ML",
        "Reading dates & places from your photos — locally",
        "No account, no cloud, no internet required",
        "Pets get their own groups too 🐾",
        "Spotting near-duplicates so you can tidy up",
    ]
    @State private var idx = 0
    private let tick = Timer.publish(every: 3.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                if let f = store.progressFraction {
                    ProgressView(value: f).progressViewStyle(.linear).frame(width: 150)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(store.statusText)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.title)
            }
            Text(Self.reassurances[idx])
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .id(idx)
                .transition(.opacity)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.cardBorder.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .onReceive(tick) { _ in
            withAnimation(.easeInOut(duration: 0.55)) { idx = (idx + 1) % Self.reassurances.count }
        }
    }
}

/// First-run welcome — shown until the user grants their first folder (gated on `didOnboard` +
/// no roots). A drag-well and a Choose… button both route through the sandbox grant path.
struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: "person.2.crop.square.stack.fill")
                    .font(.system(size: 52)).foregroundStyle(Theme.accent)
                VStack(spacing: 6) {
                    Text("Welcome to Sort")
                        .font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.titleStrong)
                    Text("Pick a folder or drive. Sort indexes the people in your photos so you can "
                         + "browse by person — your originals are never moved or changed.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 30)).foregroundStyle(targeted ? Theme.accent : Theme.iconStroke)
                    Text("Drag a folder or drive here")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.label)
                    Button("Choose…") { didOnboard = true; store.chooseFolderAndScan() }
                        .controlSize(.large)
                }
                .frame(maxWidth: 420).frame(height: 184)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(targeted ? Theme.previewWarm2 : Theme.previewWarm))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(targeted ? Theme.accent : Theme.cardBorder,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { $0.hasDirectoryPath }) else { return false }
                    didOnboard = true
                    store.scanFolder(at: url)
                    return true
                } isTargeted: { targeted = $0 }

                Label("On-device — your photos never leave your Mac.", systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 26) {
                stepDot("Grant", active: true)
                stepDot("Scan", active: false)
                stepDot("Browse", active: false)
            }
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBg)
    }

    private func stepDot(_ title: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Circle().fill(active ? Theme.accent : Theme.placeholder).frame(width: 8, height: 8)
            Text(title).font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.label : Theme.muted)
        }
    }
}

/// The Library screen (wireframe screen A): a left nav sidebar (Search + LIBRARY + SOURCES) and a
/// main pane showing the people grid, a person's detail, or All Photos / Recently Added.
struct LibraryView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.titleStrong)
                    Text("\(store.people.count) people · \(store.roots.count) source\(store.roots.count == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                ScreenToggle()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            .background(Theme.pageBg)
            Rectangle().fill(Theme.separator).frame(height: 1)

            HStack(spacing: 0) {
                LibrarySidebar()
                Rectangle().fill(Theme.separator).frame(width: 1)
                detail
            }
        }
        .background(Theme.pageBg)
        // Exactly one LightboxView may exist at a time (each owns the Delete/⌘D/←/→ shortcuts). The
        // people-filter overlay nests its own (line ~440), so suppress this window-level one then.
        .overlay { if store.viewerPhoto != nil && !store.browsingPeopleFilter { LightboxView() } }
        .onAppear { store.recheckSources() }   // re-detect unplugged/reconnected drives
    }

    @ViewBuilder private var detail: some View {
        switch store.libraryNav {
        case .people:
            if let id = store.selectedPersonID, let person = store.people.first(where: { $0.id == id }) {
                PersonDetailView(person: person)
            } else {
                PeopleGridView()
            }
        case .allPhotos:
            PhotoCollectionPane(title: "All Photos", systemImage: "photo.on.rectangle")
        case .recentlyAdded:
            PhotoCollectionPane(title: "Recently Added", systemImage: "clock")
        }
    }
}

/// Left nav: Search, LIBRARY (People / All Photos / Recently Added), SOURCES (granted folders).
struct LibrarySidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.muted)
                TextField("Search", text: $store.librarySearch).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardBorder, lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            sectionLabel("LIBRARY")
            navRow("People", "person.2", .people, count: store.people.count)
            navRow("All Photos", "photo.on.rectangle", .allPhotos, count: nil)
            navRow("Recently Added", "clock", .recentlyAdded, count: nil)

            sectionLabel("SOURCES").padding(.top, 12)
            ForEach(store.roots, id: \.id) { root in sourceRow(root) }
            Button { store.chooseFolderAndScan() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 16)
                    Text("Add folder or drive…").font(.system(size: 12))
                    Spacer()
                }.foregroundStyle(Theme.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 4).disabled(store.isWorking)

            Spacer()
        }
        .frame(width: 216)
        .background(Theme.pageBg)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.sectionLabel)
            .padding(.horizontal, 18).padding(.bottom, 4)
    }

    private func navRow(_ title: String, _ icon: String, _ nav: LibraryNav, count: Int?) -> some View {
        let active = store.libraryNav == nav && (nav != .people || store.selectedPersonID == nil)
        return HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                .foregroundStyle(active ? Theme.accent : Theme.iconStroke)
            Text(title).font(.system(size: 12.5, weight: active ? .semibold : .regular)).foregroundStyle(Theme.label)
            Spacer()
            if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.count) }
        }
        .padding(.horizontal, 9).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.previewWarm2 : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.selectNav(nav) }
        .padding(.horizontal, 8)
    }

    private func sourceRow(_ root: ScannedRoot) -> some View {
        let offline = root.id.map { store.offlineRootIDs.contains($0) } ?? false
        return HStack(spacing: 9) {
            Image(systemName: offline ? "externaldrive.badge.xmark" : "folder.fill")
                .font(.system(size: 11)).frame(width: 16)
                .foregroundStyle(offline ? Theme.muted : Color(hex: 0xD9BE63))
            Text(URL(fileURLWithPath: root.displayPath).lastPathComponent)
                .font(.system(size: 12)).foregroundStyle(offline ? Theme.muted : Theme.label)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if offline {
                Text("offline").font(.system(size: 10)).foregroundStyle(Theme.muted)
            } else if let id = root.id, let c = store.sourcePhotoCounts[id] {
                Text(c >= 1000 ? String(format: "%.1fk", Double(c) / 1000) : "\(c)")
                    .font(.system(size: 11)).foregroundStyle(Theme.count)
            }
        }
        .padding(.horizontal, 9).frame(height: 28).padding(.horizontal, 8)
        .opacity(offline ? 0.75 : 1)
        .help(offline ? "\(root.displayPath) — drive not connected" : root.displayPath)
        .contextMenu {
            Button("Rescan") { store.scan(path: root.displayPath) }.disabled(store.isWorking)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.displayPath)])
            }
            if let id = root.id {
                Button("Remove from Sort", role: .destructive) { store.removeRoot(id) }
            }
        }
    }
}

/// The people grid (wireframe screen B) — big face circles, click to drill into a person.
struct PeopleGridView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("gridTileSize") private var gridTileSize = 160.0
    private var cols: [GridItem] { [GridItem(.adaptive(minimum: gridTileSize * 0.82, maximum: gridTileSize * 1.1), spacing: 16)] }

    var body: some View {
        VStack(spacing: 0) {
            if !store.peopleFilter.isEmpty { PeopleFilterBar() }
            grid
        }
        .overlay { if store.browsingPeopleFilter { PeopleFilterDetailView() } }
    }

    @ViewBuilder private var grid: some View {
        if store.people.isEmpty {
            ContentUnavailableView("No people yet", systemImage: "person.crop.square.badge.camera",
                                   description: Text("Open a folder or drive to scan."))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pageBg)
        } else {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 20) {
                    ForEach(store.filteredPeople, id: \.id) { person in
                        DraggablePersonCell(person: person)
                    }
                }
                .padding(24)
            }
            .background(Theme.pageBg)
            .overlay(alignment: .bottom) {
                Text("Tip: drag one person onto another to merge them · ⌘-click to compare people.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// Bar shown above the People grid once people are ⌘-clicked for comparison: AND-intersection of the
/// selected people, with an "only them" toggle.
struct PeopleFilterBar: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill").foregroundStyle(Theme.accent)
            Text("\(store.peopleFilter.count) selected — photos with all of them")
                .font(.system(size: 12.5)).foregroundStyle(Theme.label)
            Spacer()
            Toggle("Only them", isOn: Binding(get: { store.peopleFilterExclusive },
                                              set: { store.setPeopleFilterExclusive($0) }))
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("Show only photos where no other known person appears")
            Button("View photos") { store.openPeopleFilter() }
            Button("Clear") { store.clearPeopleFilter() }.buttonStyle(.link)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.previewWarm2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

/// Results overlay for the multi-person filter — the photos containing all selected people.
/// Shared Export + Move-to-Trash controls (with the confirm dialog), used by every selection bar.
/// Owns its own confirm-dialog state so each call site doesn't redeclare it. Drops into an HStack
/// inline (Group is layout-transparent, so the two buttons lay out as the bar's direct children).
struct SelectionTrashBar: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmTrash = false

    var body: some View {
        Group {
            Button { store.exportPhotos(Array(store.selection)) } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Copy the selected photos out to a folder you choose (originals never move)")
            Button(role: .destructive) { confirmTrash = true } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .confirmationDialog(
                "Move \(store.selection.count) photo\(store.selection.count == 1 ? "" : "s") to the Trash?",
                isPresented: $confirmTrash, titleVisibility: .visible) {
                    Button("Move to Trash", role: .destructive) { store.deletePhotos(Array(store.selection)) }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Files go to your macOS Trash and can be recovered.") }
        }
    }
}

struct PeopleFilterDetailView: View {
    @EnvironmentObject var store: AppStore

    private var title: String {
        (store.peopleFilterExclusive ? "Only " : "") + store.peopleFilterNames.joined(separator: " + ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.closePeopleFilter() } label: { Label("People", systemImage: "chevron.backward") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.titleStrong)
                    .lineLimit(1)
                Text("\(store.photos.count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                if !store.selection.isEmpty {
                    Text("\(store.selection.count) selected").font(.system(size: 12.5)).foregroundStyle(Theme.label)
                    Button("Clear") { store.clearSelection() }.buttonStyle(.link)
                    SelectionTrashBar()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14).background(Theme.cardBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            if store.photos.isEmpty {
                ContentUnavailableView("No shared photos",
                                       systemImage: "person.2.slash",
                                       description: Text("No photos contain all of these people"
                                                         + (store.peopleFilterExclusive ? " by themselves." : ".")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pageBg)
            } else {
                PhotoGridView(photos: store.photos, highlight: false, rects: [:])
            }
        }
        .background(Theme.pageBg)
        .overlay { if store.viewerPhoto != nil { LightboxView() } }
    }
}

/// A person tile that opens on tap, can be dragged onto another tile, and accepts a drop to merge the
/// dragged person in. This is the manual override for same-person groups the engine kept apart.
struct DraggablePersonCell: View {
    @EnvironmentObject var store: AppStore
    let person: Person
    @State private var targeted = false

    var body: some View {
        let inFilter = person.id.map { store.peopleFilter.contains($0) } ?? false
        PersonCell(person: person)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted || inFilter ? Theme.accent : .clear, lineWidth: 2).padding(-6))
            .overlay(alignment: .topTrailing) {
                if inFilter {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(Theme.accent)
                        .background(Circle().fill(.white)).padding(4)
                }
            }
            .scaleEffect(targeted ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onTapGesture {
                // ⌘-click adds the person to the multi-person compare filter; a plain click opens them.
                if NSEvent.modifierFlags.contains(.command), let id = person.id {
                    store.togglePersonFilter(id)
                } else {
                    store.select(person.id)
                }
            }
            .draggable(String(person.id ?? -1))
            .dropDestination(for: String.self) { items, _ in
                guard let s = items.first, let dragged = Int64(s), let target = person.id, dragged != target
                else { return false }
                store.mergePeople(dragged, into: target)
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                if let id = person.id {
                    Button(inFilter ? "Remove from people filter" : "Add to people filter") {
                        store.togglePersonFilter(id)
                    }
                }
            }
            .help("Open · ⌘-click to compare with others · or drag another person here to merge")
    }
}

struct PersonCell: View {
    @EnvironmentObject var store: AppStore
    let person: Person
    var body: some View {
        VStack(spacing: 8) {
            PersonAvatar(person: person, size: 104)
                .overlay(alignment: .bottomTrailing) {
                    if person.kind == "pet" {
                        Image(systemName: "pawprint.circle.fill")
                            .font(.system(size: 24)).foregroundStyle(Theme.accent)
                            .background(Circle().fill(.white).padding(2))
                    }
                }
            Text(person.displayName ?? "Unnamed")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.title).lineLimit(1)
            Text("\(store.photoCount(person))").font(.system(size: 11)).foregroundStyle(Theme.count)
        }
    }
}

/// All Photos / Recently Added — a flat photo grid with select-to-trash.
struct PhotoCollectionPane: View {
    @EnvironmentObject var store: AppStore
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.titleStrong)
                Text("\(store.photos.count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                if !store.selection.isEmpty {
                    Text("\(store.selection.count) selected").font(.system(size: 12.5)).foregroundStyle(Theme.label)
                    Button("Clear") { store.clearSelection() }.buttonStyle(.link)
                    SelectionTrashBar()
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14).background(Theme.cardBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            if store.photos.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: systemImage,
                                       description: Text("Scan a folder to see photos."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pageBg)
            } else {
                PhotoGridView(photos: store.photos, highlight: false, rects: [:])
            }
        }
        .background(Theme.pageBg)
    }
}

struct PersonAvatar: View {
    @EnvironmentObject var store: AppStore
    let person: Person
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Circle().fill(.quaternary) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Clear first: this view is reused across people (e.g. the two Review avatars), so without the
        // reset it shows the PREVIOUS person's face until the new cover decodes.
        .task(id: person.id) { image = nil; image = await store.coverImage(for: person, side: Int(size * 2)) }
    }
}

struct PersonDetailView: View {
    @EnvironmentObject var store: AppStore
    let person: Person
    @State private var name = ""
    @State private var rects: [Int64: [CGRect]] = [:]
    @State private var candidates: [MergeSuggestion] = []
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !candidates.isEmpty { candidatesStrip }
            if !store.selection.isEmpty { selectionBar }
            PhotoGridView(photos: store.photos, highlight: store.highlightFaces, rects: rects)
        }
        .background(Theme.pageBg)
        .task(id: person.id) {
            name = person.displayName ?? ""
            store.selectMode = false
            rects = store.highlightRects(forPerson: person.id ?? -1)
            candidates = store.candidates(for: person)
        }
        .onChange(of: store.photos.count) { _, _ in
            rects = store.highlightRects(forPerson: person.id ?? -1)
        }
        // Re-derive look-alike candidates after any add/dismiss (those bump reviewedCount).
        .onChange(of: store.reviewedCount) { _, _ in candidates = store.candidates(for: person) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { store.backToPeople() } label: {
                Label("People", systemImage: "chevron.backward")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .help("Back to all people")

            PersonAvatar(person: person, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.titleStrong)
                    .focused($nameFocused)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(nameFocused ? Theme.cardBg : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(nameFocused ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    .help("Click to name this person")
                Text("\(store.photos.count) photos · across \(store.selectedFolderCount) "
                     + "source\(store.selectedFolderCount == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle(isOn: $store.selectMode) { Label("Select", systemImage: "checkmark.circle") }
                .toggleStyle(.button)
                .help("Tap photos to select — no ⌘ needed")
            Toggle(isOn: $store.highlightFaces) { Label("Highlight", systemImage: "viewfinder") }
                .toggleStyle(.button)
                .help("Outline this person's face in each photo")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.cardBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private func commitName() {
        store.rename(person.id ?? -1, to: name)
    }

    /// Inline "add look-alikes" strip: smaller groups whose faces resemble this person, each shown by
    /// its actual face so you can pull it in (Add) or reject it (×) right here — no merge modal.
    private var candidatesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("Faces that look like this person — add the ones that match")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.label)
            }
            let items = candidates.map { (other: store.otherPerson(in: $0, than: person), match: 1 - $0.distance) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items, id: \.other.id) { item in
                        candidateCard(item.other, match: item.match)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color(hex: 0xFBF3DC))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private func candidateCard(_ other: Person, match: Float) -> some View {
        VStack(spacing: 5) {
            PersonAvatar(person: other, size: 50)
            Text("\(Int((match * 100).rounded()))% · \(other.faceCount)")
                .font(.system(size: 9)).foregroundStyle(Theme.muted)
            HStack(spacing: 5) {
                Button("Add") { store.addSimilar(other, to: person) }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                Button { store.dismissSimilar(other, of: person) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).controlSize(.mini).help("Not the same person")
            }
        }
        .frame(width: 72)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(store.selection.count) selected")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.label)
            Button("Clear") { store.clearSelection() }.buttonStyle(.link)
            Spacer()
            Button { store.markNotThisPerson(Array(store.selection)) } label: {
                Label("Remove from this group", systemImage: "person.fill.xmark")
            }
            .help("Take these out of this person; Sort re-evaluates them into the right group and learns from it")
            SelectionTrashBar()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.previewWarm2)
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    // done + remaining ≈ session total; an estimate since a confirm can re-cluster several pairs at once.
    private var total: Int { store.reviewedCount + store.suggestions.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.titleStrong)
                if !store.suggestions.isEmpty {
                    Text("· \(store.suggestions.count) to check")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text("· Pair \(store.reviewedCount + 1) of \(total)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.label)
                }
                if store.learnedCorrections > 0 {
                    Text("· learned from \(store.learnedCorrections)")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .foregroundStyle(Theme.accent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.headerBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            if total > 0 {
                ProgressView(value: Double(store.reviewedCount), total: Double(total))
                    .progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
                    .padding(.horizontal, 18).padding(.top, 10)
            }

            if let suggestion = store.suggestions.first {
                VStack(spacing: 20) {
                    Text("Same or different person?")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.titleStrong)

                    HStack(spacing: 22) {
                        PersonAvatar(person: suggestion.personA, size: 108)
                        Text("?").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.muted)
                        PersonAvatar(person: suggestion.personB, size: 108)
                    }

                    HStack(spacing: 7) {
                        Circle().fill(suggestion.distance < 0.3 ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(String(format: "%@ · %.0f%% match · cosine %.2f",
                                    suggestion.distance < 0.3 ? "likely same" : "uncertain",
                                    max(0, 1 - suggestion.distance) * 100, suggestion.distance))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }

                    HStack(spacing: 12) {
                        choice("Same", "checkmark", .green, key: "s", hint: "S") { store.confirmSame(suggestion) }
                        choice("Different", "nosign", .red, key: "d", hint: "D") { store.confirmDifferent(suggestion) }
                        choice("Not sure", "questionmark", Theme.accent, key: " ", hint: "␣") { store.skipCurrentSuggestion() }
                    }

                    Button { store.skipCurrentSuggestion() } label: {
                        Text("→  skip").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Skip to the next pair")
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                           description: Text("No borderline groups right now."))
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 540, height: 470)
        .background(Theme.cardBg)
    }

    private func choice(_ title: String, _ icon: String, _ tint: Color,
                        key: KeyEquivalent, hint: String,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(hint).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(minWidth: 14)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.previewWarm2))
            }
            .frame(maxWidth: .infinity).frame(height: 80)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.crop.square.stack.fill")
                .font(.system(size: 46)).foregroundStyle(.tint)
            Text("Sort").font(.largeTitle).bold()
            Text("Version \(SortKit.version)").foregroundStyle(.secondary)
            Text("Browse any folder or drive's photos grouped by face. Sort never edits your photos — "
                 + "the only change it makes is moving photos you choose to delete to the Trash (recoverable).")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Text("Made by Aman Panjwani").font(.callout).foregroundStyle(Theme.title)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
        .background(Theme.cardBg)
    }
}

struct DirectoriesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rootToRemove: ScannedRoot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Folders & drives").font(.title3).bold()
                Spacer()
                Button { store.scanAll() } label: { Label("Sync all", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(store.isWorking || store.roots.isEmpty)
                Button { store.chooseFolderAndScan() } label: { Label("Add", systemImage: "plus") }
                    .disabled(store.isWorking)
            }
            .padding()
            Divider()

            if store.roots.isEmpty {
                ContentUnavailableView("No folders yet", systemImage: "externaldrive",
                                       description: Text("Add a folder or drive to scan."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.roots, id: \.id) { root in rootRow(root) }
                .confirmationDialog("Remove this folder from sort?",
                    isPresented: Binding(get: { rootToRemove != nil },
                                         set: { if !$0 { rootToRemove = nil } }),
                    presenting: rootToRemove) { root in
                    Button("Remove", role: .destructive) {
                        if let id = root.id { store.removeRoot(id) }
                        rootToRemove = nil
                    }
                    Button("Cancel", role: .cancel) { rootToRemove = nil }
                } message: { _ in
                    Text("Stops tracking this folder and clears its photos from sort. "
                         + "Your files on disk are not deleted.")
                }
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }
        .frame(width: 540, height: 440)
        .background(Theme.pageBg)
        .task { store.recheckSources() }   // re-detect a drive unplugged while this sheet is open
    }

    private func rootRow(_ root: ScannedRoot) -> some View {
        let offline = root.id.map { store.offlineRootIDs.contains($0) } ?? false
        return HStack(spacing: 10) {
            Image(systemName: offline ? "externaldrive.badge.xmark" : "folder")
                .foregroundStyle(offline ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: root.displayPath).lastPathComponent).bold()
                Text(root.displayPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if offline {
                Text("offline").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.displayPath)])
            } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            Button { store.scan(path: root.displayPath) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(offline ? "Drive not connected" : "Rescan")
                .disabled(store.isWorking || offline)
            Button { rootToRemove = root } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove from sort (keeps files on disk)")
        }
        .padding(.vertical, 2)
        .opacity(offline ? 0.7 : 1)
    }
}

/// Settings window (⌘,) — tabbed General / Grouping / Privacy / Advanced, matching the wireframe.
/// Persisted via @AppStorage; threshold/model/min-group changes apply on the next scan
/// (read in AppStore.scan + EmbedderFactory.makeDefault).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            GroupingSettings().tabItem { Label("Grouping", systemImage: "person.2.crop.square.stack") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 470)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("watchSources") private var watchSources = true
    @AppStorage("skipDeleteConfirm") private var skipDeleteConfirm = false
    var body: some View {
        Form {
            Section {
                Toggle("Watch sources for new photos", isOn: $watchSources)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Show face boxes on photos", isOn: $store.highlightFaces)
                    Text("Experimental overlay.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Delete without confirming", isOn: $skipDeleteConfirm)
                    Text("Skips the “Move to Trash?” prompt in the photo viewer (Delete / ⌘D). Photos "
                         + "still go to the macOS Trash and stay recoverable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GroupingSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("groupingModel") private var groupingModel = "arcface"
    @AppStorage("clusterThreshold") private var clusterThreshold = 0.45
    @AppStorage("gridTileSize") private var gridTileSize = 160.0
    @AppStorage("petThreshold") private var petThreshold = 0.5
    @AppStorage("minGroup") private var minGroup = 1
    @AppStorage("suggestReach") private var suggestReach = 0.6
    private var arcFaceInstalled: Bool { EmbedderFactory.installedModelURL() != nil }

    var body: some View {
        Form {
            Section {
                Picker("Thumbnail size", selection: $gridTileSize) {
                    Text("Small").tag(128.0)
                    Text("Medium").tag(160.0)
                    Text("Large").tag(210.0)
                }
                .pickerStyle(.segmented)

                Picker("Grouping model", selection: $groupingModel) {
                    Text("On-device face model").tag("arcface")
                    Text("Vision feature print").tag("vision")
                }
                Label {
                    Text(arcFaceInstalled
                         ? "\(EmbedderFactory.installedModelName() ?? "On-device model") installed — accurate face grouping."
                         : "No on-device model — using the Vision fallback (groups roughly).")
                } icon: {
                    Image(systemName: arcFaceInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(arcFaceInstalled ? .green : .orange)
                }
                .font(.caption)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Cluster threshold")
                        Spacer()
                        Text(String(format: "%.2f", clusterThreshold))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $clusterThreshold, in: 0.20...0.60, step: 0.01)
                    Text("Lower groups more strictly. On-device models separate well around 0.35–0.45.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Pet grouping threshold")
                        Spacer()
                        Text(String(format: "%.2f", petThreshold))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $petThreshold, in: 0.30...0.70, step: 0.01)
                    Text("Pets group on Vision feature-prints (looser than faces). Raise to merge a "
                         + "pet split across groups; lower if different pets are merging.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Stepper(value: $minGroup, in: 1...20) {
                        Text("Min. photos per group: \(minGroup)")
                    }
                    Text("Smaller groups stay in “Unnamed”.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Suggest look-alikes down to")
                        Spacer()
                        Text("\(Int((1 - suggestReach) * 100))% match")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $suggestReach, in: 0.45...0.75, step: 0.01)
                    Text("Slide right to surface more, looser merge suggestions (lower match %). "
                         + "Applies immediately to Review and the person pages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Threshold/min-group changes apply on your next scan — or regroup now using the "
                         + "faces already found, without rescanning:")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { store.regroupNow() } label: {
                        Label("Regroup now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isWorking)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                    Text("Sort never moves or edits your originals. The only change it can make is "
                         + "moving a photo to the Trash — and only when you confirm it.")
                        .font(.callout).foregroundStyle(Theme.label)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
                .listRowInsets(EdgeInsets())
            }
            Section {
                Label("On-device — your photos never leave your Mac.", systemImage: "desktopcomputer")
                Label("Read-only index — originals are never modified in place.", systemImage: "doc.on.doc")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var confirmReset = false
    private var indexPath: String { (try? AppDatabase.defaultURL().path) ?? "—" }
    private var modelStatus: String { EmbedderFactory.activeModelDisplayName() }
    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Face model", value: modelStatus)
                LabeledContent("Index", value: indexPath)
            }
            Section {
                Button("Show first-run screen again") { didOnboard = false }
                Text("Reopens onboarding next launch (your scanned folders stay).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset & start fresh…", role: .destructive) { confirmReset = true }
                    .disabled(store.isWorking)
                Text("Untracks every folder and clears the whole index, then returns to onboarding. "
                     + "Your photos on disk are never touched. (For testing: `SORT_FRESH=1 swift run sort-app`.)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("Clear the entire index and start fresh?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset everything", role: .destructive) { store.resetEverything() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all tracked folders, people, and groupings from Sort. "
                     + "Files on disk are not deleted.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Menu-bar dropdown — background-scan status without opening the main window. All data is read
/// straight off `AppStore`; actions route back to the main window.
struct MenuBarPanel: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("watchSources") private var watchSources = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(store.isWorking ? Color.orange : Color.green).frame(width: 8, height: 8)
                Text("Sort").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.titleStrong)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 5)

            Text(store.statusText).font(.system(size: 11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 10)

            if store.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Indexing…").font(.system(size: 11)).foregroundStyle(Theme.label)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.previewWarm)
                .padding(.horizontal, 8).padding(.bottom, 8)
            }

            Divider()
            Button { store.requestReview() } label: {
                HStack {
                    Label("\(store.suggestions.count) pair\(store.suggestions.count == 1 ? "" : "s") to review",
                          systemImage: "person.2.badge.gearshape")
                        .font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(store.suggestions.isEmpty)
            .padding(.horizontal, 14).padding(.vertical, 9)

            if !store.roots.isEmpty {
                Divider()
                Text("SOURCES").font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(Theme.sectionLabel)
                    .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 3)
                ForEach(store.roots.prefix(4), id: \.id) { root in
                    HStack(spacing: 7) {
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.iconStroke)
                        Text(URL(fileURLWithPath: root.displayPath).lastPathComponent)
                            .font(.system(size: 11)).foregroundStyle(Theme.label)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 2)
                }
                Color.clear.frame(height: 6)
            }

            Divider()
            HStack {
                // Toggles the "watch sources" preference the Settings window also exposes; the live
                // FSEvents auto-rescan (FolderWatcher, via updateFolderWatch) picks it up immediately.
                Button(watchSources ? "Pause" : "Resume") { watchSources.toggle() }
                Spacer()
                Button("Open Sort") { store.activateMainWindow() }
            }
            .padding(14)
        }
        .frame(width: 264)
    }
}

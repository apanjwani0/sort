import SwiftUI
import SortKit

/// The "Collections" screen — matches design/Sort Wireframes.html: a Photos|Collections toggle, a
/// quick-access pill row, and an auto-detected CATEGORIES grid. People & pets, Screenshots,
/// Documents, Identity & cards, Places, No faces, Duplicates and Pets are live (real counts, tap to
/// browse); Videos is the only remaining "Soon" card.
struct CollectionsView: View {
    @EnvironmentObject var store: AppStore

    private let cols3 = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                LazyVGrid(columns: cols3, spacing: 10) {
                    QuickPill(title: "Favourites", systemImage: "heart") { store.openFavourites() }
                    QuickPill(title: "Recently added", systemImage: "clock") { store.openRecents() }
                    QuickPill(title: "Videos", systemImage: "play.rectangle") { store.openCategory(.videos) }
                }

                Text("CATEGORIES · AUTO-DETECTED")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(Theme.sectionLabel)

                LazyVGrid(columns: cols3, spacing: 14) {
                    CategoryCard(title: "People & pets", count: store.people.count,
                                 live: true, onTap: { store.openPeople() }) { PeoplePreview() }
                    CategoryCard(title: "Screenshots", count: store.categoryCounts.screenshots,
                                 live: true, onTap: { store.openCategory(.screenshots) }) {
                        CategoryThumb(category: .screenshots) { ScreenshotsPreview() }
                    }
                    CategoryCard(title: "Documents", count: store.categoryCounts.documents,
                                 live: true, onTap: { store.openCategory(.documents) }) {
                        CategoryThumb(category: .documents) { DocumentsPreview() }
                    }
                    CategoryCard(title: "Videos", count: store.categoryCounts.videos,
                                 live: true, onTap: { store.openCategory(.videos) }) {
                        CategoryThumb(category: .videos) { VideosPreview() }
                    }
                    CategoryCard(title: "Identity & cards", count: store.categoryCounts.identity,
                                 live: true, onTap: { store.openCategory(.identity) }) {
                        CategoryThumb(category: .identity) { IdentityPreview() }
                    }
                    CategoryCard(title: "Places", count: store.categoryCounts.places,
                                 live: true, onTap: { store.openPlaces() }) {
                        CategoryThumb(category: .places) { PlacesPreview() }
                    }
                    CategoryCard(title: "No faces", count: store.categoryCounts.noFaces,
                                 live: true, onTap: { store.openCategory(.noFaces) }) {
                        CategoryThumb(category: .noFaces) { NoFacesPreview() }
                    }
                    CategoryCard(title: "Duplicates",
                                 count: store.duplicateGroups.reduce(0) { $0 + $1.count },
                                 live: true, onTap: { store.openDuplicates() }) { DuplicatesPreview() }
                    CategoryCard(title: "Pets", count: store.categoryCounts.pets,
                                 live: true, onTap: { store.openCategory(.pets) }) {
                        CategoryThumb(category: .pets) { PetsPreview() }
                    }
                }

                Text("Faces are one lens — the same on-device engine can bucket screenshots, "
                     + "documents, videos, ID cards and places.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBg)
        .overlay { if store.browsingCategory != nil { CategoryDetailView() } }
        .overlay {
            if let list = store.browsingList {
                PhotoBrowseScreen(
                    title: list.rawValue,
                    emptyTitle: list == .favourites ? "No favourites yet" : "Nothing here yet",
                    emptyIcon: list == .favourites ? "heart" : "clock",
                    emptyMessage: list == .favourites
                        ? "Tap the ♥ on any photo to add it here."
                        : "Newly indexed photos show up here.",
                    onBack: store.closeList)
            }
        }
        .overlay { if store.browsingDuplicates { DuplicatesView() } }
        .overlay { if store.browsingPlaces { PlacesMapView() } }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collections")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.titleStrong)
                Text("It groups more than people")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            ScreenToggle()
        }
    }
}

// MARK: - Photos | Collections toggle

struct ScreenToggle: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 2) {
            segment("Photos", .photos)
            segment("Collections", .collections)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.segmentTrack))
    }

    private func segment(_ title: String, _ screen: AppScreen) -> some View {
        let active = store.screen == screen
        return Text(title)
            .font(.system(size: 12.5, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Theme.titleStrong : Theme.muted)
            .padding(.vertical, 5).padding(.horizontal, 14)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 7).fill(.white)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { store.screen = screen } }
    }
}

// MARK: - Quick-access pill

struct QuickPill: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13)).foregroundStyle(Theme.iconStroke)
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.previewWarm : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action() }
        .help(title)
    }
}

// MARK: - Category card

struct CategoryCard<Preview: View>: View {
    let title: String
    var count: Int? = nil
    var live: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var preview: () -> Preview
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            preview()
                .frame(maxWidth: .infinity).frame(height: 128)
                .background(Theme.previewWarm)
                .clipped()

            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.title)
                Spacer()
                if let count {
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.count)
                } else if !live {
                    Text("Soon").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.previewWarm2))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(Theme.cardBg)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder, lineWidth: 1))
        .opacity(live ? 1 : 0.78)
        .scaleEffect(hovering && live ? 1.01 : 1)
        .shadow(color: .black.opacity(hovering && live ? 0.10 : 0), radius: 7, y: 2)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if live { onTap?() } }
        .help(live ? "Open \(title)" : "\(title) — coming soon")
    }
}

// MARK: - Real category thumbnail (falls back to the wireframe motif when the category is empty)

/// Shows a representative photo for a category card; if the category has no photos (or the file
/// can't be read), it renders the stylized `fallback` motif instead.
private struct CategoryThumb<Fallback: View>: View {
    @EnvironmentObject var store: AppStore
    let category: IndexService.PhotoCategory
    @ViewBuilder var fallback: () -> Fallback
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                // Color.clear sizes to the card slot; the image fills+crops inside it so its oversized
                // scaledToFill intrinsic size can't escape the card (was overflowing onto neighbors).
                Color.clear.overlay {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                .clipped()
            } else {
                fallback()
            }
        }
        .task(id: category) {
            guard let photo = store.firstPhoto(inCategory: category) else { return }
            image = await store.imageLoader.thumbnail(for: photo, maxPixel: 320)
        }
    }
}

// MARK: - Category previews (match the wireframe motifs)

private struct PeoplePreview: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let top = Array(store.people.prefix(4))
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                if i < top.count {
                    PersonAvatar(person: top[i], size: 46)
                } else {
                    Circle().fill(Theme.silhouetteBg)
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "person.fill")
                            .font(.system(size: 20)).foregroundStyle(Theme.silhouetteFg))
                }
            }
        }
        .padding(14)
    }
}

private struct ScreenshotsPreview: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0xE9E8E1))
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.placeholder)
                            .frame(width: 30, height: 4).padding(6)
                    }
                    .frame(height: 40)
            }
        }
        .padding(14)
    }
}

private struct DocumentsPreview: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.placeholder).frame(height: 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
                .frame(width: 46, height: 62)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0xDDDCD3)))
            }
        }
    }
}

private struct VideosPreview: View {
    var body: some View {
        ZStack {
            Theme.previewWarm2
            Circle().fill(.white)
                .frame(width: 46, height: 46)
                .overlay(Circle().strokeBorder(Color(hex: 0xDDDCD3)))
                .overlay(Image(systemName: "play.fill")
                    .font(.system(size: 16)).foregroundStyle(Color(hex: 0xB9B8AE)))
        }
    }
}

private struct IdentityPreview: View {
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xE2E1D8)).frame(width: 34, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.placeholder).frame(height: 4)
                }
            }
        }
        .padding(9)
        .frame(width: 104, height: 66)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xDDDCD3)))
    }
}

private struct NoFacesPreview: View {
    var body: some View {
        ZStack {
            Theme.previewWarm2
            Image(systemName: "photo")
                .font(.system(size: 26)).foregroundStyle(Theme.silhouetteFg)
        }
    }
}

private struct PetsPreview: View {
    var body: some View {
        ZStack {
            Theme.previewWarm2
            Image(systemName: "pawprint.fill").font(.system(size: 26)).foregroundStyle(Theme.silhouetteFg)
        }
    }
}

private struct DuplicatesPreview: View {
    var body: some View {
        ZStack {
            Theme.previewWarm2
            ForEach(0..<2, id: \.self) { i in
                RoundedRectangle(cornerRadius: 6).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xDDDCD3)))
                    .overlay(Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(Theme.silhouetteFg))
                    .frame(width: 46, height: 46)
                    .rotationEffect(.degrees(i == 0 ? -6 : 6))
                    .offset(x: i == 0 ? -10 : 10, y: i == 0 ? -4 : 4)
            }
        }
    }
}

private struct PlacesPreview: View {
    var body: some View {
        ZStack {
            Theme.previewWarm2
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Color(hex: 0xD8D7CE))
                    .frame(height: 1.5)
                    .rotationEffect(.degrees([8, -6, 5][i]))
                    .offset(y: CGFloat([-30, 6, 40][i]))
                    .padding(.horizontal, -10)
            }
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22)).foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Photo browse (categories + Favourites / Recently added)

/// A back-button header, an optional multi-select Move-to-Trash action, and a `PhotoGridView` over
/// `store.photos`. Shared by the category cards and the Favourites / Recently-added quick lists.
struct PhotoBrowseScreen: View {
    @EnvironmentObject var store: AppStore
    let title: String
    var emptyTitle = "Nothing here yet"
    var emptyIcon = "square.stack.3d.up.slash"
    var emptyMessage = "Re-scan a folder so sort can classify it."
    let onBack: () -> Void
    @State private var confirmTrash = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { onBack() } label: { Label("Collections", systemImage: "chevron.backward") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.titleStrong)
                Text("\(store.photos.count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                if !store.selection.isEmpty {
                    Text("\(store.selection.count) selected")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.label)
                    Button("Clear") { store.clearSelection() }.buttonStyle(.link)
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
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Theme.cardBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            if store.photos.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptyMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.pageBg)
            } else {
                PhotoGridView(photos: store.photos, highlight: false, rects: [:])
            }
        }
        .background(Theme.pageBg)
        .overlay { if store.viewerPhoto != nil { LightboxView() } }
    }
}

struct CategoryDetailView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        PhotoBrowseScreen(title: store.browsingCategoryTitle, onBack: store.closeCategory)
    }
}

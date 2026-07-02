import SwiftUI
import AppKit
import SortKit

/// Browse near-identical photo sets and trim them. Each set is laid out side-by-side with resolution,
/// file size and date so you can compare at a glance; click a photo to open it full-size (arrow keys
/// step through the set), and trash the copies you don't want. The highest-res copy is flagged "Best".
struct DuplicatesView: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmCleanup = false
    @State private var confirmKeepBest = false

    private var totalPhotos: Int { store.duplicateGroups.reduce(0) { $0 + $1.count } }
    private var trimCount: Int { store.duplicatesToTrim.count }
    private var trimSpace: String {
        ByteCountFormatter.string(fromByteCount: store.duplicatesToTrim.reduce(0) { $0 + $1.size }, countStyle: .file)
    }
    private var selTrimCount: Int { store.selectedDupTrim.count }
    private var selTrimSpace: String {
        ByteCountFormatter.string(fromByteCount: store.selectedDupTrim.reduce(0) { $0 + $1.size }, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.closeDuplicates() } label: { Label("Collections", systemImage: "chevron.backward") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                Text("Duplicates").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.titleStrong)
                if !store.duplicateGroups.isEmpty {
                    Text("\(store.duplicateGroups.count) set\(store.duplicateGroups.count == 1 ? "" : "s") · \(totalPhotos) photos")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !store.duplicateGroups.isEmpty {
                    Button { store.selectAllDupGroups() } label: {
                        Label(store.allDupGroupsSelected ? "Deselect all" : "Select all",
                              systemImage: store.allDupGroupsSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                if !store.selectedDupGroups.isEmpty {
                    Button(role: .destructive) { confirmKeepBest = true } label: {
                        Label("Keep best, delete rest", systemImage: "wand.and.stars")
                    }
                    .disabled(store.isWorking || selTrimCount == 0)
                    .confirmationDialog("Delete \(selTrimCount) photo\(selTrimCount == 1 ? "" : "s") from \(store.selectedDupGroups.count) set\(store.selectedDupGroups.count == 1 ? "" : "s")?",
                                        isPresented: $confirmKeepBest, titleVisibility: .visible) {
                        Button("Keep best, delete \(selTrimCount) · free \(selTrimSpace)", role: .destructive) { store.deleteSelectedDupGroups() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Keeps the best copy in each ticked set and moves the other \(selTrimCount) "
                             + "to the Trash (recoverable), freeing about \(selTrimSpace).")
                    }
                } else if trimCount > 0 {
                    Button(role: .destructive) { confirmCleanup = true } label: {
                        Label("Delete all but best", systemImage: "wand.and.stars")
                    }
                    .disabled(store.isWorking)
                    .confirmationDialog("Delete \(trimCount) duplicate\(trimCount == 1 ? "" : "s")?",
                                        isPresented: $confirmCleanup, titleVisibility: .visible) {
                        Button("Delete \(trimCount) · free \(trimSpace)", role: .destructive) { store.deleteAllButBest() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Keeps the highest-resolution copy in each set and moves the other \(trimCount) "
                             + "to the Trash (recoverable), freeing about \(trimSpace).")
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Theme.cardBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            if store.duplicateGroups.isEmpty {
                ContentUnavailableView("No duplicates",
                    systemImage: "square.on.square.dashed",
                    description: Text("No near-identical photos found. Re-scan after adding photos."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pageBg)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Key on a stable set id (its first photo) — NOT the array offset, which shifts
                        // when a set is trimmed and reassigns row views to the wrong group's data.
                        ForEach(store.duplicateGroups, id: \.first?.id) { group in
                            DuplicateSetRow(group: group)
                        }
                    }
                    .padding(20)
                }
                .background(Theme.pageBg)
            }
        }
        .background(Theme.pageBg)
        .overlay { if store.viewerPhoto != nil { LightboxView() } }
    }
}

private struct DuplicateSetRow: View {
    @EnvironmentObject var store: AppStore
    let group: [Photo]
    private var selected: Bool { store.isDupGroupSelected(group) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { store.toggleDupGroup(group) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain)
                .help(selected ? "Deselect this set" : "Select this set")
                Text("\(group.count) near-identical")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.label)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(group.enumerated()), id: \.element.id) { idx, photo in
                        DuplicatePhotoCard(photo: photo, group: group, isBest: idx == 0)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Theme.accent : Theme.cardBorder, lineWidth: selected ? 2 : 1))
    }
}

private struct DuplicatePhotoCard: View {
    @EnvironmentObject var store: AppStore
    let photo: Photo
    let group: [Photo]
    let isBest: Bool
    @State private var image: NSImage?
    @State private var confirmTrash = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.previewWarm)
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { ProgressView().controlSize(.small) }
            }
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if isBest {
                    Text("Best").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.green)).padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.previewSet(photo, in: group) }   // click → full-size, arrow-key nav

            if let w = photo.width, let h = photo.height {
                Text("\(w)×\(h)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.label)
            }
            Text(ByteCountFormatter.string(fromByteCount: photo.size, countStyle: .file))
                .font(.system(size: 10)).foregroundStyle(Theme.muted)

            HStack(spacing: 8) {
                Button { store.markBest(photo, in: group) } label: {
                    Label(isBest ? "Best" : "Set best", systemImage: isBest ? "star.fill" : "star")
                }
                .controlSize(.small).foregroundStyle(isBest ? .orange : Theme.accent).disabled(isBest)
                .help("Keep this one when trimming this set")

                Button(role: .destructive) { confirmTrash = true } label: { Label("Trash", systemImage: "trash") }
                    .controlSize(.small)
                    .confirmationDialog("Move this photo to the Trash?",
                                        isPresented: $confirmTrash, titleVisibility: .visible) {
                        Button("Move to Trash", role: .destructive) { if let id = photo.id { store.deletePhotos([id]) } }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Recoverable from your macOS Trash.") }
            }
        }
        .frame(width: 280)
        .help(URL(fileURLWithPath: photo.relativePath).lastPathComponent)
        .task(id: photo.id) { image = await store.imageLoader.thumbnail(for: photo, maxPixel: 560) }
    }
}

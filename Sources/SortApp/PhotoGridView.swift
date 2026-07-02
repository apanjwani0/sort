import SwiftUI
import AppKit
import AVFoundation
import SortKit

/// Loads downsampled thumbnails, cached by photo id. Read-only decode (ImageLoader → SourceAccess),
/// downsampled so full-res images never sit in memory per cell.
final class PhotoImageLoader: @unchecked Sendable {
    private let cache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.countLimit = 600                      // bound entries…
        c.totalCostLimit = 256 * 1024 * 1024    // …and ~256 MB of bitmaps, so NSCache evicts under pressure
        return c
    }()
    var roots: [Int64: String] = [:]   // rootId → path, refreshed after each scan (main actor)

    func url(for photo: Photo) -> URL? {
        guard let base = roots[photo.rootId] else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(photo.relativePath)
    }

    /// Cache lookup + URL resolution stay on the main actor (safe); the actual decode runs off-main so
    /// scrolling never blocks the UI thread. ponytail: one detached decode per cell — fine; add a
    /// bounded queue only if huge fast-scroll sessions show decodes piling up.
    @MainActor func thumbnail(for photo: Photo, maxPixel: Int = 400) async -> NSImage? {
        guard let id = photo.id else { return nil }
        let key = NSNumber(value: id)
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = url(for: photo) else { return nil }
        let cg: CGImage? = photo.category == "video"
            ? await Self.videoPoster(url, maxPixel: maxPixel)
            : await Task.detached(priority: .utility) {
                try? ImageLoader.load(url, maxPixelSize: maxPixel)
            }.value
        let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        if let image {
            // Cost ≈ decoded bitmap bytes so totalCostLimit can evict the biggest thumbnails first.
            let cost = Int(image.size.width * image.size.height) * 4
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// A poster frame for a video (first decodable frame near the start). `AVAssetImageGenerator` does
    /// its own off-main work, so no extra detach. ponytail: one frame at t≈0.5s — good enough for a card.
    private static func videoPoster(_ url: URL, maxPixel: Int) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        for t in [CMTime(seconds: 0.5, preferredTimescale: 600), .zero] {
            if let cg = try? await gen.image(at: t).image {
                return cg
            }
        }
        return nil
    }
}

/// The per-person photo grid (SwiftUI). Supports multi-select → Move to Trash, a context menu
/// (Open / Reveal in Finder / Copy Path), and the #6 face-highlight overlay.
struct PhotoGridView: View {
    @EnvironmentObject var store: AppStore
    let photos: [Photo]
    var highlight: Bool
    var rects: [Int64: [CGRect]]

    @AppStorage("gridTileSize") private var gridTileSize = 160.0
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: gridTileSize, maximum: gridTileSize * 1.35), spacing: 10)] }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(photos, id: \.id) { photo in
                    PhotoCell(photo: photo,
                              selected: store.selection.contains(photo.id ?? -1),
                              highlight: highlight,
                              faceRects: rects[photo.id ?? -1] ?? [])
                        // ⌘-click toggles, ⇧-click range-selects. Plain click opens the viewer —
                        // unless Select mode is on, where it toggles selection (no modifier needed).
                        .highPriorityGesture(TapGesture().modifiers(.command).onEnded { store.toggleSelect(photo) })
                        .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { store.rangeSelect(photo) })
                        .onTapGesture { store.selectMode ? store.toggleSelect(photo) : store.openViewer(photo) }
                }
            }
            .padding(16)
        }
        .background(Theme.pageBg)
    }
}

private struct PhotoCell: View {
    @EnvironmentObject var store: AppStore
    let photo: Photo
    var selected: Bool
    var highlight: Bool
    var faceRects: [CGRect]
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.previewWarm)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                if highlight, !faceRects.isEmpty {
                    GeometryReader { geo in
                        let fit = Self.aspectFit(imageSize: image.size, in: geo.size)
                        ForEach(Array(faceRects.enumerated()), id: \.offset) { _, r in
                            let box = Self.mapBox(r, fit: fit)
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.accent, lineWidth: 2)
                                .frame(width: box.width, height: box.height)
                                .position(x: box.midX, y: box.midY)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Theme.accent : Theme.cardBorder, lineWidth: selected ? 3 : 1))
        .overlay(alignment: .topLeading) {
            if selected || hovering || store.selectMode {
                Button { store.toggleSelect(photo) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selected ? Theme.accent : .white)
                        .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .overlay(alignment: .center) {
            if photo.category == "video" {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34)).foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 3).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if store.isFavorite(photo) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .padding(6).allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(hovering ? 0.18 : 0.07), radius: hovering ? 9 : 3.5, y: hovering ? 4 : 1.5)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(selected ? "Deselect" : "Select") { store.toggleSelect(photo) }
            Button(store.isFavorite(photo) ? "Remove from Favourites" : "Favourite") { store.toggleFavorite(photo) }
            Divider()
            Button("Open") { if let u = store.url(for: photo) { NSWorkspace.shared.open(u) } }
            Button("Reveal in Finder") {
                if let u = store.url(for: photo) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            Button("Copy Path") {
                if let u = store.url(for: photo) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(u.path, forType: .string)
                }
            }
            if store.selectedPersonID != nil {
                Button("Set as cover") { store.setCover(photo) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                if let id = photo.id { store.deletePhotos([id]) }
            }
        }
        .task(id: photo.id) { image = await store.imageLoader.thumbnail(for: photo) }
    }

    /// Rect of an aspect-fit image inside `container` (letterboxed).
    static func aspectFit(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .init(origin: .zero, size: container) }
        return AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: container))
    }

    /// Map a Vision-normalized box (origin bottom-left) into the fitted image rect (top-left coords).
    static func mapBox(_ n: CGRect, fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + n.minX * fit.width,
               y: fit.minY + (1 - n.minY - n.height) * fit.height,
               width: n.width * fit.width,
               height: n.height * fit.height)
    }
}

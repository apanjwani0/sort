import SwiftUI
import AppKit
import AVKit
import SortKit

/// In-app image viewer (the "modern image viewer" — replaces opening photos in an external app).
/// Full-window: large image, ←/→ through the current person's photos, pinch/double-click zoom, an
/// info panel, Reveal in Finder, and Move to Trash. Esc closes.
struct LightboxView: View {
    @EnvironmentObject var store: AppStore
    @State private var image: NSImage?
    @State private var player: AVPlayer?    // non-nil while viewing a video (F4)
    @State private var scale: CGFloat = 1
    @State private var showInfo = false
    @State private var confirmTrash = false
    @AppStorage("skipDeleteConfirm") private var skipDeleteConfirm = false

    private var current: Photo? { store.viewerPhoto }

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
                .onTapGesture { store.closeViewer() }

            Group {
                if let player {
                    VideoPlayerView(player: player)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnificationGesture()
                            .onChanged { scale = max(1, min(6, $0)) }
                            .onEnded { _ in if scale < 1.05 { withAnimation { scale = 1 } } })
                        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .padding(40)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .overlay(alignment: .trailing) { if showInfo { infoPanel.transition(.move(edge: .trailing)) } }
        .background {   // keyboard-only: Delete or ⌘D trashes the current photo
            Button("") { requestTrash() }.keyboardShortcut(.delete, modifiers: []).opacity(0)
            Button("") { requestTrash() }.keyboardShortcut("d", modifiers: .command).opacity(0)
        }
        .task(id: store.viewerPhotoID) { await load() }   // reload + reset zoom when the photo id changes
        .onDisappear { player?.pause(); player = nil }     // stop playback when the viewer closes
    }

    private func requestTrash() {
        if skipDeleteConfirm { trash() } else { confirmTrash = true }
    }

    private var topBar: some View {
        HStack {
            Button { store.closeViewer() } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction).help("Close (Esc)")
            Spacer()
            if let c = current {
                Text(URL(fileURLWithPath: c.relativePath).lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.92))
            }
            Spacer()
            Button { withAnimation { showInfo.toggle() } } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
            }.help("Info")
        }
        .buttonStyle(.plain).foregroundStyle(.white).font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
        .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            Button { store.viewerStep(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            if let i = store.viewerIndex {
                Text("\(i + 1) of \(store.photos.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            Button { store.viewerStep(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])

            Spacer()

            if store.viewingDuplicateSet, let c = current {
                let isBest = c.id.map { store.pinnedBest.contains($0) } ?? false
                Button { store.markBest(c) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: isBest ? "star.fill" : "star")
                        Text(isBest ? "Best" : "Set best").font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(isBest ? .yellow : .white)
                .help("Keep this one when trimming this duplicate set")
            }
            if let c = current {
                let fav = store.isFavorite(c)
                Button { store.toggleFavorite(c) } label: { Image(systemName: fav ? "heart.fill" : "heart") }
                    .foregroundStyle(fav ? .pink : .white)
                    .keyboardShortcut("f", modifiers: [])
                    .help(fav ? "Remove from Favourites (F)" : "Add to Favourites (F)")
            }
            Button { reveal() } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
            Button(role: .destructive) { requestTrash() } label: { Image(systemName: "trash") }
                .help("Move to Trash (Delete or ⌘D)")
                .confirmationDialog("Move this photo to the Trash?",
                                    isPresented: $confirmTrash, titleVisibility: .visible) {
                    Button("Move to Trash", role: .destructive) { trash() }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Recoverable from your macOS Trash.") }
        }
        .buttonStyle(.plain).foregroundStyle(.white).font(.system(size: 17, weight: .medium))
        .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 18)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info").font(.headline).foregroundStyle(.white)
            if let c = current {
                row("File", URL(fileURLWithPath: c.relativePath).lastPathComponent)
                if let url = store.url(for: c) { row("Folder", url.deletingLastPathComponent().path) }
                if let url = store.url(for: c) { row("Path", url.path) }
                row("Size", ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file))
                if let w = c.width, let h = c.height { row("Dimensions", "\(w) × \(h)") }
            }
            Spacer()
        }
        .padding(16).frame(width: 290).frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.55))
    }

    private func row(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 12)).foregroundStyle(.white).textSelection(.enabled)
        }
    }

    private func load() async {
        image = nil; scale = 1
        player?.pause(); player = nil
        guard let c = current, let url = store.url(for: c) else { return }
        if c.category == "video" {            // play instead of decode-as-image (F4)
            player = AVPlayer(url: url)
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            (try? ImageLoader.load(url, maxPixelSize: 2400))
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }.value
        if Task.isCancelled { return }   // user arrowed to another photo mid-decode
        image = decoded
    }

    private func reveal() {
        if let c = current, let url = store.url(for: c) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func trash() {
        if let id = current?.id { store.deletePhotos([id]); store.closeViewer() }
    }
}

/// AppKit `AVPlayerView` hosted in SwiftUI. We use this instead of SwiftUI's `VideoPlayer`, which
/// crashes on macOS in this SwiftPM build during generic-metadata instantiation of its representable
/// (SIGABRT in `getSuperclassMetadata`). `AVPlayerView` is a plain ObjC class, so it sidesteps that path.
private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

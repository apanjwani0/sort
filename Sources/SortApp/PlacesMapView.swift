import SwiftUI
import MapKit
import SortKit

/// A photo cluster pinned on the map (one coarse location bucket), optionally user-named.
struct PlaceCluster: Identifiable {
    let id: String                 // bucket key (stable across launches; keys the place name)
    let coordinate: CLLocationCoordinate2D
    let photos: [Photo]
    var name: String?
}

/// "Places" as an on-device map: photos appear as count pins clustered by area; zoom with the map
/// controls, tap a pin to see the photos taken there, and name a cluster so it shows as a place.
/// No network — coordinates never leave the Mac.
struct PlacesMapView: View {
    @EnvironmentObject var store: AppStore
    @State private var clusters: [PlaceCluster] = []
    @State private var position: MapCameraPosition = .automatic   // auto-frames all pins
    @State private var selected: PlaceCluster?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.closePlaces() } label: { Label("Collections", systemImage: "chevron.backward") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                Text("Places").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.titleStrong)
                let total = clusters.reduce(0) { $0 + $1.photos.count }
                if total > 0 {
                    Text("\(total) photo\(total == 1 ? "" : "s") · \(clusters.count) place\(clusters.count == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Theme.cardBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            if clusters.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "mappin.slash",
                    description: Text("Photos with GPS location appear here. Re-scan a folder that has geotagged photos."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pageBg)
            } else {
                Map(position: $position) {
                    ForEach(clusters) { cluster in
                        Annotation(cluster.name ?? "", coordinate: cluster.coordinate) {
                            Button { selected = cluster } label: {
                                ClusterPin(count: cluster.photos.count, name: cluster.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControls { MapZoomStepper(); MapCompass() }   // zoom in/out + reorient
            }
        }
        .background(Theme.pageBg)
        .task { reload() }
        .onChange(of: store.placeNames) { _, _ in reload() }   // reflect a just-saved place name on the pin
        .sheet(item: $selected) { cluster in PlaceClusterSheet(cluster: cluster) }
    }

    private func reload() {
        clusters = store.placeGroups().map {
            PlaceCluster(id: $0.key,
                         coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                         photos: $0.photos, name: store.placeNames[$0.key])
        }
    }
}

private struct ClusterPin: View {
    let count: Int
    var name: String?
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin.circle.fill").font(.system(size: 11))
            if let name, !name.isEmpty {
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("·").foregroundStyle(.white.opacity(0.7))
            }
            Text("\(count)").font(.system(size: 11, weight: .bold)).monospacedDigit()
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Theme.accent))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// The photos taken at one place. Sets `store.photos` so the lightbox steps through just this set,
/// and lets the user name the location.
private struct PlaceClusterSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let cluster: PlaceCluster
    @State private var placeName = ""
    @State private var savedPhotos: [Photo] = []   // restore the map's photos when the sheet closes

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.accent)
                TextField("Name this place", text: $placeName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .onSubmit { store.setPlaceName(placeName, for: cluster.id) }
                Button("Save") { store.setPlaceName(placeName, for: cluster.id) }
                Spacer()
                Text("\(cluster.photos.count) photo\(cluster.photos.count == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.cardBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            PhotoGridView(photos: cluster.photos, highlight: false, rects: [:])
        }
        .frame(width: 760, height: 560)
        .background(Theme.pageBg)
        .overlay { if store.viewerPhoto != nil { LightboxView() } }
        .onAppear { placeName = cluster.name ?? ""; savedPhotos = store.photos; store.photos = cluster.photos }
        .onDisappear { store.closeViewer(); store.photos = savedPhotos }
    }
}

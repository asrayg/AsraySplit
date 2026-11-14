import MapKit
import SwiftUI

/// Where everyone is (for those sharing), plus the Airbnb.
@MainActor
struct CrewMapView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 18.4590, longitude: -66.0700), span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)))

    private var location: LocationSharing { app.env.location }
    static let airbnb = CLLocationCoordinate2D(latitude: 18.4573, longitude: -66.0716)

    var body: some View {
        Map(position: $camera) {
            Annotation("Airbnb", coordinate: Self.airbnb) {
                Image(systemName: "house.fill").padding(6).background(.orange, in: Circle()).foregroundStyle(.white)
            }
            ForEach(location.friends) { friend in
                Annotation(friend.displayName, coordinate: CLLocationCoordinate2D(latitude: friend.latitude, longitude: friend.longitude)) {
                    VStack(spacing: 2) {
                        Avatar(name: friend.displayName, size: 34)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                        Text(friend.recordedAt, format: .relative(presentation: .named))
                            .font(.caption2).padding(.horizontal, 4).background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            UserAnnotation()
        }
        .mapControls { MapUserLocationButton(); MapCompass() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Toggle("Share my location", isOn: Binding(get: { location.isSharing }, set: { location.setSharing($0) }))
                    .font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(12)
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .task { location.tripID = tripID; location.resume() }
        .task { await location.watchFriends() }
    }
}

import MapKit
import SwiftUI

/// Where everyone is (for those sharing), plus the Airbnb.
@MainActor
struct CrewMapView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 18.4590, longitude: -66.0965), span: MKCoordinateSpan(latitudeDelta: 0.11, longitudeDelta: 0.075)))

    @State private var selected: TripPlace?
    @State private var dayFilter = "All"
    @Environment(\.openURL) private var openURL

    private var location: LocationSharing { app.env.location }
    private static let days = ["All", "Thu", "Fri", "Sat", "Sun", "Mon", "Tue"]

    private var places: [TripPlace] {
        guard dayFilter != "All" else { return TripPlace.puertoRico }
        return TripPlace.puertoRico.filter { $0.kind == .stay || $0.kind == .car || ($0.day?.contains(dayFilter) ?? false) }
    }

    var body: some View {
        Map(position: $camera) {
            ForEach(places) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    Image(systemName: place.symbol)
                        .font(.system(size: place.kind == .stay || place.kind == .car ? 16 : 12, weight: .bold))
                        .padding(place.kind == .stay || place.kind == .car ? 8 : 6)
                        .background(Self.color(place.kind), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: selected == place ? 3 : 1.5))
                        .foregroundStyle(.white)
                        .onTapGesture {
                            selected = place
                            if place.kind == .stay, app.eggs.tap("airbnb", needed: 5) {
                                app.eggs.trigger(.airbnb, "🏠 1364 Calle Estrella. Home sweet Airbnb.", rain: ["🏠", "🌴", "🛏️"])
                            }
                        }
                }
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
        .safeAreaInset(edge: .top) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.days, id: \.self) { day in
                        Button(day) { dayFilter = day; selected = nil }
                            .font(.caption.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(dayFilter == day ? Color.brand : Color.surface, in: Capsule())
                            .foregroundStyle(dayFilter == day ? Color.onBrand : Color.primary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let selected {
                    HStack {
                        Image(systemName: selected.symbol).foregroundStyle(Self.color(selected.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.name).font(.subheadline.bold())
                            if let day = selected.day { Text(day).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { if let url = selected.mapsURL { openURL(url) } } label: { Label("Go", systemImage: "arrow.triangle.turn.up.right.circle.fill") }
                            .buttonStyle(.borderedProminent)
                        Button { self.selected = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    Divider()
                }
                Toggle("Share my location", isOn: Binding(get: { location.isSharing }, set: { location.setSharing($0) }))
                    .font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(12)
        }
        .navigationTitle("Map")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("San Juan") { withAnimation { camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 18.4590, longitude: -66.0900), span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))) } }
                    Button("Old San Juan") { withAnimation { camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 18.4665, longitude: -66.1160), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))) } }
                    Button("El Yunque & Luquillo") { withAnimation { camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 18.345, longitude: -65.75), span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))) } }
                    Button("Fajardo & Icacos") { withAnimation { camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 18.365, longitude: -65.61), span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))) } }
                    Button("Whole island trip") { withAnimation { camera = .automatic } }
                } label: { Image(systemName: "scope") }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { location.tripID = tripID; location.resume() }
        .task { await location.watchFriends() }
    }

    static func color(_ kind: TripPlace.Kind) -> Color {
        switch kind {
        case .stay: .orange
        case .car: .blue
        case .airport: .gray
        case .beach: .cyan
        case .sight: .brown
        case .nature: .green
        case .food: .red
        case .bar: .purple
        case .boat: .teal
        }
    }
}

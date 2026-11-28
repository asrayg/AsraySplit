import CoreLocation
import Foundation

/// Itinerary spots for the map. Coordinates from Apple Maps (Café Berlin approximate: Plaza Colón).
struct TripPlace: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case stay, car, airport, beach, sight, nature, food, bar, boat }
    let name: String
    let kind: Kind
    let latitude: Double
    let longitude: Double
    var day: String? = nil
    var id: String { name }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var symbol: String {
        switch kind {
        case .stay: "house.fill"
        case .car: "car.fill"
        case .airport: "airplane"
        case .beach: "beach.umbrella.fill"
        case .sight: "building.columns.fill"
        case .nature: "leaf.fill"
        case .food: "fork.knife"
        case .bar: "wineglass.fill"
        case .boat: "ferry.fill"
        }
    }

    var mapsURL: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(q)")
    }
}

extension TripPlace {
    static let puertoRico: [TripPlace] = [
        TripPlace(name: "Airbnb · 1364 Calle Estrella", kind: .stay, latitude: 18.45171, longitude: -66.06923),
        TripPlace(name: "Rental car · 1050 Ashford Ave", kind: .car, latitude: 18.45812, longitude: -66.07593, day: "Sat–Sun"),
        TripPlace(name: "SJU Airport", kind: .airport, latitude: 18.43726, longitude: -66.00410, day: "Thu / Tue"),
        TripPlace(name: "Vagón", kind: .food, latitude: 18.45128, longitude: -66.07375, day: "Thu"),
        TripPlace(name: "Escambrón Beach", kind: .beach, latitude: 18.46715, longitude: -66.09005, day: "Mon"),
        TripPlace(name: "Condado Beach", kind: .beach, latitude: 18.45760, longitude: -66.07080, day: "Fri"),
        TripPlace(name: "Pinky’s Condado", kind: .food, latitude: 18.45790, longitude: -66.07330, day: "Fri"),
        TripPlace(name: "Café Berlin", kind: .food, latitude: 18.46546, longitude: -66.10624, day: "Fri"),
        TripPlace(name: "St. Germain Bistro", kind: .food, latitude: 18.46673, longitude: -66.11667, day: "Fri"),
        TripPlace(name: "Castillo San Felipe del Morro", kind: .sight, latitude: 18.47100, longitude: -66.12423, day: "Fri"),
        TripPlace(name: "Paseo de la Princesa", kind: .sight, latitude: 18.46329, longitude: -66.11859, day: "Fri"),
        TripPlace(name: "La Placita de Santurce", kind: .bar, latitude: 18.45068, longitude: -66.06998, day: "Fri"),
        TripPlace(name: "Juan Diego Falls", kind: .nature, latitude: 18.31204, longitude: -65.77728, day: "Sat"),
        TripPlace(name: "Angelito Trail", kind: .nature, latitude: 18.32330, longitude: -65.74694, day: "Sat"),
        TripPlace(name: "La Coca Falls", kind: .nature, latitude: 18.31877, longitude: -65.77135, day: "Sat"),
        TripPlace(name: "Yokahú Tower", kind: .nature, latitude: 18.31246, longitude: -65.77023, day: "Sat"),
        TripPlace(name: "Luquillo Kiosks", kind: .food, latitude: 18.38059, longitude: -65.73615, day: "Sat"),
        TripPlace(name: "Luquillo Beach", kind: .beach, latitude: 18.37228, longitude: -65.72126, day: "Sat"),
        TripPlace(name: "El Batey", kind: .bar, latitude: 18.46638, longitude: -66.11822, day: "Sat / Sun"),
        TripPlace(name: "La Factoría", kind: .bar, latitude: 18.46721, longitude: -66.11749, day: "Sat"),
        TripPlace(name: "Icacos boat check-in · Villa Marina", kind: .boat, latitude: 18.34133, longitude: -65.63938, day: "Sun"),
        TripPlace(name: "Icacos Island", kind: .boat, latitude: 18.38622, longitude: -65.58861, day: "Sun"),
        TripPlace(name: "La Vergüenza", kind: .bar, latitude: 18.46789, longitude: -66.11448, day: "Sun"),
        TripPlace(name: "La Taberna Lúpulo", kind: .bar, latitude: 18.46743, longitude: -66.11731, day: "Sun"),
        TripPlace(name: "Monostereo", kind: .bar, latitude: 18.46725, longitude: -66.11726, day: "Sun"),
        TripPlace(name: "Los 3 Cuernos", kind: .bar, latitude: 18.46651, longitude: -66.11277, day: "Sun"),
                TripPlace(name: "Bebo’s Café", kind: .food, latitude: 18.45178, longitude: -66.06270, day: "Mon"),
        TripPlace(name: "Orozco’s", kind: .food, latitude: 18.45617, longitude: -66.07245),
        TripPlace(name: "Atabey", kind: .food, latitude: 18.45873, longitude: -66.07694),
        TripPlace(name: "Verde Mesa", kind: .food, latitude: 18.46407, longitude: -66.11699),
    ]
}

import Foundation

/// Ride details extracted from an Uber or Lyft receipt (screenshot, PDF or shared text).
struct RideDetails: Codable, Equatable, Sendable {
    enum Provider: String, Codable, Sendable, CaseIterable {
        case uber, lyft

        var displayName: String { self == .uber ? "Uber" : "Lyft" }
    }

    var provider: Provider
    var product: String?
    var pickup: String?
    var dropoff: String?
    var distance: String?
    var duration: String?
    var driverName: String?

    /// "Uber · 123 Main St → 500 Market St"
    var summary: String {
        var parts = [product.map { $0.hasPrefix(provider.displayName) ? $0 : "\(provider.displayName) \($0)" } ?? provider.displayName]
        if let pickup, let dropoff { parts.append("\(pickup) → \(dropoff)") }
        else if let dropoff { parts.append("to \(dropoff)") }
        return parts.joined(separator: " · ")
    }
}


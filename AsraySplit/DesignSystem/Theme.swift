import SwiftUI
import UIKit

extension Color {
    /// Builds a color that adapts to light/dark mode and increased contrast.
    static func adaptive(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) -> Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let highContrast = traits.accessibilityContrast == .high
            let hex = isDark ? (highContrast ? highContrastDark ?? dark : dark) : (highContrast ? highContrastLight ?? light : light)
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    init(hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x23C58A
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static let canvas = Color.adaptive(light: 0xF4F7F6, dark: 0x090E12)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x131B1F, highContrastDark: 0x1C262B)
    static let surfaceRaised = Color.adaptive(light: 0xEAF1EE, dark: 0x1A2429)
    /// Brand mint. The light variant is darkened to keep 4.5:1 contrast on white.
    static let brand = Color.adaptive(light: 0x0B7F57, dark: 0x6EEDB5, highContrastLight: 0x065F40, highContrastDark: 0x9BF5CD)
    static let onBrand = Color.adaptive(light: 0xFFFFFF, dark: 0x062018)
    static let positive = Color.adaptive(light: 0x0B7F57, dark: 0x6EEDB5)
    static let negative = Color.adaptive(light: 0xB4471A, dark: 0xFFA36B)
    static let warning = Color.adaptive(light: 0x8A5A00, dark: 0xFFC857)
}

/// Positive/negative money styling never relies on color alone: callers also use words or signs.
@MainActor
struct BalanceText: View {
    let minor: Int64
    let currency: CurrencyCode
    var font: Font = .headline

    var body: some View {
        Text(Money(minorUnits: abs(minor), currency: currency).formatted())
            .font(font.monospacedDigit())
            .foregroundStyle(minor > 0 ? Color.positive : minor < 0 ? Color.negative : Color.secondary)
    }
}

@MainActor
struct Avatar: View {
    let name: String
    var size: CGFloat = 36
    var tint: Color = .brand
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * scale * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(Color.onBrand)
            .frame(width: size * scale, height: size * scale)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Color.brand.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(Color.onBrand)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Color.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(Color.primary)
    }
}

@MainActor
struct SyncStateBadge: View {
    let state: SyncState

    var body: some View {
        switch state {
        case .synced: EmptyView()
        case .pending:
            Label("Waiting to sync", systemImage: "icloud.and.arrow.up")
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
                .accessibilityLabel(Text("Waiting to sync"))
        case .failed:
            Label("Sync failed", systemImage: "exclamationmark.icloud.fill")
                .labelStyle(.iconOnly).foregroundStyle(Color.negative)
                .accessibilityLabel(Text("Sync failed"))
        case .conflict:
            Label("Needs review", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly).foregroundStyle(Color.warning)
                .accessibilityLabel(Text("Changed on another device, needs review"))
        }
    }
}

@MainActor
struct ErrorBanner: View {
    let error: AppError
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: error == .offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                .foregroundStyle(error == .offline ? Color.secondary : Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.subheadline.bold())
                Text(error.message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let retry { Button("Retry", action: retry).font(.subheadline.bold()) }
        }
        .padding(12)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct ToastView: View {
    let toast: Toast
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.style == .success ? "checkmark.circle.fill" : toast.style == .warning ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(toast.style == .warning ? Color.warning : Color.brand)
            Text(toast.message).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let undo = toast.undo {
                Button("Undo") { Task { await undo(); dismiss() } }.font(.subheadline.bold())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// Standard screen background.
    func screenBackground() -> some View {
        scrollContentBackground(.hidden).background(Color.canvas.ignoresSafeArea())
    }
}

extension Date {
    var shortDay: String { formatted(.dateTime.month(.abbreviated).day()) }
}

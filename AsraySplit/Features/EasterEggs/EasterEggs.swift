import SwiftUI
import UIKit

/// 🥚 Twelve hidden things. Found eggs are remembered per phone; Settings shows the count.
enum Egg: String, CaseIterable {
    case shake          // shake the phone anywhere
    case coqui          // tap the Plan title 7 times
    case wepa           // say "wepa" in chat
    case medalla        // say "medalla" in chat
    case mofongo        // say "mofongo" in chat
    case bigSpender     // save an expense of $500+
    case debtFree       // open Balances when everyone is settled
    case turkey         // open the app on Thanksgiving
    case airbnb         // tap the Airbnb pin 5 times
    case refreshSpam    // pull to refresh Money 8 times in a row
    case lateNight      // use the app between 2 and 5 AM
    case paparazzi      // add 40+ photos at once
}

@MainActor
@Observable
final class EasterEggs {
    struct Rain: Identifiable, Equatable { let id = UUID(); let emojis: [String] }

    private(set) var rain: Rain?
    private(set) var found: Set<String>
    /// Shows a toast; set by AppModel.
    var toast: (String) -> Void = { _ in }
    private var taps: [String: [Date]] = [:]

    init() { found = Set(UserDefaults.standard.stringArray(forKey: "eggs.found") ?? []) }

    var foundCount: Int { found.count }

    func trigger(_ egg: Egg, _ message: String? = nil, rain emojis: [String]? = nil) {
        if let emojis { rain = Rain(emojis: emojis) }
        if let message { toast(message) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if found.insert(egg.rawValue).inserted {
            UserDefaults.standard.set(Array(found), forKey: "eggs.found")
            if found.count == Egg.allCases.count {
                Task { try? await Task.sleep(for: .seconds(2.5)); self.rain = Rain(emojis: ["🥚", "🏆", "🇵🇷"]); self.toast("🏆 All 12 eggs found. Legend.") }
            }
        }
    }

    /// Counts taps within `window`; returns true on the `needed`-th one.
    func tap(_ key: String, needed: Int, window: TimeInterval = 3) -> Bool {
        let now = Date()
        var list = (taps[key] ?? []).filter { now.timeIntervalSince($0) < window }
        list.append(now)
        taps[key] = list
        if list.count >= needed { taps[key] = []; return true }
        return false
    }

    func clearRain() { rain = nil }

    // MARK: Hooks

    func chatSent(_ text: String) {
        let t = text.lowercased()
        if t.contains("wepa") { trigger(.wepa, "¡WEPA! 🇵🇷", rain: ["🇵🇷", "🎉", "💃", "🕺"]) }
        else if t.contains("medalla") { trigger(.medalla, "Medalla Light: cheap and refreshing 🍺", rain: ["🍺", "🍻"]) }
        else if t.contains("mofongo") { trigger(.mofongo, "Mofongo supremacy 🍌", rain: ["🍌", "🧄", "🍖"]) }
    }

    func expenseSaved(amountMinor: Int64?) {
        guard let amountMinor, amountMinor >= 50_000 else { return }
        trigger(.bigSpender, "💸 Big spender alert", rain: ["💸", "💵", "🤑"])
    }

    func photosAdded(_ count: Int) {
        if count >= 40 { trigger(.paparazzi, "📸 Paparazzi mode activated", rain: ["📸", "🤳", "✨"]) }
    }

    func appOpened(now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Puerto_Rico") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        if parts.year == 2026, parts.month == 11, parts.day == 26 {
            if UserDefaults.standard.string(forKey: "eggs.turkeyShown") != "2026-11-26" {
                UserDefaults.standard.set("2026-11-26", forKey: "eggs.turkeyShown")
                trigger(.turkey, "🦃 Happy Thanksgiving from San Juan", rain: ["🦃", "🥧", "🇵🇷"])
            }
        }
        if let hour = parts.hour, (2..<5).contains(hour) {
            let key = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            if UserDefaults.standard.string(forKey: "eggs.lateNight") != key {
                UserDefaults.standard.set(key, forKey: "eggs.lateNight")
                trigger(.lateNight, "😴 Go to sleep. Unless you're still at La Placita.", rain: ["🌙", "😴", "🪩"])
            }
        }
    }

    private var debtFreeShown = false

    func balancesShown(allSettled: Bool) {
        guard allSettled, !debtFreeShown else { return }
        debtFreeShown = true
        trigger(.debtFree, "🏝️ Debt-free crew. Nobody owes anybody.", rain: ["🏝️", "🥥", "🤝"])
    }

    func refreshedMoney() {
        if tap("refresh", needed: 8, window: 20) { trigger(.refreshSpam, "😂 Refreshing won't change what you owe", rain: ["🔄", "💀"]) }
    }

    func shook() { trigger(.shake, "¡Wepa! 🇵🇷", rain: ["🇵🇷", "🌴", "🌊", "☀️"]) }
}

// MARK: - Shake detection

extension Notification.Name { static let deviceDidShake = Notification.Name("deviceDidShake") }

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}

// MARK: - Emoji rain

@MainActor
struct EmojiRain: View {
    let emojis: [String]
    var onFinish: () -> Void = {}

    private struct Drop: Identifiable { let id = UUID(); let emoji: String; let x: CGFloat; let delay: Double; let size: CGFloat; let spin: Double }
    @State private var drops: [Drop] = []
    @State private var falling = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(drops) { drop in
                    Text(drop.emoji)
                        .font(.system(size: drop.size))
                        .rotationEffect(.degrees(falling ? drop.spin : 0))
                        .position(x: drop.x * geo.size.width, y: falling ? geo.size.height + 60 : -60)
                        .animation(.easeIn(duration: 2.2).delay(drop.delay), value: falling)
                }
            }
            .onAppear {
                drops = (0..<45).map { _ in
                    Drop(emoji: emojis.randomElement() ?? "🎉", x: .random(in: 0.03...0.97), delay: .random(in: 0...0.9),
                         size: .random(in: 26...44), spin: .random(in: -360...360))
                }
                DispatchQueue.main.async { falling = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { onFinish() }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

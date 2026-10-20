import Foundation

/// Build-time configuration injected through xcconfig -> Info.plist. No secrets live here:
/// only the Supabase URL and publishable (anon) key, which are safe to ship in the app.
struct AppConfig: Sendable {
    enum Environment: String, Sendable { case debug, staging, release }

    var environment: Environment
    var supabaseURL: URL?
    var supabasePublishableKey: String
    var inviteHost: String
    var apnsEnvironment: String
    var supportURL: URL
    var privacyURL: URL
    var termsURL: URL

    var isBackendConfigured: Bool { supabaseURL != nil && !supabasePublishableKey.isEmpty }
    /// Demo mode is allowed in debug builds and, explicitly, for App Review in any build.
    var allowsDemoMode: Bool { true }

    static func load(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> AppConfig {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let host = value("SupabaseHost")
        let url: URL? = {
            guard !host.isEmpty, !host.hasPrefix("$(") else { return nil }
            if host.hasPrefix("http") { return URL(string: host) }
            // Local development (`supabase start`) uses http on 127.0.0.1.
            let scheme = host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") ? "http" : "https"
            return URL(string: "\(scheme)://\(host)")
        }()
        let key = value("SupabasePublishableKey")
        let inviteHost = value("InviteHost")
        let webBase = inviteHost.isEmpty || inviteHost.hasPrefix("$(") ? "asraysplit.app" : inviteHost
        var config = AppConfig(
            environment: Environment(rawValue: value("AppEnvironment")) ?? .debug,
            supabaseURL: url,
            supabasePublishableKey: key.hasPrefix("$(") ? "" : key,
            inviteHost: webBase,
            apnsEnvironment: value("APNSEnvironment") == "production" ? "production" : "sandbox",
            supportURL: URL(string: "https://\(webBase)/support")!,
            privacyURL: URL(string: "https://\(webBase)/privacy")!,
            termsURL: URL(string: "https://\(webBase)/terms")!)
        // UI tests and previews always run against the in-memory backend.
        if processInfo.arguments.contains("-uiTesting") { config.supabaseURL = nil }
        return config
    }
}

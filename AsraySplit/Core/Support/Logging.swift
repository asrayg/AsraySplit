import Foundation
import OSLog

/// Structured logging. Receipt contents, merchants, amounts, emails, tokens and invite codes must be
/// logged with `privacy: .private` (the default for interpolated values) or not at all.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.asray.AsraySplit"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let push = Logger(subsystem: subsystem, category: "push")
}

/// Redacts secrets from free-form strings before they can reach logs or crash reports.
enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,          // JWTs
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,              // emails
        #"(?i)(token|code|key|secret|password)=([^&\s]+)"#,               // query secrets
        #"/join/[A-Za-z0-9_-]{8,}"#,                                      // invite links
        #"\b[0-9a-f]{64,}\b"#,                                            // APNs tokens / hashes
    ].map { try! NSRegularExpression(pattern: $0) }

    static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "<redacted>")
        }
        return result
    }
}

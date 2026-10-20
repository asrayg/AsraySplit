import Foundation

enum SyncState: String, Codable, Sendable {
    case synced, pending, failed, conflict
}

enum OutboxKind: String, Codable, Sendable {
    case createExpense, updateExpense, deleteExpense, restoreExpense, recordSettlement, deleteSettlement

    var isExpense: Bool { [.createExpense, .updateExpense, .deleteExpense, .restoreExpense].contains(self) }
}

/// A durable, retryable mutation. Created together with the optimistic local write.
struct OutboxOperation: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var tripID: TripID
    var entityID: UUID
    var kind: OutboxKind
    /// Pre-encoded request body, sent byte-for-byte on every retry.
    var payload: Data?
    var expectedRevision: Int?
    var createdAt: Date
    var attempts: Int = 0
    var nextAttemptAt: Date
    var state: SyncState = .pending
    var errorCode: String?
    var errorMessage: String?
    /// For conflicts: the server's current revision, used if the user chooses to overwrite.
    var serverRevision: Int?
}

/// Pure merge rules so at most one operation per entity waits in the outbox.
enum OutboxCoalescer {
    enum Resolution: Equatable {
        /// Append the new operation.
        case append(OutboxOperation)
        /// Replace the existing operation with this one.
        case replace(existingID: UUID, with: OutboxOperation)
        /// Both cancel out (e.g. create then delete before syncing).
        case cancel(existingID: UUID)
    }

    static func merge(existing: OutboxOperation?, new: OutboxOperation) -> Resolution {
        guard let existing else { return .append(new) }
        var merged = existing
        merged.state = .pending
        merged.attempts = 0
        merged.errorCode = nil
        merged.errorMessage = nil
        merged.nextAttemptAt = new.nextAttemptAt

        switch (existing.kind, new.kind) {
        case (.createExpense, .updateExpense):
            merged.payload = new.payload
            return .replace(existingID: existing.id, with: merged)
        case (.createExpense, .deleteExpense), (.recordSettlement, .deleteSettlement):
            return .cancel(existingID: existing.id)
        case (.updateExpense, .updateExpense):
            merged.payload = new.payload
            return .replace(existingID: existing.id, with: merged)
        case (.updateExpense, .deleteExpense):
            merged.kind = .deleteExpense
            merged.payload = nil
            return .replace(existingID: existing.id, with: merged)
        case (.deleteExpense, .restoreExpense), (.restoreExpense, .deleteExpense):
            return .cancel(existingID: existing.id)
        default:
            return .append(new)
        }
    }

    /// Exponential backoff with jitter: 2s, 4s, 8s … capped at 5 minutes.
    static func backoff(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        min(300, pow(2, Double(max(attempt, 1)))) * jitter
    }
}

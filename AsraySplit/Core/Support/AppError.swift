import Foundation

/// Typed application error surfaced to users. Server RPCs return machine-readable codes
/// (see the error contract in supabase/migrations/20261020000100_foundation.sql) which map here.
enum AppError: Error, Equatable, Sendable, Identifiable {
    case offline
    case notAuthenticated
    case notAuthorized(code: String)
    case notFound
    case validation(code: String, message: String?)
    case conflict(code: String, currentRevision: Int?)
    case rateLimited(message: String?)
    case server(message: String?)
    case invite(InviteFailure)
    case notConfigured
    case cancelled
    case unexpected(String)

    enum InviteFailure: String, Sendable {
        case invalid = "invite_invalid", expired = "invite_expired", revoked = "invite_revoked"
        case exhausted = "invite_exhausted", participantUnavailable = "participant_unavailable"
    }

    var id: String { "\(self)" }

    /// Errors worth retrying automatically (the sync outbox keeps the operation).
    var isTransient: Bool {
        switch self {
        case .offline, .server, .rateLimited: true
        default: false
        }
    }

    var isRevisionConflict: Bool {
        if case .conflict(let code, _) = self { return code == "revision_conflict" }
        return false
    }

    var title: String {
        switch self {
        case .offline: String(localized: "You’re offline")
        case .notAuthenticated: String(localized: "Please sign in again")
        case .notAuthorized: String(localized: "Not allowed")
        case .notFound: String(localized: "Not found")
        case .validation: String(localized: "Check the details")
        case .conflict(let code, _) where code == "revision_conflict": String(localized: "Someone else made changes")
        case .conflict: String(localized: "Couldn’t save")
        case .rateLimited: String(localized: "Slow down a moment")
        case .server: String(localized: "Something went wrong")
        case .invite: String(localized: "Invite problem")
        case .notConfigured: String(localized: "Sync isn’t set up")
        case .cancelled: String(localized: "Cancelled")
        case .unexpected: String(localized: "Something went wrong")
        }
    }

    var message: String {
        switch self {
        case .offline:
            String(localized: "Your changes are saved on this iPhone and will sync when you’re back online.")
        case .notAuthenticated:
            String(localized: "Your session ended. Sign in to keep syncing.")
        case .notAuthorized(let code):
            switch code {
            case "owner_required": String(localized: "Only the trip owner can do this.")
            case "admin_required": String(localized: "Only trip owners and admins can do this.")
            case "not_trip_member": String(localized: "You’re no longer a member of this trip.")
            default: String(localized: "You don’t have permission to do that.")
            }
        case .notFound:
            String(localized: "It may have been deleted by someone else.")
        case .validation(let code, let message):
            Self.validationMessages[code] ?? message ?? String(localized: "Some details aren’t valid.")
        case .conflict(let code, _):
            switch code {
            case "revision_conflict": String(localized: "This was changed on another device. Review the latest version before saving yours.")
            case "trip_archived": String(localized: "This trip is archived. Unarchive it to make changes.")
            case "unsettled_balance": String(localized: "You still have an unsettled balance in this trip.")
            case "owner_must_transfer": String(localized: "Transfer ownership or delete the trip before leaving.")
            case "idempotency_key_reused": String(localized: "This change conflicts with one already saved. Discard it and try again.")
            case "nothing_owed": String(localized: "This person doesn’t owe you anything.")
            case "base_currency_locked": String(localized: "The trip currency can’t change after expenses are added.")
            default: String(localized: "This change conflicts with the latest data.")
            }
        case .rateLimited(let message):
            message ?? String(localized: "Too many attempts. Try again later.")
        case .server(let message):
            message ?? String(localized: "Please try again in a moment.")
        case .invite(let failure):
            switch failure {
            case .invalid: String(localized: "This invite link or code isn’t valid.")
            case .expired: String(localized: "This invite has expired. Ask for a new one.")
            case .revoked: String(localized: "This invite was revoked. Ask for a new one.")
            case .exhausted: String(localized: "This invite has already been used.")
            case .participantUnavailable: String(localized: "That person is already linked to another account.")
            }
        case .notConfigured:
            String(localized: "This build isn’t connected to a server. You can keep using demo mode.")
        case .cancelled:
            ""
        case .unexpected(let detail):
            detail
        }
    }

    private static let validationMessages: [String: String] = [
        "invalid_amount": String(localized: "Enter an amount other than zero."),
        "description_required": String(localized: "Add a short description."),
        "allocations_mismatch": String(localized: "Everyone’s shares must add up to the total."),
        "payments_mismatch": String(localized: "Payments must add up to the total."),
        "receipt_unreconciled": String(localized: "Items, tax, tip and discounts must add up to the total."),
        "unassigned_items": String(localized: "Assign every item to at least one person."),
        "unknown_participant": String(localized: "Someone in this split isn’t part of the trip."),
        "exchange_rate_required": String(localized: "Add an exchange rate for this currency."),
        "unsupported_currency": String(localized: "That currency isn’t supported."),
        "invalid_timezone": String(localized: "Choose a valid time zone."),
        "invalid_parties": String(localized: "Choose two different people."),
        "mixed_signs": String(localized: "Shares must all be positive (or all negative for refunds)."),
    ]
}

extension Error {
    /// Normalizes any thrown error into an `AppError`.
    var asAppError: AppError {
        if let error = self as? AppError { return error }
        if self is CancellationError { return .cancelled }
        if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .cancelled: return .cancelled
            default: return .server(message: nil)
            }
        }
        if let error = self as? SplitError { return .validation(code: "split", message: error.userMessage) }
        return .unexpected(localizedDescription)
    }
}

extension SplitError {
    var userMessage: String {
        switch self {
        case .noParticipants: String(localized: "Choose at least one person.")
        case .zeroAmount: String(localized: "Enter an amount other than zero.")
        case .sumMismatch: String(localized: "Everyone’s shares must add up to the total.")
        case .percentagesMustTotal100: String(localized: "Percentages must add up to 100%.")
        case .invalidValue: String(localized: "One of the values isn’t valid.")
        case .tooPrecise: String(localized: "Use fewer decimal places.")
        case .adjustmentsExceedTotal: String(localized: "Adjustments are larger than the total.")
        case .unassignedItems: String(localized: "Assign every item to at least one person.")
        case .mixedSigns: String(localized: "Discounts can’t exceed the items they apply to.")
        case .overflow: String(localized: "That amount is too large.")
        }
    }
}

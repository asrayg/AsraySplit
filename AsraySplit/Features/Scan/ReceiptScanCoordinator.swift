import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Owns receipt scan jobs at app level so a scan keeps running when the user leaves the screen.
/// Pipeline: normalize locally → upload privately → AI extraction (server) → validate → review.
/// Any AI failure falls back to on-device OCR; the manual path always remains available.
@MainActor
@Observable
final class ReceiptScanCoordinator {
    enum Phase: Equatable {
        case preparing, uploading, scanning
        case ready
        case failed(String)
    }

    struct Job: Identifiable {
        let id: UUID
        let tripID: TripID
        let image: UIImage
        var prepared: PreparedReceipt?
        var receipt: Receipt?
        var duplicates: [ReceiptDuplicate] = []
        var result: ReceiptScanResult?
        var phase: Phase = .preparing
        /// Why the AI path wasn't used, shown next to the on-device result.
        var fallbackReason: String?
        let startedAt = Date()
    }

    private(set) var jobs: [UUID: Job] = [:]
    private let receipts: any ReceiptService

    init(receipts: any ReceiptService) {
        self.receipts = receipts
    }

    var unfinishedJobs: [Job] { jobs.values.sorted { $0.startedAt > $1.startedAt } }

    @discardableResult
    func start(image: UIImage, trip: Trip, useAI: Bool = true) -> UUID {
        let id = UUID()
        jobs[id] = Job(id: id, tripID: trip.id, image: image)
        Task { await run(id, trip: trip, useAI: useAI) }
        return id
    }

    func start(fileData: Data, contentType: UTType?, trip: Trip) throws -> UUID {
        let id = UUID()
        let (prepared, image) = try ReceiptImageProcessor.prepare(fileData: fileData, contentType: contentType, id: id)
        jobs[id] = Job(id: id, tripID: trip.id, image: image, prepared: prepared)
        Task { await run(id, trip: trip, useAI: true) }
        return id
    }

    func discard(_ id: UUID) {
        jobs[id] = nil
    }

    /// Removes the uploaded image when the user abandons a scan without saving.
    func discardAndDeleteUpload(_ id: UUID) async {
        if let receipt = jobs[id]?.receipt { try? await receipts.deleteReceipt(receipt) }
        jobs[id] = nil
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
    }

    private func run(_ id: UUID, trip: Trip, useAI: Bool) async {
        guard let job = jobs[id] else { return }
        do {
            let prepared = try job.prepared ?? ReceiptImageProcessor.prepare(image: job.image, id: id)
            update(id) { $0.prepared = prepared; $0.phase = .uploading }

            do {
                let registration = try await receipts.uploadReceipt(prepared, tripID: trip.id)
                update(id) { $0.receipt = registration.receipt; $0.duplicates = registration.duplicates }
            } catch {
                let appError = error.asAppError
                Log.scan.notice("Receipt upload unavailable: \(appError.title, privacy: .public)")
                update(id) { $0.fallbackReason = appError == .offline ? String(localized: "You’re offline, so the receipt was read on this iPhone and the photo isn’t attached yet.") : appError.message }
            }

            if useAI, jobs[id]?.receipt != nil {
                update(id) { $0.phase = .scanning }
                do {
                    let result = try await receipts.scanReceipt(id: prepared.id)
                    update(id) { $0.result = result; $0.phase = .ready }
                    return
                } catch {
                    let appError = error.asAppError
                    Log.scan.notice("AI scan unavailable, using on-device OCR: \(appError.title, privacy: .public)")
                    if appError != .notConfigured {
                        update(id) { $0.fallbackReason = appError.message }
                    }
                }
            }

            update(id) { $0.phase = .scanning }
            let result = try await ReceiptTextParser.scan(image: job.image, currency: trip.baseCurrency)
            update(id) { $0.result = result; $0.phase = .ready }
        } catch {
            let message = (error as? ReceiptImageError)?.errorDescription ?? error.asAppError.message
            update(id) { $0.phase = .failed(message) }
        }
    }
}


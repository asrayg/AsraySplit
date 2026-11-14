import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Owns receipt scan jobs at app level so a scan keeps running when the user leaves the screen.
/// Pipeline: normalize locally → upload privately → on-device OCR (Vision) → structure with Apple's on-device
/// model, or ask a nearby Apple Intelligence iPhone → validate → review. Falls back to the regex parser.
/// No paid AI: the `scan-receipt` Edge Function is not called.
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
    private let nearby: NearbyMesh?

    init(receipts: any ReceiptService, nearby: NearbyMesh? = nil) {
        self.receipts = receipts
        self.nearby = nearby
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

    /// Imports shared plain text (for example an emailed Uber/Lyft receipt). No image is stored.
    func start(text: String, trip: Trip) throws -> UUID {
        let lines = text.components(separatedBy: .newlines)
        let result: ReceiptScanResult
        if let (parsed, _) = RideReceiptParser.parse(lines: lines, currency: trip.baseCurrency) {
            result = parsed
        } else {
            result = ReceiptTextParser.parse(lines: lines, currency: trip.baseCurrency)
            guard !result.items.isEmpty else { throw ReceiptImageError.unreadable }
        }
        let id = UUID()
        var job = Job(id: id, tripID: trip.id, image: UIImage(systemName: "doc.text") ?? UIImage())
        job.result = result
        job.phase = .ready
        job.fallbackReason = String(localized: "Imported from text — no photo is attached.")
        jobs[id] = job
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
            update(id) { $0.prepared = prepared; $0.phase = .scanning }

            // Upload in the background — reading the receipt never waits on the network. If the upload hasn't
            // finished when the expense is saved, the review screen queues it (pendingUpload) instead.
            Task { [receipts] in
                do {
                    let registration = try await receipts.uploadReceipt(prepared, tripID: trip.id)
                    self.update(id) { $0.receipt = registration.receipt; $0.duplicates = registration.duplicates }
                } catch {
                    Log.scan.notice("Receipt upload deferred: \(error.asAppError.title, privacy: .public)")
                }
            }

            // Ride receipts (Uber/Lyft) are recognized on-device: no AI call or quota needed.
            update(id) { $0.phase = .scanning }
            let lines = (try? await ReceiptTextParser.recognizeText(in: job.image)) ?? []
            if let (result, _) = RideReceiptParser.parse(lines: lines, currency: trip.baseCurrency) {
                update(id) { $0.result = result; $0.phase = .ready }
                return
            }

            if useAI, lines.count >= 3 {
                if OnDeviceReceiptAI.isAvailable, let result = await OnDeviceReceiptAI.structure(lines: lines, currency: trip.baseCurrency) {
                    update(id) { $0.result = result; $0.phase = .ready }
                    return
                }
                if let nearby, let helper = nearby.peers.first(where: \.canParse),
                   let result = await nearby.requestParse(lines: lines, currency: trip.baseCurrency, timeout: .seconds(8)) {
                    update(id) { $0.result = result; $0.phase = .ready; $0.fallbackReason = String(localized: "Read by \(helper.name)’s iPhone nearby.") }
                    return
                }
            }

            update(id) { $0.result = ReceiptTextParser.parse(lines: lines, currency: trip.baseCurrency); $0.phase = .ready }
        } catch {
            let message = (error as? ReceiptImageError)?.errorDescription ?? error.asAppError.message
            update(id) { $0.phase = .failed(message) }
        }
    }
}


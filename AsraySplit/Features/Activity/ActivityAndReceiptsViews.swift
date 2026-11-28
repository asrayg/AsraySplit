import SwiftUI

@MainActor
struct ActivityView: View {
    @Environment(TripStore.self) private var store
    let tripID: TripID
    @State private var events: [ActivityEvent] = []

    var body: some View {
        List {
            if events.isEmpty { ContentUnavailableView("No activity yet", systemImage: "clock") }
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: Self.icon(event.kind)).foregroundStyle(Color.brand).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.describe(event, trip: store.trip(tripID), me: store.currentUserID)).font(.subheadline)
                        Text(event.createdAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .screenBackground()
        .navigationTitle("Activity")
        .refreshable { await store.refresh(tripID: tripID) }
        .task(id: store.version) { events = await store.activity(tripID: tripID) }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case let k where k.hasPrefix("expense_deleted"): "trash"
        case let k where k.hasPrefix("expense"): "receipt"
        case let k where k.hasPrefix("settlement"): "arrow.left.arrow.right"
        case let k where k.hasPrefix("member") || k.hasPrefix("participant") || k == "ownership_transferred": "person.2"
        case let k where k.hasPrefix("receipt"): "doc.viewfinder"
        default: "suitcase"
        }
    }

    /// Human-readable, explainable activity line. Activity data keys are snake_case, exactly as stored.
    static func describe(_ event: ActivityEvent, trip: Trip?, me: UserID?) -> String {
        let actor: String = {
            guard let actorID = event.actorId else { return String(localized: "Someone") }
            if actorID == me { return String(localized: "You") }
            return trip?.participant(forUser: actorID)?.displayName ?? String(localized: "A member")
        }()
        let title = event.value("description")?.stringValue ?? ""
        let amount: String = {
            guard let minor = event.value("amount_minor")?.int64Value, let code = event.value("currency")?.stringValue.flatMap(CurrencyCode.init) else { return "" }
            return Money(minorUnits: minor, currency: code).formatted()
        }()
        switch event.kind {
        case "trip_created": return String(localized: "\(actor) created the trip")
        case "trip_updated": return String(localized: "\(actor) updated trip details")
        case "trip_archived": return String(localized: "\(actor) archived the trip")
        case "trip_unarchived": return String(localized: "\(actor) unarchived the trip")
        case "member_joined": return String(localized: "\(actor) joined")
        case "member_left": return String(localized: "\(actor) left the trip")
        case "member_removed": return String(localized: "\(actor) removed a member")
        case "member_role_changed": return String(localized: "\(actor) changed a member’s role")
        case "ownership_transferred": return String(localized: "Trip ownership was transferred")
        case "participant_added": return String(localized: "\(actor) added \(event.value("name")?.stringValue ?? String(localized: "a traveler"))")
        case "participant_renamed": return String(localized: "\(actor) renamed a traveler")
        case "expense_created": return String(localized: "\(actor) added “\(title)” \(amount)")
        case "expense_updated": return String(localized: "\(actor) edited “\(title)” \(amount)")
        case "expense_deleted": return String(localized: "\(actor) deleted “\(title)” \(amount)")
        case "expense_restored": return String(localized: "\(actor) restored “\(title)”")
        case "settlement_recorded":
            let from = (event.value("from_participant_id")?.stringValue).flatMap(UUID.init(uuidString:)).map { trip?.name(of: $0) ?? "" } ?? ""
            let to = (event.value("to_participant_id")?.stringValue).flatMap(UUID.init(uuidString:)).map { trip?.name(of: $0) ?? "" } ?? ""
            return String(localized: "\(actor) recorded \(from) paying \(to) \(amount)")
        case "settlement_deleted": return String(localized: "\(actor) deleted a payment")
        case "receipt_scanned": return String(localized: "A receipt scan finished")
        case "receipt_scan_failed": return String(localized: "A receipt scan failed")
        default: return event.kind.replacingOccurrences(of: "_", with: " ")
        }
    }
}

@MainActor
struct ReceiptsView: View {
    @Environment(AppModel.self) private var app
    @Environment(ReceiptScanCoordinator.self) private var scanner
    let tripID: TripID
    @State private var receipts: [Receipt] = []
    @State private var error: AppError?
    @State private var loading = true

    var body: some View {
        List {
            let jobs = scanner.unfinishedJobs.filter { $0.tripID == tripID }
            if !jobs.isEmpty {
                Section("In progress") {
                    ForEach(jobs) { job in
                        Button { app.sheet = .scanReceipt(tripID) } label: {
                            HStack {
                                Image(uiImage: job.image).resizable().scaledToFill().frame(width: 40, height: 50).clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(job.phase == .ready ? "Ready to review" : "Scanning…")
                            }
                        }
                    }
                }
            }
            if let error { ErrorBanner(error: error) { Task { await load() } } }
            if receipts.isEmpty && !loading && error == nil {
                ContentUnavailableView("No receipts", systemImage: "doc.text.image")
            }
            ForEach(receipts) { receipt in ReceiptThumbnailRow(receipt: receipt, onDeleted: { Task { await load() } }) }
        }
        .screenBackground()
        .navigationTitle("Receipts")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { receipts = try await app.env.backend.receipts.fetchReceipts(tripID: tripID); error = nil }
        catch { self.error = error.asAppError }
    }
}

/// Shows one private receipt via a short-lived signed URL, with view/share/delete.
@MainActor
struct ReceiptThumbnailRow: View {
    @Environment(AppModel.self) private var app
    var receipt: Receipt?
    var receiptID: UUID?
    var tripID: TripID?
    var onDeleted: () -> Void = {}

    @State private var resolved: Receipt?
    @State private var image: UIImage?
    @State private var showFull = false
    @State private var confirmDelete = false
    @State private var fileURL: URL?

    init(receipt: Receipt, onDeleted: @escaping () -> Void = {}) {
        self.receipt = receipt
        self.onDeleted = onDeleted
    }

    init(receiptID: UUID, tripID: TripID) {
        self.receiptID = receiptID
        self.tripID = tripID
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "doc.text.image").foregroundStyle(.secondary) }
            }
            .frame(width: 48, height: 60).clipShape(RoundedRectangle(cornerRadius: 8)).background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text((resolved ?? receipt)?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Receipt")).font(.subheadline)
                Text((resolved ?? receipt)?.expenseId == nil ? "Not attached to an expense" : "Attached").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button { showFull = true } label: { Label("View", systemImage: "eye") }
                if let fileURL { ShareLink(item: fileURL) { Label("Save or share", systemImage: "square.and.arrow.up") } }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete image", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .accessibilityLabel(Text("Receipt options"))
        }
        .task { await load() }
        .sheet(isPresented: $showFull) { if let image { ZoomableImage(image: image) } }
        .confirmationDialog("Delete this receipt image?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: { Text("The expense stays; only the stored image is removed for everyone.") }
    }

    private func load() async {
        if resolved == nil {
            if let receipt { resolved = receipt }
            else if let receiptID, let tripID { resolved = try? await app.env.backend.receipts.fetchReceipts(tripID: tripID).first { $0.id == receiptID } }
        }
        guard image == nil, let resolved else { return }
        if let data = try? await app.env.backend.receipts.downloadReceipt(resolved) {
            image = UIImage(data: data)
            let url = FileManager.default.temporaryDirectory.appending(path: "receipt-\(resolved.id.uuidString.prefix(8)).jpg")
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            fileURL = url
        }
    }

    private func delete() async {
        guard let resolved else { return }
        do { try await app.env.backend.receipts.deleteReceipt(resolved); onDeleted(); app.show(Toast(message: String(localized: "Receipt deleted"))) }
        catch { app.report(error) }
    }
}

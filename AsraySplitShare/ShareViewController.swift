import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share to Asray Split": accepts a receipt image, PDF or text (e.g. an Uber/Lyft receipt) and drops it
/// into the shared inbox. The app picks it up, reads it and opens the split review.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(context: extensionContext))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct SharedPayload {
    var data: Data?
    var fileExtension: String?
    var contentType: String?
    var text: String?
}

private struct ShareView: View {
    let context: NSExtensionContext?
    @State private var inbox = SharedInbox.shared()
    @State private var trips: [SharedTripSummary] = []
    @State private var tripID: UUID?
    @State private var payload: SharedPayload?
    @State private var state: Phase = .loading

    enum Phase: Equatable { case loading, ready, saved, failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                switch state {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                case .saved:
                    Label("Added. Open Asray Split to review and split it.", systemImage: "checkmark.circle.fill")
                case .ready:
                    Section("Trip") {
                        if trips.isEmpty {
                            Text("Open Asray Split once to see your trips here. You can still save now and choose a trip later.")
                                .font(.footnote)
                        } else {
                            Picker("Add to", selection: $tripID) {
                                ForEach(trips) { Text("\($0.emoji) \($0.name)").tag(UUID?.some($0.id)) }
                            }
                        }
                    }
                    Section {
                        Label(payload?.text != nil && payload?.data == nil ? "Receipt text" : "Receipt file", systemImage: "doc.text.viewfinder")
                    } footer: {
                        Text("Uber and Lyft receipts are recognized automatically. Nothing is saved until you review it in the app.")
                    }
                }
            }
            .navigationTitle("Asray Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if state != .saved { Button("Cancel") { context?.cancelRequest(withError: CocoaError(.userCancelled)) } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if state == .saved {
                        Button("Done") { context?.completeRequest(returningItems: nil) }
                    } else {
                        Button("Add") { save() }.disabled(state != .ready)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let inbox else {
            state = .failed(String(localized: "Sharing isn’t available in this build."))
            return
        }
        trips = inbox.trips()
        tripID = trips.first?.id
        payload = await Self.extract(from: context)
        state = payload == nil ? .failed(String(localized: "This item can’t be added. Share a photo, PDF or text receipt.")) : .ready
    }

    private func save() {
        guard let inbox, let payload else { return }
        do {
            try inbox.add(data: payload.data, fileExtension: payload.fileExtension, contentType: payload.contentType, text: payload.text, tripId: tripID)
            state = .saved
        } catch {
            state = .failed(String(localized: "Couldn’t save this receipt."))
        }
    }

    private static func extract(from context: NSExtensionContext?) async -> SharedPayload? {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for type in [UTType.pdf, .image] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = try? await loadData(provider, type: type) {
                    let concrete = provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: type) } ?? type
                    return SharedPayload(data: data, fileExtension: concrete.preferredFilenameExtension ?? (type == .pdf ? "pdf" : "jpg"), contentType: concrete.identifier)
                }
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !text.isEmpty {
                return SharedPayload(text: text)
            }
        }
        return nil
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

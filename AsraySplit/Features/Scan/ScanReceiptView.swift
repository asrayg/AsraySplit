import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

@MainActor
struct ScanReceiptView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(ReceiptScanCoordinator.self) private var scanner
    @Environment(\.dismiss) private var dismiss
    let initialTripID: TripID?

    @State private var tripID: TripID?
    @State private var jobID: UUID?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let jobID, let job = scanner.jobs[jobID], let trip = store.trip(job.tripID) {
                    jobView(job, trip: trip)
                } else {
                    capture
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let jobID, scanner.jobs[jobID]?.phase == .ready { Task { await scanner.discardAndDeleteUpload(jobID) } }
                        dismiss()
                    }
                }
            }
        }
        .modifier(ManualHost(model: $manualModel) { dismiss() })
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCamera { image in startScan(image) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .jpeg, .png, .heic]) { result in
            guard case .success(let url) = result, let trip = selectedTrip else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                jobID = try scanner.start(fileData: data, contentType: UTType(filenameExtension: url.pathExtension), trip: trip)
            } catch { self.error = (error as? ReceiptImageError)?.errorDescription ?? error.localizedDescription }
        }
        .onChange(of: photoItem) { _, item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self), let trip = selectedTrip else { return }
                do { jobID = try scanner.start(fileData: data, contentType: item.supportedContentTypes.first, trip: trip) }
                catch { self.error = (error as? ReceiptImageError)?.errorDescription ?? error.localizedDescription }
            }
        }
        .onAppear { tripID = tripID ?? initialTripID ?? store.activeTrips.first?.id }
    }

    private var selectedTrip: Trip? { store.trip(tripID) }

    private var capture: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "doc.viewfinder").font(.system(size: 64)).foregroundStyle(Color.brand).padding(.top, 30).accessibilityHidden(true)
                Text("Scan a receipt").font(.largeTitle.bold())
                Text("We’ll read the items, tax and tip. You review everything and choose who had what before anything is saved.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if store.activeTrips.isEmpty {
                    ErrorBanner(error: .validation(code: "no_trip", message: String(localized: "Create a trip first.")))
                } else {
                    Picker("Trip", selection: $tripID) {
                        ForEach(store.activeTrips) { Text("\($0.emoji) \($0.name)").tag(TripID?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                    VStack(spacing: 12) {
                        if VNDocumentCameraViewController.isSupported {
                            Button { showCamera = true } label: { Label("Scan with camera", systemImage: "camera.fill") }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Choose a photo", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button { showFileImporter = true } label: { Label("Import PDF or file", systemImage: "doc") }
                            .buttonStyle(SecondaryButtonStyle())
                        if let trip = selectedTrip {
                            Button("Enter items manually") {
                                jobID = nil
                                manualReview(trip)
                            }
                            .font(.subheadline)
                        }
                    }
                    .disabled(selectedTrip == nil)
                }
                if let error { Text(error).foregroundStyle(Color.negative).font(.footnote) }
                Label("Photos are resized and stripped of location data before upload, and stored privately for trip members.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    @State private var manualModel: ScanReviewModel?

    private func manualReview(_ trip: Trip) {
        manualModel = ScanReviewModel(trip: trip, result: ReceiptScanResult(currency: trip.baseCurrency, items: [.init(name: "", amountMinor: 0)], confidence: 1, source: .manual),
                                      receiptID: nil, me: store.me(in: trip)?.id)
    }

    private func startScan(_ image: UIImage) {
        guard let trip = selectedTrip else { return }
        jobID = scanner.start(image: image, trip: trip)
    }

    @ViewBuilder
    private func jobView(_ job: ReceiptScanCoordinator.Job, trip: Trip) -> some View {
        switch job.phase {
        case .preparing, .uploading, .scanning:
            VStack(spacing: 20) {
                Image(uiImage: job.image).resizable().scaledToFit().frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityHidden(true)
                ProgressView()
                Text(job.phase == .uploading ? "Uploading securely…" : job.phase == .scanning ? "Reading every line…" : "Preparing…").font(.title3.bold())
                Text("You can close this screen — the scan keeps going and will be waiting in Receipts.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
        case .failed(let message):
            VStack(spacing: 16) {
                ErrorBanner(error: .validation(code: "scan_failed", message: message))
                Button("Enter items manually") { manualReview(trip); jobID = nil }.buttonStyle(PrimaryButtonStyle())
                Button("Try again") { scanner.discard(job.id); jobID = nil }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(24)
        case .ready:
            if let result = job.result {
                ReviewHost(job: job, result: result, trip: trip, me: store.me(in: trip)?.id) {
                    scanner.discard(job.id)
                    dismiss()
                }
            }
        }
    }
}

/// Keeps one review model alive for the lifetime of a scan job so edits aren't lost on re-render.
@MainActor
private struct ReviewHost: View {
    @State private var model: ScanReviewModel
    let job: ReceiptScanCoordinator.Job
    var onSaved: () -> Void

    init(job: ReceiptScanCoordinator.Job, result: ReceiptScanResult, trip: Trip, me: ParticipantID?, onSaved: @escaping () -> Void) {
        self.job = job
        self.onSaved = onSaved
        _model = State(initialValue: ScanReviewModel(trip: trip, result: result, receiptID: job.receipt?.id, me: me))
    }

    var body: some View {
        ScanReviewView(model: model, image: job.image, duplicates: job.duplicates, fallbackReason: job.fallbackReason, onSaved: onSaved)
    }
}

extension ScanReceiptView {
    /// Hosts the manual review sheet when no scan is used.
    struct ManualHost: ViewModifier {
        @Binding var model: ScanReviewModel?
        var onSaved: () -> Void
        func body(content: Content) -> some View {
            content.sheet(isPresented: Binding(get: { model != nil }, set: { if !$0 { model = nil } })) {
                if let model { NavigationStack { ScanReviewView(model: model, image: nil, duplicates: [], fallbackReason: nil) { self.model = nil; onSaved() } } }
            }
        }
    }
}

/// VisionKit document camera: edge detection, perspective correction, multi-page.
struct DocumentCamera: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onScan: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCamera
        init(_ parent: DocumentCamera) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // Long receipts span several pages: stitch them vertically into one image.
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onScan(Self.stitch(pages))
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }

        static func stitch(_ pages: [UIImage]) -> UIImage {
            guard pages.count > 1 else { return pages.first ?? UIImage() }
            let width = pages.map(\.size.width).max() ?? 0
            let height = pages.reduce(0) { $0 + $1.size.height * (width / max($1.size.width, 1)) }
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
                var y: CGFloat = 0
                for page in pages {
                    let h = page.size.height * (width / max(page.size.width, 1))
                    page.draw(in: CGRect(x: 0, y: y, width: width, height: h))
                    y += h
                }
            }
        }
    }
}

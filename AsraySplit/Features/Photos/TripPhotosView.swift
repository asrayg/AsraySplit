import Photos
import PhotosUI
import SwiftUI

@MainActor
struct TripPhotosView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: TripPhoto?
    @State private var savingAll = false

    private var album: TripPhotoStore { app.env.photos }
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        let photos = album.photos(for: tripID)
        ScrollView {
            statusBar(count: photos.count)
            if photos.isEmpty && album.importing == 0 {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Add as many as you want. Friends nearby get them over Bluetooth right away; uploads wait for Wi-Fi."))
                    .padding(.top, 40)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(photos) { photo in
                    Button { viewing = photo } label: { PhotoThumb(photo: photo) }
                        .buttonStyle(.plain)
                }
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await album.sync(tripIDs: [tripID], allowCellular: true) } } label: {
                        Label(album.onWiFi ? "Sync now" : "Sync now using cellular", systemImage: "arrow.triangle.2.circlepath")
                    }
                        .disabled(album.isSyncing)
                    Button { Task { await saveAll(photos) } } label: { Label("Save all to Photos", systemImage: "square.and.arrow.down.on.square") }
                        .disabled(photos.isEmpty || savingAll)
                } label: { Image(systemName: "ellipsis.circle") }
                PhotosPicker(selection: $picked, maxSelectionCount: 0, selectionBehavior: .ordered, matching: .images) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add photos"))
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await importItems(items) }
        }
        .fullScreenCover(item: $viewing) { photo in PhotoViewer(photo: photo, url: album.fileURL(photo.id)) }
    }

    private func statusBar(count: Int) -> some View {
        let pending = album.pendingCount(for: tripID)
        let peers = app.env.nearby.peers.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(count) photos").font(.subheadline.bold())
                Spacer()
                if album.isSyncing || album.importing > 0 || app.env.nearby.photosInFlight > 0 { ProgressView().controlSize(.small) }
            }
            Group {
                if album.importing > 0 { Text("Adding \(album.importing)…") }
                if peers > 0 { Text("Sharing with \(peers) phone(s) nearby") }
                if pending > 0 {
                    Text(album.onWiFi ? "Uploading \(pending) on Wi-Fi…" : "\(pending) queued — uploads automatically when you’re on Wi-Fi")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        // Load in small batches to keep memory flat with hundreds of photos.
        for batch in stride(from: 0, to: items.count, by: 8).map({ Array(items[$0..<min($0 + 8, items.count)]) }) {
            var datas: [Data] = []
            for item in batch { if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) } }
            await album.add(datas, tripID: tripID)
        }
    }

    private func saveAll(_ photos: [TripPhoto]) async {
        savingAll = true
        defer { savingAll = false }
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            app.show(Toast(message: String(localized: "Allow adding photos in Settings to save the album."), style: .warning))
            return
        }
        let urls = photos.map { album.fileURL($0.id) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil) }
            }
            app.show(Toast(message: String(localized: "Saved \(urls.count) photos to your library.")))
        } catch {
            app.report(error)
        }
    }
}

@MainActor
private struct PhotoThumb: View {
    let photo: TripPhoto
    @Environment(AppModel.self) private var app

    var body: some View {
        Color.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = app.env.photos.thumbnail(photo.id, size: 140) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if app.env.photos.pendingUpload.contains(photo.id) {
                    Image(systemName: "icloud.slash").font(.caption2).padding(4).foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .accessibilityLabel(Text("Photo from \(photo.uploaderName)"))
    }
}

@MainActor
private struct PhotoViewer: View {
    let photo: TripPhoto
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(photo.uploaderName)\(photo.takenAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .toolbarBackground(.black, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
    }
}

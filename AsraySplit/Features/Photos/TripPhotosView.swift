import Photos
import PhotosUI
import SwiftUI

/// Saves album photos into the user's Photos library (add-only permission). Returns how many were saved.
@MainActor
func saveTripPhotosToLibrary(_ urls: [URL], app: AppModel) async {
    guard !urls.isEmpty else { return }
    guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
        app.show(Toast(message: String(localized: "Allow adding photos in Settings to save them."), style: .warning))
        return
    }
    do {
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil) }
        }
        app.show(Toast(message: urls.count == 1 ? String(localized: "Saved to your library.") : String(localized: "Saved \(urls.count) photos to your library.")))
    } catch {
        app.report(error)
    }
}

func initials(of name: String) -> String {
    let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
    return letters.isEmpty ? "?" : String(letters).uppercased()
}

@MainActor
struct TripPhotosView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: TripPhoto?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var saving = false

    private var album: TripPhotoStore { app.env.photos }
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        let photos = album.photos(for: tripID)
        ScrollView {
            statusBar(count: photos.count)
            if photos.isEmpty && album.importing == 0 {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle.angled")
                    .padding(.top, 40)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(photos) { photo in
                    Button {
                        if selecting { toggle(photo.id) } else { viewing = photo }
                    } label: {
                        PhotoThumb(photo: photo, selecting: selecting, selected: selection.contains(photo.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Pull down to sync with the server (and nearby phones' copies); allowed on cellular because it's explicit.
        .refreshable { await album.sync(tripIDs: [tripID], allowCellular: true) }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle(selecting ? (selection.isEmpty ? "Select photos" : "\(selection.count) selected") : "Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button("Done") { selecting = false; selection = [] }
                } else {
                    Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        .disabled(photos.isEmpty)
                    Button { Task { await album.sync(tripIDs: [tripID], allowCellular: true) } } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(album.isSyncing)
                    PhotosPicker(selection: $picked, maxSelectionCount: 0, selectionBehavior: .ordered, matching: .images) {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if selecting {
                    Button { selection = Set(photos.map(\.id)) } label: { Text("Select all") }
                    Spacer()
                    Button { Task { await save(photos.filter { selection.contains($0.id) }) } } label: {
                        Label(selection.isEmpty ? "Save" : "Save \(selection.count)", systemImage: "square.and.arrow.down")
                    }
                    .disabled(selection.isEmpty || saving)
                } else if !photos.isEmpty {
                    Button { Task { await save(photos) } } label: { Label("Save all to Photos", systemImage: "square.and.arrow.down.on.square") }
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await importItems(items) }
        }
        .fullScreenCover(item: $viewing) { photo in
            PhotoViewer(photos: photos, start: photo)
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func save(_ photos: [TripPhoto]) async {
        saving = true
        defer { saving = false }
        await saveTripPhotosToLibrary(photos.map { album.fileURL($0.id) }, app: app)
        if selecting { selecting = false; selection = [] }
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
                if peers > 0 { Text("\(peers) nearby") }
                if pending > 0 {
                    Text(album.onWiFi ? "Uploading \(pending)…" : "\(pending) waiting for Wi-Fi")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        defer { app.eggs.photosAdded(items.count) }
        // Load in small batches to keep memory flat with hundreds of photos.
        for batch in stride(from: 0, to: items.count, by: 8).map({ Array(items[$0..<min($0 + 8, items.count)]) }) {
            var datas: [Data] = []
            for item in batch { if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) } }
            await album.add(datas, tripID: tripID)
        }
    }
}

@MainActor
private struct PhotoThumb: View {
    let photo: TripPhoto
    var selecting = false
    var selected = false
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
            .overlay(alignment: .topTrailing) {
                // Who added it.
                Text(initials(of: photo.uploaderName))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.brand, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if app.env.photos.pendingUpload.contains(photo.id) {
                    Image(systemName: "icloud.slash").font(.caption2).padding(4).foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? Color.brand : .white).padding(5)
                        .background(Circle().fill(.black.opacity(selected ? 0 : 0.25)).padding(3))
                }
            }
            .overlay { if selected { Color.brand.opacity(0.25) } }
            .accessibilityLabel(Text("Photo from \(photo.uploaderName)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Full-screen pager: pinch or double-tap to zoom, swipe sideways between photos, swipe down to close.
@MainActor
struct PhotoViewer: View {
    let photos: [TripPhoto]
    let start: TripPhoto
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var current: UUID
    @State private var dragY: CGFloat = 0
    @State private var zoomed = false

    init(photos: [TripPhoto], start: TripPhoto) {
        self.photos = photos
        self.start = start
        _current = State(initialValue: start.id)
    }

    private var photo: TripPhoto { photos.first { $0.id == current } ?? start }
    private var url: URL { app.env.photos.fileURL(current) }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.7, Double(abs(dragY)) / 500)).ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(photos) { item in
                    PhotoZoomView(url: app.env.photos.fileURL(item.id), zoomed: $zoomed, dragY: $dragY) { dismiss() }
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragY)

            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 30)) }
                        .accessibilityLabel(Text("Close"))
                    Spacer()
                    Button { Task { await saveTripPhotosToLibrary([url], app: app) } } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 24)) }
                        .accessibilityLabel(Text("Save to Photos"))
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.system(size: 24)) }
                }
                .foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                HStack(spacing: 8) {
                    Text(initials(of: photo.uploaderName)).font(.caption.bold()).frame(width: 26, height: 26).background(Color.brand, in: Circle())
                    Text("\(photo.uploaderName)\(photo.takenAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                        .font(.footnote)
                }
                .foregroundStyle(.white).padding(.bottom, 12)
            }
            .opacity(zoomed || dragY != 0 ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: zoomed)
        }
        .background(ClearBackground())
        .statusBarHidden()
    }
}

/// Lets the dimming background fade over the screen underneath while dragging to dismiss.
private struct ClearBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { view.superview?.superview?.backgroundColor = .clear }
    }
}

@MainActor
private struct PhotoZoomView: View {
    let url: URL
    @Binding var zoomed: Bool
    @Binding var dragY: CGFloat
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = max(1, min(6, base * $0.magnification)); zoomed = scale > 1.01 }
                            .onEnded { _ in
                                base = scale
                                if scale <= 1.01 { reset() }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.01 {
                                    offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                                } else if abs(value.translation.height) > abs(value.translation.width) {
                                    dragY = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if scale > 1.01 { lastOffset = offset; return }
                                if abs(value.translation.height) > 120 || abs(value.predictedEndTranslation.height) > 300, abs(value.translation.height) > abs(value.translation.width) {
                                    onClose()
                                } else {
                                    withAnimation(.spring(duration: 0.25)) { dragY = 0 }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.25)) {
                            if scale > 1.01 { reset() } else { scale = 2.5; base = 2.5; zoomed = true }
                        }
                    }
            }
        }
    }

    private func reset() {
        withAnimation(.spring(duration: 0.25)) { scale = 1; base = 1; offset = .zero; lastOffset = .zero; zoomed = false }
    }
}

import SwiftUI
import PhotosUI
import UIKit

struct ReceiptFlowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var isScanning = false
    @State private var draft: ReceiptDraft?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let draft { ReceiptEditorView(draft: draft, image: image) }
                else if isScanning { scanningState }
                else { captureState }
            }
            .background(Color.ink.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $showCamera) { CameraPicker(image: $image).ignoresSafeArea() }
        .onChange(of: image) { _, newImage in if newImage != nil { Task { await scan() } } }
        .onChange(of: photoItem) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { image = UIImage(data: data) } } }
        .alert("Couldn’t read that receipt", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("Try again") {} } message: { Text(errorMessage ?? "") }
    }

    private var captureState: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack { RoundedRectangle(cornerRadius: 36).fill(Color.panel).frame(width: 190, height: 230); RoundedRectangle(cornerRadius: 28).strokeBorder(Color.softMint.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [10])).frame(width: 158, height: 198); Image(systemName: "receipt.fill").font(.system(size: 62)).foregroundStyle(Color.softMint) }
            VStack(spacing: 8) { Text("Snap. Split. Done.").font(.largeTitle.bold()); Text("We’ll find every item, tax, and tip.\nYou stay in control before anything is saved.").multilineTextAlignment(.center).foregroundStyle(.secondary) }
            VStack(spacing: 12) {
                Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera.fill").frame(maxWidth: .infinity).padding().background(Color.softMint, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color.ink).font(.headline) }
                PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose from library", systemImage: "photo.fill").frame(maxWidth: .infinity).padding().background(Color.panel, in: RoundedRectangle(cornerRadius: 16)).font(.headline) }
                Button("Try a demo receipt") { image = UIImage(systemName: "receipt") ; Task { await useDemo() } }.font(.subheadline).foregroundStyle(.secondary)
            }.padding(.horizontal, 24)
            Spacer()
        }.padding()
    }

    private var scanningState: some View {
        VStack(spacing: 26) { Spacer(); if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 340).clipShape(RoundedRectangle(cornerRadius: 24)).overlay { RoundedRectangle(cornerRadius: 24).stroke(Color.softMint, lineWidth: 2) } }; ProgressView().tint(Color.softMint).scaleEffect(1.3); Text("Reading every line…").font(.title2.bold()); Text(store.backend.isConfigured ? "Securely analyzing with AI" : "Using private on-device text recognition").foregroundStyle(.secondary); Spacer() }.padding(24)
    }

    private func scan() async {
        guard let image, let data = image.jpegData(compressionQuality: 0.72) else { return }
        isScanning = true
        do {
            if store.backend.isConfigured { draft = try await store.backend.scanReceipt(imageData: data) }
            else { draft = try await ReceiptVisionService.scan(image: image) }
        } catch { errorMessage = error.localizedDescription }
        isScanning = false
    }
    private func useDemo() async {
        isScanning = true; try? await Task.sleep(for: .seconds(1.1))
        draft = ReceiptDraft(merchant: "Superba Food + Bread", date: .now, items: [ReceiptItem(name: "Avocado toast", price: 16), ReceiptItem(name: "Breakfast burrito", price: 18.5), ReceiptItem(name: "Iced oat latte", quantity: 2, price: 11), ReceiptItem(name: "Fresh orange juice", price: 7)], subtotal: 52.5, tax: 4.59, tip: 10.5, confidence: 0.96)
        isScanning = false
    }
}

struct ReceiptEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: ReceiptDraft
    let image: UIImage?
    @State private var selectedGroupID: UUID?
    @State private var saving = false
    var group: SplitGroup { store.groups.first { $0.id == selectedGroupID } ?? store.groups[0] }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) { if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: 70, height: 80).clipShape(RoundedRectangle(cornerRadius: 14)) }; VStack(alignment: .leading) { TextField("Merchant", text: $draft.merchant).font(.title3.bold()); Label("AI scan · \(Int(draft.confidence * 100))% confident", systemImage: "sparkles").font(.caption).foregroundStyle(Color.softMint) } }
            Picker("Group", selection: Binding(get: { selectedGroupID ?? store.groups.first!.id }, set: { selectedGroupID = $0 })) { ForEach(store.groups) { Text("\($0.emoji) \($0.name)").tag($0.id) } }.pickerStyle(.menu).padding().background(Color.panel, in: RoundedRectangle(cornerRadius: 16))
            Text("Tap who had each item").font(.title3.bold())
            ForEach($draft.items) { $item in ReceiptItemRow(item: $item, members: group.members) }
            Button { draft.items.append(ReceiptItem(name: "New item", price: 0)) } label: { Label("Add missing item", systemImage: "plus.circle.fill") }.foregroundStyle(Color.softMint)
            totals
            PersonTotals(draft: draft, members: group.members)
            Button { Task { saving = true; await store.addExpense(from: draft, group: group, imageData: image?.jpegData(compressionQuality: 0.72)); saving = false; dismiss() } } label: { Group { if saving { ProgressView() } else { Text("Save \(draft.total.formatted(.currency(code: draft.currency)))") } }.frame(maxWidth: .infinity).padding().background(Color.softMint, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color.ink).font(.headline) }.disabled(saving || draft.items.isEmpty)
        }.padding(20).padding(.bottom, 24) }.navigationTitle("Review receipt").navigationBarTitleDisplayMode(.inline)
    }

    private var totals: some View {
        VStack(spacing: 12) {
            moneyField("Subtotal", value: $draft.subtotal); moneyField("Tax", value: $draft.tax); moneyField("Tip", value: $draft.tip); moneyField("Discount", value: $draft.discount)
            Divider(); HStack { Text("Total").bold(); Spacer(); Text(draft.total, format: .currency(code: draft.currency)).font(.title3.bold()) }
        }.padding(18).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
    }
    private func moneyField(_ title: String, value: Binding<Double>) -> some View { HStack { Text(title).foregroundStyle(.secondary); Spacer(); TextField("0.00", value: value, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) } }
}

private struct ReceiptItemRow: View {
    @Binding var item: ReceiptItem; let members: [Person]
    var body: some View { VStack(alignment: .leading, spacing: 13) { HStack { TextField("Item", text: $item.name).font(.headline); Spacer(); TextField("0.00", value: $item.price, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 72).font(.headline) }; ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(members) { person in Button { if item.assignedTo.contains(person.id) { item.assignedTo.remove(person.id) } else { item.assignedTo.insert(person.id) } } label: { HStack(spacing: 5) { Avatar(name: person.name, size: 25); Text(person.name.split(separator: " ").first ?? "") }.font(.caption.bold()).padding(.vertical, 6).padding(.horizontal, 8).background(item.assignedTo.contains(person.id) ? Color.softMint.opacity(0.22) : Color.white.opacity(0.05), in: Capsule()).overlay(Capsule().stroke(item.assignedTo.contains(person.id) ? Color.softMint : .clear)) } } } } }.padding(16).background(Color.panel, in: RoundedRectangle(cornerRadius: 18)) }
}

private struct PersonTotals: View {
    let draft: ReceiptDraft; let members: [Person]
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text("Everyone’s share").font(.headline); ForEach(members) { member in HStack { Avatar(name: member.name, size: 30); Text(member.name); Spacer(); Text(total(for: member), format: .currency(code: draft.currency)).bold() } } }.padding(18).background(Color.panel, in: RoundedRectangle(cornerRadius: 20)) }
    private func total(for person: Person) -> Double { let itemShare = draft.items.reduce(0.0) { sum, item in guard item.assignedTo.contains(person.id), !item.assignedTo.isEmpty else { return sum }; return sum + item.price / Double(item.assignedTo.count) }; guard draft.subtotal > 0 else { return itemShare }; return itemShare + (draft.tax + draft.tip - draft.discount) * (itemShare / draft.subtotal) }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss; @Binding var image: UIImage?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; picker.cameraCaptureMode = .photo; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate { let parent: CameraPicker; init(_ parent: CameraPicker) { self.parent = parent }; func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) { parent.image = info[.originalImage] as? UIImage; parent.dismiss() }; func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() } }
}

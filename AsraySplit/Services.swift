import Foundation
import UIKit
import Vision

enum ReceiptVisionService {
    static func scan(image: UIImage) async throws -> ReceiptDraft {
        guard let cgImage = image.cgImage else { throw ScanError.invalidImage }
        let text: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async { do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { continuation.resume(throwing: error) } }
        }
        return parse(text)
    }

    static func parse(_ text: String) -> ReceiptDraft {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let amountPattern = try! NSRegularExpression(pattern: #"(?:\$\s*)?(-?\d+[.,]\d{2})\s*$"#)
        var items: [ReceiptItem] = []; var tax = 0.0; var tip = 0.0; var subtotal = 0.0; var declaredTotal = 0.0
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = amountPattern.firstMatch(in: line, range: range), let amountRange = Range(match.range(at: 1), in: line), let amount = Double(line[amountRange].replacingOccurrences(of: ",", with: ".")) else { continue }
            let name = String(line[..<amountRange.lowerBound]).replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let lower = name.lowercased()
            if lower.contains("subtotal") { subtotal = amount }
            else if lower.contains("tax") || lower.contains("vat") { tax = amount }
            else if lower.contains("tip") || lower.contains("gratuity") { tip = amount }
            else if lower == "total" || lower.contains("amount due") || lower.contains("grand total") { declaredTotal = amount }
            else if !name.isEmpty && amount > 0 { items.append(ReceiptItem(name: name.capitalized, price: amount)) }
        }
        if subtotal == 0 { subtotal = items.reduce(0) { $0 + $1.price } }
        if declaredTotal > 0, tax == 0, declaredTotal >= subtotal { tax = declaredTotal - subtotal }
        return ReceiptDraft(merchant: lines.first ?? "Receipt", items: items, subtotal: subtotal, tax: tax, tip: tip, confidence: items.isEmpty ? 0.35 : 0.72, rawText: text)
    }
    enum ScanError: LocalizedError { case invalidImage; var errorDescription: String? { "The selected file isn’t a readable image." } }
}

final class SupabaseService {
    private let baseURL: URL?
    private let key: String
    private var accessToken: String?
    var isConfigured: Bool { baseURL != nil && !key.isEmpty }

    init(bundle: Bundle = .main) {
        let rawURL = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        baseURL = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines))
        key = bundle.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""
    }

    func scanReceipt(imageData: Data) async throws -> ReceiptDraft {
        guard let baseURL else { throw BackendError.notConfigured }
        let token = try await userToken()
        var request = URLRequest(url: baseURL.appending(path: "functions/v1/scan-receipt"))
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "apikey"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["imageBase64": imageData.base64EncodedString(), "mimeType": "image/jpeg"])
        let (data, response) = try await URLSession.shared.data(for: request); try validate(response, data: data)
        return try JSONDecoder.supabase.decode(ReceiptDraft.self, from: data)
    }

    func save(expense: Expense, draft: ReceiptDraft?, imageData: Data?) async throws {
        guard let baseURL else { throw BackendError.notConfigured }; let token = try await userToken()
        var receiptPath: String?
        if let imageData { receiptPath = try await uploadReceipt(imageData, id: expense.id, baseURL: baseURL, token: token) }
        var metadata: [String: Any] = ["tags": expense.tags, "allocations": try jsonObject(expense.allocations)]
        if let draft { metadata["draft"] = try jsonObject(draft) }
        var object: [String: Any] = ["id": expense.id.uuidString, "group_id": expense.groupID.uuidString, "description": expense.title, "amount": expense.amount, "currency": draft?.currency ?? "USD", "category": expense.category.rawValue, "paid_by": expense.paidBy.id.uuidString, "payment_method": expense.paymentMethod.rawValue, "split_method": expense.splitMethod.rawValue, "tags": expense.tags, "metadata": metadata]
        if let receiptPath { object["receipt_path"] = receiptPath }
        var request = URLRequest(url: baseURL.appending(path: "rest/v1/expenses")); request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: object); applyHeaders(&request, token: token); request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let (data, response) = try await URLSession.shared.data(for: request); try validate(response, data: data)
    }

    func save(group: SplitGroup) async throws {
        guard let baseURL else { throw BackendError.notConfigured }; let token = try await userToken()
        let object: [String: Any] = ["id": group.id.uuidString, "name": group.name, "emoji": group.emoji, "color_hex": group.colorHex, "start_date": ISO8601DateFormatter().string(from: group.startDate), "end_date": ISO8601DateFormatter().string(from: group.endDate), "currency": group.currency, "budget": group.budget, "member_names": group.members.map(\.name)]
        var request = URLRequest(url: baseURL.appending(path: "rest/v1/groups")); request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: object); applyHeaders(&request, token: token); request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let (data, response) = try await URLSession.shared.data(for: request); try validate(response, data: data)
    }

    private func userToken() async throws -> String {
        if let accessToken { return accessToken }; guard let baseURL else { throw BackendError.notConfigured }
        var request = URLRequest(url: baseURL.appending(path: "auth/v1/signup")); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.setValue(key, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request); try validate(response, data: data)
        let value = try JSONDecoder().decode(AuthResponse.self, from: data); accessToken = value.accessToken; return value.accessToken
    }
    private func uploadReceipt(_ data: Data, id: UUID, baseURL: URL, token: String) async throws -> String {
        let path = "\(id.uuidString.lowercased()).jpg"; var request = URLRequest(url: baseURL.appending(path: "storage/v1/object/receipts/\(path)")); request.httpMethod = "POST"; request.httpBody = data; applyHeaders(&request, token: token); request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await URLSession.shared.data(for: request); try validate(response, data: body); return path
    }
    private func applyHeaders(_ request: inout URLRequest, token: String) { request.setValue(key, forHTTPHeaderField: "apikey"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    private func validate(_ response: URLResponse, data: Data) throws { guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw BackendError.requestFailed(String(data: data, encoding: .utf8) ?? "Backend request failed") } }
    private func jsonObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder.supabase.encode(value)) }
    private struct AuthResponse: Decodable { let accessToken: String; enum CodingKeys: String, CodingKey { case accessToken = "access_token" } }
    enum BackendError: LocalizedError { case notConfigured, requestFailed(String); var errorDescription: String? { switch self { case .notConfigured: "Supabase isn’t configured yet."; case .requestFailed(let message): message } } }
}

extension JSONDecoder { static var supabase: JSONDecoder { let value = JSONDecoder(); value.keyDecodingStrategy = .convertFromSnakeCase; value.dateDecodingStrategy = .iso8601; return value } }
extension JSONEncoder { static var supabase: JSONEncoder { let value = JSONEncoder(); value.keyEncodingStrategy = .convertToSnakeCase; value.dateEncodingStrategy = .iso8601; return value } }

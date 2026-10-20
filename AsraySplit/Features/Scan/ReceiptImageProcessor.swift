import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum ReceiptImageError: LocalizedError, Equatable {
    case unreadable, tooLarge, tooSmall

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "That file isn’t a readable image or PDF.")
        case .tooLarge: String(localized: "That file is too large. Try a photo under 25 MB.")
        case .tooSmall: String(localized: "That image is too small to read.")
        }
    }
}

/// Normalizes receipts before upload: fixes orientation, downsizes, re-encodes as JPEG (which strips
/// EXIF/GPS metadata), and computes the SHA-256 and perceptual hash used for duplicate detection.
enum ReceiptImageProcessor {
    static let maxDimension: CGFloat = 2400
    static let maxInputBytes = 25 * 1024 * 1024
    static let jpegQuality: CGFloat = 0.72

    static func prepare(image: UIImage, id: UUID = UUID()) throws -> PreparedReceipt {
        guard image.size.width >= 200, image.size.height >= 200 else { throw ReceiptImageError.tooSmall }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing into a fresh context bakes in orientation and drops all source metadata.
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.jpegData(compressionQuality: jpegQuality) else { throw ReceiptImageError.unreadable }
        return PreparedReceipt(id: id, data: data, mimeType: "image/jpeg", fileExtension: "jpg", width: Int(target.width), height: Int(target.height),
                               sha256: sha256(data), perceptualHash: rendered.cgImage.flatMap(differenceHash))
    }

    static func prepare(fileData: Data, contentType: UTType?, id: UUID = UUID()) throws -> (PreparedReceipt, UIImage) {
        guard fileData.count <= maxInputBytes else { throw ReceiptImageError.tooLarge }
        if contentType?.conforms(to: .pdf) == true || fileData.starts(with: Array("%PDF".utf8)) {
            guard let image = renderFirstPDFPage(fileData) else { throw ReceiptImageError.unreadable }
            return (try prepare(image: image, id: id), image)
        }
        guard isSupportedImage(fileData), let image = UIImage(data: fileData) else { throw ReceiptImageError.unreadable }
        return (try prepare(image: image, id: id), image)
    }

    /// Magic-byte check for JPEG, PNG and HEIC.
    static func isSupportedImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            return ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand)
        }
        return false
    }

    static func renderFirstPDFPage(_ data: Data) -> UIImage? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(3, maxDimension / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 64-bit dHash: robust to re-encoding and small crops, used to warn about re-scanned receipts.
    static func differenceHash(_ image: CGImage) -> String? {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                hash <<= 1
                if pixels[row * width + column] > pixels[row * width + column + 1] { hash |= 1 }
            }
        }
        return String(format: "%016llx", hash)
    }

    static func hammingDistance(_ lhs: String, _ rhs: String) -> Int? {
        guard let a = UInt64(lhs, radix: 16), let b = UInt64(rhs, radix: 16) else { return nil }
        return (a ^ b).nonzeroBitCount
    }
}

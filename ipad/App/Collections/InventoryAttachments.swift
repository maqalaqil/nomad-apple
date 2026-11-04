import Foundation
import Darwin
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum InventoryAttachmentFiles {
    static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        guard url.isFileURL else { throw InventoryFailure.message("Choose a local file.") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= maximum else { throw InventoryFailure.message("Choose a regular file within the supported size limit.") }
        var result = Data()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: min(1_024 * 1_024, maximum - result.count + 1)) ?? Data()
            if data.isEmpty { break }
            guard data.count <= maximum - result.count else { throw InventoryFailure.message("The selected file grew beyond its size limit.") }
            result.append(data)
        }
        return result
    }

    static func selected(_ url: URL, maximum: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            result = Result { try readRegular(coordinated, maximum: maximum) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw InventoryFailure.message("Could not coordinate the selected file.") }
        return try result.get()
    }

    static func prepare(_ url: URL) throws -> InventoryPreparedAttachment {
        let bytes = try selected(url, maximum: InventoryValidation.maximumAttachmentBytes)
        let normalized: Data, fileExtension: String
        if url.pathExtension.lowercased() == "pdf" {
            guard bytes.starts(with: Data("%PDF-".utf8)), PDFDocument(data: bytes) != nil else { throw InventoryFailure.message("The receipt is not a readable PDF.") }
            normalized = bytes; fileExtension = "pdf"
        } else {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_048
                  ] as CFDictionary),
                  let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw InventoryFailure.message("Choose a photo or PDF receipt. Images must be readable by this iPad.")
            }
            bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = bitmap.makeImage() else { throw InventoryFailure.message("Could not normalize the photo.") }
            let buffer = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { throw InventoryFailure.message("Could not encode the photo.") }
            CGImageDestinationAddImage(output, flattened, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw InventoryFailure.message("Could not save the photo.") }
            normalized = buffer as Data; fileExtension = "jpg"
        }
        let attachment = InventoryAttachment(id: UUID(), name: String(url.lastPathComponent.prefix(250)), fileExtension: fileExtension,
                                             byteCount: normalized.count, sha256: InventoryValidation.hash(normalized), addedAt: Date())
        try validate(normalized, descriptor: attachment)
        return InventoryPreparedAttachment(attachment: attachment, data: normalized)
    }

    static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var saved = false
        defer { try? handle.close(); if !saved { try? FileManager.default.removeItem(at: url) } }
        try handle.write(contentsOf: data); try handle.synchronize(); saved = true
    }

    static func validate(_ data: Data, descriptor: InventoryAttachment) throws {
        guard data.count > 0, data.count <= InventoryValidation.maximumAttachmentBytes,
              data.count == descriptor.byteCount, InventoryValidation.hash(data) == descriptor.sha256 else {
            throw InventoryFailure.message("Attachment length or checksum is invalid.")
        }
        if descriptor.fileExtension == "pdf" {
            guard data.starts(with: Data("%PDF-".utf8)), PDFDocument(data: data) != nil else { throw InventoryFailure.message("Invalid PDF attachment.") }
        } else {
            guard ["jpg", "png"].contains(descriptor.fileExtension),
                  let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(image), type as String == (descriptor.fileExtension == "jpg" ? UTType.jpeg.identifier : UTType.png.identifier),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8_192, height <= 8_192 else { throw InventoryFailure.message("Invalid or oversized photo attachment.") }
        }
    }
}

import CoreGraphics
import Foundation
import ImageIO

/// Re-encodes an image in its own format without metadata (EXIF, GPS, TIFF, IPTC, XMP); only the
/// orientation is kept so the picture looks the same (D-050). Fails rather than keep metadata.
enum CaptureImageSanitizer {
    static func sanitize(_ data: Data, contentType: CaptureContentType) throws -> Data {
        guard let typeIdentifier = contentType.imageTypeIdentifier,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) >= 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureRejection.sanitizationFailed
        }
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var properties: [CFString: Any] = [:]
        if let orientation = original?[kCGImagePropertyOrientation] {
            properties[kCGImagePropertyOrientation] = orientation
        }
        if contentType != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier as CFString, 1, nil) else {
            throw CaptureRejection.sanitizationFailed
        }
        // The image is added from pixels, not from the source, so no source metadata is copied.
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw CaptureRejection.sanitizationFailed }
        return output as Data
    }

    /// Metadata dictionaries present in an image, for tests and diagnostics (keys only, no values).
    static func metadataDictionaries(_ data: Data) -> Set<String> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        let dictionaries: [CFString] = [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary,
                                        kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
        return Set(dictionaries.filter { properties[$0] != nil }.map { $0 as String })
    }

    /// Whether any GPS or user-identifying EXIF/TIFF field survived.
    static func containsPersonalMetadata(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let personalExif: [CFString] = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifUserComment,
                                        kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber]
        let personalTIFF: [CFString] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFArtist,
                                        kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFSoftware]
        return personalExif.contains { exif[$0] != nil } || personalTIFF.contains { tiff[$0] != nil }
    }
}

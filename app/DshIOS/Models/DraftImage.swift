import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to ride the prompt: its bytes, their media type and the name to send.
struct DraftImage {
    var data: Data
    var mediaType: String
    var name: String
    var width: Int
    var height: Int
    /// Whether these are the submitted bytes, untouched.
    var original: Bool

    enum Refusal: Error, Equatable {
        /// Not an image ImageIO can read.
        case unreadable
        /// Still above the byte limit after re-encoding.
        case tooLarge
    }

    /// What the engine accepts, by the image type ImageIO detects from the bytes.
    static let mediaTypes: [String: (mediaType: String, ext: String)] = [
        UTType.png.identifier: ("image/png", "png"),
        UTType.jpeg.identifier: ("image/jpeg", "jpg"),
        UTType.webP.identifier: ("image/webp", "webp"),
        UTType.gif.identifier: ("image/gif", "gif"),
    ]

    /// Prepare submitted bytes for the prompt. Bytes the session accepts as they are
    /// (type, size, pixels, per-side limit) go through untouched: the engine
    /// normalizes them and the model route resizes for its own budget, so the client
    /// does not pick a resolution. Anything else (HEIC, TIFF, over a limit) is
    /// re-encoded once, inside the limits, keeping transparency as PNG.
    static func prepare(_ data: Data, name: String?, index: Int, limits: ImageLimits) -> Result<DraftImage, Refusal> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return .failure(.unreadable) }
        let base = name.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "image-\(index)"

        if let accepted = mediaTypes[type], limits.mediaTypes.contains(accepted.mediaType),
           data.count <= limits.maxImageBytes, width * height <= limits.maxImagePixels,
           max(width, height) <= limits.maxImageDimension {
            return .success(DraftImage(data: data, mediaType: accepted.mediaType, name: base + "." + accepted.ext,
                                       width: width, height: height, original: true))
        }

        // Re-encode: the largest size inside the pixel and per-side limits, smaller only if the bytes still do not fit.
        let alpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let png = alpha && limits.mediaTypes.contains("image/png")
        guard png || limits.mediaTypes.contains("image/jpeg") else { return .failure(.unreadable) }
        let pixelScale = (Double(limits.maxImagePixels) / Double(width * height)).squareRoot()
        var longEdge = Double(max(width, height)) * min(1, pixelScale, Double(limits.maxImageDimension) / Double(max(width, height)))
        for _ in 0..<8 {
            guard let image = thumbnail(source, longEdge: Int(longEdge.rounded(.down))) else { return .failure(.unreadable) }
            if let encoded = encode(image, png: png), encoded.count <= limits.maxImageBytes {
                return .success(DraftImage(data: encoded, mediaType: png ? "image/png" : "image/jpeg", name: base + (png ? ".png" : ".jpg"),
                                           width: image.width, height: image.height, original: false))
            }
            longEdge *= 0.75
        }
        return .failure(.tooLarge)
    }

    /// The first frame, upright (EXIF orientation applied), at most `longEdge` on its longer side.
    static func thumbnail(_ source: CGImageSource, longEdge: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, longEdge),
        ] as CFDictionary)
    }

    /// Whether ImageIO reads these bytes as a raster image (SVG and the like do not).
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// A small upright image for the attachment strip.
    static func preview(_ data: Data, longEdge: Int = 256) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail($0, longEdge: longEdge) }
    }

    private static func encode(_ image: CGImage, png: Bool) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

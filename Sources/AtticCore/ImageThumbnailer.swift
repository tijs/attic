import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates JPEG thumbnails from image data using ImageIO.
///
/// Supports any format macOS ImageIO handles: HEIC, JPEG, PNG, TIFF, RAW, etc.
/// Automatically respects EXIF orientation.
public enum ImageThumbnailer {
    /// Resize image data to a JPEG thumbnail.
    /// - Parameters:
    ///   - data: Original image data (any ImageIO-supported format)
    ///   - maxDimension: Maximum width or height in pixels (default 400)
    ///   - quality: JPEG compression quality 0.0-1.0 (default 0.8)
    /// - Returns: JPEG data
    public static func thumbnail(
        from data: Data,
        maxDimension: Int = 400,
        quality: Double = 0.8,
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ThumbnailError.decodeFailed("CGImageSourceCreateWithData returned nil")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true, // Apply EXIF orientation
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError.decodeFailed("CGImageSourceCreateThumbnailAtIndex returned nil")
        }

        return try encodeJPEG(image: thumbnail, quality: quality)
    }

    /// Encode a CGImage as JPEG data.
    static func encodeJPEG(image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ) else {
            throw ThumbnailError.decodeFailed("CGImageDestinationCreateWithData failed")
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw ThumbnailError.decodeFailed("CGImageDestinationFinalize failed")
        }

        return data as Data
    }
}

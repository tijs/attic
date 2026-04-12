import AVFoundation
import CoreGraphics
import Foundation

/// Extracts a poster frame from video files and produces a JPEG thumbnail.
///
/// Seeks to ~1 second to avoid black fade-ins. Falls back to 0 for very
/// short videos. Writes video data to a temp file since AVAssetImageGenerator
/// requires a file URL.
public enum VideoThumbnailer {
    /// Extract a poster frame from a video file and return as JPEG thumbnail.
    static func thumbnail(
        from fileURL: URL,
        maxDimension: Int = 400,
        quality: Double = 0.8
    ) throws -> Data {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        // Seek to 1 second to avoid black fade-in frames
        let seekTime = CMTime(seconds: 1.0, preferredTimescale: 600)
        var actualTime = CMTime.zero

        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: seekTime, actualTime: &actualTime)
        } catch {
            // If 1s fails (video shorter than 1s), try frame 0
            do {
                cgImage = try generator.copyCGImage(at: .zero, actualTime: &actualTime)
            } catch {
                throw ThumbnailError.decodeFailed("AVAssetImageGenerator failed: \(error)")
            }
        }

        return try ImageThumbnailer.encodeJPEG(image: cgImage, quality: quality)
    }

    /// Generate a thumbnail from video data by writing to a temp file first.
    /// Cleans up the temp file after generation.
    public static func thumbnail(
        from data: Data,
        maxDimension: Int = 400,
        quality: Double = 0.8
    ) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-video-\(UUID().uuidString).mov")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try data.write(to: tempURL)
        return try thumbnail(from: tempURL, maxDimension: maxDimension, quality: quality)
    }
}

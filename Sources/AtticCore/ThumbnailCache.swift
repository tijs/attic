import Foundation

/// On-disk cache for thumbnail JPEG files at ~/.attic/thumbnails/.
public struct ThumbnailCache: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileConfigProvider.defaultDirectory.appendingPathComponent("thumbnails")
    }

    /// Read a cached thumbnail, or nil if not cached.
    public func get(uuid: String) -> Data? {
        guard S3Paths.isValidUUID(uuid) else { return nil }
        let path = directory.appendingPathComponent("\(uuid).jpg")
        return try? Data(contentsOf: path)
    }

    /// Write a thumbnail to the cache directory. Creates the directory if needed.
    public func put(uuid: String, data: Data) throws {
        guard S3Paths.isValidUUID(uuid) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let path = directory.appendingPathComponent("\(uuid).jpg")
        try data.write(to: path)
    }
}

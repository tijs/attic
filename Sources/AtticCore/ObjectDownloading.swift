import Darwin
import Foundation

/// An owned private temporary file. The containing directory is removed on release.
public final class DownloadedObject: @unchecked Sendable {
    public let fileURL: URL
    private let directory: URL

    public init(writing write: (FileHandle) throws -> Void) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("attic-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700],
        )
        fileURL = directory.appendingPathComponent("original")
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw FilesystemError.io(operation: "create download", code: errno)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try write(handle)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public convenience init(data: Data) throws {
        try self.init { try $0.write(contentsOf: data) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// A separate capability: restoring originals must never fall back to buffering getObject.
public protocol ObjectDownloading: ObjectProviding {
    func downloadObject(key: String) async throws -> DownloadedObject
}

extension FilesystemObjectStore: ObjectDownloading {
    public func downloadObject(key: String) async throws -> DownloadedObject {
        guard let input = try reader(key: key) else { throw FilesystemError.notFound(key) }
        defer { try? input.close() }
        return try DownloadedObject { output in
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
        }
    }
}

extension MockS3Provider: ObjectDownloading {
    public func downloadObject(key: String) async throws -> DownloadedObject {
        try await DownloadedObject(data: getObject(key: key))
    }
}

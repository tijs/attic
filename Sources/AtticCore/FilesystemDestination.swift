import Darwin
import Foundation

/// Persistent identity established by explicit initialization on an existing volume.
public struct FilesystemDestination: Codable, Equatable, Sendable {
    public var path: String
    public var targetID: String
    public var volumeUUID: String
    public var rootInode: UInt64

    public init(path: String, targetID: String, volumeUUID: String, rootInode: UInt64) {
        self.path = path
        self.targetID = targetID
        self.volumeUUID = volumeUUID
        self.rootInode = rootInode
    }

    public func validateConfiguration() throws {
        guard path.hasPrefix("/"), UUID(uuidString: targetID) != nil,
              !volumeUUID.isEmpty, rootInode > 0
        else { throw FilesystemError.invalid("Invalid filesystem destination identity") }
    }

    /// Never creates the root. New destinations must be empty, or already initialized.
    public static func initialize(at url: URL) throws -> FilesystemDestination {
        let directory = try SafeDirectory(url: url)
        let writerLock = try DirectoryWriterLock(directory: directory)
        defer { _ = writerLock }
        let identity = try directory.identity()
        let marker = ".attic-target.json"
        if let existing = try directory.readIfPresent(key: marker) {
            let destination = try JSONDecoder().decode(Self.self, from: existing)
            try destination.validateConfiguration()
            guard destination.volumeUUID == identity.volumeUUID,
                  destination.rootInode == identity.inode
            else { throw FilesystemError.invalid("Destination identity does not match this directory") }
            var rebound = destination
            rebound.path = directory.url.path
            return rebound
        }
        guard try directory.list(prefix: "").isEmpty else {
            throw FilesystemError.invalid("New filesystem destinations must be empty")
        }
        try directory.makePrivate()
        let destination = Self(
            path: directory.url.path,
            targetID: UUID().uuidString,
            volumeUUID: identity.volumeUUID,
            rootInode: identity.inode,
        )
        try directory.write(key: marker, body: JSONEncoder().encode(destination), replace: false)
        return destination
    }
}

public enum FilesystemError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case io(operation: String, code: Int32)
    case notFound(String)

    public var description: String {
        switch self {
        case let .invalid(message): message
        case let .io(operation, code): "Filesystem \(operation) failed: \(String(cString: strerror(code)))"
        case let .notFound(key): "notFound: \(key)"
        }
    }
}

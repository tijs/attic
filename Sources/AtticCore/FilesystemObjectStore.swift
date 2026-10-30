import Foundation

/// Local object storage. The filesystem target is never an S3 endpoint and needs no credentials.
public final class FilesystemObjectStore: IntegrityCheckedObjectPutting, @unchecked Sendable {
    public let directory: SafeDirectory
    private let destination: FilesystemDestination
    private let writerLock: DirectoryWriterLock

    public init(destination: FilesystemDestination) throws {
        try destination.validateConfiguration()
        let directory = try SafeDirectory(url: URL(fileURLWithPath: destination.path))
        guard directory.url.path == destination.path else {
            throw FilesystemError.invalid("Destination path was replaced by a symlink")
        }
        self.directory = directory
        self.destination = destination
        writerLock = try DirectoryWriterLock(directory: directory)
        try validateDestination()
    }

    private func validateDestination() throws {
        let identity = try directory.identity()
        guard identity.volumeUUID == destination.volumeUUID, identity.inode == destination.rootInode,
              let data = try directory.readIfPresent(key: ".attic-target.json")
        else { throw FilesystemError.invalid("Destination identity is missing or does not match") }
        let marker = try JSONDecoder().decode(FilesystemDestination.self, from: data)
        guard marker.targetID == destination.targetID, marker.volumeUUID == destination.volumeUUID,
              marker.rootInode == destination.rootInode
        else { throw FilesystemError.invalid("Destination marker does not match the selected target") }
    }

    public func putObject(key: String, body: Data, contentType: String?) async throws {
        try validateKey(key)
        try validateDestination()
        try directory.write(key: physicalKey(key), body: body, replace: !key.hasPrefix("originals/"))
        try validateDestination()
    }

    public func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        try validateKey(key)
        try validateDestination()
        try directory.copy(key: physicalKey(key), fromFile: fileURL, replace: !key.hasPrefix("originals/"))
        try validateDestination()
    }

    public func putVerifiedObject(
        key: String, fileURL: URL, expectedSHA256: String, contentType: String?,
    ) async throws {
        try validateKey(key)
        try validateDestination()
        try directory.copy(
            key: physicalKey(key), fromFile: fileURL,
            replace: !key.hasPrefix("originals/"), expectedSHA256: expectedSHA256,
        )
        try validateDestination()
    }

    /// Encode uppercase ASCII and percent signs to preserve case-sensitive object
    /// identities even on the default case-insensitive APFS/HFS+ volumes.
    private func physicalKey(_ key: String) throws -> String {
        try validateKey(key)
        let parts = key.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              key.utf8.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 92 })
        else { throw FilesystemError.invalid("Unsafe object path") }
        return parts.map { part in
            part.utf8.enumerated().map { index, byte in
                let literal = (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || [45, 46, 95].contains(byte)
                return if literal, !(index == 0 && byte == 46) {
                    String(UnicodeScalar(byte))
                } else {
                    String(format: "%%%02X", byte)
                }
            }.joined()
        }.joined(separator: "/")
    }

    /// Secure, bounded-memory read seam for recovery tools. Caller closes the handle.
    public func reader(key: String) throws -> FileHandle? {
        try validateKey(key)
        try validateDestination()
        return try directory.reader(key: physicalKey(key))
    }

    public func getObject(key: String) async throws -> Data {
        try validateKey(key)
        try validateDestination()
        guard let data = try directory.readIfPresent(key: physicalKey(key)) else { throw FilesystemError.notFound(key) }
        return data
    }

    public func headObject(key: String) async throws -> S3ObjectMeta? {
        try validateKey(key)
        try validateDestination()
        return try directory.head(key: physicalKey(key))
    }

    public func listObjects(prefix: String) async throws -> [S3ListObject] {
        guard !prefix.hasPrefix("."), !prefix.hasPrefix("/") else {
            throw FilesystemError.invalid("Unsafe object prefix")
        }
        try validateDestination()
        return try directory.list(prefix: "").filter { !$0.key.hasPrefix(".") }.map { object in
            guard let decoded = object.key.removingPercentEncoding,
                  try physicalKey(decoded) == object.key
            else { throw FilesystemError.invalid("Invalid encoded object path") }
            return S3ListObject(key: decoded, size: object.size)
        }.filter { $0.key.hasPrefix(prefix) }
    }

    public func deleteObject(key: String) async throws {
        try validateKey(key)
        guard !key.hasPrefix("originals/") else {
            throw FilesystemError.invalid("Original objects are append-only")
        }
        try validateDestination()
        try directory.delete(key: physicalKey(key))
    }

    private func validateKey(_ key: String) throws {
        guard !key.hasPrefix("."), !key.hasPrefix("/"), !key.isEmpty else {
            throw FilesystemError.invalid("Unsafe object key")
        }
    }
}

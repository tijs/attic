import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative I/O below one existing local directory. Paths never follow symlinks.
/// The root stays open and its pathname identity is rechecked before publication.
public final class SafeDirectory: @unchecked Sendable {
    public let url: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private let beforePublish: @Sendable () throws -> Void

    public convenience init(url: URL) throws {
        try self.init(url: url, beforePublish: {})
    }

    init(url: URL, beforePublish: @escaping @Sendable () throws -> Void) throws {
        self.beforePublish = beforePublish
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw FilesystemError.invalid("An absolute local directory is required")
        }
        // Resolve user-selected aliases once at initialization. Runtime access uses
        // only this canonical path and never resolves a replacement symlink.
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        let fd = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("open destination") }
        var info = stat()
        var filesystem = statfs()
        guard fstat(fd, &info) == 0, fstatfs(fd, &filesystem) == 0 else {
            let error = Self.failure("inspect destination")
            close(fd)
            throw error
        }
        let type = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0, ["apfs", "hfs"].contains(type) else {
            close(fd)
            throw FilesystemError.invalid("Filesystem destinations require a local APFS or HFS+ volume")
        }
        let mountedAt = withUnsafePointer(to: &filesystem.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        do {
            try Self.validateExternalMount(
                path: self.url.path, mountedAt: mountedAt, selectedPath: url.standardizedFileURL.path,
            )
        } catch {
            close(fd)
            throw error
        }
        descriptor = fd
        device = info.st_dev
        inode = info.st_ino
    }

    /// Reject stale /Volumes placeholders before even opening a writer lock.
    static func validateExternalMount(path: String, mountedAt: String, selectedPath: String? = nil) throws {
        for candidate in [selectedPath ?? path, path] where candidate.lowercased().hasPrefix("/volumes/") {
            let parts = candidate.components(separatedBy: "/")
            let expected = "/Volumes/" + parts[2]
            guard mountedAt == expected else {
                throw FilesystemError.invalid("Expected external volume is not mounted at \(expected)")
            }
        }
    }

    deinit { close(descriptor) }

    public func validateIdentity() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == device, info.st_ino == inode
        else { throw FilesystemError.invalid("Destination is missing, replaced, or disconnected") }
    }

    public func identity() throws -> (volumeUUID: String, inode: UInt64) {
        try validateIdentity()
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard let uuid = values.volumeUUIDString else {
            throw FilesystemError.invalid("Cannot determine destination volume identity")
        }
        return (uuid, UInt64(inode))
    }

    public func readIfPresent(key: String) throws -> Data? {
        guard let handle = try reader(key: key) else { return nil }
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        try validateIdentity()
        return data
    }

    /// Caller owns the returned handle. Used for bounded-memory reads and checksum verification.
    public func reader(key: String) throws -> FileHandle? {
        try validateIdentity()
        let parent: (Int32, String)
        do {
            parent = try openParent(key: key, create: false)
        } catch FilesystemError.notFound {
            return nil
        }
        defer { close(parent.0) }
        let fd = openat(parent.0, parent.1, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.failure("read object") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw FilesystemError.invalid("Object must be a regular file without hard links")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func head(key: String) throws -> S3ObjectMeta? {
        guard let handle = try reader(key: key) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw Self.failure("stat object") }
        return S3ObjectMeta(contentLength: Int(info.st_size))
    }

    public func write(key: String, body: Data, replace: Bool) throws {
        try publish(key: key, replace: replace) { handle in
            try handle.write(contentsOf: body)
        }
    }

    /// Copies in 1 MiB chunks, verifies the staged copy, then atomically publishes it.
    /// Existing originals are accepted only if their full size and SHA-256 match.
    public func copy(key: String, fromFile source: URL, replace: Bool = false, expectedSHA256: String? = nil) throws {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("open source") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw FilesystemError.invalid("Source must be a regular file")
        }
        let expectedSize = info.st_size
        var sourceHash = SHA256()
        var bytes: Int64 = 0
        try publish(key: key, replace: replace) { output in
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                sourceHash.update(data: chunk)
                bytes += Int64(chunk.count)
                try output.write(contentsOf: chunk)
            }
            guard bytes == expectedSize else { throw FilesystemError.invalid("Source changed during copy") }
            try output.seek(toOffset: 0)
            let copied = try Self.digest(output)
            let expectedHash = sourceHash.finalize().map { String(format: "%02x", $0) }.joined()
            guard copied.size == bytes, copied.checksum == expectedHash,
                  expectedSHA256 == nil || expectedSHA256 == expectedHash
            else {
                throw FilesystemError.invalid("Staged object failed checksum verification")
            }
        }
    }

    public static func digest(_ handle: FileHandle) throws -> (size: Int64, checksum: String) {
        var hash = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public func delete(key: String) throws {
        try validateIdentity()
        let parent: (Int32, String)
        do {
            parent = try openParent(key: key, create: false)
        } catch FilesystemError.notFound {
            return
        }
        defer { close(parent.0) }
        // Open first to reject directories, links, and special files.
        guard let handle = try reader(key: key) else { return }
        try handle.close()
        try validateIdentity()
        guard unlinkat(parent.0, parent.1, 0) == 0 else { throw Self.failure("delete object") }
        guard fsync(parent.0) == 0 else { throw Self.failure("sync directory") }
    }

    public func list(prefix: String) throws -> [S3ListObject] {
        try validateIdentity()
        if !prefix.isEmpty { _ = try Self.components(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        var result: [S3ListObject] = []
        try walk(fd: descriptor, prefix: "", into: &result)
        try validateIdentity()
        return result.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
    }

    func makePrivate() throws {
        try validateIdentity()
        guard fchmod(descriptor, 0o700) == 0 else { throw Self.failure("set destination permissions") }
    }

    func lockDescriptor() throws -> Int32 {
        try validateIdentity()
        let fd = openat(descriptor, ".attic-writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("open writer lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw FilesystemError.invalid("Invalid writer lock file")
        }
        return fd
    }

    private func publish(key: String, replace: Bool, write: (FileHandle) throws -> Void) throws {
        try validateIdentity()
        let (parent, name) = try openParent(key: key, create: true)
        defer { close(parent) }
        let temporary = ".attic-part-\(UUID().uuidString)"
        let fd = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("create staging file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(parent, temporary, 0)
        }
        try write(handle)
        try Task.checkCancellation()
        guard fsync(fd) == 0 else { throw Self.failure("sync object") }
        try beforePublish()
        try validateIdentity()
        if replace {
            var existing = stat()
            if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else {
                    throw FilesystemError.invalid("Refusing to replace a symlink, hard link or special file")
                }
            } else if errno != ENOENT {
                throw Self.failure("inspect replacement")
            }
            guard renameat(parent, temporary, parent, name) == 0 else { throw Self.failure("publish object") }
        } else if renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw Self.failure("publish original") }
            guard let existing = try reader(key: key) else { throw FilesystemError.invalid("Original changed") }
            defer { try? existing.close() }
            try handle.seek(toOffset: 0)
            let left = try Self.digest(handle)
            let right = try Self.digest(existing)
            guard left == right else { throw FilesystemError.invalid("Refusing to overwrite a different original") }
        }
        guard fsync(parent) == 0 else { throw Self.failure("sync parent directory") }
        try validateIdentity()
    }

    private func openParent(key: String, create: Bool) throws -> (Int32, String) {
        let parts = try Self.components(key)
        var fd = dup(descriptor)
        guard fd >= 0 else { throw Self.failure("duplicate directory") }
        do {
            for component in parts.dropLast() {
                if create {
                    if mkdirat(fd, component, 0o700) == 0 {
                        guard fsync(fd) == 0 else { throw Self.failure("sync new directory") }
                    } else if errno != EEXIST {
                        throw Self.failure("create object directory")
                    }
                }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT { throw FilesystemError.notFound(key) }
                guard next >= 0 else { throw Self.failure("open object directory") }
                var info = stat()
                guard fstat(next, &info) == 0, info.st_dev == device else {
                    close(next)
                    throw FilesystemError.invalid("Nested volumes are unsupported")
                }
                close(fd)
                fd = next
            }
            return (fd, parts[parts.count - 1])
        } catch {
            close(fd)
            throw error
        }
    }

    private static func components(_ key: String) throws -> [String] {
        let parts = key.components(separatedBy: "/")
        guard parts.allSatisfy({ $0.utf8.count <= NAME_MAX }) else {
            throw FilesystemError.invalid("Object name exceeds the 255-byte filesystem limit")
        }
        guard !parts.isEmpty, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") &&
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw FilesystemError.invalid("Unsafe object path") }
        return parts
    }

    private func walk(fd: Int32, prefix: String, into result: inout [S3ListObject]) throws {
        let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0 else { throw Self.failure("open listing") }
        guard let directory = fdopendir(listing) else {
            close(listing)
            throw Self.failure("list directory")
        }
        defer { closedir(directory) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw Self.failure("read listing") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name
                .hasPrefix(".attic-part-") || name == ".attic-writer.lock" { continue }
            let key = prefix + name
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            else { throw Self.failure("inspect listed object") }
            guard info.st_dev == device else { throw FilesystemError.invalid("Nested volumes are unsupported") }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Self.failure("open listed directory") }
                defer { close(child) }
                try walk(fd: child, prefix: key + "/", into: &result)
            } else if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 {
                result.append(S3ListObject(key: key, size: Int(info.st_size)))
            } else {
                throw FilesystemError.invalid("Symlinks, hard links and special files are unsupported")
            }
        }
    }

    private static func failure(_ operation: String) -> FilesystemError {
        .io(operation: operation, code: errno)
    }
}

/// Nonblocking advisory lock held for the complete writer lifetime. Stale lock files
/// are harmless: flock ownership belongs to the open descriptor, not the file contents.
public final class DirectoryWriterLock: @unchecked Sendable {
    private let descriptor: Int32

    public init(directory: SafeDirectory) throws {
        let fd = try directory.lockDescriptor()
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FilesystemError.invalid("Another Attic writer is using this destination")
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

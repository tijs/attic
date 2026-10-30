@testable import AtticCore
import Darwin
import Foundation
import Testing

struct SafeDirectoryTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test(arguments: ["../escape", "a/../../escape", "/absolute", "a//b", "a/./b", "a\\b", "a\u{0}b"])
    func rejectsUnsafeKeys(key: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SafeDirectory(url: root)
        #expect(throws: FilesystemError.self) {
            try directory.write(key: key, body: Data("private".utf8), replace: true)
        }
    }

    @Test func rejectsSymlinkParentsLeavesAndHardLinks() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("original".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside,
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: sentinel,
        )
        try FileManager.default.linkItem(at: sentinel, to: root.appendingPathComponent("hardlink"))
        let directory = try SafeDirectory(url: root)
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "escape/sentinel", body: Data("bad".utf8), replace: true)
        }
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "linked", body: Data("bad".utf8), replace: true)
        }
        #expect(throws: FilesystemError.self) { try directory.readIfPresent(key: "linked") }
        #expect(throws: FilesystemError.self) { try directory.readIfPresent(key: "hardlink") }
        #expect(throws: FilesystemError.self) { try directory.list(prefix: "") }
        #expect(try Data(contentsOf: sentinel) == Data("original".utf8))
    }

    @Test func missingAndReplacedRootNeverRecreated() throws {
        let root = try temporaryDirectory()
        let moved = root.appendingPathExtension("removed")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let directory = try SafeDirectory(url: root)
        try FileManager.default.moveItem(at: root, to: moved)
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "manifest.json", body: Data(), replace: true)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "manifest.json", body: Data(), replace: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func rootReplacementDuringCopyFailsBeforePublication() throws {
        let root = try temporaryDirectory()
        let moved = root.appendingPathExtension("unplugged")
        let source = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let directory = try SafeDirectory(url: root, beforePublish: {
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        })
        #expect(throws: FilesystemError.self) { try directory.copy(key: "originals/file.bin", fromFile: source) }
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("originals/file.bin").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.appendingPathComponent("originals").path)
            .isEmpty)
    }

    @Test func simulatedDiskFullNeverPublishesPartialFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SafeDirectory(url: root, beforePublish: {
            throw FilesystemError.io(operation: "sync object", code: ENOSPC)
        })
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "manifest.json", body: Data(repeating: 1, count: 100), replace: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func checksumMismatchAndCancelledCopyLeaveNoObject() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        try Data(repeating: 31, count: 2 * 1024 * 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SafeDirectory(url: root)
        #expect(throws: FilesystemError.self) {
            try directory.copy(
                key: "originals/bad.bin",
                fromFile: source,
                expectedSHA256: String(repeating: "0", count: 64),
            )
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try directory.copy(key: "originals/cancelled.bin", fromFile: source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try directory.list(prefix: "originals/").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path)
            .isEmpty)
    }

    @Test func lockContentionAndStaleFileRecovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SafeDirectory(url: root)
        do {
            let lock = try DirectoryWriterLock(directory: directory)
            defer { _ = lock }
            #expect(throws: FilesystemError.self) { try DirectoryWriterLock(directory: directory) }
        }
        // File intentionally persists; lock ownership no longer exists.
        let recovered = try DirectoryWriterLock(directory: directory)
        defer { _ = recovered }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".attic-writer.lock").path))
    }

    @Test func repeatedListingAndAppendOnlyPublication() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SafeDirectory(url: root)
        try directory.write(key: "originals/file", body: Data("one".utf8), replace: false)
        try directory.write(key: "originals/file", body: Data("one".utf8), replace: false)
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "originals/file", body: Data("two".utf8), replace: false)
        }
        #expect(try directory.list(prefix: "originals/").map(\.key) == ["originals/file"])
        #expect(try directory.list(prefix: "originals/").map(\.key) == ["originals/file"])
        #expect(try directory.readIfPresent(key: "originals/file") == Data("one".utf8))
    }

    @Test func missingExternalMountCannotBindToInternalPlaceholder() throws {
        #expect(throws: FilesystemError.self) {
            try SafeDirectory.validateExternalMount(path: "/Volumes/Backup/Attic", mountedAt: "/System/Volumes/Data")
        }
        #expect(throws: FilesystemError.self) {
            try SafeDirectory.validateExternalMount(path: "/Volumes/Backup/Attic", mountedAt: "/")
        }
        #expect(throws: FilesystemError.self) {
            try SafeDirectory.validateExternalMount(path: "/volumes/Backup/Attic", mountedAt: "/System/Volumes/Data")
        }
        #expect(throws: FilesystemError.self) {
            try SafeDirectory.validateExternalMount(
                path: "/Users/test/internal", mountedAt: "/System/Volumes/Data", selectedPath: "/Volumes/Backup/Attic",
            )
        }
        try SafeDirectory.validateExternalMount(path: "/Volumes/Backup/Attic", mountedAt: "/Volumes/Backup")
        try SafeDirectory.validateExternalMount(path: "/Users/test/Attic", mountedAt: "/System/Volumes/Data")
    }

    @Test func readOnlyDirectoryFailsWithoutReplacingExistingFile() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let directory = try SafeDirectory(url: root)
        try directory.write(key: "manifest.json", body: Data("original".utf8), replace: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: FilesystemError.self) {
            try directory.write(key: "manifest.json", body: Data("replacement".utf8), replace: true)
        }
        #expect(try directory.readIfPresent(key: "manifest.json") == Data("original".utf8))
    }
}

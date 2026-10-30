import AtticCore
import Darwin
import Foundation

/// macOS exposes library selection through Photos.app, rather than PhotoKit.
/// Refuses an existing session and verifies the selected database before/after each import.
struct PhotosLibraryImporter: PhotosImportProviding {
    func libraryIdentity(for library: URL) async throws -> String {
        let directory = try checkedLibrary(library)
        let identity = try directory.identity()
        return RestoreItem.identifier("\(directory.url.path)\u{0}\(identity.volumeUUID)\u{0}\(identity.inode)")
    }

    func prepare(library: URL) async throws {
        _ = try checkedLibrary(library)
        let running = try await RestoreProcess.run("/usr/bin/pgrep", arguments: ["-x", "Photos"], timeout: 3)
        guard running.status == 1 else {
            throw RestoreError
                .invalid("Quit Photos before optional restore import; Attic will not interrupt an existing session")
        }
        let opened = try await RestoreProcess.run(
            "/usr/bin/open", arguments: ["-a", "/System/Applications/Photos.app", library.path], timeout: 10,
        )
        guard opened.status == 0 else { throw RestoreError.invalid("Cannot open the selected Photos library") }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await (try? verifySelection(library)) == true { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RestoreError.invalid("Cannot verify the selected Photos database; import was not started")
    }

    func importFile(_ file: URL, library: URL) async throws -> [String] {
        guard try await verifySelection(library) else { throw RestoreError.invalid("Photos library selection changed") }
        let script = """
        on run argv
            tell application "Photos"
                set importedItems to import {POSIX file (item 1 of argv)} skip check duplicates false
                set resultIDs to {}
                repeat with photo in importedItems
                    set end of resultIDs to id of photo
                end repeat
                set AppleScript's text item delimiters to linefeed
                return resultIDs as text
            end tell
        end run
        """
        let result = try await RestoreProcess.run(
            "/usr/bin/osascript", arguments: ["-e", script, "--", file.path], timeout: 120,
        )
        guard result.status == 0, try await verifySelection(library) else {
            throw RestoreError.invalid("Photos import could not be confirmed")
        }
        let ids = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard ids.allSatisfy(S3Paths.isValidUUID) else { throw RestoreError.invalid("Invalid Photos import response") }
        return ids
    }

    private func checkedLibrary(_ library: URL) throws -> SafeDirectory {
        guard library.pathExtension.lowercased() == "photoslibrary" else {
            throw RestoreError.invalid("Select an existing .photoslibrary explicitly")
        }
        let directory = try SafeDirectory(url: library)
        guard let database = try directory.reader(key: "database/Photos.sqlite") else {
            throw RestoreError.invalid("The selected Photos library has no database")
        }
        try database.close()
        return directory
    }

    private func verifySelection(_ library: URL) async throws -> Bool {
        let directory = try checkedLibrary(library)
        let process = try await RestoreProcess.run("/usr/bin/pgrep", arguments: ["-x", "Photos"], timeout: 3)
        let ids = process.output.split(whereSeparator: \.isNewline)
        guard process.status == 0, ids.count == 1, Int32(ids[0]) != nil else { return false }
        let files = try await RestoreProcess.run("/usr/sbin/lsof", arguments: ["-p", String(ids[0]), "-Fn"], timeout: 5)
        guard files.status == 0 else { return false }
        return Self.selectionMatches(
            database: directory.url.appendingPathComponent("database/Photos.sqlite").path, output: files.output,
        )
    }

    static func selectionMatches(database: String, output: String) -> Bool {
        let databases = Set(output.split(whereSeparator: \.isNewline).filter {
            $0.hasPrefix("n") && $0.hasSuffix("/Photos.sqlite")
        }.map { String($0.dropFirst()) })
        return databases == [database]
    }
}

private final class RestoreProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ chunk: Data) {
        lock.withLock {
            let available = max(0, 64 * 1024 - data.count)
            data.append(chunk.prefix(available))
            if chunk.count > available { overflow = true }
        }
    }

    func result() throws -> String {
        try lock.withLock {
            guard !overflow else { throw RestoreError.invalid("Import subprocess output exceeded its limit") }
            guard let string = String(data: data, encoding: .utf8) else {
                throw RestoreError.invalid("Invalid import subprocess response encoding")
            }
            return string
        }
    }
}

private enum RestoreProcess {
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: Double,
    ) async throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        let output = RestoreProcessOutput()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try Task.checkCancellation()
        try process.run()
        let reader = Task.detached {
            while true {
                guard let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty else { break }
                output.append(chunk)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw RestoreError.invalid("Import subprocess timed out")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? pipe.fileHandleForWriting.close()
            try? await reader.value
            throw error
        }
        process.waitUntilExit()
        try pipe.fileHandleForWriting.close()
        try await reader.value
        return try (process.terminationStatus, output.result())
    }
}

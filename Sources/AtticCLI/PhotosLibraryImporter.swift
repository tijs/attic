import AtticCore
import Darwin
import Foundation

/// macOS exposes library selection through Photos.app, rather than PhotoKit.
/// Refuses an existing session and verifies the selected database before/after each import.
struct PhotosLibraryImporter: PhotosImportProviding {
    private var auxiliaryDatabases: [String] {
        [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Photos/Libraries/Syndication.photoslibrary/database/Photos.sqlite")
            .resolvingSymlinksInPath().path]
    }

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
        guard !auxiliaryDatabases.contains(directory.url.appendingPathComponent("database/Photos.sqlite").path) else {
            throw RestoreError.invalid("Select a normal Photos library, not a system auxiliary library")
        }
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
            auxiliaryDatabases: auxiliaryDatabases,
        )
    }

    static func selectionMatches(database: String, output: String, auxiliaryDatabases: [String] = []) -> Bool {
        let auxiliary = Set(auxiliaryDatabases)
        guard !auxiliary.contains(database) else { return false }
        let databases = Set(output.split(whereSeparator: \.isNewline).filter {
            $0.hasPrefix("n") && $0.hasSuffix("/Photos.sqlite")
        }.map { String($0.dropFirst()) })
        return databases.subtracting(auxiliary) == [database]
    }
}

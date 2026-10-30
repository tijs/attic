import ArgumentParser
import AtticCore
import Foundation

struct RestoreCommand: AsyncParsableCommand {
    @OptionGroup var source: DestinationOptions
    @Option(name: .long, help: "Existing local directory for verified originals, metadata and resume journal.")
    var destination: String
    @Flag(name: .long, help: "List the selection without creating files or requesting archive retrieval.")
    var dryRun = false
    @Option(name: .long, help: "Creation date from this UTC day (YYYY-MM-DD), inclusive.")
    var from: String?
    @Option(name: .long, help: "Creation date through this UTC day (YYYY-MM-DD), inclusive.")
    var through: String?
    @Option(name: .long, help: "Select photo or video originals; missing metadata fails selection.")
    var type: String?
    @Option(name: .long, help: "Exact album UUID in backup metadata; missing metadata fails selection.")
    var album: String?
    @Option(name: .long, help: "Concurrent downloads (1-16).")
    var concurrency = 4
    @Flag(name: .long, help: "Explicitly authorize potentially chargeable Glacier/Deep Archive retrieval requests.")
    var requestArchive = false
    @Option(name: .long, help: "Temporary Glacier copy retention (1-365 days; omitted for Intelligent-Tiering).")
    var archiveDays = 7
    @Option(name: .long, help: "Archive retrieval tier: standard or bulk. Charges/duration depend on provider.")
    var archiveTier = "standard"
    @Option(name: .long, help: "Total archive polling budget in seconds (0-86400; default: do not wait).")
    var waitSeconds: Double = 0
    @Option(name: .long, help: "Optional existing .photoslibrary. Quit Photos first; keep this library selected.")
    var photosLibrary: String?
    @Flag(name: .long, help: "Explicitly retry uncertain prior Photos imports; duplicate checking stays enabled.")
    var retryUncertainImports = false

    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Recover checksum-verified originals without needing the old Photos library.",
    )

    func run() async throws {
        try await CLISignalCancellation.run { try await execute() }
    }

    private func execute() async throws {
        guard (1 ... 16).contains(concurrency), ["photo", "video"].contains(type ?? "photo"),
              ["standard", "bulk"].contains(archiveTier), (1 ... 365).contains(archiveDays),
              waitSeconds.isFinite, (0 ... 86400).contains(waitSeconds),
              !retryUncertainImports || photosLibrary != nil
        else { throw ValidationError("Invalid restore concurrency, type, archive options or Photos retry selection") }
        let filters = try RestoreFilters(
            from: from.map(Self.utcDay), before: through.map { try Self.utcDay($0).addingTimeInterval(86400) },
            type: type, album: album,
        )
        let (config, objects, _) = try Dependencies.makeBackupDeps(profile: source.profile)
        guard let downloads = objects as? any ObjectDownloading else {
            throw ValidationError("This destination does not support streamed recovery")
        }
        let manifest = try await Self.loadManifest(objects)
        let plan = try await planRestore(
            manifest: manifest, source: objects, sourceID: config.restoreSourceID,
            filters: filters, concurrency: concurrency,
        )
        print("Selected \(plan.items.count) unique original resources; \(plan.metadataWarnings) metadata warnings.")
        if dryRun { Self.printInventory(plan)
            return
        }
        let photos = photosLibrary.map {
            RestorePhotosOptions(library: URL(fileURLWithPath: $0), retryUncertain: retryUncertainImports)
        }
        let importer: (any PhotosImportProviding)? = photos == nil ? nil : PhotosLibraryImporter()
        let archive = RestoreArchiveOptions(
            request: requestArchive, days: archiveDays, tier: archiveTier.capitalized, waitSeconds: waitSeconds,
        )
        let report = try await runRestore(
            plan: plan, source: downloads, destination: URL(fileURLWithPath: destination), concurrency: concurrency,
            archive: archive, photos: photos, importer: importer,
        )
        Self.printReport(report, hasPhotos: photos != nil)
        if !report.successful { throw ExitCode.failure }
    }

    private static func loadManifest(_ objects: any ObjectProviding) async throws -> Manifest {
        do {
            return try await Manifest.parse(from: objects.getObject(key: manifestS3Key))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let hint = "Cannot read backup manifest. If it is missing or damaged, "
                + "run 'attic rebuild' with the same --profile first."
            throw ValidationError(hint)
        }
    }

    private static func printInventory(_ plan: RestorePlan) {
        let preview = plan.items.prefix(20)
        for item in preview {
            print("  \(item.relativePath)  \(item.expectedSize.map(String.init) ?? "unknown") bytes")
        }
        if plan.items.count > 20 { print("  ... \(plan.items.count - 20) more") }
    }

    private static func printReport(_ report: RestoreReport, hasPhotos: Bool) {
        let summary = "Restore: \(report.restored) recovered, \(report.skipped) verified existing, "
            + "\(report.failed) failed, \(report.pending) archive pending."
        print(summary)
        if hasPhotos {
            let imports = "Photos: \(report.imported) resources processed, \(report.importFailed) failed, "
                + "\(report.importUncertain) uncertain."
            print(imports)
        }
        let errors = report.errors.prefix(20)
        for error in errors {
            FileHandle.standardError.write(Data((sanitizeTerminalText(error) + "\n").utf8))
        }
    }

    static func utcDay(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw ValidationError("Restore dates must be valid UTC days in YYYY-MM-DD format")
        }
        return date
    }
}

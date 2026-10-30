import Foundation

public struct ArchiveObjectState: Sendable {
    public let storageClass: String?
    public let archiveStatus: String?
    public let restorationOngoing: Bool?

    public init(storageClass: String? = nil, archiveStatus: String? = nil, restorationOngoing: Bool? = nil) {
        self.storageClass = storageClass
        self.archiveStatus = archiveStatus
        self.restorationOngoing = restorationOngoing
    }

    public var intelligentTiering: Bool {
        storageClass == "INTELLIGENT_TIERING"
    }

    public var requiresRetrieval: Bool {
        ["GLACIER", "DEEP_ARCHIVE"].contains(storageClass ?? "") ||
            ["ARCHIVE_ACCESS", "DEEP_ARCHIVE_ACCESS"].contains(archiveStatus ?? "")
    }

    public var readable: Bool {
        !requiresRetrieval || restorationOngoing == false
    }
}

public protocol ArchiveRetrieving: ObjectProviding {
    func inspectArchive(key: String) async throws -> ArchiveObjectState
    func requestArchive(key: String, days: Int, tier: String, intelligentTiering: Bool) async throws
}

public struct RestoreArchiveOptions: Sendable {
    public var request: Bool
    public var days: Int
    public var tier: String
    public var waitSeconds: Double

    public init(request: Bool = false, days: Int = 7, tier: String = "Standard", waitSeconds: Double = 0) {
        self.request = request
        self.days = days
        self.tier = tier
        self.waitSeconds = waitSeconds
    }

    func validate() throws {
        guard (1 ... 365).contains(days), ["Standard", "Bulk"].contains(tier),
              waitSeconds.isFinite, (0 ... 86400).contains(waitSeconds)
        else { throw RestoreError.invalid("Invalid archive retention, tier, or wait interval") }
    }
}

struct ArchiveWaitClock: Sendable {
    var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}

func awaitReadableArchive(
    source: any ArchiveRetrieving,
    key: String,
    options: RestoreArchiveOptions,
    deadline: Double,
    clock: ArchiveWaitClock = ArchiveWaitClock(),
) async throws -> Bool {
    var state = try await source.inspectArchive(key: key)
    if state.readable { return true }
    if options.request, state.restorationOngoing != true {
        try Task.checkCancellation()
        try await source.requestArchive(
            key: key, days: options.days, tier: options.tier, intelligentTiering: state.intelligentTiering,
        )
    }
    while true {
        let remaining = deadline - clock.now()
        guard remaining > 0 else { break }
        try await clock.sleep(min(15, remaining))
        try Task.checkCancellation()
        state = try await source.inspectArchive(key: key)
        if state.readable { return true }
    }
    return false
}

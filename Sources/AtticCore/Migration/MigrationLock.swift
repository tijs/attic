import Foundation

/// Body of the migration lock object on S3.
public struct MigrationLockBody: Codable, Sendable, Equatable {
    public var machineId: String
    public var startedAt: String
    public var ttlSeconds: Int

    public init(machineId: String, startedAt: String, ttlSeconds: Int) {
        self.machineId = machineId
        self.startedAt = startedAt
        self.ttlSeconds = ttlSeconds
    }
}

/// Errors raised by ``MigrationLock``.
public enum MigrationLockError: Error, CustomStringConvertible {
    /// Another migration is already in flight (or the lock is unexpired and
    /// belongs to another run).
    case heldElsewhere(MigrationLockBody)

    public var description: String {
        switch self {
        case let .heldElsewhere(body):
            "Another `attic migrate` is in flight on \(body.machineId), started \(body.startedAt). " +
                "If you are sure no other migration is running, re-run `attic migrate --repair` to clear it."
        }
    }
}

/// S3 key for the migration lock. Acquired before any v2 write, released
/// after the manifest swap (or on dry-run completion).
public let migrationLockS3Key = "migration.lock"

/// Best-effort coordination across machines running `attic migrate` against
/// the same bucket. The lock is a small JSON object whose contents identify
/// the holder and a TTL beyond which a stale lock can be reclaimed.
///
/// This is **not** distributed-systems-safe by itself — there is no atomic
/// compare-and-swap on plain S3. It exists to turn the documented invariant
/// "do not run migrate on two Macs at once" into a loud, recoverable failure
/// rather than silent data corruption.
public struct MigrationLock: Sendable {
    public static let defaultTTLSeconds = 30 * 60 // 30 minutes

    private let s3: any S3Providing
    private let now: @Sendable () -> Date
    private let machineId: String
    private let ttlSeconds: Int

    public init(
        s3: any S3Providing,
        machineId: String = MigrationLock.defaultMachineId(),
        ttlSeconds: Int = MigrationLock.defaultTTLSeconds,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.s3 = s3
        self.machineId = machineId
        self.ttlSeconds = ttlSeconds
        self.now = now
    }

    /// Acquire the lock. Throws ``MigrationLockError/heldElsewhere(_:)`` if
    /// an unexpired lock from a different run exists. If an expired lock
    /// exists, it is overwritten.
    public func acquire() async throws -> MigrationLockBody {
        if let existing = try await readExisting() {
            if !isExpired(existing) {
                throw MigrationLockError.heldElsewhere(existing)
            }
        }

        let body = MigrationLockBody(
            machineId: machineId,
            startedAt: formatISO8601(now()),
            ttlSeconds: ttlSeconds,
        )
        try await s3.putObject(
            key: migrationLockS3Key,
            body: try JSONEncoder().encode(body),
            contentType: "application/json",
        )
        return body
    }

    /// Best-effort release. Errors are swallowed — a stale lock is reclaimable
    /// via TTL or `--repair`.
    public func release() async {
        try? await s3.deleteObject(key: migrationLockS3Key)
    }

    /// Read the current lock body if present, else nil.
    public func readExisting() async throws -> MigrationLockBody? {
        guard try await s3.headObject(key: migrationLockS3Key) != nil else { return nil }
        let data = try await s3.getObject(key: migrationLockS3Key)
        return try? JSONDecoder().decode(MigrationLockBody.self, from: data)
    }

    private func isExpired(_ body: MigrationLockBody) -> Bool {
        guard let started = parseISO8601(body.startedAt) else { return true }
        return now().timeIntervalSince(started) > Double(body.ttlSeconds)
    }

    /// Stable, human-readable id for the current machine. Used in the lock
    /// body so a held-elsewhere error tells the user *which* Mac is running.
    public static func defaultMachineId() -> String {
        ProcessInfo.processInfo.hostName
    }
}

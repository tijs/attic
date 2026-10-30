@testable import AtticCore
import Foundation
import Testing

actor RestoreArchiveFixture: ObjectDownloading, ArchiveRetrieving {
    let source: RestoreFixtureSource
    var states: [ArchiveObjectState]
    var requests: [(Int, String, Bool)] = []
    var inspections = 0
    init(source: RestoreFixtureSource, states: [ArchiveObjectState]) { self.source = source
        self.states = states
    }

    func inspectArchive(key: String) async throws -> ArchiveObjectState {
        inspections += 1
        if states.count > 1 { return states.removeFirst() }
        return states[0]
    }

    func requestArchive(key: String, days: Int, tier: String, intelligentTiering: Bool) async throws {
        requests.append((days, tier, intelligentTiering))
    }

    func downloadObject(key: String) async throws -> DownloadedObject { try await source.downloadObject(key: key) }
    func getObject(key: String) async throws -> Data { try await source.getObject(key: key) }
    func headObject(key: String) async throws -> S3ObjectMeta? { try await source.headObject(key: key) }
    func listObjects(prefix: String) async throws -> [S3ListObject] { try await source.listObjects(prefix: prefix) }
    func putObject(key: String, body: Data, contentType: String?) async throws { try await source.putObject(
        key: key,
        body: body,
        contentType: contentType,
    ) }
    func deleteObject(key: String) async throws { try await source.deleteObject(key: key) }
}

private final class RestoreArchiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    private var sleeps: [Double] = []
    private var jump = false

    func jumpOnRead() { lock.withLock { jump = true } }
    var now: Double {
        lock.withLock {
            let value = time
            if jump { time = 2 }
            return value
        }
    }

    func sleep(_ seconds: Double) {
        lock.withLock {
            sleeps.append(seconds)
            time += max(0, seconds)
        }
    }

    var values: [Double] {
        lock.withLock { sleeps }
    }
}

struct RestoreArchiveTests {
    @Test func instantGlacierDownloadsNormallyWithoutRestoreRequest() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let archive = RestoreArchiveFixture(source: source, states: [ArchiveObjectState(storageClass: "GLACIER_IR")])
        let plan = try await planRestore(manifest: manifest, source: archive, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await runRestore(plan: plan, source: archive, destination: root).restored == 1)
        #expect(await archive.requests.isEmpty)
    }

    @Test func noArchiveFlagLeavesPendingWithoutDownloadsOrCharges() async throws {
        let (source, manifest) = try RestoreTestSupport.fixture(count: 1)
        let archive = RestoreArchiveFixture(source: source, states: [ArchiveObjectState(storageClass: "DEEP_ARCHIVE")])
        let plan = try await planRestore(manifest: manifest, source: archive, sourceID: "fixture")
        let root = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await runRestore(plan: plan, source: archive, destination: root)
        #expect(result.pending == 1)
        #expect(!result.successful)
        #expect(await archive.requests.isEmpty)
        #expect(await source.downloads.isEmpty)
        #expect(await source.mutations == 0)
    }

    @Test func explicitRequestsAreSeparateAndAlreadyOngoingDoesNotDuplicate() async throws {
        let (source, _) = try RestoreTestSupport.fixture(count: 1)
        let options = RestoreArchiveOptions(request: true, days: 3, tier: "Bulk")
        let archive = RestoreArchiveFixture(source: source, states: [
            ArchiveObjectState(storageClass: "INTELLIGENT_TIERING", archiveStatus: "ARCHIVE_ACCESS"),
        ])
        #expect(try await !awaitReadableArchive(source: archive, key: "originals/a", options: options, deadline: 0))
        #expect(await archive.requests.count == 1)
        #expect(await archive.requests.first?.2 == true)
        let ongoing = RestoreArchiveFixture(source: source, states: [
            ArchiveObjectState(storageClass: "GLACIER", restorationOngoing: true),
        ])
        #expect(try await !awaitReadableArchive(source: ongoing, key: "originals/a", options: options, deadline: 0))
        #expect(await ongoing.requests.isEmpty)
    }

    @Test func boundedPollingResumesExistingRequestAndStopsAtDeadline() async throws {
        let (source, _) = try RestoreTestSupport.fixture(count: 1)
        let archive = RestoreArchiveFixture(source: source, states: [
            ArchiveObjectState(storageClass: "GLACIER", restorationOngoing: true),
            ArchiveObjectState(storageClass: "GLACIER", restorationOngoing: false),
        ])
        let clock = RestoreArchiveClock()
        let seam = ArchiveWaitClock(now: { clock.now }, sleep: { clock.sleep($0) })
        #expect(try await awaitReadableArchive(
            source: archive,
            key: "originals/a",
            options: RestoreArchiveOptions(),
            deadline: 30,
            clock: seam,
        ))
        #expect(clock.values == [15])
        #expect(await archive.requests.isEmpty)
        let waiting = RestoreArchiveFixture(
            source: source,
            states: [ArchiveObjectState(storageClass: "DEEP_ARCHIVE", restorationOngoing: true)],
        )
        #expect(try await !awaitReadableArchive(
            source: waiting,
            key: "originals/a",
            options: RestoreArchiveOptions(),
            deadline: 20,
            clock: seam,
        ))
        #expect(clock.values == [15, 5])
        #expect(clock.values.allSatisfy { $0 >= 0 && $0 <= 15 })
    }

    @Test func crossingDeadlineCannotProduceANegativeSleep() async throws {
        let (source, _) = try RestoreTestSupport.fixture(count: 1)
        let archive = RestoreArchiveFixture(source: source, states: [
            ArchiveObjectState(storageClass: "GLACIER", restorationOngoing: true),
        ])
        let clock = RestoreArchiveClock()
        clock.jumpOnRead()
        let seam = ArchiveWaitClock(now: { clock.now }, sleep: { clock.sleep($0) })
        #expect(try await !awaitReadableArchive(
            source: archive, key: "originals/a", options: RestoreArchiveOptions(), deadline: 1, clock: seam,
        ))
        #expect(clock.values == [1])
    }
}

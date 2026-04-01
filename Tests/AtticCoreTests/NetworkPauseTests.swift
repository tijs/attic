import Testing
import Foundation
import LadderKit
@testable import AtticCore

// MARK: - Test helpers

/// S3 provider that fails with a network error after a configured number of
/// successful uploads. Simulates network loss mid-backup.
actor NetworkFailingS3Provider: S3Providing {
    private let inner = MockS3Provider()
    private var putCallCount = 0
    private let failAfterPuts: Int
    private var shouldFail = true

    init(failAfterPuts: Int = 0) {
        self.failAfterPuts = failAfterPuts
    }

    func stopFailing() {
        shouldFail = false
    }

    func putObject(key: String, body: Data, contentType: String?) async throws {
        putCallCount += 1
        if shouldFail && putCallCount > failAfterPuts {
            throw NetworkError.networkDown
        }
        try await inner.putObject(key: key, body: body, contentType: contentType)
    }

    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        putCallCount += 1
        if shouldFail && putCallCount > failAfterPuts {
            throw NetworkError.networkDown
        }
        try await inner.putObject(key: key, fileURL: fileURL, contentType: contentType)
    }

    func getObject(key: String) async throws -> Data {
        try await inner.getObject(key: key)
    }

    func headObject(key: String) async throws -> S3ObjectMeta? {
        try await inner.headObject(key: key)
    }

    func listObjects(prefix: String) async throws -> [S3ListObject] {
        try await inner.listObjects(prefix: prefix)
    }
}

enum NetworkError: Error, CustomStringConvertible {
    case networkDown

    var description: String {
        // Use "nsurlerrordomain" — recognized by isTransientUploadError in
        // BackupPipeline but NOT by withRetry's isTransient patterns, so
        // withRetry throws immediately without sleeping through retries.
        "NSURLErrorDomain Code=-1009"
    }
}

/// Network monitor that always reports unavailable and always times out.
/// Used for testing the timeout path without any polling or actor overhead.
struct AlwaysUnavailableNetworkMonitor: NetworkMonitoring {
    var isNetworkAvailable: Bool { false }

    func waitForNetwork(timeout: Duration) async throws -> Bool {
        try Task.checkCancellation()
        try await Task.sleep(for: timeout)
        return false
    }
}

/// Progress delegate that records pause/resume events for assertions.
final class RecordingProgressDelegate: BackupProgressDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.withLock { _events }
    }

    private func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    func backupStarted(pending: Int, photos: Int, videos: Int) {
        record("started(\(pending))")
    }
    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        record("batch(\(batchNumber))")
    }
    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        record("uploaded(\(uuid))")
    }
    func assetFailed(uuid: String, filename: String, message: String) {
        record("failed(\(uuid))")
    }
    func manifestSaved(entriesCount: Int) {
        record("manifestSaved(\(entriesCount))")
    }
    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        record("completed(\(uploaded),\(failed))")
    }
    func backupPaused(reason: String) {
        record("paused")
    }
    func backupResumed() {
        record("resumed")
    }
}

// MARK: - Tests

@Suite("NetworkPause")
struct NetworkPauseTests {
    @Test func backupCompletesNormallyWithoutNetworkMonitor() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10)
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 0)
    }

    @Test func backupCompletesNormallyWithAvailableNetwork() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])
        let (s3, manifestStore) = try await createTestContext()
        var manifest = try await manifestStore.load()
        let monitor = MockNetworkMonitor(available: true)

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
            networkMonitor: monitor
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 0)
    }

    @Test func pausesAndResumesWhenNetworkDropsAndRecovers() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])

        // S3 provider that fails on first put (simulating network loss)
        let s3 = NetworkFailingS3Provider(failAfterPuts: 0)
        let manifestStore = S3ManifestStore(s3: s3)
        var manifest = try await manifestStore.load()

        let monitor = MockNetworkMonitor(available: false)
        let progress = RecordingProgressDelegate()

        // Simulate network recovery after a short delay
        Task {
            try await Task.sleep(for: .milliseconds(100))
            await s3.stopFailing()
            await monitor.setAvailable()
        }

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: BackupOptions(batchSize: 10),
            progress: progress,
            networkMonitor: monitor
        )

        #expect(report.uploaded == 1)
        #expect(report.failed == 0)
        #expect(progress.events.contains("paused"))
        #expect(progress.events.contains("resumed"))
    }

    @Test(.timeLimit(.minutes(1)))
    func networkTimeoutExitsCleanly() async throws {
        // Verify that AlwaysUnavailableNetworkMonitor times out correctly
        let monitor = AlwaysUnavailableNetworkMonitor()
        let result = try await monitor.waitForNetwork(timeout: .milliseconds(100))
        #expect(!result)

        // Test the full pipeline with network failure + timeout
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])
        // Use separate S3 instances: one for manifest (works), one for uploads (fails)
        let goodS3 = MockS3Provider()
        let manifestStore = S3ManifestStore(s3: goodS3)
        var manifest = try await manifestStore.load()

        let failingS3 = NetworkFailingS3Provider(failAfterPuts: 0)
        let progress = RecordingProgressDelegate()

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: failingS3,
            options: BackupOptions(batchSize: 10, networkTimeout: .milliseconds(100)),
            progress: progress,
            networkMonitor: monitor
        )

        #expect(progress.events.contains("paused"))
        #expect(progress.events.contains("resumed"))
        #expect(report.failed >= 1)
    }

    @Test func cancellationDuringNetworkWaitExitsCleanly() async throws {
        let assets = [makeTestAsset(uuid: "uuid-1")]
        let exporter = MockExportProvider(assets: [
            "uuid-1": ("IMG_0001.HEIC", Data("photo1".utf8)),
        ])

        let s3 = NetworkFailingS3Provider(failAfterPuts: 0)
        let manifestStore = S3ManifestStore(s3: s3)
        var manifest = try await manifestStore.load()

        let monitor = AlwaysUnavailableNetworkMonitor()

        let task = Task {
            try await runBackup(
                assets: assets,
                manifest: &manifest,
                manifestStore: manifestStore,
                exporter: exporter,
                s3: s3,
                options: BackupOptions(batchSize: 10, networkTimeout: .seconds(30)),
                networkMonitor: monitor
            )
        }

        // Cancel after a brief delay
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        // Should throw CancellationError
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func mockNetworkMonitorBasicBehavior() async throws {
        let monitor = MockNetworkMonitor(available: true)
        let available = await monitor.isNetworkAvailable
        #expect(available)

        await monitor.setUnavailable()
        let unavailable = await monitor.isNetworkAvailable
        #expect(!unavailable)

        // waitForNetwork returns immediately when available
        await monitor.setAvailable()
        let recovered = try await monitor.waitForNetwork(timeout: .seconds(1))
        #expect(recovered)
    }
}

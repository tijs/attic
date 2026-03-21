import Foundation

/// Result of a verify run.
public struct VerifyReport: Sendable {
    public var ok: Int = 0
    public var missing: Int = 0
    public var failed: Int = 0
    public var errors: [(uuid: String, message: String)] = []
}

/// Verify backed-up assets exist in S3 via HEAD requests.
public func runVerify(
    manifest: Manifest,
    s3: any S3Providing,
    concurrency: Int = 20
) async throws -> VerifyReport {
    let entries = Array(manifest.entries.values)

    guard !entries.isEmpty else {
        return VerifyReport()
    }

    let report = VerifyReportAccumulator()

    await withTaskGroup(of: Void.self) { group in
        var cursor = 0

        // Seed initial tasks up to concurrency limit
        for _ in 0..<min(concurrency, entries.count) {
            let entry = entries[cursor]
            cursor += 1
            group.addTask {
                await verifySingle(entry: entry, s3: s3, report: report)
            }
        }

        // As each task completes, enqueue the next
        for await _ in group {
            if cursor < entries.count {
                let entry = entries[cursor]
                cursor += 1
                group.addTask {
                    await verifySingle(entry: entry, s3: s3, report: report)
                }
            }
        }
    }

    return await report.snapshot()
}

// MARK: - Internals

/// Actor to accumulate verify results safely.
private actor VerifyReportAccumulator {
    var ok = 0
    var missing = 0
    var failed = 0
    var errors: [(uuid: String, message: String)] = []

    func markOK() { ok += 1 }
    func markMissing(_ uuid: String) {
        missing += 1
        if errors.count < maxReportErrors {
            errors.append((uuid: uuid, message: "Missing from S3"))
        }
    }
    func markFailed(_ uuid: String, _ message: String) {
        failed += 1
        if errors.count < maxReportErrors {
            errors.append((uuid: uuid, message: message))
        }
    }

    func snapshot() -> VerifyReport {
        VerifyReport(ok: ok, missing: missing, failed: failed, errors: errors)
    }
}

private func verifySingle(
    entry: ManifestEntry,
    s3: any S3Providing,
    report: VerifyReportAccumulator
) async {
    do {
        if try await s3.headObject(key: entry.s3Key) != nil {
            await report.markOK()
        } else {
            await report.markMissing(entry.uuid)
        }
    } catch {
        await report.markFailed(entry.uuid, String(describing: error))
    }
}

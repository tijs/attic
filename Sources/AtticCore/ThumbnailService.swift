import Foundation

/// Orchestrates thumbnail generation with three-tier lookup, in-flight
/// deduplication, and bounded concurrency.
///
/// Lookup order:
/// 1. Local disk cache (~/.attic/thumbnails/)
/// 2. S3 thumbnail (thumbnails/{uuid}.jpg)
/// 3. Generate from original (download → resize → save to cache + S3)
public actor ThumbnailService: ThumbnailProviding {
    private let cache: ThumbnailCache
    private let s3: S3Providing
    private let dataStore: ViewerDataStore
    private let maxConcurrent: Int
    private var inFlight: [String: Task<Data, any Error>] = [:]
    private var activeGenerations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        cache: ThumbnailCache = ThumbnailCache(),
        s3: S3Providing,
        dataStore: ViewerDataStore,
        maxConcurrent: Int = 6
    ) {
        self.cache = cache
        self.s3 = s3
        self.dataStore = dataStore
        self.maxConcurrent = maxConcurrent
    }

    public func thumbnail(uuid: String) async throws -> Data {
        // 1. Deduplicate: if already generating this UUID, wait for it
        if let existing = inFlight[uuid] {
            return try await existing.value
        }

        // 2. Local disk cache
        if let cached = cache.get(uuid: uuid) {
            return cached
        }

        // 3. Start a generation task (S3 thumbnail → generate from original)
        let task = Task<Data, any Error> { [cache, s3] in
            // 3a. Check S3 for existing thumbnail (single GET, no HEAD)
            let thumbKey = try S3Paths.thumbnailKey(uuid: uuid)
            if let data = try? await s3.getObject(key: thumbKey) {
                try? cache.put(uuid: uuid, data: data)
                return data
            }

            // 3b. Generate from original
            let asset = await self.dataStore.asset(uuid: uuid)
            guard let asset else {
                throw ThumbnailError.notFound(uuid)
            }

            return try await self.generateThumbnail(
                for: asset, uuid: uuid, thumbKey: thumbKey
            )
        }

        inFlight[uuid] = task

        do {
            let result = try await task.value
            inFlight.removeValue(forKey: uuid)
            return result
        } catch {
            inFlight.removeValue(forKey: uuid)
            throw error
        }
    }

    // MARK: - Bounded generation

    /// Download original, generate thumbnail, save to cache + S3.
    /// Acquires and releases a concurrency slot synchronously within actor context.
    private func generateThumbnail(
        for asset: AssetView, uuid: String, thumbKey: String
    ) async throws -> Data {
        await acquireSlot()
        defer { releaseSlot() }

        let originalData: Data
        do {
            originalData = try await s3.getObject(key: asset.s3Key)
        } catch {
            throw ThumbnailError.s3Failure(uuid, error)
        }

        let jpegData: Data
        if asset.isVideo {
            jpegData = try VideoThumbnailer.thumbnail(from: originalData)
        } else {
            jpegData = try ImageThumbnailer.thumbnail(from: originalData)
        }

        // Save to local cache
        try? cache.put(uuid: uuid, data: jpegData)

        // Best-effort upload to S3 (don't fail if upload errors)
        try? await s3.putObject(
            key: thumbKey, body: jpegData, contentType: "image/jpeg"
        )

        return jpegData
    }

    // MARK: - Concurrency limiting (slot-transfer pattern)

    private func acquireSlot() async {
        if activeGenerations < maxConcurrent {
            activeGenerations += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // Slot was transferred by releaseSlot — no increment needed
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume() // Transfer the slot directly
        } else {
            activeGenerations -= 1
        }
    }
}

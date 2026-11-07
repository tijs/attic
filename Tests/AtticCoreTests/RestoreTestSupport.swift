@testable import AtticCore
import CryptoKit
import Foundation
import LadderKit
import Testing

actor RestoreFixtureSource: ObjectDownloading {
    enum DownloadMode: Sendable { case normal, corrupt, truncated, missing, cancelled }
    var objects: [String: Data]
    var modes: [String: DownloadMode] = [:]
    var downloads: [String: Int] = [:]
    var mutations = 0
    var active = 0
    var maximumActive = 0

    init(objects: [String: Data]) { self.objects = objects }
    func mode(_ mode: DownloadMode, for key: String) { modes[key] = mode }
    func set(_ data: Data, key: String) { objects[key] = data }
    func remove(_ key: String) { objects.removeValue(forKey: key) }

    func putObject(key: String, body: Data, contentType: String?) async throws { mutations += 1 }
    func deleteObject(key: String) async throws { mutations += 1 }
    func getObject(key: String) async throws -> Data {
        guard let data = objects[key] else { throw FilesystemError.notFound(key) }
        return data
    }

    func headObject(key: String) async throws -> S3ObjectMeta? {
        objects[key].map { S3ObjectMeta(contentLength: $0.count) }
    }

    func listObjects(prefix: String) async throws -> [S3ListObject] {
        objects.filter { $0.key.hasPrefix(prefix) }.map { S3ListObject(key: $0.key, size: $0.value.count) }
    }

    func downloadObject(key: String) async throws -> DownloadedObject {
        downloads[key, default: 0] += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        switch modes[key] ?? .normal {
        case .missing: throw FilesystemError.notFound(key)
        case .cancelled: throw CancellationError()
        case .corrupt: return try DownloadedObject(data: Data("corrupt original".utf8))
        case .truncated: return try DownloadedObject(data: Data((objects[key] ?? Data()).prefix(2)))
        case .normal: return try await DownloadedObject(data: getObject(key: key))
        }
    }
}

enum RestoreTestSupport {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-restore-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fixture(count: Int = 2, version: Int = 2) throws -> (RestoreFixtureSource, Manifest) {
        var objects: [String: Data] = [:]
        var manifest = Manifest(version: version)
        for index in 0 ..< count {
            let uuid = "cloud/id+\(index)="
            let asset = makeTestAsset(uuid: "local-\(index)", filename: "same.heic")
                .withResolvedCloudIdentity(.cloud(uuid))
            let key = try S3Paths.originalKey(uuid: uuid, dateCreated: asset.creationDate, extension: "heic")
            let data = Data("original \(index) bytes".utf8)
            let checksum = "sha256:" + hash(data)
            manifest.markBackedUp(uuid: uuid, s3Key: key, checksum: checksum, size: data.count, identityKind: .cloud)
            var metadata = buildMetadataJSON(asset: asset, s3Key: key, checksum: checksum, backedUpAt: "2024-01-01")
            metadata.albums = [AlbumRef(uuid: "album-1", title: "A holiday")]
            metadata.dateCreated = "2024-01-15T12:00:00.000+02:00"
            metadata.fileSize = data.count
            objects[key] = data
            try objects[S3Paths.metadataKey(uuid: uuid)] = try JSONEncoder().encode(metadata)
        }
        objects[manifestS3Key] = try manifest.encoded()
        return (RestoreFixtureSource(objects: objects), manifest)
    }
}

import Foundation

/// In-memory S3 mock for tests. Stores objects as [String: StoredObject].
public actor MockS3Provider: S3Providing {
    public struct StoredObject: Sendable {
        public var body: Data
        public var contentType: String?

        public init(body: Data, contentType: String? = nil) {
            self.body = body
            self.contentType = contentType
        }
    }

    public private(set) var objects: [String: StoredObject] = [:]
    public private(set) var putCount = 0
    public private(set) var getCount = 0

    public init() {}

    /// Pre-populate with test data.
    public init(objects: [String: Data]) {
        self.objects = objects.mapValues { StoredObject(body: $0) }
    }

    public func putObject(key: String, body: Data, contentType: String?) async throws {
        objects[key] = StoredObject(body: body, contentType: contentType)
        putCount += 1
    }

    public func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        let data = try Data(contentsOf: fileURL)
        objects[key] = StoredObject(body: data, contentType: contentType)
        putCount += 1
    }

    public func getObject(key: String) async throws -> Data {
        getCount += 1
        guard let obj = objects[key] else {
            throw MockS3Error.notFound(key)
        }
        return obj.body
    }

    public func headObject(key: String) async throws -> S3ObjectMeta? {
        guard let obj = objects[key] else { return nil }
        return S3ObjectMeta(
            contentLength: obj.body.count,
            contentType: obj.contentType,
        )
    }

    public nonisolated func presignedURL(key: String, expires: Int) -> URL {
        URL(string: "http://mock-s3/\(key)?expires=\(expires)")!
    }

    public func listObjects(prefix: String) async throws -> [S3ListObject] {
        objects.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { key in
                S3ListObject(
                    key: key,
                    size: objects[key]?.body.count ?? 0,
                )
            }
    }

    public func deleteObject(key: String) async throws {
        objects.removeValue(forKey: key)
    }
}

enum MockS3Error: Error {
    case notFound(String)
}

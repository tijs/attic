@testable import AtticCore
import Foundation
import Testing

@Suite("S3 storage class on uploads", .serialized)
struct StorageClassUploadTests {
    @Test func singlePutFileUploadCarriesStorageClass() async throws {
        let fileURL = try makeFile(contents: "photo bytes")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        StorageClassURLProtocol.reset()

        let client = try makeClient(storageClass: "GLACIER_IR")
        try await client.putObject(key: "originals/photo.heic", fileURL: fileURL, contentType: "image/heic")

        #expect(StorageClassURLProtocol.requests == [
            .init(method: "PUT", query: nil, storageClass: "GLACIER_IR"),
        ])
    }

    @Test func storageClassHeaderIsSigned() async throws {
        let fileURL = try makeFile(contents: "photo bytes")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        StorageClassURLProtocol.reset()

        let client = try makeClient(storageClass: "GLACIER_IR")
        try await client.putObject(key: "originals/photo.heic", fileURL: fileURL, contentType: "image/heic")

        let authorization = try #require(StorageClassURLProtocol.authorizations.first ?? nil)
        #expect(authorization.contains("x-amz-storage-class"))
    }

    @Test func multipartInitiationCarriesStorageClass() async throws {
        let fileURL = try makeFile(contents: "large video bytes")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        StorageClassURLProtocol.reset()

        let client = try makeClient(storageClass: "GLACIER_IR", multipartThreshold: 8)
        try await client.putObject(key: "originals/video.mov", fileURL: fileURL, contentType: "video/quicktime")

        let initiation = try #require(
            StorageClassURLProtocol.requests.first { $0.method == "POST" && $0.query == "uploads=" },
        )
        #expect(initiation.storageClass == "GLACIER_IR")

        let parts = StorageClassURLProtocol.requests.filter {
            $0.query?.hasPrefix("partNumber=") == true
        }
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.storageClass == nil })
    }

    @Test func bodyUploadOmitsStorageClass() async throws {
        StorageClassURLProtocol.reset()

        let client = try makeClient(storageClass: "GLACIER_IR")
        try await client.putObject(
            key: "manifest.json",
            body: Data("{}".utf8),
            contentType: "application/json",
        )

        #expect(StorageClassURLProtocol.requests == [
            .init(method: "PUT", query: nil, storageClass: nil),
        ])
    }

    @Test func nilStorageClassSendsNoHeader() async throws {
        let fileURL = try makeFile(contents: "photo bytes")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        StorageClassURLProtocol.reset()

        let client = try makeClient(storageClass: nil)
        try await client.putObject(key: "originals/photo.heic", fileURL: fileURL, contentType: "image/heic")

        #expect(StorageClassURLProtocol.requests == [
            .init(method: "PUT", query: nil, storageClass: nil),
        ])
    }

    private func makeClient(
        storageClass: String?,
        multipartThreshold: Int = 5 * 1024 * 1024 * 1024,
    ) throws -> URLSessionS3Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StorageClassURLProtocol.self]
        return try URLSessionS3Client(
            credentials: S3Credentials(accessKeyId: "key", secretAccessKey: "secret"),
            bucket: "bucket",
            endpoint: "https://example.com",
            region: "us-east-1",
            pathStyle: true,
            session: URLSession(configuration: configuration),
            multipartThreshold: multipartThreshold,
            multipartPreferredPartSize: 5 * 1024 * 1024,
            storageClass: storageClass,
        )
    }

    private func makeFile(contents: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }
}

private final class StorageClassURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let method: String
        let query: String?
        let storageClass: String?
    }

    nonisolated(unsafe) static var requests: [Request] = []
    nonisolated(unsafe) static var authorizations: [String?] = []

    static func reset() {
        requests = []
        authorizations = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(Request(
            method: request.httpMethod ?? "GET",
            query: request.url?.query,
            storageClass: request.value(forHTTPHeaderField: "x-amz-storage-class"),
        ))
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization"))

        let data: Data
        let headers: [String: String]
        if request.httpMethod == "POST", request.url?.query == "uploads=" {
            let xml = [
                "<InitiateMultipartUploadResult>",
                "<UploadId>upload-id</UploadId>",
                "</InitiateMultipartUploadResult>",
            ].joined()
            data = Data(xml.utf8)
            headers = [:]
        } else if request.url?.query?.hasPrefix("partNumber=") == true {
            data = Data()
            headers = ["ETag": "\"part\""]
        } else {
            data = Data()
            headers = [:]
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers,
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@testable import AtticCore
import CryptoKit
import Foundation
import Testing

@Suite("Multipart S3 uploads", .serialized)
struct MultipartUploadTests {
    @Test func oversizedFileUsesMultipartLifecycle() async throws {
        let partSize = 5 * 1024 * 1024
        let fileURL = try makeFile(size: 2 * partSize + 1)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        S3MultipartURLProtocol.reset()

        let client = try makeClient(threshold: 8, multipartPreferredPartSize: partSize)
        try await client.putObject(key: "originals/video.mov", fileURL: fileURL, contentType: "video/quicktime")

        #expect(S3MultipartURLProtocol.requests == [
            .init(method: "POST", query: "uploads="),
            .init(method: "PUT", query: "partNumber=1&uploadId=upload-id"),
            .init(method: "PUT", query: "partNumber=2&uploadId=upload-id"),
            .init(method: "PUT", query: "partNumber=3&uploadId=upload-id"),
            .init(method: "POST", query: "uploadId=upload-id"),
        ])
        #expect(S3MultipartURLProtocol.signedRequests.allSatisfy(\.self))

        let completion = [
            "<CompleteMultipartUpload>",
            "<Part><PartNumber>1</PartNumber><ETag>&quot;part-1&quot;</ETag></Part>",
            "<Part><PartNumber>2</PartNumber><ETag>&quot;part-2&quot;</ETag></Part>",
            "<Part><PartNumber>3</PartNumber><ETag>&quot;part-3&quot;</ETag></Part>",
            "</CompleteMultipartUpload>",
        ].joined()
        #expect(S3MultipartURLProtocol.payloadHashes.last == SHA256.hash(data: Data(completion.utf8)).hexDigest())
    }

    @Test func failedPartAbortsMultipartUpload() async throws {
        let fileURL = try makeFile(contents: "multipart payload")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        S3MultipartURLProtocol.reset(failPart: true)

        let client = try makeClient(threshold: 8)
        do {
            try await client.putObject(key: "originals/video.mov", fileURL: fileURL, contentType: nil)
            Issue.record("Expected multipart part upload to fail")
        } catch {
            #expect(error is S3ClientError)
        }

        #expect(S3MultipartURLProtocol.requests == [
            .init(method: "POST", query: "uploads="),
            .init(method: "PUT", query: "partNumber=1&uploadId=upload-id"),
            .init(method: "DELETE", query: "uploadId=upload-id"),
        ])
    }

    @Test func completionErrorAbortsMultipartUpload() async throws {
        let fileURL = try makeFile(contents: "multipart payload")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        S3MultipartURLProtocol.reset(completeWithError: true)

        let client = try makeClient(threshold: 8)
        do {
            try await client.putObject(key: "originals/video.mov", fileURL: fileURL, contentType: nil)
            Issue.record("Expected multipart completion error to fail")
        } catch {
            #expect(error is S3ClientError)
        }

        #expect(S3MultipartURLProtocol.requests == [
            .init(method: "POST", query: "uploads="),
            .init(method: "PUT", query: "partNumber=1&uploadId=upload-id"),
            .init(method: "POST", query: "uploadId=upload-id"),
            .init(method: "DELETE", query: "uploadId=upload-id"),
        ])
    }

    @Test func malformedInitiationResponseFails() async throws {
        let fileURL = try makeFile(contents: "multipart payload")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        S3MultipartURLProtocol.reset(malformedInitiation: true)

        let client = try makeClient(threshold: 8)
        do {
            try await client.putObject(key: "originals/video.mov", fileURL: fileURL, contentType: nil)
            Issue.record("Expected malformed multipart initiation response to fail")
        } catch {
            #expect(error is S3ClientError)
        }

        #expect(S3MultipartURLProtocol.requests == [.init(method: "POST", query: "uploads=")])
    }

    @Test func ordinaryFileRetainsSinglePut() async throws {
        let fileURL = try makeFile(contents: "small")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        S3MultipartURLProtocol.reset()

        let client = try makeClient(threshold: 8)
        try await client.putObject(key: "originals/photo.heic", fileURL: fileURL, contentType: "image/heic")

        #expect(S3MultipartURLProtocol.requests == [.init(method: "PUT", query: nil)])
    }

    private func makeClient(
        threshold: Int,
        multipartPreferredPartSize: Int = 64 * 1024 * 1024,
    ) throws -> URLSessionS3Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3MultipartURLProtocol.self]
        return try URLSessionS3Client(
            credentials: S3Credentials(accessKeyId: "key", secretAccessKey: "secret"),
            bucket: "bucket",
            endpoint: "https://example.com",
            region: "us-east-1",
            pathStyle: true,
            session: URLSession(configuration: configuration),
            multipartThreshold: threshold,
            multipartPreferredPartSize: multipartPreferredPartSize,
        )
    }

    private func makeFile(contents: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    private func makeFile(size: Int) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: size).write(to: fileURL)
        return fileURL
    }
}

private final class S3MultipartURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let method: String
        let query: String?
    }

    nonisolated(unsafe) static var requests: [Request] = []
    nonisolated(unsafe) static var signedRequests: [Bool] = []
    nonisolated(unsafe) static var payloadHashes: [String?] = []
    nonisolated(unsafe) static var failPart = false
    nonisolated(unsafe) static var malformedInitiation = false
    nonisolated(unsafe) static var completeWithError = false

    static func reset(
        failPart: Bool = false,
        malformedInitiation: Bool = false,
        completeWithError: Bool = false,
    ) {
        requests = []
        signedRequests = []
        payloadHashes = []
        self.failPart = failPart
        self.malformedInitiation = malformedInitiation
        self.completeWithError = completeWithError
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = Request(method: request.httpMethod ?? "GET", query: request.url?.query)
        Self.requests.append(request)
        Self.signedRequests.append(self.request.value(forHTTPHeaderField: "Authorization") != nil)
        Self.payloadHashes.append(self.request.value(forHTTPHeaderField: "X-Amz-Content-Sha256"))

        let isPart = request.method == "PUT" && request.query?.hasPrefix("partNumber=") == true
        let statusCode: Int
        let headers: [String: String]
        if Self.failPart, isPart {
            statusCode = 500
            headers = [:]
        } else {
            statusCode = 200
            if let partNumber = request.query?.split(separator: "&").first?.split(separator: "=").last {
                headers = ["ETag": "\"part-\(partNumber)\""]
            } else {
                headers = [:]
            }
        }

        let data: Data
        if request.query == "uploads=" {
            if Self.malformedInitiation {
                data = Data("<InitiateMultipartUploadResult/>".utf8)
            } else {
                let xml = "<InitiateMultipartUploadResult><UploadId>upload-id</UploadId></InitiateMultipartUploadResult>"
                data = Data(xml.utf8)
            }
        } else if request.method == "POST", request.query == "uploadId=upload-id", Self.completeWithError {
            data = Data("<Error><Code>InvalidPart</Code><Message>Part is invalid</Message></Error>".utf8)
        } else {
            data = Data()
        }
        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers,
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

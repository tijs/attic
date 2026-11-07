@testable import AtticCore
import Foundation
import Testing

private class RestoreTransportURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    static func respond(_ action: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) {
        lock.withLock { handler = action }
    }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < 65536 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let action = Self.lock.withLock { Self.handler }
        let (status, headers, data) = action?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers,
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct S3RestoreTransportTests {
    private func client() throws -> URLSessionS3Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RestoreTransportURLProtocol.self]
        return try URLSessionS3Client(
            credentials: S3Credentials(accessKeyId: "fixture", secretAccessKey: "fixture"),
            bucket: "bucket", endpoint: "https://example.invalid", region: "us-east-1", pathStyle: true,
            session: URLSession(configuration: config),
        )
    }

    @Test func headClassifiesRestoreStatusAndPermissionErrorsAreNotMissingObjects() async throws {
        RestoreTransportURLProtocol.respond { request in
            #expect(request.httpMethod == "HEAD")
            #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
            return (200, ["x-amz-storage-class": "GLACIER", "x-amz-restore": "ongoing-request=\"true\""], Data())
        }
        let client = try client()
        let state = try await client.inspectArchive(key: "originals/cloud%2Fid.heic")
        #expect(!state.readable)
        #expect(state.restorationOngoing == true)
        RestoreTransportURLProtocol.respond { _ in (403, [:], Data()) }
        await #expect(throws: S3ClientError.self) { try await client.inspectArchive(key: "originals/a.heic") }
    }

    @Test(arguments: [false, true])
    func restorePostSignsNamespacedXMLAndOmitsDaysForIntelligentTiering(intelligent: Bool) async throws {
        RestoreTransportURLProtocol.respond { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.query == "restore=")
            let body = String(data: RestoreTransportURLProtocol.body(request), encoding: .utf8) ?? ""
            #expect(body.contains("xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\""))
            #expect(body.contains("<Tier>Bulk</Tier>"))
            #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == RestoreTestSupport
                .hash(Data(body.utf8)))
            #expect(body.contains("<Days>3</Days>") == !intelligent)
            #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
            return (202, [:], Data())
        }
        try await client().requestArchive(
            key: "originals/a.heic",
            days: 3,
            tier: "Bulk",
            intelligentTiering: intelligent,
        )
    }

    @Test func onlyRestoreAlreadyInProgressConflictIsAccepted() async throws {
        RestoreTransportURLProtocol.respond { _ in
            (409, [:], Data("<Error><Code>RestoreAlreadyInProgress</Code><Message>pending</Message></Error>".utf8))
        }
        let client = try client()
        try await client.requestArchive(key: "originals/a", days: 7, tier: "Standard", intelligentTiering: false)
        RestoreTransportURLProtocol.respond { _ in
            (409, [:], Data("<Error><Code>DifferentConflict</Code><Message>failure</Message></Error>".utf8))
        }
        await #expect(throws: S3ClientError.self) {
            try await client.requestArchive(key: "originals/a", days: 7, tier: "Standard", intelligentTiering: false)
        }
    }

    @Test func malformedEscapesNeverReachNewTransportMethods() async throws {
        RestoreTransportURLProtocol.respond { _ in
            Issue.record("Transport must not receive an unsafe key")
            return (500, [:], Data())
        }
        let client = try client()
        await #expect(throws: RestoreError.self) { try await client.downloadObject(key: "originals/bad%X") }
        await #expect(throws: RestoreError.self) { try await client.inspectArchive(key: "originals/bad%X") }
        await #expect(throws: RestoreError.self) {
            try await client.requestArchive(
                key: "originals/bad%X",
                days: 7,
                tier: "Standard",
                intelligentTiering: false,
            )
        }
    }
}

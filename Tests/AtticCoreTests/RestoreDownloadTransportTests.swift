@testable import AtticCore
import Darwin
import Foundation
import Testing

/// One-request loopback server verifies the real URLSession download-to-file path.
private final class RestoreLoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let task: Task<Void, any Error>

    init(body: Data, status: Int = 200) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RestoreError.invalid("Cannot create fixture socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size),
            ) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw RestoreError.invalid("Cannot bind fixture socket")
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
        task = Task.detached {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { throw RestoreError.invalid("Fixture accept failed") }
            defer { close(connection) }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard recv(connection, &buffer, buffer.count, 0) > 0
            else { throw RestoreError.invalid("Missing fixture request") }
            var response = Data(
                "HTTP/1.1 \(status) Fixture\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    .utf8,
            )
            response.append(body)
            try response.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(connection, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { throw RestoreError.invalid("Fixture response failed") }
                    sent += count
                }
            }
        }
    }

    func finish() async throws { try await task.value }
    deinit { close(descriptor) }
}

struct RestoreDownloadTransportTests {
    @Test func nativeDownloadOwnsPrivateTemporaryFileAndRemovesItOnRelease() async throws {
        let data = Data(repeating: 39, count: 2 * 1024 * 1024)
        let server = try RestoreLoopbackServer(body: data)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        let client = try URLSessionS3Client(
            credentials: S3Credentials(accessKeyId: "fixture", secretAccessKey: "fixture"),
            bucket: "bucket", endpoint: "http://127.0.0.1:\(server.port)", region: "us-east-1", pathStyle: true,
            session: URLSession(configuration: config),
        )
        var download: DownloadedObject? = try await client.downloadObject(key: "originals/a.heic")
        let file = try #require(download?.fileURL)
        let handle = try FileHandle(forReadingFrom: file)
        #expect(try SafeDirectory.digest(handle).checksum == RestoreTestSupport.hash(data))
        try handle.close()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        download = nil
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await server.finish()
    }
}

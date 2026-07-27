import AWSSigner
import CryptoKit
import Foundation
import NIOHTTP1

/// S3 client using URLSession and aws-signer-v4.
///
/// Replaces the full AWS SDK with a lightweight implementation that only
/// needs URLSession (built-in) and SigV4 signing. Supports S3-compatible
/// providers via custom endpoints and path-style URLs.
public struct URLSessionS3Client: S3Providing, @unchecked Sendable {
    private let bucket: String
    private let endpoint: URL
    private let region: String
    private let pathStyle: Bool
    private let signer: AWSSigner
    private let headerSigner: S3V4HeaderSigner
    private let session: URLSession
    private let multipartThreshold: Int
    private let multipartPreferredPartSize: Int

    private static let singlePutMaximumSize = 5 * 1024 * 1024 * 1024
    private static let multipartMinimumPartSize = 5 * 1024 * 1024
    private static let defaultMultipartPreferredPartSize = 64 * 1024 * 1024
    private static let multipartMaximumPartCount = 10000

    public init(
        credentials: S3Credentials,
        bucket: String,
        endpoint: String,
        region: String,
        pathStyle: Bool,
    ) throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        // Default is 6, which throttles concurrent uploads to one bucket host.
        // Align with our bounded-concurrency upload group (effectively ~16).
        config.httpMaximumConnectionsPerHost = 32
        try self.init(
            credentials: credentials,
            bucket: bucket,
            endpoint: endpoint,
            region: region,
            pathStyle: pathStyle,
            session: URLSession(configuration: config),
        )
    }

    init(
        credentials: S3Credentials,
        bucket: String,
        endpoint: String,
        region: String,
        pathStyle: Bool,
        session: URLSession,
        multipartThreshold: Int = Self.singlePutMaximumSize,
        multipartPreferredPartSize: Int = Self.defaultMultipartPreferredPartSize,
    ) throws {
        guard let endpointURL = URL(string: endpoint) else {
            throw S3ClientError.unexpectedResponse("Invalid endpoint URL: \(endpoint)")
        }
        if !pathStyle, bucket.contains(".") {
            throw S3ClientError.unexpectedResponse(
                "Bucket name \"\(bucket)\" contains a dot — use path-style URLs instead.",
            )
        }
        self.bucket = bucket
        self.endpoint = endpointURL
        self.region = region
        self.pathStyle = pathStyle
        let creds = StaticCredential(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
        )
        signer = AWSSigner(credentials: creds, name: "s3", region: region)
        headerSigner = S3V4HeaderSigner(credentials: credentials, region: region)
        self.session = session
        self.multipartThreshold = multipartThreshold
        self.multipartPreferredPartSize = multipartPreferredPartSize
    }

    // MARK: - S3Providing

    public func putObject(key: String, body: Data, contentType: String?) async throws {
        var request = try makeRequest(key: key, method: "PUT")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        signRequest(&request, payloadHash: Self.sha256Hex(body))

        let (data, response) = try await session.upload(for: request, from: body)
        try checkResponse(response, data: data, key: key)
    }

    public func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size > multipartThreshold {
            try await putMultipartObject(key: key, fileURL: fileURL, size: size, contentType: contentType)
            return
        }

        var request = try makeRequest(key: key, method: "PUT")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let payloadHash = try Self.sha256Hex(fileURL: fileURL)
        signRequest(&request, payloadHash: payloadHash)

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try checkResponse(response, data: data, key: key)
    }

    public func getObject(key: String) async throws -> Data {
        var request = try makeRequest(key: key, method: "GET")
        signRequest(&request)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data, key: key)
        return data
    }

    public func headObject(key: String) async throws -> S3ObjectMeta? {
        var request = try makeRequest(key: key, method: "HEAD")
        signRequest(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3ClientError.unexpectedResponse("Not an HTTP response")
        }

        if http.statusCode == 404 || http.statusCode == 403 {
            // Some S3-compatible providers return 403 for missing objects
            return nil
        }

        if http.statusCode >= 400 {
            throw S3ClientError.httpError(http.statusCode, "HEAD \(key)")
        }

        let contentLength = Int(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        return S3ObjectMeta(contentLength: contentLength, contentType: contentType)
    }

    public func deleteObject(key: String) async throws {
        var request = try makeRequest(key: key, method: "DELETE")
        signRequest(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw S3ClientError.unexpectedResponse("Not an HTTP response")
        }
        // S3 returns 204 No Content for successful deletes; idempotent — 404
        // for missing keys is also a success here.
        if http.statusCode == 204 || http.statusCode == 200 || http.statusCode == 404 {
            return
        }
        throw S3ClientError.httpError(http.statusCode, "DELETE \(key)")
    }

    public func listObjects(prefix: String) async throws -> [S3ListObject] {
        var results: [S3ListObject] = []
        var continuationToken: String?

        repeat {
            var request = try makeRequest(key: "", method: "GET")
            guard let baseURL = request.url,
                  var fullComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            else {
                throw S3ClientError.unexpectedResponse("Failed to construct list URL")
            }
            // SigV4 canonical query strings require each value to be URI-
            // encoded, but `aws-signer-v4` canonicalizes `url.query` raw —
            // it does NOT uri-encode values during canonicalization (see
            // signer.swift comment: "should really uriEncode all the query
            // string values"). Pre-encode values here so what the request
            // carries on the wire and what the signer canonicalizes match
            // exactly. Without this, prefixes containing `/` (e.g.
            // `thumbnails/`, `metadata/assets/`) signature-mismatch on
            // strict S3 endpoints because the server canonicalizes
            // `thumbnails/` to `thumbnails%2F` while the signer signs
            // `thumbnails/` raw.
            var pairs: [String] = [
                "list-type=2",
                "prefix=\(uriEncodeQueryValue(prefix))",
            ]
            if let token = continuationToken {
                pairs.append("continuation-token=\(uriEncodeQueryValue(token))")
            }
            fullComponents.percentEncodedQuery = pairs.joined(separator: "&")
            request.url = fullComponents.url
            signRequest(&request)

            let (data, response) = try await session.data(for: request)
            try checkResponse(response, data: data, key: "list:\(prefix)")

            let parsed = parseListObjectsV2(data: data)
            results.append(contentsOf: parsed.objects)
            continuationToken = parsed.isTruncated ? parsed.nextContinuationToken : nil
        } while continuationToken != nil

        return results
    }

    public func presignedURL(key: String, expires: Int = 14400) -> URL {
        // makeRequest can only throw for invalid virtual-hosted URLs, which
        // would have failed at init time. Force-try is safe here.
        // swiftlint:disable:next force_try
        let request = try! makeRequest(key: key, method: "GET")
        return signer.signURL(url: request.url!, method: .GET, expires: expires)
    }

    // MARK: - Helpers

    /// Percent-encode a query value to AWS SigV4's canonical-query-string
    /// rules: every byte outside RFC 3986 unreserved characters is encoded.
    /// Critically tighter than Foundation's `urlQueryAllowed`, which leaves
    /// `/`, `:`, `+`, `=`, `?` raw in query values — those characters
    /// signature-mismatch on strict S3 endpoints because the server
    /// canonicalizes them as `%2F` / `%3A` / etc. while the signer used
    /// here signs the raw form.
    private nonisolated static let unreservedQueryChars: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    private func uriEncodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.unreservedQueryChars) ?? value
    }

    private func makeRequest(key: String, method: String) throws -> URLRequest {
        // S3 keys produced by ``S3Paths`` are already percent-encoded —
        // PhotoKit cloud identifiers contain `:`, `/`, `+`, `=` which must
        // not be re-interpreted as path structure. `appendingPathComponent`
        // re-encodes existing `%` to `%25`, which corrupts the key. Build
        // the URL via URLComponents.percentEncodedPath so the encoded form
        // survives intact through to AWS SigV4 signing.
        let url: URL = if pathStyle {
            try makePathStyleURL(key: key)
        } else {
            try makeVirtualHostedURL(key: key)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func makePathStyleURL(key: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw S3ClientError.unexpectedResponse("Invalid endpoint URL: \(endpoint)")
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var fullPath = basePath.isEmpty ? "/\(bucket)" : "/\(basePath)/\(bucket)"
        if !key.isEmpty {
            fullPath += "/" + key
        }
        components.percentEncodedPath = fullPath
        guard let url = components.url else {
            throw S3ClientError.unexpectedResponse("Invalid path-style URL for key: \(key)")
        }
        return url
    }

    private func makeVirtualHostedURL(key: String) throws -> URL {
        let host = endpoint.host ?? ""
        let scheme = endpoint.scheme ?? "https"
        let port = endpoint.port.map { ":\($0)" } ?? ""
        let bucketHost = "\(scheme)://\(bucket).\(host)\(port)"
        guard var components = URLComponents(string: bucketHost) else {
            throw S3ClientError.unexpectedResponse("Invalid virtual-hosted URL: \(bucketHost)")
        }
        if !key.isEmpty {
            components.percentEncodedPath = "/" + key
        }
        guard let url = components.url else {
            throw S3ClientError.unexpectedResponse("Invalid virtual-hosted URL for key: \(key)")
        }
        return url
    }

    private func signRequest(
        _ request: inout URLRequest,
        payloadHash: String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    ) {
        guard let url = request.url else { return }

        let signedHeaders = headerSigner.signHeaders(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            payloadHash: payloadHash,
            date: Date(),
        )

        // Apply signed headers back to the URLRequest
        for (name, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func putMultipartObject(
        key: String,
        fileURL: URL,
        size: Int,
        contentType: String?,
    ) async throws {
        let uploadID = try await initiateMultipartUpload(key: key, contentType: contentType)

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            let partSize = multipartPartSize(for: size)
            var remaining = size
            var partNumber = 1
            var parts: [(number: Int, eTag: String)] = []

            while remaining > 0 {
                let count = min(partSize, remaining)
                guard let body = try handle.read(upToCount: count), body.count == count else {
                    throw S3ClientError.unexpectedResponse("Failed to read multipart upload part")
                }

                var request = try makeMultipartRequest(
                    key: key,
                    method: "PUT",
                    query: "partNumber=\(partNumber)&uploadId=\(uriEncodeQueryValue(uploadID))",
                )
                signRequest(&request, payloadHash: Self.sha256Hex(body))
                let (data, response) = try await session.upload(for: request, from: body)
                try checkResponse(response, data: data, key: key)
                guard let eTag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else {
                    throw S3ClientError.unexpectedResponse("Multipart upload part missing ETag")
                }

                parts.append((partNumber, eTag))
                remaining -= count
                partNumber += 1
            }

            try await completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
        } catch {
            try? await abortMultipartUpload(key: key, uploadID: uploadID)
            throw error
        }
    }

    private func initiateMultipartUpload(key: String, contentType: String?) async throws -> String {
        var request = try makeMultipartRequest(key: key, method: "POST", query: "uploads=")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        signRequest(&request)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data, key: key)
        guard let uploadID = parseInitiateMultipartUpload(data: data) else {
            throw S3ClientError.unexpectedResponse("Multipart initiation response missing UploadId")
        }
        return uploadID
    }

    private func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [(number: Int, eTag: String)],
    ) async throws {
        let partsXML = parts.map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(Self.xmlEscaped($0.eTag))</ETag></Part>"
        }.joined()
        let body = Data("<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>".utf8)
        var request = try makeMultipartRequest(
            key: key,
            method: "POST",
            query: "uploadId=\(uriEncodeQueryValue(uploadID))",
        )
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        signRequest(&request, payloadHash: Self.sha256Hex(body))

        let (data, response) = try await session.upload(for: request, from: body)
        try checkResponse(response, data: data, key: key)
        if let s3Error = parseS3Error(data: data) {
            throw S3ClientError.s3Error(code: s3Error.code, message: s3Error.message)
        }
    }

    private func abortMultipartUpload(key: String, uploadID: String) async throws {
        var request = try makeMultipartRequest(
            key: key,
            method: "DELETE",
            query: "uploadId=\(uriEncodeQueryValue(uploadID))",
        )
        signRequest(&request)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data, key: key)
    }

    private func makeMultipartRequest(key: String, method: String, query: String) throws -> URLRequest {
        var request = try makeRequest(key: key, method: method)
        guard var components = try URLComponents(url: requireURL(request), resolvingAgainstBaseURL: false) else {
            throw S3ClientError.unexpectedResponse("Failed to construct multipart upload URL")
        }
        components.percentEncodedQuery = query
        request.url = components.url
        return request
    }

    private func requireURL(_ request: URLRequest) throws -> URL {
        guard let url = request.url else {
            throw S3ClientError.unexpectedResponse("Failed to construct multipart upload URL")
        }
        return url
    }

    private func multipartPartSize(for size: Int) -> Int {
        let minimumForPartCount = (size + Self.multipartMaximumPartCount - 1) / Self.multipartMaximumPartCount
        return max(Self.multipartMinimumPartSize, multipartPreferredPartSize, minimumForPartCount)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexDigest()
    }

    private static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexDigest()
    }

    private func checkResponse(_ response: URLResponse, data: Data, key: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw S3ClientError.unexpectedResponse("Not an HTTP response")
        }

        guard http.statusCode >= 200, http.statusCode < 300 else {
            if let s3Error = parseS3Error(data: data) {
                throw S3ClientError.s3Error(code: s3Error.code, message: s3Error.message)
            }
            throw S3ClientError.httpError(http.statusCode, key)
        }
    }
}

private extension Sequence<UInt8> {
    func hexDigest() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors from the S3 client.
public enum S3ClientError: Error, CustomStringConvertible {
    case httpError(Int, String)
    case unexpectedResponse(String)
    case s3Error(code: String, message: String)

    public var description: String {
        switch self {
        case let .httpError(status, key):
            "S3 HTTP \(status) for key: \(key)"
        case let .unexpectedResponse(msg):
            "Unexpected response: \(msg)"
        case let .s3Error(code, message):
            "S3 error \(code): \(message)"
        }
    }
}

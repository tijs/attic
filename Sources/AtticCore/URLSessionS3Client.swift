import Foundation
import AWSSigner
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
    private let session: URLSession

    public init(
        credentials: S3Credentials,
        bucket: String,
        endpoint: String,
        region: String,
        pathStyle: Bool
    ) throws {
        guard let endpointURL = URL(string: endpoint) else {
            throw S3ClientError.unexpectedResponse("Invalid endpoint URL: \(endpoint)")
        }
        self.bucket = bucket
        self.endpoint = endpointURL
        self.region = region
        self.pathStyle = pathStyle

        let creds = StaticCredential(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey
        )
        self.signer = AWSSigner(credentials: creds, name: "s3", region: region)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - S3Providing

    public func putObject(key: String, body: Data, contentType: String?) async throws {
        var request = try makeRequest(key: key, method: "PUT")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        signRequest(&request, hasBody: true)

        let (data, response) = try await session.upload(for: request, from: body)
        try checkResponse(response, data: data, key: key)
    }

    public func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        var request = try makeRequest(key: key, method: "PUT")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        signRequest(&request, hasBody: true)

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

    public func listObjects(prefix: String) async throws -> [S3ListObject] {
        var results: [S3ListObject] = []
        var continuationToken: String?

        repeat {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let token = continuationToken {
                components.queryItems?.append(URLQueryItem(name: "continuation-token", value: token))
            }

            var request = try makeRequest(key: "", method: "GET")
            // Append query string to the bucket-level URL
            guard let baseURL = request.url,
                  var fullComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            else {
                throw S3ClientError.unexpectedResponse("Failed to construct list URL")
            }
            fullComponents.queryItems = components.queryItems
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

    // MARK: - Helpers

    private func makeRequest(key: String, method: String) throws -> URLRequest {
        let url: URL
        if pathStyle {
            // Path-style: endpoint/bucket/key
            if key.isEmpty {
                url = endpoint.appendingPathComponent(bucket)
            } else {
                url = endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
            }
        } else {
            // Virtual-hosted: bucket.host/key
            let host = endpoint.host ?? ""
            let scheme = endpoint.scheme ?? "https"
            let port = endpoint.port.map { ":\($0)" } ?? ""
            let bucketHost = "\(scheme)://\(bucket).\(host)\(port)"
            guard let baseURL = URL(string: bucketHost) else {
                throw S3ClientError.unexpectedResponse(
                    "Invalid virtual-hosted URL: \(bucketHost)")
            }
            if key.isEmpty {
                url = baseURL
            } else {
                url = baseURL.appendingPathComponent(key)
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(url.host, forHTTPHeaderField: "Host")
        return request
    }

    private func signRequest(_ request: inout URLRequest, hasBody: Bool = false) {
        guard let url = request.url else { return }

        let method = HTTPMethod(rawValue: request.httpMethod ?? "GET")

        // Collect existing headers
        var nioHeaders = HTTPHeaders()
        if let allHeaders = request.allHTTPHeaderFields {
            for (name, value) in allHeaders {
                nioHeaders.add(name: name, value: value)
            }
        }

        // For uploads, use UNSIGNED-PAYLOAD to avoid hashing large files.
        // For bodiless requests (GET/HEAD), use an empty body so the signer
        // computes the correct empty-payload hash — some S3-compatible
        // providers reject UNSIGNED-PAYLOAD on non-PUT requests.
        let body: AWSSigner.BodyData = hasBody
            ? .string("UNSIGNED-PAYLOAD")
            : .string("")

        let signedHeaders = signer.signHeaders(
            url: url,
            method: method,
            headers: nioHeaders,
            body: body,
            date: Date()
        )

        // Apply signed headers back to the URLRequest
        for (name, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func checkResponse(_ response: URLResponse, data: Data, key: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw S3ClientError.unexpectedResponse("Not an HTTP response")
        }

        guard http.statusCode >= 200 && http.statusCode < 300 else {
            if let s3Error = parseS3Error(data: data) {
                throw S3ClientError.s3Error(code: s3Error.code, message: s3Error.message)
            }
            throw S3ClientError.httpError(http.statusCode, key)
        }
    }
}

/// Errors from the S3 client.
public enum S3ClientError: Error, CustomStringConvertible {
    case httpError(Int, String)
    case unexpectedResponse(String)
    case s3Error(code: String, message: String)

    public var description: String {
        switch self {
        case .httpError(let status, let key):
            "S3 HTTP \(status) for key: \(key)"
        case .unexpectedResponse(let msg):
            "Unexpected response: \(msg)"
        case .s3Error(let code, let message):
            "S3 error \(code): \(message)"
        }
    }
}

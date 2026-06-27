import CryptoKit
import Foundation

struct S3V4HeaderSigner {
    private let credentials: S3Credentials
    private let region: String
    private let service = "s3"

    init(credentials: S3Credentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    func signHeaders(
        url: URL,
        method: String,
        headers inputHeaders: [String: String],
        payloadHash: String,
        date: Date,
    ) -> [String: String] {
        let timestamp = Self.timestamp(date)
        let host = Self.hostHeaderValue(for: url)
        var headers = inputHeaders.filter { name, _ in
            let lowercased = name.lowercased()
            return lowercased != "authorization"
                && lowercased != "content-length"
                && lowercased != "host"
                && lowercased != "x-amz-date"
                && lowercased != "x-amz-content-sha256"
        }
        headers["Host"] = host
        headers["X-Amz-Date"] = timestamp
        headers["X-Amz-Content-Sha256"] = payloadHash

        let canonical = canonicalRequest(
            url: url,
            method: method,
            headers: headers,
            payloadHash: payloadHash,
        )
        let credentialDate = String(timestamp.prefix(8))
        let scope = "\(credentialDate)/\(region)/\(service)/aws4_request"
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(timestamp)
        \(scope)
        \(Self.sha256Hex(Data(canonical.utf8)))
        """
        let signature = Self.signature(
            stringToSign: stringToSign,
            date: credentialDate,
            secretAccessKey: credentials.secretAccessKey,
            region: region,
            service: service,
        )
        let signedHeaderNames = Self.canonicalHeaders(headers).signedHeaders
        headers["Authorization"] = """
        AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), \
        SignedHeaders=\(signedHeaderNames), Signature=\(signature)
        """
        return headers
    }

    func canonicalRequest(
        url: URL,
        method: String,
        headers: [String: String],
        payloadHash: String,
    ) -> String {
        let canonicalHeaders = Self.canonicalHeaders(headers)
        return [
            method,
            Self.canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaders.lines,
            "",
            canonicalHeaders.signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
    }

    private static func canonicalHeaders(_ headers: [String: String]) -> (lines: String, signedHeaders: String) {
        var valuesByName: [String: [String]] = [:]
        for (name, value) in headers {
            let lowercasedName = name.lowercased()
            guard lowercasedName != "authorization" else { continue }
            valuesByName[lowercasedName, default: []].append(normalizeHeaderValue(value))
        }

        let names = valuesByName.keys.sorted()
        let lines = names
            .map { "\($0):\(valuesByName[$0, default: []].joined(separator: ","))" }
            .joined(separator: "\n")
        return (lines, names.joined(separator: ";"))
    }

    private static func normalizeHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return awsPercentEncode(path.isEmpty ? "/" : path, encodeSlash: false)
    }

    private static func canonicalQuery(_ url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              !query.isEmpty
        else {
            return ""
        }
        return query.split(separator: "&", omittingEmptySubsequences: false)
            .sorted()
            .joined(separator: "&")
    }

    private static func awsPercentEncode(_ value: String, encodeSlash: Bool) -> String {
        var encoded = ""
        for byte in value.utf8 {
            let isAlpha = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            let isDigit = byte >= 48 && byte <= 57
            let isUnreserved = isAlpha || isDigit || byte == 45 || byte == 46 || byte == 95 || byte == 126
            if isUnreserved || (!encodeSlash && byte == 47) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func hostHeaderValue(for url: URL) -> String {
        guard let host = url.host else { return "" }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    private static func signature(
        stringToSign: String,
        date: String,
        secretAccessKey: String,
        region: String,
        service: String,
    ) -> String {
        let kDate = hmac(key: Data("AWS4\(secretAccessKey)".utf8), message: date)
        let kRegion = hmac(key: kDate, message: region)
        let kService = hmac(key: kRegion, message: service)
        let kSigning = hmac(key: kService, message: "aws4_request")
        return hmac(key: kSigning, message: stringToSign).hexDigest()
    }

    private static func hmac(key: Data, message: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key),
        )
        return Data(code)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexDigest()
    }
}

private extension Sequence<UInt8> {
    func hexDigest() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

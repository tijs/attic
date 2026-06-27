@testable import AtticCore
import Foundation
import Testing

struct S3V4HeaderSignerTests {
    private let credentials = S3Credentials(
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    )

    private let fixedDate = Date(timeIntervalSince1970: 1_704_067_200)

    @Test func uploadSigningUsesProvidedPayloadHash() throws {
        let signer = S3V4HeaderSigner(credentials: credentials, region: "us-east-1")
        let url = try #require(URL(string: "https://storage.googleapis.com/example-bucket/metadata/assets/test.json"))
        let payloadHash = "9b45b81a4bc8572c12f4c476aa21cd060a4fb2fbf1a102a1c323e781aacf6f76"

        let headers = signer.signHeaders(
            url: url,
            method: "PUT",
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "42",
                "Host": "ignored.example.com",
            ],
            payloadHash: payloadHash,
            date: fixedDate,
        )

        let authorization = try #require(headers["Authorization"])
        #expect(headers["X-Amz-Content-Sha256"] == payloadHash)
        #expect(headers["Host"] == "storage.googleapis.com")
        #expect(!authorization.contains("content-length"))
        #expect(authorization.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"))
    }

    @Test func canonicalURIUsesDecodedPathAndKeepsSlashes() throws {
        let signer = S3V4HeaderSigner(credentials: credentials, region: "us-east-1")
        let url = try #require(URL(
            string: "https://storage.googleapis.com/example-bucket/metadata/assets/uuid%2Fwith%2Fslashes.json",
        ))

        let canonical = signer.canonicalRequest(
            url: url,
            method: "GET",
            headers: [
                "Host": "storage.googleapis.com",
                "X-Amz-Date": "20240101T000000Z",
                "X-Amz-Content-Sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )

        #expect(canonical.contains(
            "/example-bucket/metadata/assets/uuid/with/slashes.json\n",
        ))
    }

    @Test func canonicalQueryPreservesPreEncodedListPrefix() throws {
        let signer = S3V4HeaderSigner(credentials: credentials, region: "us-east-1")
        let url = try #require(URL(
            string: "https://storage.googleapis.com/example-bucket?prefix=metadata%2Fassets&list-type=2",
        ))

        let canonical = signer.canonicalRequest(
            url: url,
            method: "GET",
            headers: [
                "Host": "storage.googleapis.com",
                "X-Amz-Date": "20240101T000000Z",
                "X-Amz-Content-Sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )

        #expect(canonical.contains("\nlist-type=2&prefix=metadata%2Fassets\n"))
    }
}

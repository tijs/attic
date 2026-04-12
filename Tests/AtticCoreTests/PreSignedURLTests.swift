@testable import AtticCore
import Foundation
import Testing

@Suite
struct PreSignedURLTests {
    @Test func mockReturnsExpectedURL() async throws {
        let s3 = MockS3Provider()
        let url = await s3.presignedURL(key: "originals/2024/07/test-uuid.heic", expires: 14400)
        #expect(url.absoluteString == "http://mock-s3/originals/2024/07/test-uuid.heic?expires=14400")
    }

    @Test func mockURLIncludesExpiryValue() async throws {
        let s3 = MockS3Provider()
        let url = await s3.presignedURL(key: "originals/2024/01/abc.jpg", expires: 3600)
        #expect(url.absoluteString.contains("expires=3600"))
    }

    @Test func mockURLPreservesS3Key() async throws {
        let s3 = MockS3Provider()
        let key = "metadata/assets/8A3B1C2D-4E5F-6789-ABCD-EF0123456789.json"
        let url = await s3.presignedURL(key: key, expires: 14400)
        #expect(url.absoluteString.contains(key))
    }
}

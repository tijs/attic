@testable import AtticCore
import Foundation
import Testing

struct AtticConfigTests {
    @Test func validateAcceptsValidConfigWithAllFields() throws {
        let config = try AtticConfig.validate([
            "endpoint": "https://s3.fr-par.scw.cloud",
            "region": "fr-par",
            "bucket": "my-photo-backup",
            "pathStyle": false,
            "keychain": [
                "accessKeyService": "custom-access",
                "secretKeyService": "custom-secret",
            ],
        ] as [String: Any])

        #expect(config.endpoint == "https://s3.fr-par.scw.cloud")
        #expect(config.region == "fr-par")
        #expect(config.bucket == "my-photo-backup")
        #expect(config.pathStyle == false)
        #expect(config.keychain.accessKeyService == "custom-access")
        #expect(config.keychain.secretKeyService == "custom-secret")
    }

    @Test func validateAppliesDefaultsForOptionalFields() throws {
        let config = try AtticConfig.validate([
            "endpoint": "https://s3.fr-par.scw.cloud",
            "region": "fr-par",
            "bucket": "my-photo-backup",
        ] as [String: Any])

        #expect(config.pathStyle == true)
        #expect(config.keychain.accessKeyService == "attic-s3-access-key")
        #expect(config.keychain.secretKeyService == "attic-s3-secret-key")
    }

    @Test func validateRejectsMissingEndpoint() {
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate(["region": "fr-par", "bucket": "b"] as [String: Any])
        }
    }

    @Test func validateRejectsNonHTTPSEndpoint() {
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate([
                "endpoint": "http://s3.example.com",
                "region": "us-east-1",
                "bucket": "bbb",
            ] as [String: Any])
        }
    }

    @Test func validateRejectsMissingRegion() {
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate([
                "endpoint": "https://s3.example.com",
                "bucket": "bbb",
            ] as [String: Any])
        }
    }

    @Test func validateRejectsMissingBucket() {
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate([
                "endpoint": "https://s3.example.com",
                "region": "us-east-1",
            ] as [String: Any])
        }
    }

    @Test func validateRejectsInvalidBucketName() {
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate([
                "endpoint": "https://s3.example.com",
                "region": "us-east-1",
                "bucket": "A",
            ] as [String: Any])
        }
    }

    @Test func validateRejectsNonObjectInput() {
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate("not an object" as Any)
        }
        #expect(throws: ConfigError.self) {
            try AtticConfig.validate([] as [Any] as Any)
        }
    }

    @Test func writeAndLoadConfigRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = FileConfigProvider(directory: dir)
        let config = AtticConfig(
            endpoint: "https://s3.fr-par.scw.cloud",
            region: "fr-par",
            bucket: "test-bucket",
        )

        try provider.write(config)

        let loaded = try provider.load()
        #expect(loaded == config)
    }

    @Test func loadReturnsNilWhenFileDoesNotExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let provider = FileConfigProvider(directory: dir)
        let result = try provider.load()
        #expect(result == nil)
    }
}

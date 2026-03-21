import Foundation
import AWSS3
import SmithyIdentity
import Smithy

/// S3 provider using the official AWS SDK for Swift.
public struct AWSS3Client: S3Providing {
    private let client: S3Client
    private let bucket: String

    public init(
        credentials: S3Credentials,
        bucket: String,
        endpoint: String,
        region: String,
        pathStyle: Bool
    ) throws {
        let awsCredentials = AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey
        )
        let config = try S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(awsCredentials),
            region: region,
            forcePathStyle: pathStyle,
            endpoint: endpoint
        )
        self.client = S3Client(config: config)
        self.bucket = bucket
    }

    public func putObject(key: String, body: Data, contentType: String?) async throws {
        let input = PutObjectInput(
            body: .data(body),
            bucket: bucket,
            contentType: contentType,
            key: key
        )
        _ = try await client.putObject(input: input)
    }

    public func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        // Use memory-mapped I/O to avoid loading the entire file into heap.
        // The kernel pages in only what the network layer reads.
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let input = PutObjectInput(
            body: .data(data),
            bucket: bucket,
            contentType: contentType,
            key: key
        )
        _ = try await client.putObject(input: input)
    }

    public func getObject(key: String) async throws -> Data {
        let input = GetObjectInput(bucket: bucket, key: key)
        let output = try await client.getObject(input: input)
        guard let body = output.body else {
            throw S3ClientError.emptyResponse(key)
        }
        return try await body.readData() ?? Data()
    }

    public func headObject(key: String) async throws -> S3ObjectMeta? {
        do {
            let input = HeadObjectInput(bucket: bucket, key: key)
            let output = try await client.headObject(input: input)
            return S3ObjectMeta(
                contentLength: Int(output.contentLength ?? 0),
                contentType: output.contentType
            )
        } catch is AWSS3.NotFound {
            return nil
        } catch {
            // Some S3-compatible providers return different error types for 404
            let description = String(describing: error)
            if description.contains("NotFound") || description.contains("NoSuchKey")
                || description.contains("404") {
                return nil
            }
            throw error
        }
    }

    public func listObjects(prefix: String) async throws -> [S3ListObject] {
        var results: [S3ListObject] = []
        var continuationToken: String?

        repeat {
            let input = ListObjectsV2Input(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: prefix
            )
            let output = try await client.listObjectsV2(input: input)

            for object in output.contents ?? [] {
                if let key = object.key {
                    results.append(S3ListObject(
                        key: key,
                        size: Int(object.size ?? 0)
                    ))
                }
            }

            continuationToken = output.nextContinuationToken
        } while continuationToken != nil

        return results
    }
}

/// Errors from the S3 client wrapper.
public enum S3ClientError: Error, CustomStringConvertible {
    case emptyResponse(String)

    public var description: String {
        switch self {
        case .emptyResponse(let key):
            "Empty response body for S3 key: \(key)"
        }
    }
}

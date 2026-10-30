import CryptoKit
import Foundation

extension URLSessionS3Client: ObjectDownloading {
    public func downloadObject(key: String) async throws -> DownloadedObject {
        try RestoreValidation.objectKey(key)
        var request = try makeRequest(key: key, method: "GET")
        signRequest(&request)
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try checkResponse(response, data: Data(), key: key)
        let input = try FileHandle(forReadingFrom: temporary)
        defer { try? input.close() }
        return try DownloadedObject { output in
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
        }
    }
}

extension URLSessionS3Client: ArchiveRetrieving {
    public func inspectArchive(key: String) async throws -> ArchiveObjectState {
        try RestoreValidation.objectKey(key)
        var request = try makeRequest(key: key, method: "HEAD")
        signRequest(&request)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data, key: key)
        guard let http = response as? HTTPURLResponse else { throw S3ClientError.unexpectedResponse("Invalid HEAD") }
        let restore = http.value(forHTTPHeaderField: "x-amz-restore")
        let ongoing: Bool? = if restore?.contains("ongoing-request=\"true\"") == true {
            true
        } else if restore?.contains("ongoing-request=\"false\"") == true {
            false
        } else {
            nil
        }
        return ArchiveObjectState(
            storageClass: http.value(forHTTPHeaderField: "x-amz-storage-class"),
            archiveStatus: http.value(forHTTPHeaderField: "x-amz-archive-status"), restorationOngoing: ongoing,
        )
    }

    public func requestArchive(key: String, days: Int, tier: String, intelligentTiering: Bool) async throws {
        try RestoreValidation.objectKey(key)
        try RestoreArchiveOptions(days: days, tier: tier).validate()
        var request = try makeRequest(key: key, method: "POST")
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw S3ClientError.unexpectedResponse("Cannot construct archive retrieval request")
        }
        components.queryItems = [URLQueryItem(name: "restore", value: "")]
        request.url = components.url
        let retention = intelligentTiering ? "" : "<Days>\(days)</Days>"
        let xml = "<RestoreRequest xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" + retention
            + "<GlacierJobParameters><Tier>\(tier)</Tier></GlacierJobParameters></RestoreRequest>"
        let body = Data(xml.utf8)
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        signRequest(&request, payloadHash: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           parseS3Error(data: data)?.code == "RestoreAlreadyInProgress" { return }
        try checkResponse(response, data: data, key: key)
    }
}

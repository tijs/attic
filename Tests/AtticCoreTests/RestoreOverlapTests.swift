@testable import AtticCore
import Foundation
import Testing

struct RestoreOverlapTests {
    @Test(arguments: ["files", "metadata"])
    func ancestorDestinationIsRejectedBeforeAnyWrites(sourceDirectory: String) async throws {
        let parent = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let sourceRoot = parent.appendingPathComponent(sourceDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let source = try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: sourceRoot))
        let (fixture, manifest) = try RestoreTestSupport.fixture(count: 1)
        for object in try await fixture.listObjects(prefix: "") {
            try await source.putObject(key: object.key, body: fixture.getObject(key: object.key))
        }
        let plan = try await planRestore(manifest: manifest, source: source, sourceID: "ancestor-regression")
        var sourceBefore: [String: Data] = [:]
        for object in try await source.listObjects(prefix: "") {
            sourceBefore[object.key] = try await source.getObject(key: object.key)
        }
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: parent.path)

        await #expect(throws: RestoreError.self) {
            try await runRestore(plan: plan, source: source, destination: parent)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == namesBefore)
        let permissions = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int
        #expect(permissions == 0o750)
        #expect(try await source.listObjects(prefix: "").map(\.key).sorted() == sourceBefore.keys.sorted())
        for (key, data) in sourceBefore {
            #expect(try await source.getObject(key: key) == data)
        }
    }
}

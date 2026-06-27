@testable import AtticCore
import Testing

struct PhotosPermissionPreflightTests {
    @Test func authorizedSucceeds() throws {
        try PhotosPermissionPreflight.validate(status: .authorized)
        #expect(PhotosPermissionPreflight.failureMessage(for: .authorized) == nil)
    }

    @Test func limitedRequiresFullAccess() {
        let message = PhotosPermissionPreflight.failureMessage(for: .limited) ?? ""
        #expect(message.contains("full Photos access"))
        #expect(message.contains("Limited Photos access is not enough"))
    }

    @Test func deniedIncludesSystemSettingsGuidance() {
        let message = PhotosPermissionPreflight.failureMessage(for: .denied) ?? ""
        #expect(message.contains("System Settings > Privacy & Security > Photos"))
        #expect(message.contains("iTerm or Terminal"))
        #expect(message.contains("Re-run the command"))
    }

    @Test func restrictedIncludesSystemSettingsGuidance() {
        let message = PhotosPermissionPreflight.failureMessage(for: .restricted) ?? ""
        #expect(message.contains("System Settings > Privacy & Security > Photos"))
        #expect(message.contains("iTerm or Terminal"))
        #expect(message.contains("Re-run the command"))
    }

    @Test func notDeterminedIncludesSystemSettingsGuidance() {
        let message = PhotosPermissionPreflight.failureMessage(for: .notDetermined) ?? ""
        #expect(message.contains("System Settings > Privacy & Security > Photos"))
        #expect(message.contains("iTerm or Terminal"))
        #expect(message.contains("Re-run the command"))
    }

    @Test func unknownIncludesSystemSettingsGuidance() {
        let message = PhotosPermissionPreflight.failureMessage(for: .unknown) ?? ""
        #expect(message.contains("System Settings > Privacy & Security > Photos"))
        #expect(message.contains("iTerm or Terminal"))
        #expect(message.contains("Re-run the command"))
    }
}

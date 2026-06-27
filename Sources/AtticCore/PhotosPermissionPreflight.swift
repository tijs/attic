import Foundation

public enum PhotosPermissionStatus: Equatable, Sendable {
    case authorized
    case limited
    case denied
    case restricted
    case notDetermined
    case unknown
}

public struct PhotosPermissionError: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    public let status: PhotosPermissionStatus
    public let message: String

    public var description: String {
        message
    }

    public var errorDescription: String? {
        message
    }
}

public enum PhotosPermissionPreflight {
    public static func validate(status: PhotosPermissionStatus) throws {
        guard let message = failureMessage(for: status) else { return }
        throw PhotosPermissionError(status: status, message: message)
    }

    public static func failureMessage(for status: PhotosPermissionStatus) -> String? {
        switch status {
        case .authorized:
            nil
        case .limited:
            """
            Attic needs full Photos access before it can scan your Photos library.
            Limited Photos access is not enough for backup or migration.

            Grant full Photos access to the terminal app you are using, such as iTerm or Terminal:
            System Settings > Privacy & Security > Photos

            Re-run the command after granting access.
            """
        case .denied, .restricted, .notDetermined, .unknown:
            """
            Attic needs full Photos access before it can scan your Photos library.

            Grant full Photos access to the terminal app you are using, such as iTerm or Terminal:
            System Settings > Privacy & Security > Photos

            Re-run the command after granting access.
            """
        }
    }
}

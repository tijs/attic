import AtticCore
@preconcurrency import Photos

enum PhotosPermissionAuthorizer {
    static func preflight() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try PhotosPermissionPreflight.validate(status: PhotosPermissionStatus(status))
    }
}

private extension PhotosPermissionStatus {
    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }
}

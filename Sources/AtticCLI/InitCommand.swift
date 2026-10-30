import ArgumentParser
import AtticCore
import Foundation

struct InitCommand: AsyncParsableCommand {
    @OptionGroup var destination: DestinationOptions

    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Configure an S3 or filesystem backup destination.",
    )

    @Option(name: .long, help: "Initialize an existing empty directory on a local APFS/HFS+ volume.")
    var filesystem: String?

    func run() async throws {
        let profile = try AtticProfile(name: destination.profile)
        let configProvider = FileConfigProvider(directory: profile.directory)
        guard try configProvider.load() == nil else {
            throw ValidationError("This profile is already configured. Select a new --profile for another destination.")
        }
        if let filesystem {
            let target = try FilesystemDestination.initialize(at: URL(fileURLWithPath: filesystem))
            try configProvider.write(AtticConfig(filesystem: target))
            print("Filesystem destination initialized: \(target.path)")
            print("Use the same --profile on backup, status, verify, refresh-metadata and rebuild.")
            return
        }
        print("Attic Setup")
        print("===========")
        print("")

        let endpoint = prompt("S3 endpoint (https://...): ")
        guard endpoint.hasPrefix("https://") else {
            throw ValidationError("Endpoint must start with https://")
        }

        let region = prompt("Region: ")
        let bucket = prompt("Bucket name: ")

        print("")
        print("URL style controls where the bucket appears in each S3 URL:")
        print("  Path-style (recommended; press Enter): https://<endpoint>/<bucket>/<object>")
        print("  Virtual-hosted style:                  https://<bucket>.<endpoint>/<object>")
        print("  Do not include the bucket name in the endpoint when using path-style URLs.")
        print("  For Scaleway, use https://s3.<region>.scw.cloud and choose Y.")
        let pathStyleInput = prompt("Use path-style URLs? (Y/n): ")
        let pathStyle = pathStyleInput.lowercased() != "n"

        let accessKey = prompt("Access key ID: ")
        let secretKey = try promptSecret("Secret access key: ")

        let keychain = AtticConfig.KeychainConfig(
            accessKeyService: destination.profile.map { "attic-\($0)-s3-access-key" } ?? "attic-s3-access-key",
            secretKeyService: destination.profile.map { "attic-\($0)-s3-secret-key" } ?? "attic-s3-secret-key",
        )
        let config = AtticConfig(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            pathStyle: pathStyle,
            keychain: keychain,
        )
        // Save config
        try configProvider.write(config)

        // Save credentials to Keychain
        let keychainStore = SecurityKeychain()
        try keychainStore.store(service: config.keychain.accessKeyService, value: accessKey)
        try keychainStore.store(service: config.keychain.secretKeyService, value: secretKey)

        print("")
        print("Configuration saved.")
        print("Credentials stored in macOS Keychain.")
        print("")
        print("Next steps:")
        print("  attic scan      Scan your Photos library")
        print("  attic status    Check backup progress")
        print("  attic backup    Start backing up")
        print("")
        print("macOS will ask for permission to access Photos and")
        print("Keychain on first run — both are expected and required.")
    }
}

// MARK: - Interactive prompts

private func prompt(_ message: String) -> String {
    print(message, terminator: "")
    return readLine(strippingNewline: true) ?? ""
}

private struct TerminalEchoError: LocalizedError {
    let errorDescription: String? =
        "Cannot disable terminal echo — refusing to read secret. Run in an interactive terminal."
}

private func promptSecret(_ message: String) throws -> String {
    print(message, terminator: "")

    // Fail closed: if we can't disable echo (e.g. stdin is not a TTY), we
    // won't silently read the secret in plaintext and leak it to the screen
    // or a pipe's tee.
    var oldTermios = termios()
    guard tcgetattr(STDIN_FILENO, &oldTermios) == 0 else {
        print("")
        throw TerminalEchoError()
    }
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &newTermios) == 0 else {
        print("")
        throw TerminalEchoError()
    }

    let value = readLine(strippingNewline: true) ?? ""

    tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
    print("") // newline after hidden input
    return value
}

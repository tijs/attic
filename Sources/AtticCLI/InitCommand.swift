import ArgumentParser
import Foundation
import AtticCore

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Set up Attic with S3 endpoint, bucket, and credentials."
    )

    func run() async throws {
        debugPrint("Attic Setup")
        debugPrint("===========")
        debugPrint("")

        let endpoint = prompt("S3 endpoint (https://...): ")
        guard endpoint.hasPrefix("https://") else {
            throw ValidationError("Endpoint must start with https://")
        }

        let region = prompt("Region: ")
        let bucket = prompt("Bucket name: ")
        let pathStyleInput = prompt("Use path-style URLs? (Y/n): ")
        let pathStyle = pathStyleInput.lowercased() != "n"

        let accessKey = prompt("Access key ID: ")
        let secretKey = promptSecret("Secret access key: ")

        let config = AtticConfig(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            pathStyle: pathStyle
        )
        // Save config
        let configProvider = FileConfigProvider()
        try configProvider.write(config)

        // Save credentials to Keychain
        let keychain = SecurityKeychain()
        try keychain.store(service: config.keychain.accessKeyService, value: accessKey)
        try keychain.store(service: config.keychain.secretKeyService, value: secretKey)

        debugPrint("")
        debugPrint("Configuration saved.")
        debugPrint("Credentials stored in macOS Keychain.")
        debugPrint("")
        debugPrint("Next steps:")
        debugPrint("  attic scan      Scan your Photos library")
        debugPrint("  attic status    Check backup progress")
        debugPrint("  attic backup    Start backing up")
        debugPrint("")
        debugPrint("macOS will ask for permission to access Photos and")
        debugPrint("Keychain on first run — both are expected and required.")
    }
}

// MARK: - Interactive prompts

private func prompt(_ message: String) -> String {
    print(message, terminator: "")
    return readLine(strippingNewline: true) ?? ""
}

private func promptSecret(_ message: String) -> String {
    print(message, terminator: "")

    // Disable echo for secret input
    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

    let value = readLine(strippingNewline: true) ?? ""

    // Restore echo
    tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
    print("") // newline after hidden input
    return value
}

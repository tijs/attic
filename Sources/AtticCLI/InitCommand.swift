import ArgumentParser
import AtticCore
import Foundation

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Set up Attic with S3 endpoint, bucket, and credentials.",
    )

    func run() async throws {
        print("Attic Setup")
        print("===========")
        print("")

        let endpoint = prompt("S3 endpoint (https://...): ")
        guard endpoint.hasPrefix("https://") else {
            throw ValidationError("Endpoint must start with https://")
        }

        let region = prompt("Region: ")
        let bucket = prompt("Bucket name: ")
        let pathStyleInput = prompt("Use path-style URLs? (Y/n): ")
        let pathStyle = pathStyleInput.lowercased() != "n"

        let accessKey = prompt("Access key ID: ")
        let secretKey = try promptSecret("Secret access key: ")

        let config = AtticConfig(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            pathStyle: pathStyle,
        )
        // Save config
        let configProvider = FileConfigProvider()
        try configProvider.write(config)

        // Save credentials to Keychain
        let keychain = SecurityKeychain()
        try keychain.store(service: config.keychain.accessKeyService, value: accessKey)
        try keychain.store(service: config.keychain.secretKeyService, value: secretKey)

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

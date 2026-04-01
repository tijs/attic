import ArgumentParser
import AtticCore

@main
struct AtticCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attic",
        abstract: "Back up iCloud Photos to S3-compatible storage.",
        version: AtticCore.version,
        subcommands: [
            ScanCommand.self,
            StatusCommand.self,
            BackupCommand.self,
            VerifyCommand.self,
            RefreshMetadataCommand.self,
            RebuildCommand.self,
            InitCommand.self,
        ],
    )
}

import ArgumentParser

struct DestinationOptions: ParsableArguments {
    @Option(name: .long, help: "Named backup configuration and independent local state (default: ~/.attic).")
    var profile: String?
}

import AtticCore
import Foundation

struct StatusRenderer {
    let isTTY: Bool

    func render(_ data: DashboardData) {
        if isTTY {
            renderRich(data)
        } else {
            renderPlain(data)
        }
    }

    // MARK: - Rich (ANSI) Output

    private func renderRich(_ data: DashboardData) {
        let bold = "\u{1b}[1m"
        let reset = "\u{1b}[0m"
        let dim = "\u{1b}[2m"

        print("\(bold)Attic v\(data.version)\(reset)")
        print(dim + String(repeating: "\u{2500}", count: 38) + reset)

        // Library section
        print("")
        print("\(bold)Library\(reset)")
        printTwoColumn("Photos", format(data.library.photos), "Videos", format(data.library.videos))
        printTwoColumn("Favorites", format(data.library.favorites), "Edited", format(data.library.edited))

        // Backup section
        if let backup = data.backup {
            print("")
            print("\(bold)Backup\(reset)")
            let bar = progressBar(percentage: backup.percentage, width: 28)
            let pctColor = colorForPercentage(backup.percentage)
            print("  \(bar)  \(pctColor)\(String(format: "%.1f", backup.percentage))%\(reset)")
            print("  Backed up  \(padLeft(format(backup.backedUp), width: 8))  (\(formatBytes(backup.backedUpBytes)))")
            print("  Pending    \(padLeft(format(backup.pending), width: 8))")
        }

        // S3 section
        if let s3 = data.s3 {
            print("")
            print("\(bold)S3\(reset) \(dim)- \(s3.bucket)\(reset)")
            print("  Manifest   \(padLeft(format(s3.manifestEntries), width: 8)) entries")
            if let lastBackup = s3.lastBackup {
                print("  Last backup \(lastBackup)")
            }
        }

        // No config hint
        if data.backup == nil {
            print("")
            print("\(dim)Run 'attic init' to configure S3 backup.\(reset)")
        }

        // Types section
        if !data.types.isEmpty {
            print("")
            let typeParts = data.types.map { "\($0.uti) \(Int(round($0.percentage)))%" }
            print("\(bold)Types:\(reset) \(typeParts.joined(separator: " \(dim)-\(reset) "))")
        }
    }

    // MARK: - Plain Text Output

    private func renderPlain(_ data: DashboardData) {
        print("Attic v\(data.version)")
        print(String(repeating: "-", count: 38))

        print("")
        print("Library")
        print("  Photos:      \(format(data.library.photos))")
        print("  Videos:      \(format(data.library.videos))")
        print("  Favorites:   \(format(data.library.favorites))")
        print("  Edited:      \(format(data.library.edited))")

        if let backup = data.backup {
            print("")
            print("Backup")
            print("  Progress:    \(String(format: "%.1f", backup.percentage))%")
            print("  Backed up:   \(format(backup.backedUp)) (\(formatBytes(backup.backedUpBytes)))")
            print("  Pending:     \(format(backup.pending))")
        }

        if let s3 = data.s3 {
            print("")
            print("S3 - \(s3.bucket)")
            print("  Manifest:    \(format(s3.manifestEntries)) entries")
            if let lastBackup = s3.lastBackup {
                print("  Last backup: \(lastBackup)")
            }
        }

        if data.backup == nil {
            print("")
            print("Run 'attic init' to configure S3 backup.")
        }

        if !data.types.isEmpty {
            let typeParts = data.types.map { "\($0.uti) \(Int(round($0.percentage)))%" }
            print("")
            print("Types: \(typeParts.joined(separator: " - "))")
        }
    }

    // MARK: - Helpers

    private func progressBar(percentage: Double, width: Int) -> String {
        let filled = Int(Double(width) * min(percentage, 100) / 100)
        let empty = width - filled
        return "[\(String(repeating: "#", count: filled))\(String(repeating: "-", count: empty))]"
    }

    private func colorForPercentage(_ pct: Double) -> String {
        if pct >= 80 { return "\u{1b}[32m" } // green
        if pct >= 40 { return "\u{1b}[33m" } // yellow
        return "\u{1b}[31m" // red
    }

    private func printTwoColumn(_ label1: String, _ value1: String, _ label2: String, _ value2: String) {
        let col1 = "  \(label1.padding(toLength: 10, withPad: " ", startingAt: 0)) \(padLeft(value1, width: 6))"
        let col2 = "  \(label2.padding(toLength: 10, withPad: " ", startingAt: 0)) \(padLeft(value2, width: 6))"
        print("\(col1)\(col2)")
    }

    private func padLeft(_ string: String, width: Int) -> String {
        let padding = max(0, width - string.count)
        return String(repeating: " ", count: padding) + string
    }
}

// MARK: - Number Formatting

private func format(_ number: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
}

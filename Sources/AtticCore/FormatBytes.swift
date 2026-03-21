import Foundation

/// Format a byte count as a human-readable string.
public func formatBytes(_ bytes: Int) -> String {
    if bytes == 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    let index = min(Int(log(Double(bytes)) / log(1024)), units.count - 1)
    let value = Double(bytes) / pow(1024, Double(index))
    return String(format: "%.1f %@", value, units[index])
}

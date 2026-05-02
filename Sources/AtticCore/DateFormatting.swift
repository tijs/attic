import Foundation

/// Format a date as ISO 8601. Uses the value-type `Date.ISO8601FormatStyle`
/// instead of `ISO8601DateFormatter` (an NSObject subclass that is not
/// thread-safe when shared and can cause malloc zone issues when many
/// instances are created/destroyed concurrently).
func formatISO8601(_ date: Date) -> String {
    date.formatted(.iso8601)
}

/// Parse an ISO 8601 timestamp produced by ``formatISO8601(_:)``. Returns
/// nil for malformed input.
func parseISO8601(_ string: String) -> Date? {
    try? Date(string, strategy: .iso8601)
}

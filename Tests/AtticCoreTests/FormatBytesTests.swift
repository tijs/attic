import Testing
@testable import AtticCore

@Suite("FormatBytes")
struct FormatBytesTests {
    @Test func zero() {
        #expect(formatBytes(0) == "0 B")
    }

    @Test func bytes() {
        #expect(formatBytes(500) == "500.0 B")
    }

    @Test func kilobytes() {
        #expect(formatBytes(1024) == "1.0 KB")
        #expect(formatBytes(1536) == "1.5 KB")
    }

    @Test func megabytes() {
        #expect(formatBytes(1_048_576) == "1.0 MB")
        #expect(formatBytes(2_500_000) == "2.4 MB")
    }

    @Test func gigabytes() {
        #expect(formatBytes(1_073_741_824) == "1.0 GB")
    }
}

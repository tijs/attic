import AtticCore
import Darwin
import Foundation

/// Uses waitpid directly: Foundation's run-loop-based waitUntilExit can hang
/// when a timed-out AppleScript is killed from an async CLI operation.
enum RestoreProcess {
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: Double,
    ) async throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw failure("create output pipe") }
        defer { close(descriptors[0]) }
        let processID: pid_t
        do {
            guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
                throw failure("configure output pipe")
            }
            processID = try spawn(executable, arguments: arguments, descriptors: descriptors)
        } catch {
            close(descriptors[1])
            throw error
        }
        close(descriptors[1])

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var reaped = false
        do {
            while true {
                try Task.checkCancellation()
                try drain(descriptors[0], into: &output)
                var status: Int32 = 0
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID {
                    reaped = true
                    try drain(descriptors[0], into: &output)
                    guard let string = String(data: output, encoding: .utf8) else {
                        throw RestoreError.invalid("Invalid import subprocess response encoding")
                    }
                    let signal = status & 0x7F
                    return (signal == 0 ? (status >> 8) & 0xFF : signal, string)
                }
                guard result == 0 || errno == EINTR else { throw failure("read subprocess status") }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw RestoreError.invalid("Import subprocess timed out")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            // The isolated process group also catches descendants holding the pipe.
            if !reaped {
                kill(-processID, SIGKILL)
                await reap(processID)
            }
            throw error
        }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) throws {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= 64 * 1024 else {
                    throw RestoreError.invalid("Import subprocess output exceeded its limit")
                }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 || errno == EAGAIN {
                return
            } else if errno != EINTR {
                throw failure("read subprocess output")
            }
        }
    }

    private static func spawn(_ executable: String, arguments: [String], descriptors: [Int32]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw failure("initialize subprocess files") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw failure("initialize subprocess attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        let results = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
        ]
        guard results.allSatisfy({ $0 == 0 }) else { throw failure("configure subprocess") }
        var processID: pid_t = 0
        let result = withCStrings([executable] + arguments) { argumentPointers in
            withCStrings(ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }) { environment in
                posix_spawn(&processID, executable, &actions, &attributes, argumentPointers, environment)
            }
        }
        guard result == 0 else {
            throw RestoreError.invalid("Cannot launch import subprocess: \(String(cString: strerror(result)))")
        }
        return processID
    }

    private static func withCStrings<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result,
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    private static func reap(_ processID: pid_t) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(processID, &status, 0) == -1, errno == EINTR {}
                continuation.resume()
            }
        }
    }

    private static func failure(_ operation: String) -> RestoreError {
        .invalid("Cannot \(operation): \(String(cString: strerror(errno)))")
    }
}

import Foundation
import Testing

struct TerminalRendererPTYTests {
    // The bounded Python PTY harness is intentionally kept next to its assertions.
    // swiftlint:disable:next function_body_length
    @Test func realPTYSmokePreservesFramingWidthSanitizationAndTerminalModes() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AtticCLI")
            .path
        let script = """
        import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time, unicodedata

        def set_size(fd, columns):
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))

        def cell_width(text):
            width = 0
            for character in text:
                if unicodedata.combining(character) or unicodedata.category(character) == "Cf":
                    continue
                code = ord(character)
                if unicodedata.east_asian_width(character) in ("W", "F") or 0x1F300 <= code <= 0x1FAFF:
                    width += 2
                elif code >= 0x20 and not 0x7F <= code <= 0x9F:
                    width += 1
            return width

        master, slave = pty.openpty()
        set_size(slave, 40)
        before_modes = termios.tcgetattr(slave)[3] & (termios.ECHO | termios.ICANON)
        env = dict(os.environ, ATTIC_TEST_RENDERER_SMOKE="1")
        process = subprocess.Popen(
            [sys.argv[1], "backup"], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
            env=env, close_fds=True)
        stdout = b""
        stderr = b""
        before_resize = b""
        resized = False
        deadline = time.time() + 8
        while time.time() < deadline and process.poll() is None:
            ready, _, _ = select.select([master, process.stderr], [], [], 0.1)
            for stream in ready:
                chunk = os.read(stream.fileno() if hasattr(stream, "fileno") else stream, 4096)
                if stream == process.stderr:
                    stderr += chunk
                else:
                    stdout += chunk
            if not resized and b"ATTIC_TEST_RENDERER_RESIZE_READY" in stderr:
                before_resize = stdout
                set_size(slave, 14)
                resized = True
        if process.poll() is None:
            process.kill()
            raise SystemExit("PTY renderer smoke timed out")
        process.wait(timeout=2)
        while True:
            ready, _, _ = select.select([master], [], [], 0)
            if not ready:
                break
            try:
                stdout += os.read(master, 4096)
            except OSError:
                break
        stderr += process.stderr.read()
        after_modes = termios.tcgetattr(slave)[3] & (termios.ECHO | termios.ICANON)
        os.close(master)
        os.close(slave)

        if not resized or b"ATTIC_TEST_RENDERER_COMPLETED" not in stderr:
            raise SystemExit("missing renderer smoke marker: " + repr(stderr))
        if before_modes != after_modes:
            raise SystemExit("terminal modes changed")
        if stdout.count(b"\\x1b[") < 5:
            raise SystemExit("expected ANSI redraw framing")
        if b"\\x1b[999A" in stdout or b"owned-title" in stdout or b"device-payload" in stdout:
            raise SystemExit("untrusted terminal controls reached PTY: " + repr(stdout))

        ansi = re.compile(rb"\\x1b\\[[0-9;?]*[ -/]*[@-~]")
        def assert_rows_fit(chunk, columns):
            plain = ansi.sub(b"", chunk).decode("utf-8", "strict")
            for row in plain.replace("\\r", "").split("\\n"):
                if row and cell_width(row) > columns:
                    raise SystemExit("row exceeded %d cells: %r" % (columns, row))
        assert_rows_fit(before_resize, 40)
        assert_rows_fit(stdout[len(before_resize):], 14)
        print("ATTIC_PTY_TEST_COMPLETED", stdout.count(b"\\x1b["), before_modes, after_modes)
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, executable]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let transcript = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8,
        ) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: transcript))
        #expect(transcript.contains("ATTIC_PTY_TEST_COMPLETED"))
    }

    // The PTY subprocess proves cancellation unwinds through TerminalRenderer.finish().
    // swiftlint:disable:next function_body_length
    @Test func realPTYSignalCancellationPreservesTerminalModesAndCursorSafety() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/AtticCLI")
            .path
        let script = """
        import os, pty, select, signal, subprocess, sys, termios, time

        master, slave = pty.openpty()
        before_modes = termios.tcgetattr(slave)[3] & (termios.ECHO | termios.ICANON)
        env = dict(os.environ, ATTIC_TEST_RENDERER_SMOKE="1")
        process = subprocess.Popen(
            [sys.argv[1], "backup"], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
            env=env, close_fds=True)
        stdout = b""
        stderr = b""
        marker = b"ATTIC_TEST_RENDERER_RESIZE_READY"
        deadline = time.time() + 5
        while marker not in stderr and time.time() < deadline and process.poll() is None:
            ready, _, _ = select.select([master, process.stderr], [], [], 0.1)
            for stream in ready:
                chunk = os.read(stream.fileno() if hasattr(stream, "fileno") else stream, 4096)
                if stream == process.stderr:
                    stderr += chunk
                else:
                    stdout += chunk
        if marker not in stderr:
            process.kill()
            raise SystemExit("renderer did not become ready: " + repr(stderr))
        os.kill(process.pid, signal.SIGTERM)
        deadline = time.time() + 5
        while process.poll() is None and time.time() < deadline:
            ready, _, _ = select.select([master, process.stderr], [], [], 0.1)
            for stream in ready:
                try:
                    chunk = os.read(stream.fileno() if hasattr(stream, "fileno") else stream, 4096)
                except OSError:
                    chunk = b""
                if stream == process.stderr:
                    stderr += chunk
                else:
                    stdout += chunk
        if process.poll() is None:
            process.kill()
            raise SystemExit("PTY backup did not stop after SIGTERM")
        process.wait(timeout=2)
        stderr += process.stderr.read()
        while True:
            ready, _, _ = select.select([master], [], [], 0)
            if not ready:
                break
            try:
                stdout += os.read(master, 4096)
            except OSError:
                break
        after_modes = termios.tcgetattr(slave)[3] & (termios.ECHO | termios.ICANON)
        os.close(master)
        os.close(slave)

        if process.returncode == 0:
            raise SystemExit("PTY signal cancellation unexpectedly exited zero")
        if before_modes != after_modes:
            raise SystemExit("terminal modes changed across signal cancellation")
        if not stdout.endswith(b"\\r\\n"):
            raise SystemExit("cursor was not left below the final complete frame: " + repr(stdout[-80:]))
        if b"\\x1b[999A" in stdout or b"owned-title" in stdout:
            raise SystemExit("untrusted controls reached signal-cancelled PTY")
        print("ATTIC_PTY_SIGNAL_TEST_COMPLETED", process.returncode, before_modes, after_modes)
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, executable]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let transcript = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8,
        ) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: transcript))
        #expect(transcript.contains("ATTIC_PTY_SIGNAL_TEST_COMPLETED"))
    }
}

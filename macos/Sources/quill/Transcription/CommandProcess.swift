import Darwin
import Foundation

enum CommandProcess {
    private static let maxStdoutBytes: UInt64 = 16 * 1024 * 1024
    private static let maxStderrBytes: UInt64 = 4 * 1024 * 1024

    static func executable(at path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw TranscriptionCommandError("command executable must be an absolute path (or begin with ~/)")
        }
        return URL(fileURLWithPath: expanded)
    }

    static func checkExecutable(_ executable: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &directory),
            !directory.boolValue, FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw TranscriptionCommandError("command executable not found or not executable: \(executable.path)") }
    }

    /// File-backed output avoids pipe-buffer deadlocks on either stdout or
    /// stderr. The exit deadline also covers commands that never produce output.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        try checkExecutable(executable)
        return try withTemporaryDirectory { directory in
            let stdoutURL = directory.appendingPathComponent("stdout")
            let stderrURL = directory.appendingPathComponent("stderr")
            try Data().write(to: stdoutURL)
            try Data().write(to: stderrURL)
            var processID: pid_t = 0
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                throw TranscriptionCommandError("could not initialize command process")
            }
            guard posix_spawnattr_init(&attributes) == 0 else {
                posix_spawn_file_actions_destroy(&actions)
                throw TranscriptionCommandError("could not initialize command process")
            }
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            let actionError = posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
            ) | posix_spawn_file_actions_addopen(
                &actions, STDOUT_FILENO, stdoutURL.path, O_WRONLY | O_TRUNC, 0o600
            ) | posix_spawn_file_actions_addopen(
                &actions, STDERR_FILENO, stderrURL.path, O_WRONLY | O_TRUNC, 0o600
            )
            guard actionError == 0,
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
                posix_spawnattr_setpgroup(&attributes, 0) == 0
            else { throw TranscriptionCommandError("could not configure command process isolation") }

            let strings = [executable.path] + arguments
            var argv: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
            guard argv.allSatisfy({ $0 != nil }) else {
                argv.compactMap { $0 }.forEach { free($0) }
                throw TranscriptionCommandError("could not prepare command arguments")
            }
            argv.append(nil)
            defer { argv.compactMap { $0 }.forEach { free($0) } }
            let spawnError = argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID, executable.path, &actions, &attributes,
                    buffer.baseAddress!, environ
                )
            }
            guard spawnError == 0 else {
                throw TranscriptionCommandError(
                    "could not start \(executable.lastPathComponent): \(String(cString: strerror(spawnError)))"
                )
            }

            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeout, 0) * 1_000_000_000)
            var status: Int32 = 0
            var exited = false
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if try waitForExit(processID, status: &status) {
                    exited = true
                    break
                }
                let sizes: (stdout: UInt64, stderr: UInt64)
                do {
                    sizes = try outputSizes(stdoutURL: stdoutURL, stderrURL: stderrURL)
                } catch {
                    terminate(processID, status: &status)
                    throw error
                }
                if let limit = outputLimitExceeded(sizes) {
                    terminate(processID, status: &status)
                    let detail = try tail(of: stderrURL)
                    let fallback = detail.isEmpty ? try tail(of: stdoutURL) : detail
                    throw TranscriptionCommandError(
                        "\(executable.lastPathComponent) \(limit)"
                            + (fallback.isEmpty ? "" : ": \(fallback)")
                    )
                }
                usleep(5_000)
            }
            if !exited, try waitForExit(processID, status: &status) { exited = true }
            if !exited {
                terminate(processID, status: &status)
                throw TranscriptionCommandError("\(executable.lastPathComponent) timed out after \(timeout) seconds")
            }
            if kill(-processID, 0) == 0 { terminate(processID, status: &status) }
            let sizes = try outputSizes(stdoutURL: stdoutURL, stderrURL: stderrURL)
            if let limit = outputLimitExceeded(sizes) {
                let detail = try tail(of: stderrURL)
                let fallback = detail.isEmpty ? try tail(of: stdoutURL) : detail
                throw TranscriptionCommandError(
                    "\(executable.lastPathComponent) \(limit)" + (fallback.isEmpty ? "" : ": \(fallback)")
                )
            }
            let signal = status & 0x7f
            let exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            guard exitStatus == 0 else {
                let detail = try tail(of: stderrURL)
                let fallback = detail.isEmpty ? try tail(of: stdoutURL) : detail
                throw TranscriptionCommandError(
                    "\(executable.lastPathComponent) failed (status \(exitStatus))"
                        + (fallback.isEmpty ? "" : ": \(fallback)")
                )
            }
            let reader = try FileHandle(forReadingFrom: stdoutURL)
            defer { try? reader.close() }
            return try reader.read(upToCount: Int(maxStdoutBytes) + 1) ?? Data()
        }
    }

    private static func outputSizes(stdoutURL: URL, stderrURL: URL) throws -> (stdout: UInt64, stderr: UInt64) {
        let stdout = try FileManager.default.attributesOfItem(atPath: stdoutURL.path)[.size] as? NSNumber
        let stderr = try FileManager.default.attributesOfItem(atPath: stderrURL.path)[.size] as? NSNumber
        guard let stdout, let stderr else {
            throw TranscriptionCommandError("could not inspect command output files")
        }
        return (stdout.uint64Value, stderr.uint64Value)
    }

    private static func outputLimitExceeded(_ sizes: (stdout: UInt64, stderr: UInt64)) -> String? {
        if sizes.stdout > maxStdoutBytes { return "stdout exceeds 16 MiB output limit" }
        if sizes.stderr > maxStderrBytes { return "stderr exceeds 4 MiB output limit" }
        return nil
    }

    private static func terminate(_ processID: pid_t, status: inout Int32) {
        kill(-processID, SIGTERM)
        let graceDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < graceDeadline {
            if (try? waitForExit(processID, status: &status)) == true { break }
            usleep(10_000)
        }
        kill(-processID, SIGKILL)
        while (try? waitForExit(processID, status: &status)) == false { usleep(10_000) }
    }

    private static func waitForExit(_ processID: pid_t, status: inout Int32) throws -> Bool {
        while true {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            if errno == ECHILD { return true }
            throw TranscriptionCommandError("could not wait for command process: \(String(cString: strerror(errno)))")
        }
    }

    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private static func tail(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: size > 4096 ? size - 4096 : 0)
        return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

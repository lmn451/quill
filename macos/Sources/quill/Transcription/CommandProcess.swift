import Darwin
import Foundation

enum CommandProcess {
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
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }

            let task = Process()
            let exited = DispatchSemaphore(value: 0)
            task.executableURL = executable
            task.arguments = arguments
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = stdout
            task.standardError = stderr
            task.terminationHandler = { _ in exited.signal() }
            do {
                try task.run()
            } catch {
                throw TranscriptionCommandError("could not start \(executable.lastPathComponent): \(error)")
            }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                task.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(task.processIdentifier, SIGKILL)
                    task.waitUntilExit()
                }
                throw TranscriptionCommandError("\(executable.lastPathComponent) timed out after \(timeout) seconds")
            }
            guard task.terminationStatus == 0 else {
                let detail = try tail(of: stderrURL)
                let fallback = detail.isEmpty ? try tail(of: stdoutURL) : detail
                throw TranscriptionCommandError(
                    "\(executable.lastPathComponent) failed (status \(task.terminationStatus))"
                        + (fallback.isEmpty ? "" : ": \(fallback)")
                )
            }
            let reader = try FileHandle(forReadingFrom: stdoutURL)
            defer { try? reader.close() }
            let maxOutput = 16 * 1024 * 1024
            let data = try reader.read(upToCount: maxOutput + 1) ?? Data()
            guard data.count <= maxOutput else {
                throw TranscriptionCommandError("command JSON output exceeds 16 MiB per chunk")
            }
            return data
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

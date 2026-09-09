import Foundation
import Darwin

/// lsof's local manual defines -p as PID selection and -F fields as p=PID,
/// f=file descriptor, n=file name/comment/address. NUL delimiters preserve paths.
/// Only absolute database-file paths are account evidence; comments and sockets
/// are never treated as a login identity.
enum WeChatAccountEvidence {
    enum Verdict: Equatable {
        case verified
        case unverified
        case mismatch
    }

    struct Capture: Sendable {
        let data: Data
        let succeeded: Bool
        let timedOut: Bool
        let exceededLimit: Bool
    }

    static func evaluate(_ capture: Capture, processID: Int32, expectedRoot: String) -> Verdict {
        guard expectedRoot.hasPrefix("/") else { return .unverified }
        guard let roots = observedRoots(capture, processID: processID), roots.count == 1,
              let observedRoot = roots.first else { return .unverified }
        return observedRoot == canonicalRoot(expectedRoot) ? .verified : .mismatch
    }

    /// Parses only the NUL-delimited lsof names for one PID. A nil result
    /// means the capture was incomplete or structurally unsafe; an array with
    /// multiple roots is deliberately retained so callers can refuse to guess.
    static func observedRoots(_ capture: Capture, processID: Int32) -> [String]? {
        guard capture.succeeded, !capture.timedOut, !capture.exceededLimit,
              processID > 0,
              capture.data.last == 0 || capture.data.last == 10 else { return nil }
        var observedPID: Int32?
        var roots: Set<String> = []
        var descriptorSeen = false
        var regularFile = false
        for raw in capture.data.split(separator: 0) {
            let field = String(decoding: raw, as: UTF8.self).drop(while: { $0 == "\n" || $0 == "\r" })
            guard let kind = field.first else { continue }
            let value = String(field.dropFirst())
            switch kind {
            case "p":
                guard let pid = Int32(value), pid == processID else { return nil }
                observedPID = pid
                descriptorSeen = false
                regularFile = false
            case "f":
                guard observedPID == processID else { return nil }
                descriptorSeen = true
                regularFile = false
            case "t":
                regularFile = value == "REG"
            case "n":
                guard observedPID == processID, descriptorSeen else { return nil }
                if regularFile, let root = databaseRoot(openPath: value) { roots.insert(root) }
            default:
                break
            }
        }
        guard observedPID == processID, !roots.isEmpty else { return nil }
        return roots.sorted()
    }

    static func processMatches(expectedPID: Int32, expectedLaunch: Date, actualPID: Int32?, actualLaunch: Date?, terminated: Bool) -> Bool {
        !terminated && expectedPID > 0 && actualPID == expectedPID && actualLaunch == expectedLaunch
    }

    static func databaseRoot(openPath: String) -> String? {
        guard openPath.hasPrefix("/"), !openPath.contains("\n"), !openPath.contains("\r"),
              openPath.hasSuffix(".db") || openPath.hasSuffix(".db-wal") || openPath.hasSuffix(".db-shm") else { return nil }
        let components = URL(fileURLWithPath: openPath).standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "db_storage"), index > 1, index < components.count - 1 else { return nil }
        return canonicalRoot(NSString.path(withComponents: Array(components.prefix(index + 1))))
    }

    static func canonicalRoot(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func inspect(processID: Int32, expectedRoot: String) async -> Verdict {
        let capture = await Task.detached(priority: .userInitiated) { captureOpenFiles(processID: processID) }.value
        guard !Task.isCancelled else { return .unverified }
        return evaluate(capture, processID: processID, expectedRoot: expectedRoot)
    }

    /// Captures WeChat's open database paths off the main actor. No file
    /// contents are opened; callers must validate the process identity again
    /// after this asynchronous probe returns.
    static func inspectRoots(processID: Int32) async -> [String] {
        let capture = await Task.detached(priority: .userInitiated) { captureOpenFiles(processID: processID) }.value
        guard !Task.isCancelled else { return [] }
        return observedRoots(capture, processID: processID) ?? []
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var overflow = false
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            guard data.count + chunk.count <= 1_048_576 else { overflow = true; return }
            if !overflow { data.append(chunk) }
        }
        func result(succeeded: Bool, timedOut: Bool) -> Capture {
            lock.lock(); defer { lock.unlock() }
            return Capture(data: data, succeeded: succeeded, timedOut: timedOut, exceededLimit: overflow)
        }
    }

    /// Never run on the main thread. No shell, no auth files, no file contents;
    /// the child only lists the specified WeChat process's open-file names.
    private static func captureOpenFiles(processID: Int32) -> Capture {
        guard processID > 0 else { return Capture(data: Data(), succeeded: false, timedOut: false, exceededLimit: false) }
        let process = Process()
        let pipe = Pipe()
        let output = OutputBuffer()
        let eof = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-F0pftn", "-p", String(processID)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                output.append(chunk)
            }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
        do { try process.run() } catch { return output.result(succeeded: false, timedOut: false) }
        let deadline = DispatchTime.now() + 2
        guard exited.wait(timeout: deadline) == .success, eof.wait(timeout: deadline) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 0.2)
            return output.result(succeeded: false, timedOut: true)
        }
        return output.result(succeeded: process.terminationStatus == 0, timedOut: false)
    }
}

import Foundation
import Darwin

/// Only fixed, read-only invocations may be added here. Arguments never contain user input.
public enum ReadOnlyNetworkCommand: Sendable {
    case routeGetDefault
    case netstatIPv4
    case netstatIPv6
    case scutilDNS
    case scutilProxy

    var executable: String {
        switch self {
        case .routeGetDefault: return "/sbin/route"
        case .netstatIPv4, .netstatIPv6: return "/usr/sbin/netstat"
        case .scutilDNS, .scutilProxy: return "/usr/sbin/scutil"
        }
    }

    var arguments: [String] {
        switch self {
        case .routeGetDefault: return ["-n", "get", "default"]
        case .netstatIPv4: return ["-rn", "-f", "inet"]
        case .netstatIPv6: return ["-rn", "-f", "inet6"]
        case .scutilDNS: return ["--dns"]
        case .scutilProxy: return ["--proxy"]
        }
    }
}

/// Sensitive, ephemeral command output. Never pass this value to Logger, a session, or export.
public struct ProcessOutput: CustomStringConvertible, CustomDebugStringConvertible {
    public let stdout: String
    public let stderr: String
    public let exitStatus: Int32

    init(stdout: String, stderr: String, exitStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    public var description: String { "<redacted process output>" }
    public var debugDescription: String { description }
}

public enum ProcessRunError: Error, Equatable, Sendable {
    case launchFailed
    case permissionDenied
    case nonZeroExit(Int32)
    case timedOut
    case cancelled
    case outputTooLarge
    case invalidEncoding

    /// Stable and safe for structured evidence; never embeds raw command output.
    public var code: String {
        switch self {
        case .launchFailed: return "process.launch_failed"
        case .permissionDenied: return "process.permission_denied"
        case .nonZeroExit: return "process.nonzero_exit"
        case .timedOut: return "process.timeout"
        case .cancelled: return "process.cancelled"
        case .outputTooLarge: return "process.output_too_large"
        case .invalidEncoding: return "process.invalid_encoding"
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ command: ReadOnlyNetworkCommand) async throws -> ProcessOutput
}

public struct SystemProcessRunner: ProcessRunning {
    public let timeout: TimeInterval
    public let outputLimit: Int

    public init(timeout: TimeInterval = 3, outputLimit: Int = 65_536) {
        self.timeout = max(0.01, timeout)
        self.outputLimit = max(1, outputLimit)
    }

    public func run(_ command: ReadOnlyNetworkCommand) async throws -> ProcessOutput {
        let execution = ProcessExecution(command: command, timeout: timeout, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.abort(.cancelled)
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let command: ReadOnlyNetworkCommand
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let lock = NSLock()
    private var process: Process?
    private var abortReason: ProcessRunError?
    private var timer: DispatchSourceTimer?
    private var stdout = Data()
    private var stderr = Data()

    init(command: ReadOnlyNetworkCommand, timeout: TimeInterval, outputLimit: Int) {
        self.command = command
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func start(_ continuation: CheckedContinuation<ProcessOutput, Error>) {
        lock.lock()
        if let abortReason {
            lock.unlock()
            continuation.resume(throwing: abortReason)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command.executable)
        task.arguments = command.arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice
        process = task
        lock.unlock()

        do {
            try task.run()
        } catch {
            lock.lock()
            let reason = abortReason ?? ((error as NSError).code == Int(EACCES) ? .permissionDenied : .launchFailed)
            lock.unlock()
            continuation.resume(throwing: reason)
            return
        }

        // A cancellation can race process launch. It must still stop the launched process.
        lock.lock()
        let pendingAbort = abortReason
        lock.unlock()
        if pendingAbort != nil { terminate(task) }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.abort(.timedOut) }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            self.read(outPipe.fileHandleForReading, intoStdout: true)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            self.read(errPipe.fileHandleForReading, intoStdout: false)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            task.waitUntilExit()
            group.leave()
        }
        group.notify(queue: .global(qos: .utility)) {
            self.lock.lock()
            self.timer?.cancel()
            self.timer = nil
            let reason = self.abortReason
            let out = self.stdout
            let err = self.stderr
            self.lock.unlock()
            if let reason {
                continuation.resume(throwing: reason)
            } else if task.terminationStatus != 0 {
                continuation.resume(throwing: ProcessRunError.nonZeroExit(task.terminationStatus))
            } else if let stdout = String(data: out, encoding: .utf8),
                      let stderr = String(data: err, encoding: .utf8) {
                continuation.resume(returning: ProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    exitStatus: task.terminationStatus
                ))
            } else {
                continuation.resume(throwing: ProcessRunError.invalidEncoding)
            }
        }
    }

    func abort(_ reason: ProcessRunError) {
        lock.lock()
        if abortReason == nil { abortReason = reason }
        let task = process
        lock.unlock()
        if let task { terminate(task) }
    }

    private func terminate(_ task: Process) {
        if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
    }

    private func read(_ handle: FileHandle, intoStdout: Bool) {
        while true {
            let chunk = handle.readData(ofLength: 4_096)
            if chunk.isEmpty { return }
            lock.lock()
            let currentCount = intoStdout ? stdout.count : stderr.count
            let exceeded = chunk.count > outputLimit - currentCount
            if !exceeded {
                if intoStdout { stdout.append(chunk) } else { stderr.append(chunk) }
            }
            lock.unlock()
            if exceeded {
                abort(.outputTooLarge)
                return
            }
        }
    }
}

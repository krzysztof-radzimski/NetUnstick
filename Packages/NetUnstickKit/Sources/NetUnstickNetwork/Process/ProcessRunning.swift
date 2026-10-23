import Foundation
import Darwin

/// Only fixed, read-only invocations may be added here. Arguments never contain user input.
public enum ReadOnlyNetworkCommand: Sendable {
    case routeGetDefault
    case netstatIPv4
    case netstatIPv6
    case scutilDNS
    case scutilProxy
    /// Configured VPN services and their connection status; works from a root daemon as well.
    case scutilNetworkConnections

    var executable: String {
        switch self {
        case .routeGetDefault: return "/sbin/route"
        case .netstatIPv4, .netstatIPv6: return "/usr/sbin/netstat"
        case .scutilDNS, .scutilProxy, .scutilNetworkConnections: return "/usr/sbin/scutil"
        }
    }

    var arguments: [String] {
        switch self {
        case .routeGetDefault: return ["-n", "get", "default"]
        case .netstatIPv4: return ["-rn", "-f", "inet"]
        case .netstatIPv6: return ["-rn", "-f", "inet6"]
        case .scutilDNS: return ["--dns"]
        case .scutilProxy: return ["--proxy"]
        case .scutilNetworkConnections: return ["--nc", "list"]
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
        try await BoundedProcess.run(executable: command.executable, arguments: command.arguments,
                                     timeout: timeout, outputLimit: outputLimit)
    }
}

/// Launches one fixed executable with an argument array, a deadline and an output limit.
///
/// The child's exit is observed with a kqueue process source and reaped with `waitpid`,
/// never with `Process.waitUntilExit()`: that call waits on a run-loop wake-up that can
/// be lost when the child finishes before the waiting thread is scheduled, which leaves
/// the caller blocked forever even though the child is gone.
public enum BoundedProcess {
    public static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, outputLimit: Int) async throws -> ProcessOutput {
        let execution = ProcessExecution(executable: executable, arguments: arguments, environment: environment,
                                         timeout: max(0.01, timeout), outputLimit: max(1, outputLimit))
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
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let lock = NSLock()
    private var process: Process?
    private var pid: pid_t = 0
    private var abortReason: ProcessRunError?
    private var timer: DispatchSourceTimer?
    private var exitWatcher: DispatchSourceProcess?
    private var stdout = Data()
    private var stderr = Data()
    private var exitStatus: Int32?
    private var readersDone = 0
    private var continuation: CheckedContinuation<ProcessOutput, Error>?

    init(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval, outputLimit: Int) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
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
        self.continuation = continuation
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let environment { task.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice
        // Foundation's own reaping is the preferred path; the handler only nudges the reaper below.
        task.terminationHandler = { [weak self] _ in self?.reap(attempt: 0) }
        process = task
        lock.unlock()

        do {
            try task.run()
        } catch {
            lock.lock()
            let reason = abortReason ?? ((error as NSError).code == Int(EACCES) ? .permissionDenied : .launchFailed)
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: reason)
            return
        }
        let identifier = task.processIdentifier
        lock.lock()
        pid = identifier
        let pendingAbort = abortReason
        lock.unlock()
        // A cancellation can race process launch. It must still stop the launched process.
        if pendingAbort != nil { terminate() }

        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.abort(.timedOut) }
        lock.lock()
        timer = deadline
        lock.unlock()
        deadline.resume()

        DispatchQueue.global(qos: .utility).async { self.read(outPipe.fileHandleForReading, intoStdout: true) }
        DispatchQueue.global(qos: .utility).async { self.read(errPipe.fileHandleForReading, intoStdout: false) }

        let watcher = DispatchSource.makeProcessSource(identifier: identifier, eventMask: .exit, queue: .global(qos: .utility))
        watcher.setEventHandler { [weak self] in self?.reap(attempt: 0) }
        lock.lock()
        exitWatcher = watcher
        lock.unlock()
        watcher.resume()
        // The child may already be gone; a source registered afterwards never fires, so probe once now.
        reap(attempt: 0)
    }

    func abort(_ reason: ProcessRunError) {
        lock.lock()
        if abortReason == nil { abortReason = reason }
        lock.unlock()
        terminate()
        // Output readers may hang on a pipe inherited by a grandchild; do not wait for them after an abort.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish(force: true) }
    }

    private func terminate() {
        lock.lock()
        let identifier = pid
        let alive = exitStatus == nil
        lock.unlock()
        if identifier > 0 && alive { _ = Darwin.kill(identifier, SIGKILL) }
    }

    /// Records the exit status exactly once.
    ///
    /// `waitid` with `WNOWAIT` tells whether the child has exited without consuming its
    /// status, so Foundation keeps a short grace period to reap the child itself and
    /// update the `Process` object. If that notification was lost, the child is reaped
    /// here after the grace period; if Foundation reaped it first, its status is used.
    private func reap(attempt: Int) {
        lock.lock()
        let identifier = pid
        let task = process
        let known = exitStatus != nil
        lock.unlock()
        guard identifier > 0, !known, let task else { return }
        if !task.isRunning { record(task.terminationStatus); return }
        var info = siginfo_t()
        let probe = waitid(P_PID, id_t(identifier), &info, WEXITED | WNOHANG | WNOWAIT)
        if probe == 0 && info.si_pid == 0 { return } // Still running; the exit watcher fires later.
        if probe == -1 && errno == ECHILD {
            // Foundation consumed the status a moment ago and is about to update the object.
            if attempt < 25 { retry(after: 0.02, attempt: attempt + 1) }
            return
        }
        if attempt < 10 { retry(after: 0.02, attempt: attempt + 1); return }
        var status: Int32 = 0
        let reaped = waitpid(identifier, &status, WNOHANG)
        if reaped == identifier {
            let signal = status & 0x7f
            record(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        } else if !task.isRunning {
            record(task.terminationStatus)
        } else if attempt < 25 {
            retry(after: 0.02, attempt: attempt + 1)
        }
    }

    private func retry(after delay: TimeInterval, attempt: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in self?.reap(attempt: attempt) }
    }

    private func record(_ code: Int32) {
        lock.lock()
        if exitStatus == nil { exitStatus = code }
        lock.unlock()
        finish(force: false)
    }

    private func finish(force: Bool) {
        lock.lock()
        guard let pending = continuation else { lock.unlock(); return }
        let ready = exitStatus != nil && readersDone == 2
        guard ready || force else { lock.unlock(); return }
        continuation = nil
        timer?.cancel(); timer = nil
        exitWatcher?.cancel(); exitWatcher = nil
        let reason = abortReason
        let status = exitStatus
        let out = stdout
        let err = stderr
        lock.unlock()
        if let reason {
            pending.resume(throwing: reason)
        } else if let status, status != 0 {
            pending.resume(throwing: ProcessRunError.nonZeroExit(status))
        } else if status == nil {
            pending.resume(throwing: ProcessRunError.timedOut)
        } else if let stdout = String(data: out, encoding: .utf8),
                  let stderr = String(data: err, encoding: .utf8) {
            pending.resume(returning: ProcessOutput(stdout: stdout, stderr: stderr, exitStatus: status ?? 0))
        } else {
            pending.resume(throwing: ProcessRunError.invalidEncoding)
        }
    }

    private func read(_ handle: FileHandle, intoStdout: Bool) {
        while true {
            let chunk = handle.readData(ofLength: 4_096)
            if chunk.isEmpty { break }
            lock.lock()
            let currentCount = intoStdout ? stdout.count : stderr.count
            let exceeded = chunk.count > outputLimit - currentCount
            if !exceeded {
                if intoStdout { stdout.append(chunk) } else { stderr.append(chunk) }
            }
            lock.unlock()
            if exceeded {
                abort(.outputTooLarge)
                break
            }
        }
        try? handle.close()
        lock.lock()
        readersDone += 1
        lock.unlock()
        finish(force: false)
    }
}

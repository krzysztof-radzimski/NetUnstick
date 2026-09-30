import Foundation
import NetUnstickCore

/// Closed outcome codes for the read-only check of this Mac as a file server for other Macs.
public enum FileSharingReason: String, Sendable, CaseIterable {
    case healthy, guestRejected, sharingOff, accountNotEnabledForSMB, noLoginMethod, noSharedFolders, dataIncomplete, cancelled

    public var message: String {
        switch self {
        case .healthy:
            return "Udostępnianie plików przyjmuje połączenia, a Twoje konto może logować się przez SMB."
        case .guestRejected:
            return "Twoje konto może logować się przez SMB, ale serwer odrzuca gości; Finder na drugim komputerze pokaże „Błąd połączenia” do czasu użycia „Połącz jako…” z tym kontem."
        case .noLoginMethod:
            return "Udostępnianie działa, ale serwer odrzuca logowanie gościa, a Twoje konto nie ma zapisanego hasła SMB; żaden komputer nie zaloguje się do folderów tego Maca."
        case .sharingOff:
            return "Udostępnianie plików na tym Macu jest wyłączone; inne komputery nie połączą się z jego dyskami."
        case .accountNotEnabledForSMB:
            return "Udostępnianie działa, ale Twoje konto nie ma zapisanego hasła SMB; logowanie tym kontem z innego Maca jest odrzucane, a bez logowania widać tylko folder dla gości."
        case .noSharedFolders:
            return "Udostępnianie działa, ale żaden folder nie jest udostępniony przez SMB; zalogowani użytkownicy zobaczą tylko swoje katalogi domowe."
        case .dataIncomplete:
            return "Nie udało się odczytać stanu udostępniania plików."
        case .cancelled:
            return "Sprawdzenie zostało anulowane."
        }
    }
}

/// Ephemeral observation. Folder names, paths and account data never leave the probe.
public struct FileSharingObservation: Sendable, Equatable {
    public let smbListening: Bool
    public let accountEnabledForSMB: Bool?
    public let sharedFolderCount: Int?
    public let guestFolderCount: Int?
    /// Whether the server accepted an anonymous (guest) session over loopback; nil when not tested.
    public let guestLoginAccepted: Bool?
    public init(smbListening: Bool, accountEnabledForSMB: Bool?, sharedFolderCount: Int?, guestFolderCount: Int?,
                guestLoginAccepted: Bool? = nil) {
        self.smbListening = smbListening
        self.accountEnabledForSMB = accountEnabledForSMB
        self.sharedFolderCount = sharedFolderCount
        self.guestFolderCount = guestFolderCount
        self.guestLoginAccepted = guestLoginAccepted
    }
}

public protocol FileSharingProbing: Sendable {
    func observe() async -> FileSharingObservation
}

/// Reads three facts without changing anything: whether the SMB server accepts a loopback
/// connection, whether the current account carries an SMB password hash (macOS stores one only
/// after the account is enabled under File Sharing options), and how many share points exist.
/// Command output stays in memory: the account record contains password hashes and the share
/// list contains folder names and paths, so only booleans and counts are derived from it.
public struct SystemFileSharingProbe: FileSharingProbing {
    public static let sharingExecutable = "/usr/sbin/sharing"
    public static let directoryExecutable = "/usr/bin/dscl"
    public static let smbClientExecutable = "/usr/bin/smbutil"
    private let deviceProbe: any DeviceConnectionProbing

    public init(deviceProbe: any DeviceConnectionProbing = SystemDeviceConnectionProbe()) {
        self.deviceProbe = deviceProbe
    }

    public func observe() async -> FileSharingObservation {
        let listening = await deviceProbe.probe(host: "127.0.0.1", port: 445, timeout: .seconds(2)).reason == .reachable
        var accountEnabled: Bool?
        let account = NSUserName()
        if Self.isPlainAccountName(account),
           let output = try? await BoundedProcess.run(executable: Self.directoryExecutable,
                                                      arguments: [".", "-read", "/Users/\(account)", "AuthenticationAuthority"],
                                                      timeout: 3, outputLimit: 65_536) {
            accountEnabled = Self.accountHasSMBPassword(output.stdout)
        }
        var shared: Int?
        var guest: Int?
        if let output = try? await BoundedProcess.run(executable: Self.sharingExecutable, arguments: ["-l"],
                                                      timeout: 3, outputLimit: 262_144) {
            let counts = Self.countSharePoints(output.stdout)
            shared = counts.smbShared
            guest = counts.guest
        }
        var guestLogin: Bool?
        if listening {
            // The same anonymous session Finder on another Mac opens first; only the exit status is read.
            do {
                let output = try await BoundedProcess.run(executable: Self.smbClientExecutable,
                                                          arguments: ["view", "-N", "//127.0.0.1"], timeout: 6, outputLimit: 65_536)
                guestLogin = Self.classifyGuestListing(exitStatus: output.exitStatus)
            } catch ProcessRunError.nonZeroExit(let status) {
                guestLogin = Self.classifyGuestListing(exitStatus: status)
            } catch {
                guestLogin = nil
            }
        }
        return .init(smbListening: listening, accountEnabledForSMB: accountEnabled,
                     sharedFolderCount: shared, guestFolderCount: guest, guestLoginAccepted: guestLogin)
    }

    /// `smbutil view -N` exits 0 after listing shares and 77 (EX_NOPERM) when the server rejects the
    /// anonymous session; any other status says nothing about guest policy.
    public static func classifyGuestListing(exitStatus: Int32) -> Bool? {
        switch exitStatus {
        case 0: return true
        case 77: return false
        default: return nil
        }
    }

    /// The account name becomes one fixed argument; anything outside this alphabet is not queried.
    static func isPlainAccountName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// True when the directory record lists the SMB-NT authority; the hashes themselves are never inspected.
    public static func accountHasSMBPassword(_ directoryOutput: String) -> Bool {
        directoryOutput.contains(";SMB-NT;") || directoryOutput.contains("SMB-NT")
    }

    /// Counts share points whose SMB block is enabled and how many of those allow guests.
    /// Top-level `name:` lines start a share point; indented `smb: {` opens its SMB block.
    public static func countSharePoints(_ output: String) -> (sharePoints: Int, smbShared: Int, guest: Int) {
        var sharePoints = 0
        var smbShared = 0
        var guest = 0
        var currentShared = false
        var currentGuest = false
        var inSharePoint = false
        var inSMBBlock = false
        func flush() {
            guard inSharePoint else { return }
            if currentShared { smbShared += 1; if currentGuest { guest += 1 } }
        }
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("name:") {
                flush()
                sharePoints += 1
                inSharePoint = true; inSMBBlock = false; currentShared = false; currentGuest = false
                continue
            }
            if trimmed.hasPrefix("smb:") { inSMBBlock = true; continue }
            if trimmed.hasPrefix("}") { inSMBBlock = false; continue }
            guard inSMBBlock else { continue }
            if trimmed.hasPrefix("shared:") { currentShared = Self.flag(trimmed) }
            else if trimmed.hasPrefix("guest access:") { currentGuest = Self.flag(trimmed) }
        }
        flush()
        return (sharePoints, smbShared, guest)
    }

    private static func flag(_ line: String) -> Bool {
        line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) == "1" } ?? false
    }
}

/// The readiness check as a structured operation; evidence carries a code and a folder count only.
public struct FileSharingReadinessCheck: DiagnosticCheck {
    public static let checkID = "file_sharing_readiness"
    public let id = FileSharingReadinessCheck.checkID
    public let name = FileSharingReadinessCheck.checkID
    private let probe: any FileSharingProbing

    public init(probe: any FileSharingProbing = SystemFileSharingProbe()) { self.probe = probe }

    public func run(context: OperationContext) async -> OperationResult {
        let start = context.clock.now()
        let reason: FileSharingReason
        var count = 0
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            reason = .cancelled
        } else {
            let observation = await probe.observe()
            count = observation.sharedFolderCount ?? 0
            reason = Self.decide(observation)
        }
        let outcome: OperationOutcome
        switch reason {
        case .healthy, .guestRejected: outcome = .success
        case .accountNotEnabledForSMB, .noLoginMethod: outcome = .failure
        case .cancelled: outcome = .cancelled
        case .sharingOff, .noSharedFolders, .dataIncomplete: outcome = .skipped
        }
        let next: NextStep
        switch reason {
        case .accountNotEnabledForSMB, .noLoginMethod: next = .enableSMBAccount
        case .dataIncomplete, .cancelled: next = .retryCheck
        default: next = .reviewDetails
        }
        let evidence = EvidenceSanitizer.sanitize([
            .checkStatus: .status(outcome == .success ? .passed : outcome == .failure ? .failed : .unknown),
            .errorCode: .errorCode(reason.rawValue),
            .count: .count(count)
        ])
        return try! OperationResult(operationID: id, name: name, kind: .diagnostic, startedAt: start,
            endedAt: max(start, context.clock.now()), outcome: outcome, after: evidence,
            error: outcome == .failure ? try? OperationError(domain: "file_sharing", code: reason.rawValue) : nil,
            nextStep: next.rawValue)
    }

    /// Sharing off or nothing shared is a configuration choice, so it is reported as skipped.
    /// An account without an SMB password silently breaks Finder logins; when guests are rejected
    /// as well, no login method is left and the failure says so. A rejected guest next to a
    /// working account is only a hint, because Finder tries the guest session first.
    public static func decide(_ observation: FileSharingObservation) -> FileSharingReason {
        guard observation.smbListening else { return .sharingOff }
        guard let enabled = observation.accountEnabledForSMB, let folders = observation.sharedFolderCount else {
            return .dataIncomplete
        }
        let guestRejected = observation.guestLoginAccepted == false
        if !enabled { return guestRejected ? .noLoginMethod : .accountNotEnabledForSMB }
        if folders == 0 { return .noSharedFolders }
        return guestRejected ? .guestRejected : .healthy
    }
}

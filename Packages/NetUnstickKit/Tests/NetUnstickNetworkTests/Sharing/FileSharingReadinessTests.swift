import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork

private struct FixedFileSharingProbe: FileSharingProbing {
    let observation: FileSharingObservation
    func observe() async -> FileSharingObservation { observation }
}

final class FileSharingReadinessTests: XCTestCase {
    /// Representative `sharing -l` output with names that must never appear in a result.
    private let sharingListing = """

    \t\t\tList of Share Points
    name:\t\tJan Kowalski’s Public Folder
    path:\t\t/Users/jkowalski/Public
    \tsmb:\t{
        \t\tname:\tJan Kowalski’s Public Folder
        \t\tshared:\t1
        \t\tguest access:\t1
        \t\tread-only:\t0
        \t\tsealed:\t0
    \t}
    name:\t\tProjekty ABC
    path:\t\t/Volumes/Dane/Projekty ABC
    \tsmb:\t{
        \t\tname:\tProjekty ABC
        \t\tshared:\t1
        \t\tguest access:\t0
        \t\tread-only:\t0
        \t\tsealed:\t0
    \t}
    name:\t\tArchiwum
    path:\t\t/Volumes/Dane/Archiwum
    \tsmb:\t{
        \t\tname:\tArchiwum
        \t\tshared:\t0
        \t\tguest access:\t1
        \t\tread-only:\t0
        \t\tsealed:\t0
    \t}
    """

    func testSharePointCountingIgnoresNamesAndDisabledSMBBlocks() {
        let counts = SystemFileSharingProbe.countSharePoints(sharingListing)
        XCTAssertEqual(counts.sharePoints, 3)
        XCTAssertEqual(counts.smbShared, 2)
        XCTAssertEqual(counts.guest, 1)
        let empty = SystemFileSharingProbe.countSharePoints("\n\t\t\tList of Share Points\n")
        XCTAssertEqual(empty.sharePoints, 0)
        XCTAssertEqual(empty.smbShared, 0)
        XCTAssertEqual(SystemFileSharingProbe.countSharePoints("").smbShared, 0)
    }

    func testAccountRecordIsReducedToOneFlag() {
        // Realistic shape of the directory attribute; the hash values are placeholders, never real.
        let withSMB = "AuthenticationAuthority: ;ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2,SRP-RFC5054-4096-SHA512-PBKDF2,SMB-NT> ;Kerberosv5;;user@LKDC:SHA1.0000;LKDC:SHA1.0000; ;SecureToken\n"
        let withoutSMB = "AuthenticationAuthority: ;ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2,SRP-RFC5054-4096-SHA512-PBKDF2> ;Kerberosv5;;user@LKDC:SHA1.0000;LKDC:SHA1.0000; ;SecureToken\n"
        XCTAssertTrue(SystemFileSharingProbe.accountHasSMBPassword(withSMB))
        XCTAssertFalse(SystemFileSharingProbe.accountHasSMBPassword(withoutSMB))
        XCTAssertFalse(SystemFileSharingProbe.accountHasSMBPassword(""))
    }

    func testDecisionTableCoversEveryObservation() {
        let cases: [(FileSharingObservation, FileSharingReason)] = [
            (.init(smbListening: false, accountEnabledForSMB: true, sharedFolderCount: 1, guestFolderCount: 0), .sharingOff),
            (.init(smbListening: true, accountEnabledForSMB: nil, sharedFolderCount: 1, guestFolderCount: 0), .dataIncomplete),
            (.init(smbListening: true, accountEnabledForSMB: true, sharedFolderCount: nil, guestFolderCount: nil), .dataIncomplete),
            (.init(smbListening: true, accountEnabledForSMB: false, sharedFolderCount: 1, guestFolderCount: 1), .accountNotEnabledForSMB),
            (.init(smbListening: true, accountEnabledForSMB: false, sharedFolderCount: 0, guestFolderCount: 0), .accountNotEnabledForSMB),
            (.init(smbListening: true, accountEnabledForSMB: true, sharedFolderCount: 0, guestFolderCount: 0), .noSharedFolders),
            (.init(smbListening: true, accountEnabledForSMB: true, sharedFolderCount: 2, guestFolderCount: 1), .healthy)
        ]
        for (observation, expected) in cases {
            XCTAssertEqual(FileSharingReadinessCheck.decide(observation), expected, expected.rawValue)
        }
    }

    func testCheckResultCarriesOnlyCodeAndCount() async throws {
        let cases: [(FileSharingObservation, OperationOutcome, String?, NextStep)] = [
            (.init(smbListening: true, accountEnabledForSMB: true, sharedFolderCount: 2, guestFolderCount: 1), .success, nil, .reviewDetails),
            (.init(smbListening: true, accountEnabledForSMB: false, sharedFolderCount: 1, guestFolderCount: 1), .failure, "accountNotEnabledForSMB", .enableSMBAccount),
            (.init(smbListening: false, accountEnabledForSMB: nil, sharedFolderCount: nil, guestFolderCount: nil), .skipped, nil, .reviewDetails),
            (.init(smbListening: true, accountEnabledForSMB: nil, sharedFolderCount: nil, guestFolderCount: nil), .skipped, nil, .retryCheck)
        ]
        for (observation, outcome, code, next) in cases {
            let result = await FileSharingReadinessCheck(probe: FixedFileSharingProbe(observation: observation)).run(context: .init())
            XCTAssertEqual(result.operationID, "file_sharing_readiness")
            XCTAssertEqual(result.outcome, outcome, observation.smbListening.description)
            XCTAssertEqual(result.error?.code, code)
            XCTAssertEqual(result.after.values[.errorCode], FileSharingReadinessCheck.decide(observation).rawValue)
            XCTAssertEqual(result.after.values[.count], "\(observation.sharedFolderCount ?? 0)")
            XCTAssertEqual(result.nextStep, next.rawValue)
            let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            for sensitive in ["Kowalski", "Public", "Projekty", "/Users", "SMB-NT", "SHA512"] {
                XCTAssertFalse(json.contains(sensitive), sensitive)
            }
        }
    }

    func testCancelledContextIsDistinct() async {
        struct AlwaysCancelled: CancellationChecking {
            func checkCancellation() throws { throw CancellationError() }
        }
        let context = OperationContext(cancellation: AlwaysCancelled())
        let probe = FixedFileSharingProbe(observation: .init(smbListening: true, accountEnabledForSMB: true, sharedFolderCount: 1, guestFolderCount: 0))
        let result = await FileSharingReadinessCheck(probe: probe).run(context: context)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.after.values[.errorCode], FileSharingReason.cancelled.rawValue)
    }

    /// Opt-in host check: NETUNSTICK_READ_ONLY_SMOKE=1 prints flags and counts only.
    func testLiveHostObservationWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_READ_ONLY_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in read-only host smoke test")
        }
        let observation = await SystemFileSharingProbe().observe()
        print("NETUNSTICK_FILE_SHARING: listening=\(observation.smbListening) account=\(observation.accountEnabledForSMB.map(String.init) ?? "nil") " +
              "smbShared=\(observation.sharedFolderCount.map(String.init) ?? "nil") guest=\(observation.guestFolderCount.map(String.init) ?? "nil") " +
              "decision=\(FileSharingReadinessCheck.decide(observation).rawValue)")
    }
}

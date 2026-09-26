import Foundation
import Security
import NetUnstickRepair

private func clientRequirement() -> String? {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let info = information as? [String: Any],
          let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
          team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
    return ClientIdentityPolicy.requirement(forTeam: team)
}

private final class HelperService: NSObject, NetUnstickHelperXPC {
    private let executor = PrivilegedRepairExecutor()
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= 2048, let decoded = try? JSONDecoder().decode(PrivilegedRequest.self, from: request) else {
            reply(try! JSONEncoder().encode(PrivilegedRepairExecutor.rejectMalformedRequest()))
            return
        }
        Task { reply((try? JSONEncoder().encode(await executor.perform(decoded))) ?? Data()) }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetUnstickHelperXPC.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

guard geteuid() == 0, let requirement = clientRequirement() else { exit(77) }
private let delegate = ListenerDelegate(requirement: requirement)
let listener = NSXPCListener(machServiceName: PrivilegedProtocol.machService)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

import Foundation

public enum ClientIdentityPolicy {
    public static let appIdentifier = "org.netunstick.NetUnstick"
    public static func requirement(forTeam team: String) -> String? {
        guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        return "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

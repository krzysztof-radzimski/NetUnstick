import Foundation

public enum ClientIdentityPolicy {
    public static let appIdentifier = "org.netunstick.NetUnstick"
    public static func requirement(forLeafCertificateSHA1 hash: String) -> String? {
        guard hash.range(of: #"^[0-9A-Fa-f]{40}$"#, options: .regularExpression) != nil else { return nil }
        return "identifier \"\(appIdentifier)\" and certificate leaf = H\"\(hash.lowercased())\""
    }
}

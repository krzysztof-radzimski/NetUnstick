import Foundation

/// Parses the fixed, read-only output of `scutil --nc list`. Service names and IDs never
/// leave this type; only the aggregate connection status does.
public enum ScutilNetworkConnectionParser {
    public static func parse(_ output: String) -> VPNServiceStatus {
        var found = false
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*") || trimmed.hasPrefix("("),
                  let open = trimmed.firstIndex(of: "("),
                  let close = trimmed[open...].firstIndex(of: ")") else { continue }
            let status = trimmed[trimmed.index(after: open)..<close].lowercased()
            found = true
            switch status {
            case "disconnected": continue
            case "connected", "connecting", "disconnecting": return .connected
            default: return .unknown
            }
        }
        return found ? .disconnected : .unknown
    }
}

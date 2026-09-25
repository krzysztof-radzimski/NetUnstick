import Foundation

/// Parses the fixed, read-only output of macOS netstat. The result stays inside the raw snapshot.
public enum NetstatRouteParser {
    public static func parse(_ output: String, family: String) -> [RawRoute] {
        guard family == "ipv4" || family == "ipv6" else { return [] }
        var routes: [RawRoute] = []
        var inTable = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.first == "Destination", fields.count >= 4 {
                inTable = true
                continue
            }
            guard inTable, fields.count >= 4 else { continue }
            let destination = fields[0]
            let gateway = fields[1]
            let flags = fields[2]
            guard flags.contains("U") else { continue }
            // The interface column follows Flags on macOS. Refuse malformed rows rather than
            // infer an interface from a variable trailing metric or expiry column.
            let interface = fields[3]
            guard interface.range(of: #"^[A-Za-z][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { continue }
            let isDefault = destination == "default" || destination == "0.0.0.0/0" || destination == "::/0"
            let isLocal = !isDefault && (gateway.hasPrefix("link#") || gateway == destination || flags.contains("L"))
            routes.append(RawRoute(destination: destination, gateway: gateway, interfaceName: interface,
                                   isDefault: isDefault, isLocal: isLocal))
        }
        return routes
    }
}

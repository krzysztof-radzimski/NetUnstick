import Foundation

/// Parses only resolver fields needed for VPN correlation; never retains full command output.
public enum ScutilDNSParser {
    public static func parse(_ output: String) -> [RawResolver] {
        var results: [RawResolver] = []
        var domain: String?
        var searchDomains: [String] = []
        var nameservers: [String] = []
        var interfaceName: String?
        var inResolver = false

        func flush() {
            if inResolver, !nameservers.isEmpty || !searchDomains.isEmpty || domain != nil || interfaceName != nil {
                results.append(RawResolver(domain: domain, searchDomains: searchDomains,
                                           nameservers: nameservers, interfaceName: interfaceName))
            }
            domain = nil; searchDomains = []; nameservers = []; interfaceName = nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                flush()
                inResolver = true
                continue
            }
            guard inResolver, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "domain" { domain = value }
            else if key.hasPrefix("search domain[") { searchDomains.append(value) }
            else if key.hasPrefix("nameserver[") { nameservers.append(value) }
            else if key == "if_index", let open = value.firstIndex(of: "("),
                    let close = value[open...].firstIndex(of: ")") {
                interfaceName = String(value[value.index(after: open)..<close])
            }
        }
        flush()
        return results
    }
}

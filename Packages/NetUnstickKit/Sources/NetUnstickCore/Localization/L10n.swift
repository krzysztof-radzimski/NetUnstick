import Foundation

/// The shared, app-owned localization boundary. Evidence and persisted identifiers never
/// pass through this layer; a translated label is produced only when presenting them.
public enum L10n {
    public static let supportedLanguages = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "ga", "hr",
        "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "sk", "sl", "sv"
    ]

    public static var bundle: Bundle { .module }

    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    /// Explicit locale lookup keeps translated diagnostics testable independently of
    /// the machine's language and provides an English fallback for unsupported languages.
    public static func text(_ key: String, locale: Locale) -> String {
        localizedBundle(locale).localizedString(forKey: key, value: nil, table: "Localizable")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    public static func format(_ key: String, locale: Locale, arguments: [CVarArg]) -> String {
        String(format: text(key, locale: locale), locale: locale, arguments: arguments)
    }

    private static func localizedBundle(_ locale: Locale) -> Bundle {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = identifier.split(separator: "-").first.map(String.init) ?? "en"
        for candidate in [identifier, language, "en"] {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localized = Bundle(path: path) { return localized }
        }
        return bundle
    }

    public static func nextStep(_ rawValue: String) -> String {
        let step = NextStep(rawValue: rawValue) ?? .reviewDetails
        return text("nextstep_" + step.localizationID)
    }

    public static func nextStep(_ rawValue: String, locale: Locale) -> String {
        let step = NextStep(rawValue: rawValue) ?? .reviewDetails
        return text("nextstep_" + step.localizationID, locale: locale)
    }

    public static func operationTitle(_ stableID: String) -> String {
        // Never turn arbitrary stored data into a localization key. Unknown technical
        // IDs remain available in expandable details, while this label stays fixed.
        let known: Set<String> = [
            "physical_link", "default_route", "local_subnet_route", "resolver_configuration",
            "unicast_dns_resolution", "internet_path", "proxy_configuration", "interface_consistency",
            "local_multicast_path", "bonjour_discovery", "bonjour_permission", "file_sharing_readiness",
            "content_filter", "device_connection", "diagnosis_cancelled", "helper_status",
            "helper_handshake", "privileged_repair",
            "retryCheck", "refreshResolverCache", "renewDHCP", "removeStaleTunnelRoutes"
        ]
        let phases: Set<String> = ["revalidate", "fresh_vpn", "vpn_gate", "before_snapshot",
            "helper_request", "read_only_retry", "settle", "after_snapshot", "recheck", "result"]
        if phases.contains(stableID) { return text("phase_" + stableID) }
        return text(known.contains(stableID) ? "operation_" + stableID : "operation_other")
    }
}

private extension NextStep {
    var localizationID: String {
        switch self {
        case .reviewDetails: "reviewDetails"
        case .retryCheck: "retryCheck"
        case .checkPermissions: "checkPermissions"
        case .waitForVPN: "waitForVPN"
        case .verifyVPN: "verifyVPN"
        case .contactSupport: "contactSupport"
        case .registerHelper: "registerHelper"
        case .approveHelper: "approveHelper"
        case .reinstallApp: "reinstallApp"
        case .retryHelper: "retryHelper"
        case .checkHelperPermissions: "checkHelperPermissions"
        case .restartAppForHelper: "restartAppForHelper"
        case .restartVPNClient: "restartVPNClient"
        case .enableSMBAccount: "enableSMBAccount"
        case .disableLocalFirewall: "disableLocalFirewall"
        case .connectAsAccount: "connectAsAccount"
        case .limitSMBToVersion2: "limitSMBToVersion2"
        }
    }
}

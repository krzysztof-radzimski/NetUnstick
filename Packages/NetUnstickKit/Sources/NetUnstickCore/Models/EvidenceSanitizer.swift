import Foundation

public enum EvidenceKey: String, Codable, Sendable, CaseIterable {
    case networkStatus, vpnStatus, checkStatus, interfaceType, count, errorCode
}

public enum PublicStatus: String, Codable, Sendable {
    case available, unavailable, active, inactive, unknown, passed, failed
}

public enum InterfaceType: String, Codable, Sendable {
    case wifi, ethernet, cellular, loopback, other
}

public enum EvidenceValue: Sendable, Equatable {
    case status(PublicStatus)
    case count(Int)
    case interfaceType(InterfaceType)
    case errorCode(String)
    case sensitive(String)
}

public struct SafeEvidence: Codable, Sendable, Equatable {
    public let values: [EvidenceKey: String]
    public static let empty = SafeEvidence(values: [:])

    private init(values: [EvidenceKey: String]) { self.values = values }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode([String: String].self)
        var checked: [EvidenceKey: String] = [:]
        for (rawKey, value) in raw {
            guard let key = EvidenceKey(rawValue: rawKey) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown evidence key")
            }
            switch key {
            case .count:
                guard let number = Int(value), number >= 0 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid count") }
                checked[key] = String(number)
            case .interfaceType:
                guard InterfaceType(rawValue: value) != nil else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid interface type") }
                checked[key] = value
            case .errorCode:
                guard StableIdentifier.isValid(value) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid error code") }
                checked[key] = value
            default:
                guard PublicStatus(rawValue: value) != nil else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid status") }
                checked[key] = value
            }
        }
        self.values = checked
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}

public enum EvidenceSanitizer {
    public static func sanitize(_ input: [EvidenceKey: EvidenceValue]) -> SafeEvidence {
        var safe: [EvidenceKey: String] = [:]
        for (key, value) in input {
            switch (key, value) {
            case (.networkStatus, .status(let status)), (.vpnStatus, .status(let status)), (.checkStatus, .status(let status)):
                safe[key] = status.rawValue
            case (.count, .count(let count)) where count >= 0:
                safe[key] = String(count)
            case (.interfaceType, .interfaceType(let type)):
                safe[key] = type.rawValue
            case (.errorCode, .errorCode(let code)) where StableIdentifier.isValid(code):
                safe[key] = code
            default:
                break
            }
        }
        return SafeEvidence.make(safe)
    }

    // Free-form strings, including stdout/stderr, are never published. Callers must map
    // observations to the typed allowlist above before crossing the logging boundary.
    public static func safeLabel(_ text: String) -> String {
        guard StableIdentifier.isValid(text), text.count <= 64 else { return "[redacted]" }
        return text
    }

    public static func safeNextStep(_ text: String) -> String {
        // A closed set prevents a caller or persisted record from embedding host names or secrets.
        NextStep(rawValue: text)?.rawValue ?? NextStep.reviewDetails.rawValue
    }
}

public enum NextStep: String, Codable, Sendable {
    case reviewDetails = "Review the operation details."
    case retryCheck = "Run the check again."
    case checkPermissions = "Check app permissions and retry."
    case waitForVPN = "Disconnect VPN and retry."
    case contactSupport = "Contact your network administrator."
}

extension SafeEvidence {
    fileprivate static func make(_ values: [EvidenceKey: String]) -> Self { Self(values: values) }
}

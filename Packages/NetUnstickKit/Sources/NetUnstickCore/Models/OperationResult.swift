import Foundation

public enum OperationOutcome: String, Codable, Sendable, CaseIterable {
    case success, failure, skipped, cancelled, permissionDenied, timedOut
}

public enum OperationKind: String, Codable, Sendable {
    case diagnostic, repair
}

public struct OperationError: Codable, Sendable, Equatable {
    public let domain: String
    public let code: String

    public init(domain: String, code: String) throws {
        guard StableIdentifier.isValid(domain), StableIdentifier.isValid(code) else {
            throw OperationContractError.invalidIdentifier
        }
        self.domain = domain
        self.code = code
    }

    private enum CodingKeys: String, CodingKey { case domain, code }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(domain: c.decode(String.self, forKey: .domain),
                      code: c.decode(String.self, forKey: .code))
    }
}

public enum OperationContractError: Error, Equatable {
    case invalidIdentifier
    case invalidTimeRange
    case missingErrorCode
}

public enum StableIdentifier {
    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 &&
        value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            scalar == "." || scalar == "_" || scalar == "-"
        }
    }
}

public struct OperationResult: Codable, Sendable, Equatable {
    public let operationID: String
    public let name: String
    public let kind: OperationKind
    public let startedAt: Date
    public let endedAt: Date
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public let outcome: OperationOutcome
    public let before: SafeEvidence
    public let after: SafeEvidence
    public let error: OperationError?
    public let nextStep: String?

    public init(operationID: String, name: String, kind: OperationKind,
                startedAt: Date, endedAt: Date, outcome: OperationOutcome,
                before: SafeEvidence = .empty, after: SafeEvidence = .empty,
                error: OperationError? = nil, nextStep: String? = nil) throws {
        guard StableIdentifier.isValid(operationID) else { throw OperationContractError.invalidIdentifier }
        guard endedAt >= startedAt else { throw OperationContractError.invalidTimeRange }
        guard !Self.requiresError(outcome) || error != nil else { throw OperationContractError.missingErrorCode }
        self.operationID = operationID
        self.name = EvidenceSanitizer.safeLabel(name)
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.before = before
        self.after = after
        self.error = error
        self.nextStep = nextStep.map(EvidenceSanitizer.safeNextStep)
    }

    private static func requiresError(_ outcome: OperationOutcome) -> Bool {
        outcome == .failure || outcome == .permissionDenied || outcome == .timedOut
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, name, kind, startedAt, endedAt, outcome, before, after, error, nextStep
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: c.decode(String.self, forKey: .operationID),
                      name: c.decode(String.self, forKey: .name),
                      kind: c.decode(OperationKind.self, forKey: .kind),
                      startedAt: c.decode(Date.self, forKey: .startedAt),
                      endedAt: c.decode(Date.self, forKey: .endedAt),
                      outcome: c.decode(OperationOutcome.self, forKey: .outcome),
                      before: c.decode(SafeEvidence.self, forKey: .before),
                      after: c.decode(SafeEvidence.self, forKey: .after),
                      error: c.decodeIfPresent(OperationError.self, forKey: .error),
                      nextStep: c.decodeIfPresent(String.self, forKey: .nextStep))
    }
}

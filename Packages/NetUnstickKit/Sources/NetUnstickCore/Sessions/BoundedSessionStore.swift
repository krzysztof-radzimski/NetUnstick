import Foundation

public struct ActivitySession: Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let appVersion: String
    public let macOSVersion: String
    public private(set) var entries: [OperationResult]

    public init(id: UUID = UUID(), startedAt: Date, appVersion: String,
                macOSVersion: String, entries: [OperationResult] = []) {
        self.id = id
        self.startedAt = startedAt
        self.appVersion = Self.safeVersion(appVersion)
        self.macOSVersion = Self.safeVersion(macOSVersion)
        self.entries = entries
    }

    public mutating func append(_ result: OperationResult, limit: Int) {
        entries.append(result)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    private static func safeVersion(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 32,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || $0 == "." })
        else { return "unknown" }
        return value
    }

    private enum CodingKeys: String, CodingKey { case id, startedAt, appVersion, macOSVersion, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  startedAt: try c.decode(Date.self, forKey: .startedAt),
                  appVersion: try c.decode(String.self, forKey: .appVersion),
                  macOSVersion: try c.decode(String.self, forKey: .macOSVersion),
                  entries: try c.decode([OperationResult].self, forKey: .entries))
    }
}

public enum SessionStoreError: Error, Equatable {
    case permissionDenied
    case unsupportedFormat(Int)
    case ioFailure
}

public enum SessionLoadWarning: Equatable, Sendable {
    case corruptFile
}

private struct SessionFile: Codable {
    let formatVersion: Int
    let sessions: [ActivitySession]
}

public actor BoundedSessionStore {
    public static let maxSessions = 20
    public static let maxEntriesPerSession = 100
    public static let maxFileBytes = 4_000_000
    public static let formatVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private var loaded = false
    private var storedSessions: [ActivitySession] = []
    public private(set) var loadWarning: SessionLoadWarning?

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw SessionStoreError.ioFailure
            }
            self.fileURL = support.appendingPathComponent("NetUnstick", isDirectory: true)
                .appendingPathComponent("sessions.json")
        }
        self.fileManager = fileManager
    }

    public func sessions() throws -> [ActivitySession] {
        try loadIfNeeded()
        return storedSessions
    }

    public func startSession(_ session: ActivitySession) throws {
        try Task.checkCancellation()
        try loadIfNeeded()
        var candidate = storedSessions.filter { $0.id != session.id }
        candidate.append(ActivitySession(id: session.id, startedAt: session.startedAt,
                                         appVersion: session.appVersion, macOSVersion: session.macOSVersion))
        candidate = Array(candidate.suffix(Self.maxSessions))
        try persist(candidate)
        storedSessions = candidate
    }

    public func append(_ result: OperationResult, to sessionID: UUID) throws {
        try Task.checkCancellation()
        try loadIfNeeded()
        var candidate = storedSessions
        guard let index = candidate.firstIndex(where: { $0.id == sessionID }) else { throw SessionStoreError.ioFailure }
        candidate[index].append(result, limit: Self.maxEntriesPerSession)
        try persist(candidate)
        storedSessions = candidate
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw Self.map(error) }
        guard data.count <= Self.maxFileBytes else {
            storedSessions = []
            loadWarning = .corruptFile
            loaded = true
            return
        }
        do {
            let file = try JSONDecoder().decode(SessionFile.self, from: data)
            guard file.formatVersion == Self.formatVersion else {
                throw SessionStoreError.unsupportedFormat(file.formatVersion)
            }
            storedSessions = Array(file.sessions.suffix(Self.maxSessions)).map { session in
                ActivitySession(id: session.id, startedAt: session.startedAt,
                                appVersion: session.appVersion, macOSVersion: session.macOSVersion,
                                entries: Array(session.entries.suffix(Self.maxEntriesPerSession)))
            }
        } catch let error as SessionStoreError {
            throw error
        } catch {
            storedSessions = []
            loadWarning = .corruptFile
        }
        loaded = true
    }

    private func persist(_ sessions: [ActivitySession]) throws {
        try Task.checkCancellation()
        let data: Data
        do { data = try JSONEncoder().encode(SessionFile(formatVersion: Self.formatVersion, sessions: sessions)) }
        catch { throw SessionStoreError.ioFailure }
        guard data.count <= Self.maxFileBytes else { throw SessionStoreError.ioFailure }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Task.checkCancellation()
            try data.write(to: fileURL, options: .atomic)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> SessionStoreError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain &&
            (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError) {
            return .permissionDenied
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) {
            return .permissionDenied
        }
        return .ioFailure
    }
}

import Foundation

public enum MemoryKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case profile, preference, person, routine, project, instruction

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: "About me"
        case .preference: "Preferences"
        case .person: "People"
        case .routine: "Routines"
        case .project: "Projects & interests"
        case .instruction: "Standing instructions"
        }
    }

    /// What the extractor is told about each kind.
    var hint: String {
        switch self {
        case .profile: "facts about the user: name, home city, languages, job, time zone"
        case .preference: "how the user likes things: language, length, units, formats, tastes"
        case .person: "someone in the user's life and who they are to the user"
        case .routine: "recurring habits and schedules: work hours, gym days, weekly reviews"
        case .project: "what the user works on or is interested in"
        case .instruction: "a standing rule the assistant should always follow"
        }
    }

    /// Learned items of these kinds are accepted without review (unless sensitive).
    public static let defaultAutoAccept: Set<MemoryKind> = [.preference, .project]
}

public enum MemorySource: String, Codable, Sendable, Hashable {
    /// The user said so (/remember, the Memory view, an approved remember call).
    case explicit
    /// Proposed from the user's own Chat messages.
    case learned
}

public enum MemoryStatus: String, Codable, Sendable, Hashable {
    case active
    /// Learned, waiting for review.
    case pending
    case archived
}

public struct MemoryItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: MemoryKind
    public var text: String
    /// Person or project the item is about ("Anna"), for grouping and updates.
    public var subject: String?
    public var source: MemorySource
    public var status: MemoryStatus
    /// Health, money, relationships, beliefs…: never auto-accepted, never in notifications.
    public var sensitive: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    /// For a pending update: the item it would replace.
    public var replaces: UUID?
    /// Embedding of `text` with `embeddingModel`; recomputed when either changes.
    public var embedding: [Float]?
    public var embeddingModel: String?

    public init(
        id: UUID = UUID(), kind: MemoryKind, text: String, subject: String? = nil, source: MemorySource = .explicit,
        status: MemoryStatus = .active, sensitive: Bool = false, createdAt: Date = .now, replaces: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.subject = subject
        self.source = source
        self.status = status
        self.sensitive = sensitive
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.replaces = replaces
    }
}

/// A fact proposed by the extractor or typed by the user, before it is matched against memory.
public struct MemoryCandidate: Codable, Sendable, Hashable {
    public var kind: MemoryKind
    public var text: String
    public var subject: String?
    public var sensitive: Bool

    public init(kind: MemoryKind, text: String, subject: String? = nil, sensitive: Bool = false) {
        self.kind = kind
        self.text = text
        self.subject = subject
        self.sensitive = sensitive
    }
}

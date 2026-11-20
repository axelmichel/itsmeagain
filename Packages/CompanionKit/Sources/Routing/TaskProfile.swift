import CompanionCore
import Foundation

/// What the user wants to do. Each task maps to its own provider, model and prompt.
public enum TaskKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case chat, translate, research, code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat: "Chat"
        case .translate: "Translate"
        case .research: "Research"
        case .code: "Code"
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .translate: "character.bubble"
        case .research: "magnifyingglass"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// The user's mapping of one task to a provider/model plus how to prompt it.
public struct TaskProfile: Codable, Sendable, Hashable, Identifiable {
    public static let targetLanguagePlaceholder = "{{target_language}}"
    public static let datePlaceholder = "{{date}}"

    /// Tool names (see `ToolCatalog`) offered to the model for this task.
    public enum ToolName {
        public static let webSearch = "web_search"
        public static let fetchPage = "fetch_page"
        public static let searchDocuments = "search_documents"
    }

    public var task: TaskKind
    public var providerID: ProviderID
    public var modelID: String
    public var systemPrompt: String
    public var temperature: Double?
    public var contextLength: Int?
    public var think: Bool?
    /// When false only the latest user message is sent (translation works per message).
    public var includesHistory: Bool
    public var tools: [String]

    public var id: TaskKind { task }

    public init(
        task: TaskKind,
        providerID: ProviderID = .ollama,
        modelID: String,
        systemPrompt: String,
        temperature: Double? = nil,
        contextLength: Int? = nil,
        think: Bool? = nil,
        includesHistory: Bool = true,
        tools: [String] = []
    ) {
        self.task = task
        self.providerID = providerID
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.contextLength = contextLength
        self.think = think
        self.includesHistory = includesHistory
        self.tools = tools
    }

    /// Fields added in later versions fall back to the task's defaults, so saved settings survive upgrades.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let task = try container.decode(TaskKind.self, forKey: .task)
        self.task = task
        let fallback = TaskProfiles.defaultProfiles.first { $0.task == task }!
        providerID = try container.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? fallback.providerID
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? fallback.modelID
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? fallback.systemPrompt
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        think = try container.decodeIfPresent(Bool.self, forKey: .think)
        includesHistory = try container.decodeIfPresent(Bool.self, forKey: .includesHistory) ?? fallback.includesHistory
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? fallback.tools
    }

    public func makeRequest(
        history: [ChatMessage],
        model: String? = nil,
        targetLanguage: String = "English",
        keepAlive: String? = "10m"
    ) -> ChatRequest {
        var messages = history
        if !includesHistory, let last = history.last(where: { $0.role == .user }) {
            messages = [last]
        }
        let system = systemPrompt
            .replacingOccurrences(of: Self.targetLanguagePlaceholder, with: targetLanguage)
            .replacingOccurrences(of: Self.datePlaceholder, with: Date.now.formatted(date: .complete, time: .omitted))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatRequest(
            model: model ?? modelID,
            system: system.isEmpty ? nil : system,
            messages: messages,
            options: ChatOptions(
                temperature: temperature,
                contextLength: contextLength,
                keepAlive: keepAlive,
                think: think
            ),
            targetLanguage: task == .translate ? targetLanguage : nil
        )
    }
}

/// One profile per `TaskKind`, always complete: missing entries fall back to the defaults.
public struct TaskProfiles: Codable, Sendable, Hashable {
    private var profiles: [TaskKind: TaskProfile]

    public init(_ profiles: [TaskProfile] = []) {
        var byTask = Dictionary(uniqueKeysWithValues: Self.defaultProfiles.map { ($0.task, $0) })
        for profile in profiles { byTask[profile.task] = profile }
        self.profiles = byTask
    }

    public subscript(task: TaskKind) -> TaskProfile {
        get { profiles[task]! }
        set {
            var profile = newValue
            profile.task = task
            profiles[task] = profile
        }
    }

    public var all: [TaskProfile] { TaskKind.allCases.map { self[$0] } }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([TaskProfile].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(all)
    }

    public static let defaults = TaskProfiles()

    static let defaultProfiles: [TaskProfile] = [
        TaskProfile(
            task: .chat,
            modelID: "gemma4:26b",
            systemPrompt: """
                You are a helpful, friendly assistant running locally on the user's Mac. \
                Answer concisely and in the language the user writes in.
                """
        ),
        TaskProfile(
            task: .translate,
            modelID: "gemma4:26b",
            systemPrompt: """
                You are a professional translator. Translate the user's text into \(TaskProfile.targetLanguagePlaceholder). \
                Preserve meaning, tone, formatting and Markdown. Keep names, code and URLs unchanged. \
                Output only the translation, without explanations or quotes.
                """,
            temperature: 0.2,
            think: false,
            includesHistory: false
        ),
        TaskProfile(
            task: .research,
            modelID: "qwen3:30b-a3b",
            systemPrompt: """
                You are a careful research assistant. Today is \(TaskProfile.datePlaceholder).
                If the question may concern the user's own notes or files, use search_documents first.
                When the question needs facts, current information or comparisons, use web_search, then open \
                the 2–4 most relevant results with fetch_page; snippets alone are not enough. If a search \
                returns nothing useful, try different, shorter keywords instead of repeating it.
                Separate facts from assumptions and say clearly when sources disagree or you are unsure. \
                If the tools didn't provide the answer, say so and mark anything from general knowledge as such.
                Cite sources inline as [1], [2], … and end with a "Sources" list in the same numbering. \
                Only cite URLs that appeared in tool results; never invent a source. \
                Structure longer answers with headings and bullet points.
                """,
            contextLength: 32_768,
            tools: [TaskProfile.ToolName.webSearch, TaskProfile.ToolName.fetchPage, TaskProfile.ToolName.searchDocuments]
        ),
        TaskProfile(
            task: .code,
            modelID: "qwen3-coder:30b",
            systemPrompt: """
                You are an expert software engineer. Write correct, idiomatic, production-quality code. \
                Keep explanations short and put code in fenced blocks with a language tag.
                """,
            temperature: 0.2,
            contextLength: 16_384
        ),
    ]
}

public enum Languages {
    public static let common = [
        "English", "German", "French", "Spanish", "Italian", "Portuguese", "Dutch", "Polish",
        "Swedish", "Danish", "Norwegian", "Finnish", "Czech", "Greek", "Turkish", "Russian",
        "Ukrainian", "Arabic", "Hebrew", "Hindi", "Chinese (Simplified)", "Chinese (Traditional)",
        "Japanese", "Korean", "Vietnamese", "Thai", "Indonesian",
    ]

    /// BCP 47 code for a name from `common`, for system translation APIs.
    public static func code(for language: String) -> String? {
        codes[language]
    }

    private static let codes: [String: String] = [
        "English": "en", "German": "de", "French": "fr", "Spanish": "es", "Italian": "it", "Portuguese": "pt",
        "Dutch": "nl", "Polish": "pl", "Swedish": "sv", "Danish": "da", "Norwegian": "nb", "Finnish": "fi",
        "Czech": "cs", "Greek": "el", "Turkish": "tr", "Russian": "ru", "Ukrainian": "uk", "Arabic": "ar",
        "Hebrew": "he", "Hindi": "hi", "Chinese (Simplified)": "zh-Hans", "Chinese (Traditional)": "zh-Hant",
        "Japanese": "ja", "Korean": "ko", "Vietnamese": "vi", "Thai": "th", "Indonesian": "id",
    ]
}

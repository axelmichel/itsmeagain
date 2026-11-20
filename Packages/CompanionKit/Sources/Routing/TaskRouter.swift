import CompanionCore
import Foundation

/// Decides which task a message belongs to (for conversations in Auto mode).
public protocol TaskClassifier: Sendable {
    func classify(_ text: String) async throws -> TaskKind
}

public struct RoutingDecision: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case heuristic, classifier, fallback }

    public var task: TaskKind
    /// For translations: the language named in the message ("… ins Französische"), if any.
    public var targetLanguage: String?
    public var source: Source
}

public struct TaskRouter: Sendable {
    public var classifier: (any TaskClassifier)?
    public var timeout: Duration

    public init(classifier: (any TaskClassifier)?, timeout: Duration = .seconds(15)) {
        self.classifier = classifier
        self.timeout = timeout
    }

    public func route(_ text: String) async -> RoutingDecision {
        if let task = Self.heuristic(text) {
            return decision(task, text, .heuristic)
        }
        if let classifier, let task = await classify(text, with: classifier) {
            return decision(task, text, .classifier)
        }
        return decision(.chat, text, .fallback)
    }

    private func decision(_ task: TaskKind, _ text: String, _ source: RoutingDecision.Source) -> RoutingDecision {
        RoutingDecision(task: task, targetLanguage: task == .translate ? Self.targetLanguage(in: text) : nil, source: source)
    }

    private func classify(_ text: String, with classifier: any TaskClassifier) async -> TaskKind? {
        let timeout = timeout
        return await withTaskGroup(of: TaskKind?.self) { group in
            group.addTask { try? await classifier.classify(text) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Heuristics

    /// Unambiguous signals only; everything else goes to the classifier.
    public static func heuristic(_ text: String) -> TaskKind? {
        let lower = text.lowercased()
        if lower.firstMatch(of: translateCommand) != nil { return .translate }
        if lower.firstMatch(of: researchCommand) != nil { return .research }
        if looksLikeCode(text) { return .code }
        return nil
    }

    nonisolated(unsafe) private static let translateCommand =
        /^\s*(?:please\s+|bitte\s+|can you\s+|could you\s+|kannst du\s+)?(?:translate|übersetze|übersetz|traduis|traduire|traduce|tradurre|vertaal)\b/
    nonisolated(unsafe) private static let researchCommand =
        /^\s*(?:please\s+|bitte\s+)?(?:research|recherchiere|investigate|find sources)\b/
    nonisolated(unsafe) private static let codeLine =
        /^\s*(?:func|def|class|struct|enum|import|#include|fn|package|interface|public|private|const|let|var|SELECT|INSERT|UPDATE)\s+\S/
    nonisolated(unsafe) private static let stackTrace =
        /Traceback \(most recent call last\)|\.(?:swift|py|js|ts|rs|go|java|kt|cpp|c):\d+|Exception in thread|panicked at/

    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("```") || text.firstMatch(of: stackTrace) != nil { return true }
        let codeLines = text.split(separator: "\n").filter { $0.firstMatch(of: codeLine) != nil }.count
        let structural = text.filter { "{};".contains($0) }.count
        return codeLines >= 2 || (codeLines >= 1 && structural >= 3)
    }

    // MARK: Target language

    /// Finds "to/into/ins/auf/en <language>" and maps English, German, French and Spanish names.
    public static func targetLanguage(in text: String) -> String? {
        let lower = text.lowercased()
        for match in lower.matches(of: languagePhrase) {
            let word = String(match.output.1)
            for candidate in [word, String(word.dropLast()), String(word.dropLast(2))] where !candidate.isEmpty {
                if let language = languageNames[candidate] { return language }
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let languagePhrase =
        /\b(?:to|into|in|ins|auf|nach|en|al|in das)\s+(?:the\s+|das\s+)?(\p{L}+)/

    private static let languageNames: [String: String] = {
        let table: [String: [String]] = [
            "English": ["english", "englisch", "anglais", "inglés", "ingles"],
            "German": ["german", "deutsch", "allemand", "alemán", "aleman"],
            "French": ["french", "französisch", "franzoesisch", "français", "francais", "francés", "frances"],
            "Spanish": ["spanish", "spanisch", "espagnol", "español", "espanol"],
            "Italian": ["italian", "italienisch", "italien", "italiano"],
            "Portuguese": ["portuguese", "portugiesisch", "portugais", "portugués"],
            "Dutch": ["dutch", "niederländisch", "holländisch", "néerlandais"],
            "Polish": ["polish", "polnisch", "polonais"],
            "Swedish": ["swedish", "schwedisch", "suédois"],
            "Danish": ["danish", "dänisch", "danois"],
            "Norwegian": ["norwegian", "norwegisch", "norvégien"],
            "Finnish": ["finnish", "finnisch", "finnois"],
            "Czech": ["czech", "tschechisch", "tchèque"],
            "Greek": ["greek", "griechisch", "grec"],
            "Turkish": ["turkish", "türkisch", "turc"],
            "Russian": ["russian", "russisch", "russe"],
            "Ukrainian": ["ukrainian", "ukrainisch", "ukrainien"],
            "Arabic": ["arabic", "arabisch", "arabe"],
            "Hebrew": ["hebrew", "hebräisch", "hébreu"],
            "Hindi": ["hindi"],
            "Chinese (Simplified)": ["chinese", "chinesisch", "chinois"],
            "Japanese": ["japanese", "japanisch", "japonais"],
            "Korean": ["korean", "koreanisch", "coréen"],
            "Vietnamese": ["vietnamese", "vietnamesisch", "vietnamien"],
            "Thai": ["thai", "thailändisch", "thaï"],
            "Indonesian": ["indonesian", "indonesisch", "indonésien"],
        ]
        var names: [String: String] = [:]
        for (language, words) in table {
            for word in words { names[word] = language }
        }
        return names
    }()

    public static let classifierInstructions = """
        Classify the user's message into exactly one task:
        - chat: conversation, questions, advice, writing or summarising text
        - translate: the user wants text translated into another language
        - research: needs investigation, facts, comparisons, current information or sources
        - code: programming, code, scripts, debugging, software tools
        Answer with the task only.
        """
}

/// Classifies with a chat model (typically a small local one), using constrained JSON output.
public struct LLMTaskClassifier: TaskClassifier {
    public let provider: any LLMProvider
    public let model: String

    public init(provider: any LLMProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    static let schema: JSONValue = [
        "type": "object",
        "properties": ["task": ["type": "string", "enum": .array(TaskKind.allCases.map { .string($0.rawValue) })]],
        "required": ["task"],
    ]

    public func classify(_ text: String) async throws -> TaskKind {
        let request = ChatRequest(
            model: model,
            system: TaskRouter.classifierInstructions + "\nRespond as JSON: {\"task\": \"…\"}.",
            messages: [.user(String(text.prefix(2_000)))],
            options: ChatOptions(temperature: 0, keepAlive: "30m", think: false, maxTokens: 30),
            responseFormat: Self.schema
        )
        var output = ""
        for try await event in provider.stream(request) {
            if case .textDelta(let delta) = event { output += delta }
        }
        guard let task = Self.parse(output) else {
            throw ProviderError.invalidResponse("classifier answered \(output.prefix(80))")
        }
        return task
    }

    static func parse(_ output: String) -> TaskKind? {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)),
            let task = json["task"]?.stringValue.flatMap(TaskKind.init(rawValue:))
        {
            return task
        }
        let lower = output.lowercased()
        return TaskKind.allCases.first { lower.contains($0.rawValue) }
    }
}

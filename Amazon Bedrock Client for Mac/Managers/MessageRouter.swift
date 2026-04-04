import Foundation
import Logging

/// Routes messages to the appropriate model tier based on complexity
enum MessageComplexity: String {
    case simple   // Quick factual answers, casual chat
    case medium   // Code explanations, moderate analysis
    case complex  // Multi-step tasks, tool use, deep reasoning
}

class MessageRouter {
    static let shared = MessageRouter()
    private let logger = Logger(label: "MessageRouter")
    
    // Model IDs for each tier — will be resolved from available models
    struct ModelTier {
        let simple: String   // Haiku
        let medium: String   // Sonnet
        let complex: String  // Opus
    }
    
    /// Resolve model tier IDs from available models
    func resolveModelTier(from models: [ChatModel]) -> ModelTier {
        let ids = models.map { $0.id.lowercased() }
        
        let haiku = ids.first { $0.contains("haiku") } ?? ""
        let sonnet = ids.first { $0.contains("sonnet") } ?? ""
        let opus = ids.first { $0.contains("opus") } ?? ""
        
        return ModelTier(
            simple: haiku.isEmpty ? sonnet : haiku,
            medium: sonnet.isEmpty ? opus : sonnet,
            complex: opus.isEmpty ? sonnet : opus
        )
    }
    
    /// Hybrid routing: local heuristic first, then Haiku classifier if uncertain
    func route(
        message: String,
        conversationLength: Int,
        hasAttachments: Bool,
        backend: BedrockClient,
        tier: ModelTier
    ) async -> (modelId: String, complexity: MessageComplexity) {
        // Step 1: Local heuristic for obvious cases
        let heuristic = localHeuristic(message: message, conversationLength: conversationLength, hasAttachments: hasAttachments)
        
        if heuristic.confidence >= 0.8 {
            logger.info("Router: heuristic → \(heuristic.complexity.rawValue) (confidence: \(heuristic.confidence))")
            return (modelIdFor(heuristic.complexity, tier: tier), heuristic.complexity)
        }
        
        // Step 2: Haiku classifier for ambiguous cases
        if !tier.simple.isEmpty {
            let classified = await classifyWithHaiku(message: message, backend: backend, modelId: tier.simple)
            logger.info("Router: Haiku classifier → \(classified.rawValue)")
            return (modelIdFor(classified, tier: tier), classified)
        }
        
        // Fallback: use heuristic result
        return (modelIdFor(heuristic.complexity, tier: tier), heuristic.complexity)
    }
    
    private func modelIdFor(_ complexity: MessageComplexity, tier: ModelTier) -> String {
        // Use original casing from available models
        let models = SettingManager.shared.availableModels
        switch complexity {
        case .simple:
            return models.first { $0.id.lowercased() == tier.simple }?.id ?? tier.simple
        case .medium:
            return models.first { $0.id.lowercased() == tier.medium }?.id ?? tier.medium
        case .complex:
            return models.first { $0.id.lowercased() == tier.complex }?.id ?? tier.complex
        }
    }
    
    // MARK: - Local Heuristic
    
    struct HeuristicResult {
        let complexity: MessageComplexity
        let confidence: Double // 0.0 - 1.0
    }
    
    private func localHeuristic(message: String, conversationLength: Int, hasAttachments: Bool) -> HeuristicResult {
        let msg = message.lowercased()
        let wordCount = message.split(separator: " ").count
        
        // Definite complex signals
        let complexKeywords = ["refactor", "implement", "build", "deploy", "create a", "write a",
                               "analyze this", "debug", "fix this", "migrate", "architect",
                               "design a", "set up", "configure", "install", "compile"]
        if complexKeywords.contains(where: { msg.contains($0) }) || hasAttachments {
            return HeuristicResult(complexity: .complex, confidence: 0.9)
        }
        
        // Definite simple signals
        let isShortQuestion = wordCount <= 12 && msg.hasSuffix("?")
        let simpleKeywords = ["what is", "what's", "who is", "when did", "how many",
                              "define ", "meaning of", "translate", "convert"]
        if isShortQuestion && simpleKeywords.contains(where: { msg.contains($0) }) {
            return HeuristicResult(complexity: .simple, confidence: 0.9)
        }
        
        // Short casual messages
        if wordCount <= 5 && !msg.contains("code") && !msg.contains("file") {
            return HeuristicResult(complexity: .simple, confidence: 0.85)
        }
        
        // Code-related but not complex
        let codeKeywords = ["explain", "how does", "what does", "difference between"]
        if codeKeywords.contains(where: { msg.contains($0) }) && wordCount < 30 {
            return HeuristicResult(complexity: .medium, confidence: 0.8)
        }
        
        // Long messages are likely complex
        if wordCount > 50 {
            return HeuristicResult(complexity: .complex, confidence: 0.8)
        }
        
        // Uncertain — let Haiku decide
        return HeuristicResult(complexity: .medium, confidence: 0.5)
    }
    
    // MARK: - Haiku Classifier
    
    private func classifyWithHaiku(message: String, backend: BedrockClient, modelId: String) async -> MessageComplexity {
        let classifierPrompt = """
        Classify this user message complexity. Reply with exactly one word: SIMPLE, MEDIUM, or COMPLEX.
        
        SIMPLE: factual questions, definitions, short answers, casual chat, greetings
        MEDIUM: explanations, comparisons, summaries, moderate code questions
        COMPLEX: multi-step tasks, code generation, debugging, tool use, file operations, builds, analysis of large content
        
        Message: \(message.prefix(500))
        """
        
        do {
            let response = try await backend.converse(
                modelId: modelId,
                messages: [.init(content: [.text(classifierPrompt)], role: .user)]
            )
            
            if case .message(let output) = response.output,
               let content = output.content?.first,
               case .text(let text) = content {
                let result = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if result.contains("SIMPLE") { return .simple }
                if result.contains("COMPLEX") { return .complex }
            }
        } catch {
            logger.error("Haiku classifier failed: \(error)")
        }
        
        return .medium // Default fallback
    }
}

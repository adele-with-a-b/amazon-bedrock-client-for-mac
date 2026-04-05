import Foundation
import Logging

/// Routes messages to the appropriate model tier based on complexity
enum MessageComplexity: String {
    case simple   // Quick factual answers, casual chat
    case medium   // Code explanations, moderate analysis
    case complex  // Multi-step tasks, tool use, deep reasoning
}

final class MessageRouter: Sendable {
    static let shared = MessageRouter()
    private let logger = Logger(label: "MessageRouter")
    
    struct ModelTier {
        let simple: String
        let medium: String
        let complex: String
    }
    
    /// Resolve model tier from available models — capability-based, not name-based
    func resolveModelTier(from models: [ChatModel]) -> ModelTier {
        // Rank models by capability tier
        let ranked = models
            .filter { !$0.isAutoRouting }
            .sorted { tierScore($0.id) > tierScore($1.id) }
        
        let complex = ranked.first?.id ?? ""
        let simple = ranked.last?.id ?? complex
        let medium = ranked.count >= 3
            ? ranked[ranked.count / 2].id
            : (ranked.count >= 2 ? ranked[1].id : complex)
        
        return ModelTier(simple: simple, medium: medium, complex: complex)
    }
    
    /// Score a model ID by capability tier (higher = more capable)
    private func tierScore(_ modelId: String) -> Int {
        let id = modelId.lowercased()
        // Top tier
        if id.contains("opus") || id.contains("claude-4") { return 100 }
        // Upper tier
        if id.contains("sonnet") && !id.contains("haiku") { return 80 }
        if id.contains("nova-pro") { return 75 }
        if id.contains("llama-3") && id.contains("70b") { return 70 }
        if id.contains("mistral-large") { return 70 }
        // Mid tier
        if id.contains("nova-lite") { return 50 }
        if id.contains("llama-3") && id.contains("8b") { return 45 }
        if id.contains("mistral") { return 40 }
        // Low tier (fast)
        if id.contains("haiku") { return 20 }
        if id.contains("nova-micro") { return 15 }
        if id.contains("titan-text-lite") { return 10 }
        return 50 // unknown → mid
    }
    
    /// Pure heuristic routing — no API calls, uses conversation context
    func route(
        message: String,
        conversationLength: Int,
        hasAttachments: Bool,
        previousComplexity: MessageComplexity?,
        tier: ModelTier
    ) -> (modelId: String, complexity: MessageComplexity) {
        let result = classify(
            message: message,
            conversationLength: conversationLength,
            hasAttachments: hasAttachments,
            previousComplexity: previousComplexity
        )
        let modelId = modelIdFor(result, tier: tier)
        logger.info("Router: \(result.rawValue) → \(modelId)")
        return (modelId, result)
    }
    
    private func modelIdFor(_ complexity: MessageComplexity, tier: ModelTier) -> String {
        switch complexity {
        case .simple: return tier.simple
        case .medium: return tier.medium
        case .complex: return tier.complex
        }
    }
    
    private func classify(
        message: String,
        conversationLength: Int,
        hasAttachments: Bool,
        previousComplexity: MessageComplexity?
    ) -> MessageComplexity {
        let msg = message.lowercased()
        let wordCount = message.split(separator: " ").count
        
        // Attachments always complex
        if hasAttachments { return .complex }
        
        // Complex signals
        let complexPatterns = ["refactor", "implement", "build", "deploy", "create a", "write a",
                               "analyze", "debug", "fix this", "migrate", "architect",
                               "design a", "set up", "configure", "compile", "explain the code",
                               "review this", "optimize", "test this"]
        if complexPatterns.contains(where: { msg.contains($0) }) { return .complex }
        
        // Long messages are complex
        if wordCount > 50 { return .complex }
        
        // Short follow-ups inherit previous complexity
        // "yes", "do it", "go ahead", "continue", "ok" etc.
        if wordCount <= 5 && conversationLength > 0 {
            if let prev = previousComplexity, prev != .simple {
                return prev
            }
        }
        
        // Simple signals
        let simplePatterns = ["what is", "what's", "who is", "when did", "how many",
                              "define ", "meaning of", "translate", "convert", "hello",
                              "hi", "thanks", "thank you"]
        if simplePatterns.contains(where: { msg.contains($0) }) && wordCount <= 15 {
            return .simple
        }
        
        // Very short questions
        if wordCount <= 8 && msg.hasSuffix("?") { return .simple }
        
        // Code-related but explanatory
        if wordCount < 30 && ["explain", "how does", "what does", "difference between"]
            .contains(where: { msg.contains($0) }) {
            return .medium
        }
        
        return .medium
    }
}

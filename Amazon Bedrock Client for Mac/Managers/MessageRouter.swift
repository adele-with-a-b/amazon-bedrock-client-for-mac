import Foundation
import Logging

enum MessageComplexity: String {
    case simple
    case medium
    case complex
}

final class MessageRouter: Sendable {
    static let shared = MessageRouter()
    private let logger = Logger(label: "MessageRouter")
    
    struct ModelTier {
        let simple: String
        let medium: String
        let complex: String
    }
    
    // Score = (smarts * 0.7) + (cheapness * 0.3)
    // smarts: 0-100, price: $/1M input tokens (lower = cheaper)
    private struct ModelProfile {
        let pattern: String
        let smarts: Int
        let pricePerMInput: Double  // $/1M input tokens
    }
    
    private let knownModels: [ModelProfile] = [
        // Claude family — specific patterns first
        ModelProfile(pattern: "claude-opus-4",    smarts: 98, pricePerMInput: 15.0),
        ModelProfile(pattern: "claude-sonnet-4",  smarts: 92, pricePerMInput: 3.0),
        ModelProfile(pattern: "claude-haiku-4",   smarts: 78, pricePerMInput: 0.80),
        ModelProfile(pattern: "claude-3-5-sonnet", smarts: 88, pricePerMInput: 3.0),
        ModelProfile(pattern: "claude-3-5-haiku", smarts: 72, pricePerMInput: 0.80),
        ModelProfile(pattern: "claude-3-opus",    smarts: 85, pricePerMInput: 15.0),
        ModelProfile(pattern: "claude-3-sonnet",  smarts: 75, pricePerMInput: 3.0),
        ModelProfile(pattern: "claude-3-haiku",   smarts: 65, pricePerMInput: 0.25),
        // Nova family
        ModelProfile(pattern: "nova-pro",     smarts: 70, pricePerMInput: 0.80),
        ModelProfile(pattern: "nova-lite",    smarts: 50, pricePerMInput: 0.06),
        ModelProfile(pattern: "nova-micro",   smarts: 30, pricePerMInput: 0.035),
        // Llama family
        ModelProfile(pattern: "llama.*70b",   smarts: 75, pricePerMInput: 2.65),
        ModelProfile(pattern: "llama.*8b",    smarts: 50, pricePerMInput: 0.22),
        ModelProfile(pattern: "llama",        smarts: 55, pricePerMInput: 0.50),
        // Mistral family
        ModelProfile(pattern: "mistral-large", smarts: 75, pricePerMInput: 4.0),
        ModelProfile(pattern: "mistral",       smarts: 55, pricePerMInput: 0.15),
        // Qwen
        ModelProfile(pattern: "qwen",         smarts: 65, pricePerMInput: 1.0),
        // Titan
        ModelProfile(pattern: "titan-text-premier", smarts: 55, pricePerMInput: 0.50),
        ModelProfile(pattern: "titan-text-lite",    smarts: 30, pricePerMInput: 0.15),
    ]
    
    /// Composite score: smarts weighted 70%, cheapness weighted 30%
    private func compositeScore(for modelId: String) -> Double {
        let id = modelId.lowercased()
        let profile = knownModels.first { id.contains($0.pattern) || id.range(of: $0.pattern, options: .regularExpression) != nil }
        let smarts = Double(profile?.smarts ?? 50)
        let price = profile?.pricePerMInput ?? 1.0
        // Normalize cheapness: $0.035 → 100, $15 → ~0
        let cheapness = max(0, 100.0 - (price * 6.67))
        return (smarts * 0.7) + (cheapness * 0.3)
    }
    
    func resolveModelTier(from models: [ChatModel]) -> ModelTier {
        // Only route to inference profiles (global.*) — these are actually enabled
        // Fall back to all models if no inference profiles exist
        let candidates = models.filter { !$0.isAutoRouting }
        let routable = candidates.filter { $0.id.hasPrefix("global.") || $0.id.hasPrefix("us.") }
        let pool = routable.isEmpty ? candidates : routable
        
        let scored = pool
            .map { (id: $0.id, score: compositeScore(for: $0.id), smarts: smartsScore($0.id)) }
            .sorted { $0.score > $1.score }
        
        guard !scored.isEmpty else {
            return ModelTier(simple: "", medium: "", complex: "")
        }
        
        // Complex: highest smarts regardless of price
        let bySmarts = scored.sorted { $0.smarts > $1.smarts }
        let complex = bySmarts.first!.id
        
        // Medium: best composite score (smart + affordable)
        let medium = scored.first!.id
        
        // Simple: best composite among models with smarts >= 60 (must be competent)
        let competent = scored.filter { $0.smarts >= 60 }
        let simple = competent.last?.id ?? medium  // cheapest competent model
        
        logger.info("Tier resolved: simple=\(simple), medium=\(medium), complex=\(complex) (from \(scored.count) models)")
        return ModelTier(simple: simple, medium: medium, complex: complex)
    }
    
    private func smartsScore(_ modelId: String) -> Int {
        let id = modelId.lowercased()
        let profile = knownModels.first { id.contains($0.pattern) || id.range(of: $0.pattern, options: .regularExpression) != nil }
        return profile?.smarts ?? 50
    }
    
    /// Pure heuristic routing with conversation context
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
        let modelId: String
        switch result {
        case .simple: modelId = tier.simple
        case .medium: modelId = tier.medium
        case .complex: modelId = tier.complex
        }
        logger.info("Router: \(result.rawValue) → \(modelId)")
        return (modelId, result)
    }
    
    private func classify(
        message: String,
        conversationLength: Int,
        hasAttachments: Bool,
        previousComplexity: MessageComplexity?
    ) -> MessageComplexity {
        let msg = message.lowercased()
        let wordCount = message.split(separator: " ").count
        
        if hasAttachments { return .complex }
        
        let complexPatterns = ["refactor", "implement", "build", "deploy", "create a", "write a",
                               "analyze", "debug", "fix this", "migrate", "architect",
                               "design a", "set up", "configure", "compile", "explain the code",
                               "review this", "optimize", "test this"]
        if complexPatterns.contains(where: { msg.contains($0) }) { return .complex }
        if wordCount > 50 { return .complex }
        
        // Short follow-ups inherit previous complexity
        if wordCount <= 5 && conversationLength > 0, let prev = previousComplexity, prev != .simple {
            return prev
        }
        
        let simplePatterns = ["what is", "what's", "who is", "when did", "how many",
                              "define ", "meaning of", "translate", "convert", "hello",
                              "hi", "thanks", "thank you", "weather", "time", "date"]
        if simplePatterns.contains(where: { msg.contains($0) }) && wordCount <= 15 {
            return .simple
        }
        if wordCount <= 8 && msg.hasSuffix("?") { return .simple }
        
        if wordCount < 30 && ["explain", "how does", "what does", "difference between"]
            .contains(where: { msg.contains($0) }) {
            return .medium
        }
        
        return .medium
    }
}

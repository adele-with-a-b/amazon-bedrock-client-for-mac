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
    private let routeLLMURL = URL(string: "http://127.0.0.1:6060/route")!
    
    struct ModelTier {
        let simple: String
        let medium: String
        let complex: String
    }
    
    private struct ModelProfile {
        let pattern: String
        let smarts: Int
        let pricePerMInput: Double
    }
    
    private let knownModels: [ModelProfile] = [
        ModelProfile(pattern: "claude-opus-4",    smarts: 98, pricePerMInput: 15.0),
        ModelProfile(pattern: "claude-sonnet-4",  smarts: 92, pricePerMInput: 3.0),
        ModelProfile(pattern: "claude-haiku-4",   smarts: 78, pricePerMInput: 0.80),
        ModelProfile(pattern: "claude-3-5-sonnet", smarts: 88, pricePerMInput: 3.0),
        ModelProfile(pattern: "claude-3-5-haiku", smarts: 72, pricePerMInput: 0.80),
        ModelProfile(pattern: "claude-3-opus",    smarts: 85, pricePerMInput: 15.0),
        ModelProfile(pattern: "claude-3-sonnet",  smarts: 75, pricePerMInput: 3.0),
        ModelProfile(pattern: "claude-3-haiku",   smarts: 65, pricePerMInput: 0.25),
        ModelProfile(pattern: "nova-pro",     smarts: 70, pricePerMInput: 0.80),
        ModelProfile(pattern: "nova-lite",    smarts: 50, pricePerMInput: 0.06),
        ModelProfile(pattern: "nova-micro",   smarts: 30, pricePerMInput: 0.035),
        ModelProfile(pattern: "llama.*70b",   smarts: 75, pricePerMInput: 2.65),
        ModelProfile(pattern: "llama.*8b",    smarts: 50, pricePerMInput: 0.22),
        ModelProfile(pattern: "llama",        smarts: 55, pricePerMInput: 0.50),
        ModelProfile(pattern: "mistral-large", smarts: 75, pricePerMInput: 4.0),
        ModelProfile(pattern: "mistral",       smarts: 55, pricePerMInput: 0.15),
        ModelProfile(pattern: "qwen",         smarts: 65, pricePerMInput: 1.0),
        ModelProfile(pattern: "titan-text-premier", smarts: 55, pricePerMInput: 0.50),
        ModelProfile(pattern: "titan-text-lite",    smarts: 30, pricePerMInput: 0.15),
    ]
    
    func resolveModelTier(from models: [ChatModel]) -> ModelTier {
        let candidates = models.filter { !$0.isAutoRouting && $0.id.hasPrefix("global.") }
        let pool = candidates.isEmpty ? models.filter { !$0.isAutoRouting } : candidates
        
        guard !pool.isEmpty else { return ModelTier(simple: "", medium: "", complex: "") }
        
        let bySmarts = pool.sorted { smartsScore($0.id) > smartsScore($1.id) }
        let complex = bySmarts.first!.id
        
        let scored = pool.map { (id: $0.id, score: compositeScore(for: $0.id)) }.sorted { $0.score > $1.score }
        let medium = scored.first!.id
        
        let competent = pool.filter { smartsScore($0.id) >= 60 }.sorted { priceScore($0.id) < priceScore($1.id) }
        let simple = competent.first?.id ?? medium
        
        logger.info("Tier resolved: simple=\(simple), medium=\(medium), complex=\(complex) (from \(pool.count) models)")
        return ModelTier(simple: simple, medium: medium, complex: complex)
    }
    
    // MARK: - RouteLLM Integration
    
    /// Route using RouteLLM sidecar, falling back to heuristic
    func route(
        message: String,
        conversationLength: Int,
        hasAttachments: Bool,
        previousComplexity: MessageComplexity?,
        tier: ModelTier
    ) async -> (modelId: String, complexity: MessageComplexity) {
        // Attachments always complex
        if hasAttachments {
            logger.info("Router: complex (attachments) → \(tier.complex)")
            return (tier.complex, .complex)
        }
        
        // Short follow-ups inherit previous complexity
        let wordCount = message.split(separator: " ").count
        if wordCount <= 5 && conversationLength > 0, let prev = previousComplexity, prev != .simple {
            logger.info("Router: \(prev.rawValue) (follow-up) → \(modelIdFor(prev, tier: tier))")
            return (modelIdFor(prev, tier: tier), prev)
        }
        
        // Try RouteLLM sidecar
        if let score = await queryRouteLLM(prompt: message) {
            // score > 0.5 = strong model needed, < 0.5 = weak model fine
            // Map to 3 tiers: <0.44 simple, 0.44-0.47 medium, >0.47 complex
            let complexity: MessageComplexity
            if score < 0.44 {
                complexity = .simple
            } else if score < 0.47 {
                complexity = .medium
            } else {
                complexity = .complex
            }
            let modelId = modelIdFor(complexity, tier: tier)
            logger.info("Router [RouteLLM]: score=\(String(format: "%.3f", score)) → \(complexity.rawValue) → \(modelId)")
            return (modelId, complexity)
        }
        
        // Fallback: heuristic
        let complexity = heuristicClassify(message: message)
        let modelId = modelIdFor(complexity, tier: tier)
        logger.info("Router [heuristic fallback]: \(complexity.rawValue) → \(modelId)")
        return (modelId, complexity)
    }
    
    private func queryRouteLLM(prompt: String) async -> Double? {
        var request = URLRequest(url: routeLLMURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2.0  // fast timeout — don't block the user
        
        let body: [String: Any] = ["prompt": String(prompt.prefix(500))]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let score = json["score"] as? Double else { return nil }
            return score
        } catch {
            logger.debug("RouteLLM sidecar unavailable: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func modelIdFor(_ complexity: MessageComplexity, tier: ModelTier) -> String {
        switch complexity {
        case .simple: return tier.simple
        case .medium: return tier.medium
        case .complex: return tier.complex
        }
    }
    
    // MARK: - Heuristic Fallback
    
    private func heuristicClassify(message: String) -> MessageComplexity {
        let msg = message.lowercased()
        let wordCount = message.split(separator: " ").count
        
        let complexPatterns = ["refactor", "implement", "build", "deploy", "create a", "write a",
                               "analyze", "debug", "fix this", "migrate", "architect",
                               "design a", "set up", "configure", "compile", "review this", "optimize"]
        if complexPatterns.contains(where: { msg.contains($0) }) { return .complex }
        if wordCount > 50 { return .complex }
        
        let simplePatterns = ["what is", "what's", "who is", "when did", "how many",
                              "define ", "meaning of", "translate", "hello", "hi", "thanks"]
        if simplePatterns.contains(where: { msg.contains($0) }) && wordCount <= 15 { return .simple }
        if wordCount <= 8 && msg.hasSuffix("?") { return .simple }
        
        return .medium
    }
    
    // MARK: - Scoring
    
    private func compositeScore(for modelId: String) -> Double {
        let smarts = Double(smartsScore(modelId))
        let price = priceScore(modelId)
        let cheapness = max(0, 100.0 - (price * 6.67))
        return (smarts * 0.7) + (cheapness * 0.3)
    }
    
    private func smartsScore(_ modelId: String) -> Int {
        let id = modelId.lowercased()
        return (knownModels.first { id.contains($0.pattern) || id.range(of: $0.pattern, options: .regularExpression) != nil })?.smarts ?? 50
    }
    
    private func priceScore(_ modelId: String) -> Double {
        let id = modelId.lowercased()
        return (knownModels.first { id.contains($0.pattern) || id.range(of: $0.pattern, options: .regularExpression) != nil })?.pricePerMInput ?? 1.0
    }
}

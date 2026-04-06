//
//  PromptTemplateManager.swift
//  Amazon Bedrock Client for Mac
//
//  Created by Na, Sanghwa on 12/4/25.
//

import Foundation
import Combine
import Logging

// MARK: - System Prompt Template Model
struct SystemPromptTemplate: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var isAgent: Bool
    var promptFile: String?  // file path for agent prompts
    var pinnedModelId: String?  // agent-specified model override
    
    init(id: UUID = UUID(), name: String, content: String, isAgent: Bool = false, promptFile: String? = nil, pinnedModelId: String? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.isAgent = isAgent
        self.promptFile = promptFile
        self.pinnedModelId = pinnedModelId
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    /// Resolves content — loads from file for agents, returns inline content otherwise
    var resolvedContent: String {
        if let path = promptFile {
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? content
        }
        return content
    }
    
    // Default template (empty system prompt)
    static let defaultTemplate = SystemPromptTemplate(
        name: "Default",
        content: ""
    )
    
    // Example templates
    static let examples: [SystemPromptTemplate] = [
        SystemPromptTemplate(
            name: "Concise Assistant",
            content: "You are a helpful assistant. Be concise and direct in your responses. Avoid unnecessary explanations."
        ),
        SystemPromptTemplate(
            name: "Code Expert",
            content: "You are an expert software engineer. Focus on writing clean, efficient, and well-documented code. Always explain your reasoning."
        ),
        SystemPromptTemplate(
            name: "Creative Writer",
            content: "You are a creative writing assistant. Help with storytelling, brainstorming ideas, and improving prose. Be imaginative and engaging."
        )
    ]
}

// MARK: - System Prompt Template Manager
@MainActor
class PromptTemplateManager: ObservableObject {
    static let shared = PromptTemplateManager()
    private var logger = Logger(label: "PromptTemplateManager")
    
    @Published var templates: [SystemPromptTemplate] = [] {
        didSet {
            saveTemplates()
        }
    }
    
    @Published var agents: [SystemPromptTemplate] = []
    
    /// Skills keyed by agent template ID
    private(set) var agentSkills: [UUID: [SkillMetadata]] = [:]
    
    @Published var selectedTemplateId: UUID? {
        didSet {
            if let id = selectedTemplateId,
               let template = allTemplates.first(where: { $0.id == id }) {
                SettingManager.shared.systemPrompt = template.resolvedContent
            }
            saveSelectedTemplate()
        }
    }
    
    private let storageKey = "systemPromptTemplates"
    private let selectedTemplateKey = "selectedSystemPromptTemplateId"
    
    private let agentsDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Amazon Bedrock/agents")
    }()
    
    private init() {
        loadTemplates()
        loadSelectedTemplate()
        loadAgents()
    }
    
    // MARK: - Selected Template
    
    var selectedTemplate: SystemPromptTemplate? {
        guard let id = selectedTemplateId else { return nil }
        return allTemplates.first { $0.id == id }
    }
    
    func selectTemplate(_ template: SystemPromptTemplate) {
        selectedTemplateId = template.id
        logger.info("Selected template: \(template.name)")
    }
    
    // MARK: - CRUD Operations
    
    func addTemplate(_ template: SystemPromptTemplate) {
        templates.append(template)
        logger.info("Added template: \(template.name)")
    }
    
    func addTemplate(name: String, content: String) {
        let template = SystemPromptTemplate(name: name, content: content)
        addTemplate(template)
        // Auto-select the newly created template
        selectTemplate(template)
    }
    
    func updateTemplate(_ template: SystemPromptTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            var updated = template
            updated.updatedAt = Date()
            templates[index] = updated
            
            // If this is the selected template, update system prompt
            if selectedTemplateId == template.id {
                SettingManager.shared.systemPrompt = updated.content
            }
            
            logger.info("Updated template: \(template.name)")
        }
    }
    
    func deleteTemplate(_ template: SystemPromptTemplate) {
        // Don't allow deleting if it's the only template
        guard templates.count > 1 else {
            logger.warning("Cannot delete the only template")
            return
        }
        
        templates.removeAll { $0.id == template.id }
        
        // If deleted template was selected, select the first one
        if selectedTemplateId == template.id {
            selectedTemplateId = templates.first?.id
        }
        
        logger.info("Deleted template: \(template.name)")
    }
    
    func deleteTemplate(at offsets: IndexSet) {
        guard templates.count > offsets.count else { return }
        
        let deletedIds = offsets.map { templates[$0].id }
        templates.remove(atOffsets: offsets)
        
        if let selectedId = selectedTemplateId, deletedIds.contains(selectedId) {
            selectedTemplateId = templates.first?.id
        }
    }
    
    // MARK: - Persistence
    
    private func loadTemplates() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SystemPromptTemplate].self, from: data),
           !decoded.isEmpty {
            self.templates = decoded
            logger.info("Loaded \(decoded.count) templates")
        } else {
            // First launch - create default template with current system prompt
            let currentPrompt = SettingManager.shared.systemPrompt
            let defaultTemplate = SystemPromptTemplate(
                name: "Default",
                content: currentPrompt
            )
            self.templates = [defaultTemplate]
            self.selectedTemplateId = defaultTemplate.id
            logger.info("Initialized with default template")
        }
    }
    
    private func saveTemplates() {
        if let encoded = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
            logger.debug("Saved \(templates.count) templates")
        }
    }
    
    private func loadSelectedTemplate() {
        if let idString = UserDefaults.standard.string(forKey: selectedTemplateKey),
           let id = UUID(uuidString: idString),
           allTemplates.contains(where: { $0.id == id }) {
            self.selectedTemplateId = id
        } else {
            // Select first template by default
            self.selectedTemplateId = templates.first?.id
        }
    }
    
    private func saveSelectedTemplate() {
        if let id = selectedTemplateId {
            UserDefaults.standard.set(id.uuidString, forKey: selectedTemplateKey)
        }
    }
    
    // MARK: - Agent Loading
    
    private struct AgentConfigFile: Codable {
        let name: String
        let description: String
        let prompt: String  // file:// URI or inline
        let resources: [String]?  // file:// and skill:// URIs
        let model: String?  // optional model ID to pin agent to
    }
    
    struct SkillMetadata: Identifiable {
        let id = UUID()
        let name: String
        let description: String
        let filePath: String
        
        /// Load full skill content on demand
        var content: String? {
            try? String(contentsOfFile: filePath, encoding: .utf8)
        }
        
        /// Check if user message matches this skill's triggers
        func matches(_ userMessage: String) -> Bool {
            let lower = userMessage.lowercased()
            let stopWords: Set<String> = ["when", "this", "that", "with", "from", "have", "been",
                                          "will", "would", "could", "should", "also", "about",
                                          "their", "them", "they", "your", "more", "some", "other",
                                          "into", "over", "such", "than", "only", "very", "just",
                                          "like", "make", "made", "does", "doing", "each", "help",
                                          "work", "working", "using", "used", "asked", "want",
                                          "file", "files", "need", "want", "know", "what", "how"]
            let keywords = description.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
            let uniqueKeywords = Set(keywords)
            let hits = uniqueKeywords.filter { lower.contains($0) }.count
            return hits >= 2
        }
    }
    
    /// Generates a deterministic UUID from a string (SHA-256 based, stable across launches)
    private static func deterministicUUID(from input: String) -> UUID {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            // Simple hash using CC_SHA256 via CryptoKit-free approach
            // Use the string bytes directly to build a stable 16-byte value
            let bytes = Array(buf.bindMemory(to: UInt8.self))
            for (i, byte) in bytes.enumerated() {
                hash[i % 16] = hash[i % 16] &+ byte
                hash[i % 16] ^= byte &* UInt8(truncatingIfNeeded: i &+ 1)
            }
        }
        // Set version 4 and variant bits for valid UUID format
        hash[6] = (hash[6] & 0x0F) | 0x40  // version 4
        hash[8] = (hash[8] & 0x3F) | 0x80  // variant 1
        let uuid = UUID(uuid: (hash[0], hash[1], hash[2], hash[3],
                                hash[4], hash[5], hash[6], hash[7],
                                hash[8], hash[9], hash[10], hash[11],
                                hash[12], hash[13], hash[14], hash[15]))
        return uuid
    }
    
    /// Parse YAML frontmatter from a skill .md file
    private static func parseSkillFrontmatter(at path: String) -> SkillMetadata? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Frontmatter is between first --- and second ---
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        
        var name: String?
        var description: String?
        
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("description:") {
                description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard let n = name, let d = description else { return nil }
        return SkillMetadata(name: n, description: d, filePath: path)
    }
    
    func loadAgents() {
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else { return }
        
        agents = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SystemPromptTemplate? in
                guard let data = try? Data(contentsOf: url),
                      let config = try? JSONDecoder().decode(AgentConfigFile.self, from: data) else { return nil }
                
                let promptFile: String?
                if config.prompt.hasPrefix("file://") {
                    promptFile = String(config.prompt.dropFirst(7))
                } else {
                    promptFile = nil
                }
                
                // Stable ID derived from filename so it survives app restarts
                let stableId = Self.deterministicUUID(from: url.lastPathComponent)
                
                let template = SystemPromptTemplate(
                    id: stableId,
                    name: config.name,
                    content: config.description,
                    isAgent: true,
                    promptFile: promptFile,
                    pinnedModelId: config.model
                )
                
                // Parse skill:// resources
                let skills = (config.resources ?? [])
                    .filter { $0.hasPrefix("skill://") }
                    .compactMap { uri -> SkillMetadata? in
                        let path = String(uri.dropFirst(8))  // drop "skill://"
                        return Self.parseSkillFrontmatter(at: path)
                    }
                
                if !skills.isEmpty {
                    agentSkills[template.id] = skills
                    logger.info("Agent '\(config.name)': loaded \(skills.count) skills")
                }
                
                return template
            }
            .sorted { $0.name < $1.name }
        
        logger.info("Loaded \(agents.count) agents from \(agentsDir.path)")
    }
    
    /// All available options: user templates + agents
    var allTemplates: [SystemPromptTemplate] {
        templates + agents
    }
    
    var agentsDirectory: URL { agentsDir }
    
    /// Names of skills triggered on the last message (for UI display)
    @Published var lastTriggeredSkills: [String] = []
    
    /// Get skills that match a user message for the currently selected agent
    /// Supports force-invoke with @skill:SkillName prefix
    func matchedSkillContent(for userMessage: String) -> String? {
        guard let id = selectedTemplateId,
              let skills = agentSkills[id] else {
            lastTriggeredSkills = []
            return nil
        }
        
        // Check for force-invoke: @skill:Name
        let forcePattern = "@skill:"
        var matched: [SkillMetadata] = []
        if userMessage.hasPrefix(forcePattern) {
            let nameEnd = userMessage.index(forcePattern.endIndex, offsetBy: 0)
            let rest = userMessage[nameEnd...]
            let forceName = String(rest.prefix(while: { !$0.isWhitespace }))
            if let skill = skills.first(where: { $0.name.lowercased() == forceName.lowercased() }) {
                matched = [skill]
                logger.info("Skill force-invoked: \(skill.name)")
            }
        }
        
        // Fall back to keyword matching
        if matched.isEmpty {
            matched = skills.filter { $0.matches(userMessage) }
        }
        
        guard !matched.isEmpty else {
            logger.debug("Skills: no match for '\(userMessage.prefix(60))' against \(skills.count) skills")
            lastTriggeredSkills = []
            return nil
        }
        
        lastTriggeredSkills = matched.map { $0.name }
        logger.info("Skills triggered: \(lastTriggeredSkills.joined(separator: ", ")) for '\(userMessage.prefix(60))'")
        
        let contents = matched.compactMap { skill -> String? in
            guard let content = skill.content else { return nil }
            return "# Skill: \(skill.name)\n\n\(content)"
        }
        
        return contents.isEmpty ? nil : "\n\n---\n\n" + contents.joined(separator: "\n\n---\n\n")
    }
    
    // MARK: - Import Examples
    
    func importExampleTemplates() {
        for example in SystemPromptTemplate.examples {
            if !templates.contains(where: { $0.name == example.name }) {
                templates.append(example)
            }
        }
        logger.info("Imported example templates")
    }
}

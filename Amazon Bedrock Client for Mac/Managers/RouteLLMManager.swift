//
//  RouteLLMManager.swift
//  Amazon Bedrock Client for Mac
//
//  Manages the RouteLLM BERT sidecar process lifecycle.
//  Launches on app start, kills on app quit. Binds to 127.0.0.1 only.
//

import Foundation
import Logging

final class RouteLLMManager: @unchecked Sendable {
    static let shared = RouteLLMManager()
    private var process: Process?
    private let logger = Logger(label: "RouteLLMManager")
    private let port = 6060
    private let lock = NSLock()
    
    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Amazon Bedrock")
    }
    
    private var venvPython: String {
        appSupportDir.appendingPathComponent("routellm-env/bin/python3").path
    }
    
    private var serverScript: String {
        appSupportDir.appendingPathComponent("routellm-server.py").path
    }
    
    func start() {
        // Don't start if already running or files missing
        guard process == nil || process?.isRunning != true else { return }
        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            logger.info("RouteLLM sidecar not installed (missing venv or script), skipping")
            return
        }
        
        // Kill any orphaned sidecar from a previous crash
        killOrphaned()
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [serverScript]
        proc.currentDirectoryURL = appSupportDir
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        
        do {
            try proc.run()
            process = proc
            logger.info("RouteLLM sidecar started (pid \(proc.processIdentifier), port \(port))")
        } catch {
            logger.error("Failed to start RouteLLM sidecar: \(error)")
        }
    }
    
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        proc.waitUntilExit()
        process = nil
        logger.info("RouteLLM sidecar stopped")
    }
    
    /// Kill any orphaned routellm-server.py processes not managed by us
    private func killOrphaned() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "routellm-server.py"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}

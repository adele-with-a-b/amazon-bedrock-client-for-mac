//
//  RouteLLMManager.swift
//  Amazon Bedrock Client for Mac
//
//  Manages the RouteLLM BERT sidecar process lifecycle.
//  On first launch: copies bundled script, creates venv, installs deps.
//  Launches on app start, kills on app quit. Binds to 127.0.0.1 only.
//

import Foundation
import Logging

final class RouteLLMManager: @unchecked Sendable {
    static let shared = RouteLLMManager()
    private var process: Process?
    private let logger = Logger(label: "RouteLLMManager")
    private let lock = NSLock()
    
    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Amazon Bedrock")
    }
    
    private var venvDir: URL { appSupportDir.appendingPathComponent("routellm-env") }
    private var venvPython: String { venvDir.appendingPathComponent("bin/python3").path }
    private var serverScript: String { appSupportDir.appendingPathComponent("routellm-server.py").path }
    
    /// Start the sidecar. Runs setup in background if needed, then launches.
    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            defer { lock.unlock() }
            
            guard process == nil || process?.isRunning != true else { return }
            
            killOrphaned()
            
            // Copy bundled script to App Support if missing or outdated
            copyBundledScript()
            
            // Create venv + install deps if missing
            if !FileManager.default.fileExists(atPath: venvPython) {
                logger.info("RouteLLM venv not found, setting up (this may take a minute)...")
                guard setupVenv() else {
                    logger.error("RouteLLM venv setup failed, sidecar disabled")
                    return
                }
            }
            
            guard FileManager.default.fileExists(atPath: serverScript) else {
                logger.info("RouteLLM server script not found, sidecar disabled")
                return
            }
            
            launch()
        }
    }
    
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        proc.waitUntilExit()
        process = nil
        logger.info("RouteLLM sidecar stopped")
    }
    
    // MARK: - Private
    
    private func copyBundledScript() {
        guard let bundled = Bundle.main.path(forResource: "routellm-server", ofType: "py") else {
            logger.debug("No bundled routellm-server.py found in app bundle")
            return
        }
        let dest = appSupportDir.appendingPathComponent("routellm-server.py").path
        // Always overwrite with latest bundled version
        try? FileManager.default.removeItem(atPath: dest)
        try? FileManager.default.copyItem(atPath: bundled, toPath: dest)
    }
    
    private func setupVenv() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        // Find python3
        let pythonPaths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = pythonPaths.first(where: { fm.fileExists(atPath: $0) }) else {
            logger.error("No python3 found on system")
            return false
        }
        
        // Create venv
        if !run(python, args: ["-m", "venv", venvDir.path]) {
            logger.error("Failed to create venv")
            return false
        }
        
        // Install deps
        let pip = venvDir.appendingPathComponent("bin/pip3").path
        if !run(pip, args: ["install", "--quiet", "flask", "routellm[bert]"]) {
            logger.error("Failed to install routellm dependencies")
            // Clean up broken venv
            try? fm.removeItem(at: venvDir)
            return false
        }
        
        logger.info("RouteLLM venv setup complete")
        return true
    }
    
    private func launch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [serverScript]
        proc.currentDirectoryURL = appSupportDir
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        
        do {
            try proc.run()
            process = proc
            logger.info("RouteLLM sidecar started (pid \(proc.processIdentifier), port 6060)")
        } catch {
            logger.error("Failed to start RouteLLM sidecar: \(error)")
        }
    }
    
    private func killOrphaned() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "routellm-server.py"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
    
    /// Run a command synchronously, return success
    private func run(_ executable: String, args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        // Capture stderr for debugging
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                logger.error("Command failed (\(executable)): \(errStr.prefix(500))")
            }
            return proc.terminationStatus == 0
        } catch {
            logger.error("Failed to run \(executable): \(error)")
            return false
        }
    }
}

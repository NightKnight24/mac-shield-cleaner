import SwiftUI
import AppKit
import Foundation
import ServiceManagement

// MARK: - Data Models

struct ShieldTelemetry: Codable {
    let active: Bool
    let mode: String?
    let interface: String?
    let gateway: String?
    let gateway_mac: String?
    let arp_locked: Bool?
    let usb_speed: String?
    let cable_speed: String?
    let router_ms: Double?
    let ping_ms: Double?
    let rx_bps: Int?
    let tx_bps: Int?
    let active_apps: [String]?
    let stremio_4k_clients: Int?
    let spoof_count: Int?
    let spoof_alert: Bool?
    let timestamp: String?
    let restored: Bool?
}

struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let badge: String?
    let requiresAdmin: Bool
    var kb: Int64
    var isSelected: Bool
}

struct TopStorageItem: Identifiable, Codable {
    var id: String { path }
    let label: String
    let path: String
    let kb: Int64
}

struct ScanResponse: Codable {
    let total_kb: Int64
    let free_kb: Int64
    let used_kb: Int64
    let open_apps: [String]
    let categories: [String: Int64]
    let top_items: [TopStorageItem]
}

struct CleanSummary {
    let beforeKB: Int64
    let afterKB: Int64
    let cleanedKB: Int64
    let skippedApps: [String]
}

struct ExternalDriveInfo: Identifiable, Hashable {
    var id: String { mountPath }
    let name: String
    let mountPath: String
    let formatName: String
    var totalKB: Int64
    var freeKB: Int64
    var usedKB: Int64 { max(totalKB - freeKB, 0) }
}

struct ExternalScanResponse: Codable {
    let mount: String
    let total_kb: Int64
    let free_kb: Int64
    let used_kb: Int64
    let dot_sample_count: Int
    let categories: [String: Int64]
}

// MARK: - Formatting Helpers

func formatKB(_ kb: Int64) -> String {
    if kb >= 1_048_576 {
        return String(format: "%.2f GB", Double(kb) / 1_048_576.0)
    } else if kb >= 1024 {
        return String(format: "%.1f MB", Double(kb) / 1024.0)
    } else {
        return "\(kb) KB"
    }
}

func formatBPS(_ bps: Int) -> String {
    if bps >= 1_048_576 {
        return String(format: "%.1f MB/s", Double(bps) / 1_048_576.0)
    } else if bps >= 1024 {
        return String(format: "%.1f KB/s", Double(bps) / 1024.0)
    } else {
        return "\(bps) B/s"
    }
}

// MARK: - Helpers (Streaming & Login Item & Update Checker)

private func runLineStreamingBash(
    scriptPath: String,
    arguments: [String],
    onProgress: @escaping @Sendable (Double, String) -> Void
) -> (cleanedKB: Int64, beforeKB: Int64, afterKB: Int64, skipped: [String], stderr: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [scriptPath] + arguments
    let pipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = errPipe

    var cleanedKB: Int64 = 0
    var beforeKB: Int64 = 0
    var afterKB: Int64 = 0
    var skipped: [String] = []

    func handleLine(_ s: String) {
        if s.hasPrefix("PROGRESS|") {
            let parts = s.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count == 3, let pct = Double(parts[1]) {
                onProgress(pct, parts[2])
            }
        } else if s.hasPrefix("RESULT|") {
            let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 5 {
                beforeKB = Int64(parts[1]) ?? beforeKB
                afterKB = Int64(parts[2]) ?? afterKB
                cleanedKB += Int64(parts[3]) ?? 0
                skipped = parts[4].split(separator: "|").map(String.init).filter { !$0.hasPrefix("com.apple.") }
            }
        }
    }

    do {
        try proc.run()
        var lineBuffer = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            lineBuffer.append(chunk)
            while let nlIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nlIndex)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nlIndex)
                if let s = String(data: lineData, encoding: .utf8) {
                    handleLine(s)
                }
            }
        }
        if !lineBuffer.isEmpty, let s = String(data: lineBuffer, encoding: .utf8) {
            handleLine(s)
        }
        proc.waitUntilExit()
    } catch {
        return (0, 0, 0, [], error.localizedDescription)
    }

    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (cleanedKB, beforeKB, afterKB, skipped, errStr)
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var statusMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        let st = SMAppService.mainApp.status
        isEnabled = (st == .enabled || st == .requiresApproval)
        if st == .requiresApproval {
            statusMessage = "Approve in System Settings → General → Login Items"
        } else {
            statusMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusMessage = "Login item requires running from /Applications (\(error.localizedDescription))"
        }
    }
}

private struct GitHubLatestRelease: Codable {
    let tag_name: String
    let html_url: String
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var isChecking: Bool = false
    @Published var updateAvailableVersion: String?
    @Published var releaseURL: URL = URL(string: "https://github.com/NightKnight24/mac-shield-cleaner/releases/latest")!
    @Published var statusText: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    }

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let rParts = remote.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").compactMap { Int($0) }
        let lParts = local.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").compactMap { Int($0) }
        let maxCount = max(rParts.count, lParts.count)
        for i in 0..<maxCount {
            let rv = i < rParts.count ? rParts[i] : 0
            let lv = i < lParts.count ? lParts[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isChecking else { return }
        guard let url = URL(string: "https://api.github.com/repos/NightKnight24/mac-shield-cleaner/releases/latest") else { return }
        isChecking = true
        if !silent { statusText = "Checking GitHub..." }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacShieldCleaner/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false
                if let error = error {
                    if !silent { self.statusText = "Update check failed: \(error.localizedDescription)" }
                    return
                }
                guard let data = data,
                      let rel = try? JSONDecoder().decode(GitHubLatestRelease.self, from: data) else {
                    if !silent { self.statusText = "Could not parse release info" }
                    return
                }
                if let parsedURL = URL(string: rel.html_url) {
                    self.releaseURL = parsedURL
                }
                if self.isNewerVersion(rel.tag_name, than: self.currentVersion) {
                    self.updateAvailableVersion = rel.tag_name
                    self.statusText = "Update available: \(rel.tag_name)"
                } else {
                    self.updateAvailableVersion = nil
                    if !silent { self.statusText = "Up to date (v\(self.currentVersion))" }
                }
            }
        }.resume()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(releaseURL)
    }
}

// MARK: - Shield ViewModel

@MainActor
final class ShieldViewModel: ObservableObject {
    @Published var isActive: Bool = false
    @Published var isTransitioning: Bool = false
    @Published var selectedMode: String = UserDefaults.standard.string(forKey: "shield.selectedMode") ?? "gaming" {
        didSet { UserDefaults.standard.set(selectedMode, forKey: "shield.selectedMode") }
    }
    @Published var lockGatewayARP: Bool = (UserDefaults.standard.object(forKey: "shield.lockGatewayARP") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(lockGatewayARP, forKey: "shield.lockGatewayARP") }
    }
    @Published var customGatewayMAC: String = UserDefaults.standard.string(forKey: "shield.customGatewayMAC") ?? "" {
        didSet { UserDefaults.standard.set(customGatewayMAC, forKey: "shield.customGatewayMAC") }
    }
    @Published var watchSpoofMAC: String = UserDefaults.standard.string(forKey: "shield.watchSpoofMAC") ?? "" {
        didSet { UserDefaults.standard.set(watchSpoofMAC, forKey: "shield.watchSpoofMAC") }
    }
    @Published var telemetry: ShieldTelemetry?
    @Published var pingHistory: [Double] = []
    @Published var logs: [String] = []
    @Published var errorMessage: String?

    private let stopFile = "/tmp/mac_shield_stop"
    private let telemFile = "/tmp/mac_shield_telemetry.json"
    private let logFile = "/tmp/mac_shield_live.log"
    private let pidFile = "/tmp/mac_shield_engine.pid"
    private var pollTimer: Timer?
    private var shieldStartedAt: Date?

    var onStatusChange: ((Bool, String) -> Void)?
    var onTelemetryUpdate: ((ShieldTelemetry) -> Void)?

    var pingJitter: Double? {
        guard pingHistory.count >= 2 else { return nil }
        var totalDiff = 0.0
        for i in 1..<pingHistory.count {
            totalDiff += abs(pingHistory[i] - pingHistory[i - 1])
        }
        return totalDiff / Double(pingHistory.count - 1)
    }

    var pingMin: Double? { pingHistory.min() }
    var pingAvg: Double? {
        guard !pingHistory.isEmpty else { return nil }
        return pingHistory.reduce(0, +) / Double(pingHistory.count)
    }

    init() {
        checkExistingEngine()
    }

    private func isValidMAC(_ s: String) -> Bool {
        s.range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func checkExistingEngine() {
        if FileManager.default.fileExists(atPath: pidFile),
           let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr),
           isProcessAlive(pid) {
            isActive = true
            shieldStartedAt = Date()
            startPolling()
        }
    }

    func startShield() {
        guard !isTransitioning else { return }
        guard let scriptPath = Bundle.main.resourcePath.map({ $0 + "/shield_engine.sh" }),
              FileManager.default.fileExists(atPath: scriptPath) else {
            errorMessage = "Missing shield_engine.sh inside app bundle."
            return
        }

        errorMessage = nil
        isTransitioning = true
        try? FileManager.default.removeItem(atPath: stopFile)
        try? FileManager.default.removeItem(atPath: telemFile)

        let mode = selectedMode
        let appPid = ProcessInfo.processInfo.processIdentifier
        let user = NSUserName()
        let home = NSHomeDirectory()
        let lockArg = lockGatewayARP ? "1" : "0"

        let escapedScript = scriptPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedHome = home.replacingOccurrences(of: "'", with: "'\\''")
        let escapedUser = user.replacingOccurrences(of: "'", with: "'\\''")

        let cleanGW = customGatewayMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSpoof = watchSpoofMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanGW.isEmpty && !isValidMAC(cleanGW) {
            errorMessage = "Invalid Gateway MAC format (expected xx:xx:xx:xx:xx:xx)."
            isTransitioning = false
            return
        }
        if !cleanSpoof.isEmpty && !isValidMAC(cleanSpoof) {
            errorMessage = "Invalid Spoofer MAC format (expected xx:xx:xx:xx:xx:xx)."
            isTransitioning = false
            return
        }

        pingHistory.removeAll()
        var extraFlags = " --lock-arp \(lockArg)"
        if !cleanGW.isEmpty {
            extraFlags += " --gateway-mac '\(cleanGW)'"
        }
        if !cleanSpoof.isEmpty {
            extraFlags += " --spoof-mac '\(cleanSpoof)'"
        }

        let innerCmd = "'\(escapedScript)' --mode \(mode) --app-pid \(appPid) --stop-file '\(stopFile)' --user '\(escapedUser)' --home '\(escapedHome)'\(extraFlags) </dev/null >/tmp/mac_shield_boot.log 2>&1 &"
        let appleScript = "do shell script \"/bin/bash -c \\\"\(innerCmd.replacingOccurrences(of: "\"", with: "\\\""))\\\"\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScript]
            let errPipe = Pipe()
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let status = proc.terminationStatus
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isTransitioning = false
                    if status == 0 {
                        self.shieldStartedAt = Date()
                        self.isActive = true
                        self.startPolling()
                        self.onStatusChange?(true, mode)
                    } else if !errStr.lowercased().contains("user canceled") {
                        self.errorMessage = errStr.isEmpty ? "Failed to obtain admin privileges." : errStr
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isTransitioning = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stopShield() {
        guard isActive, !isTransitioning else { return }
        isTransitioning = true
        try? "stop".write(toFile: stopFile, atomically: true, encoding: .utf8)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.15)
                if !FileManager.default.fileExists(atPath: self.pidFile) {
                    break
                }
            }
            DispatchQueue.main.async {
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.shieldStartedAt = nil
                self.pingHistory.removeAll()
                self.isActive = false
                self.isTransitioning = false
                self.readLogs()
                self.onStatusChange?(false, self.selectedMode)
            }
        }
    }

    func stopSynchronouslyOnQuit() {
        guard isActive else { return }
        try? "stop".write(toFile: stopFile, atomically: true, encoding: .utf8)
        for _ in 0..<25 {
            if !FileManager.default.fileExists(atPath: pidFile) {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTelemetry()
            }
        }
        refreshTelemetry()
    }

    private func refreshTelemetry() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: telemFile)),
           let decoded = try? JSONDecoder().decode(ShieldTelemetry.self, from: data) {
            telemetry = decoded
            if decoded.restored == true && !decoded.active {
                isActive = false
                shieldStartedAt = nil
                pingHistory.removeAll()
                pollTimer?.invalidate()
                pollTimer = nil
                onStatusChange?(false, selectedMode)
            } else if decoded.active {
                if let p = decoded.ping_ms {
                    pingHistory.append(p)
                    if pingHistory.count > 20 { pingHistory.removeFirst() }
                }
                onTelemetryUpdate?(decoded)
            }
        } else if isActive, let startedAt = shieldStartedAt, Date().timeIntervalSince(startedAt) > 12 {
            let pidAlive: Bool
            if let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidStr) {
                pidAlive = isProcessAlive(pid)
            } else {
                pidAlive = false
            }
            if !pidAlive {
                isActive = false
                shieldStartedAt = nil
                pingHistory.removeAll()
                pollTimer?.invalidate()
                pollTimer = nil
                errorMessage = "Shield engine stopped unexpectedly (see /tmp/mac_shield_boot.log)"
                onStatusChange?(false, selectedMode)
            }
        }
        readLogs()
    }

    private func readLogs() {
        if let text = try? String(contentsOfFile: logFile, encoding: .utf8) {
            let lines = text.split(separator: "\n").map(String.init)
            logs = Array(lines.suffix(120))
        }
    }
}

// MARK: - Cleaner ViewModel

@MainActor
final class CleanerViewModel: ObservableObject {
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var progress: Double = 0
    @Published var statusText: String = "Ready to scan storage & System Data"
    @Published var totalKB: Int64 = 0
    @Published var freeKB: Int64 = 0
    @Published var usedKB: Int64 = 0
    @Published var openApps: [String] = []
    @Published var topItems: [TopStorageItem] = []
    @Published var cleanSummary: CleanSummary?
    @Published var errorMessage: String?

    private var hasLoadedPrefs = false
    private let prefsKey = "cleaner.catSelection"

    @Published var categories: [CleanCategory] = [
        CleanCategory(id: "app_caches", title: "App Caches", subtitle: "~/Library/Caches (open apps safely skipped)", icon: "shippingbox.fill", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "containers", title: "Sandboxed Containers & Mail", subtitle: "Containers, Group Containers & Mail Downloads", icon: "square.stack.3d.up.fill", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "browsers", title: "Web Browser Caches", subtitle: "Chrome, Brave, Edge, Arc, Vivaldi (keeps cookies/logins)", icon: "globe", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "desktop_app_support", title: "Desktop & Electron App Caches", subtitle: "Discord, Steam, Heroic caches (never touches saves/bottles)", icon: "macwindow", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "system_user_temp", title: "User System Caches & Temp Files", subtitle: "/var/folders caches, $TMPDIR, /private/tmp leftovers", icon: "clock.arrow.circlepath", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "bottles", title: "CrossOver / Wine Bottle Temp", subtitle: "Windows temp, crash dumps & Steam-in-Wine web cache", icon: "wineglass.fill", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "dev_caches", title: "Developer & Package Caches", subtitle: "Homebrew, uv, npm, pip, Go, Cargo, Xcode DerivedData", icon: "hammer.fill", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "system_data_bloat", title: "System Data Heavy Hitters", subtitle: "Chrome AI Model (4GB), 4K Aerial Wallpapers, Clones, Old Discord", icon: "sparkles", badge: "System Data", requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "logs", title: "Logs, QuickLook & DNS Cache", subtitle: "~/Library/Logs, thumbnail & DNS resolver cache", icon: "doc.text.magnifyingglass", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "shaders", title: "GPU Shader Caches", subtitle: "d3dm & Metal shader caches (rebuilds on next launch)", icon: "cpu.fill", badge: "Optional", requiresAdmin: false, kb: 0, isSelected: false),
        CleanCategory(id: "trash", title: "Empty Trash", subtitle: "Permanently deletes items in ~/.Trash", icon: "trash.fill", badge: "Optional", requiresAdmin: false, kb: 0, isSelected: false),
        CleanCategory(id: "system_wide", title: "System-Wide Caches & APFS Snapshots", subtitle: "/Library/Caches, DiagnosticReports, /var/log, tmutil snapshots", icon: "lock.shield.fill", badge: "Admin", requiresAdmin: true, kb: 0, isSelected: false)
    ] {
        didSet { saveCategorySelection() }
    }

    var selectedTotalKB: Int64 {
        categories.filter(\.isSelected).reduce(0) { $0 + $1.kb }
    }

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: prefsKey) as? [String: Bool] {
            for i in categories.indices {
                if let val = saved[categories[i].id] {
                    categories[i].isSelected = val
                }
            }
        }
        hasLoadedPrefs = true
        scan()
    }

    private func saveCategorySelection() {
        guard hasLoadedPrefs else { return }
        let dict = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.isSelected) })
        UserDefaults.standard.set(dict, forKey: prefsKey)
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        guard let scriptPath = Bundle.main.resourcePath.map({ $0 + "/cleaner_engine.sh" }) else { return }

        isScanning = true
        errorMessage = nil
        statusText = "Scanning System Data, caches & storage..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath, "--scan"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let exitStatus = proc.terminationStatus

                if exitStatus == 0, let decoded = try? JSONDecoder().decode(ScanResponse.self, from: data) {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.totalKB = decoded.total_kb
                        self.freeKB = decoded.free_kb
                        self.usedKB = decoded.used_kb
                        self.openApps = decoded.open_apps
                        self.topItems = decoded.top_items
                        for i in self.categories.indices {
                            let id = self.categories[i].id
                            self.categories[i].kb = decoded.categories[id] ?? 0
                        }
                        self.isScanning = false
                        self.statusText = "Scan complete — select items to clean"
                    }
                } else {
                    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    DispatchQueue.main.async {
                        self?.isScanning = false
                        self?.statusText = "Scan failed"
                        self?.errorMessage = errStr.isEmpty ? "Storage scan failed (exit code \(exitStatus))." : errStr
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isScanning = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func quitOpenApps() {
        let running = NSWorkspace.shared.runningApplications
        var targets = Set(openApps.map { $0.lowercased() })
        if targets.contains("steam_osx") {
            targets.insert("steam")
        }
        for app in running {
            let locName = app.localizedName?.lowercased() ?? ""
            let execName = app.executableURL?.deletingPathExtension().lastPathComponent.lowercased() ?? ""
            if (!locName.isEmpty && targets.contains(locName)) || (!execName.isEmpty && targets.contains(execName)) {
                app.terminate()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            self.scan()
        }
    }

    func cleanSelected() {
        guard !isCleaning, !isScanning else { return }
        guard let scriptPath = Bundle.main.resourcePath.map({ $0 + "/cleaner_engine.sh" }) else { return }

        let selectedIDs = categories.filter(\.isSelected).map(\.id)
        guard !selectedIDs.isEmpty else { return }

        let needsAdmin = selectedIDs.contains("system_wide")
        let userCats = selectedIDs.filter { $0 != "system_wide" }

        isCleaning = true
        cleanSummary = nil
        errorMessage = nil
        progress = 0.05
        statusText = "Preparing cleanup..."

        let startFreeKB = freeKB

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var totalCleanedKB: Int64 = 0
            var skipped: [String] = []

            if !userCats.isEmpty {
                let res = runLineStreamingBash(
                    scriptPath: scriptPath,
                    arguments: ["--clean", "--cats", userCats.joined(separator: ",")]
                ) { [weak self] pct, text in
                    DispatchQueue.main.async {
                        self?.progress = min(pct / 100.0, needsAdmin ? 0.88 : 0.98)
                        self?.statusText = text
                    }
                }
                totalCleanedKB += res.cleanedKB
                skipped = res.skipped
            }

            if needsAdmin {
                DispatchQueue.main.async {
                    self?.statusText = "Requesting admin approval for System-Wide & Snapshot clean..."
                    self?.progress = 0.90
                }
                let escapedScript = scriptPath.replacingOccurrences(of: "'", with: "'\\''")
                let cmd = "'\(escapedScript)' --clean --cats system_wide"
                let appleScript = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
                let adminProc = Process()
                adminProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                adminProc.arguments = ["-e", appleScript]
                let outPipe = Pipe()
                adminProc.standardOutput = outPipe
                try? adminProc.run()
                adminProc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let outStr = String(data: data, encoding: .utf8) {
                    for line in outStr.split(separator: "\n") where line.hasPrefix("RESULT|") {
                        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        if parts.count >= 4 {
                            let before = Int64(parts[1]) ?? 0
                            let after = Int64(parts[2]) ?? 0
                            if after > before {
                                totalCleanedKB += (after - before)
                            }
                        }
                    }
                }
            }

            let dfProc = Process()
            dfProc.executableURL = URL(fileURLWithPath: "/bin/df")
            dfProc.arguments = ["-k", "/"]
            let dfPipe = Pipe()
            dfProc.standardOutput = dfPipe
            try? dfProc.run()
            dfProc.waitUntilExit()
            let dfOut = String(data: dfPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var finalFreeKB = startFreeKB
            let lines = dfOut.split(separator: "\n")
            if lines.count >= 2 {
                let cols = lines[1].split(separator: " ", omittingEmptySubsequences: true)
                if cols.count >= 4, let parsed = Int64(cols[3]) {
                    finalFreeKB = parsed
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progress = 1.0
                self.isCleaning = false
                self.freeKB = finalFreeKB
                self.cleanSummary = CleanSummary(
                    beforeKB: startFreeKB,
                    afterKB: finalFreeKB,
                    cleanedKB: totalCleanedKB,
                    skippedApps: skipped
                )
                self.statusText = "Cleanup finished!"
                self.scan()
            }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - External Drives ViewModel

@MainActor
final class ExternalDrivesViewModel: ObservableObject {
    @Published var drives: [ExternalDriveInfo] = []
    @Published var selectedMount: String?
    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var progress: Double = 0
    @Published var statusText: String = "Select an external drive to scan"
    @Published var dotSampleCount: Int = 0
    @Published var cleanSummary: CleanSummary?
    @Published var errorMessage: String?

    private var hasLoadedPrefs = false
    private let prefsKey = "external.catSelection"

    @Published var categories: [CleanCategory] = [
        CleanCategory(id: "ext_trashes", title: "Drive Trash (.Trashes)", subtitle: "Deleted files still occupying space on this external drive", icon: "trash.fill", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "ext_temp", title: "Temporary Items (.TemporaryItems)", subtitle: "Interrupted copies & macOS safe temp items on this drive", icon: "clock.arrow.circlepath", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "ext_root_temp", title: "Root Temp Folder (Temp/)", subtitle: "Top-level Temp folder on drive root (review before enabling)", icon: "folder.badge.minus", badge: "Opt-In", requiresAdmin: false, kb: 0, isSelected: false),
        CleanCategory(id: "ext_steam_cache", title: "External Steam Download & Depot Cache", subtitle: "SteamLibrary downloading/temp/depotcache (never touches installed games)", icon: "gamecontroller.fill", badge: nil, requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "ext_appledouble", title: "macOS ._* AppleDouble & .DS_Store Clutter", subtitle: "Removes 128KB-cluster ExFAT sidecar files & .DS_Store safely", icon: "doc.on.doc.fill", badge: "ExFAT Boost", requiresAdmin: false, kb: 0, isSelected: true),
        CleanCategory(id: "ext_spotlight", title: "Spotlight & FSEvents Logs (.Spotlight-V100)", subtitle: "Clears external Spotlight index cache on this drive", icon: "magnifyingglass", badge: "Optional", requiresAdmin: false, kb: 0, isSelected: false)
    ] {
        didSet { saveCategorySelection() }
    }

    private var mountObservers: [NSObjectProtocol] = []

    var selectedDrive: ExternalDriveInfo? {
        drives.first(where: { $0.mountPath == selectedMount }) ?? drives.first
    }

    var selectedTotalKB: Int64 {
        categories.filter(\.isSelected).reduce(0) { $0 + $1.kb }
    }

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: prefsKey) as? [String: Bool] {
            for i in categories.indices {
                if let val = saved[categories[i].id] {
                    categories[i].isSelected = val
                }
            }
        }
        hasLoadedPrefs = true
        refreshDrives()
        let nc = NSWorkspace.shared.notificationCenter
        mountObservers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDrives() }
        })
        mountObservers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDrives() }
        })
    }

    private func saveCategorySelection() {
        guard hasLoadedPrefs else { return }
        let dict = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.isSelected) })
        UserDefaults.standard.set(dict, forKey: prefsKey)
    }

    func refreshDrives() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
            .volumeIsReadOnlyKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var found: [ExternalDriveInfo] = []

        for url in urls {
            let path = url.path
            guard path.hasPrefix("/Volumes/"),
                  path != "/Volumes/Macintosh HD",
                  path != "/Volumes/Recovery" else { continue }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if vals.volumeIsInternal == true { continue }
            if vals.volumeIsReadOnly == true { continue }

            let name = vals.volumeName ?? url.lastPathComponent
            let fmt = vals.volumeLocalizedFormatDescription ?? "External"
            let totalKB = Int64((vals.volumeTotalCapacity ?? 0) / 1024)
            let freeKB = Int64((vals.volumeAvailableCapacity ?? 0) / 1024)
            found.append(ExternalDriveInfo(name: name, mountPath: path, formatName: fmt, totalKB: totalKB, freeKB: freeKB))
        }

        drives = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let sel = selectedMount, drives.contains(where: { $0.mountPath == sel }) {
            // keep selection
        } else {
            selectedMount = drives.first?.mountPath
        }
        if let activeDrive = selectedDrive {
            scanDrive(activeDrive.mountPath)
        } else {
            statusText = "No external drives detected"
        }
    }

    func scanDrive(_ mountPath: String) {
        guard !isScanning, !isCleaning else { return }
        guard let scriptPath = Bundle.main.resourcePath.map({ $0 + "/cleaner_engine.sh" }) else { return }

        selectedMount = mountPath
        isScanning = true
        errorMessage = nil
        statusText = "Scanning \(URL(fileURLWithPath: mountPath).lastPathComponent)..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath, "--ext-scan", "--vol", mountPath]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let exitStatus = proc.terminationStatus

                if exitStatus == 0, let decoded = try? JSONDecoder().decode(ExternalScanResponse.self, from: data) {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if let idx = self.drives.firstIndex(where: { $0.mountPath == decoded.mount }) {
                            self.drives[idx].totalKB = decoded.total_kb
                            self.drives[idx].freeKB = decoded.free_kb
                        }
                        self.dotSampleCount = decoded.dot_sample_count
                        for i in self.categories.indices {
                            self.categories[i].kb = decoded.categories[self.categories[i].id] ?? 0
                        }
                        self.isScanning = false
                        self.statusText = "Scan complete for \(URL(fileURLWithPath: decoded.mount).lastPathComponent)"
                    }
                } else {
                    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    DispatchQueue.main.async {
                        self?.isScanning = false
                        self?.statusText = "Scan failed"
                        self?.errorMessage = errStr.isEmpty ? "External drive scan failed (exit code \(exitStatus))." : errStr
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isScanning = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cleanSelectedDrive() {
        guard !isCleaning, !isScanning, let drive = selectedDrive else { return }
        guard let scriptPath = Bundle.main.resourcePath.map({ $0 + "/cleaner_engine.sh" }) else { return }
        let selectedIDs = categories.filter(\.isSelected).map(\.id)
        guard !selectedIDs.isEmpty else { return }

        isCleaning = true
        cleanSummary = nil
        errorMessage = nil
        progress = 0.05
        statusText = "Cleaning \(drive.name)..."

        let mountPath = drive.mountPath
        let startFreeKB = drive.freeKB

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = runLineStreamingBash(
                scriptPath: scriptPath,
                arguments: ["--ext-clean", "--vol", mountPath, "--cats", selectedIDs.joined(separator: ",")]
            ) { [weak self] pct, text in
                DispatchQueue.main.async {
                    self?.progress = min(pct / 100.0, 0.98)
                    self?.statusText = text
                }
            }
            let beforeKB = res.beforeKB > 0 ? res.beforeKB : startFreeKB
            let afterKB = res.afterKB > 0 ? res.afterKB : startFreeKB

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progress = 1.0
                self.isCleaning = false
                if !res.stderr.isEmpty && res.cleanedKB == 0 {
                    self.errorMessage = res.stderr
                }
                self.cleanSummary = CleanSummary(beforeKB: beforeKB, afterKB: afterKB, cleanedKB: res.cleanedKB, skippedApps: [])
                self.statusText = "External drive cleanup finished!"
                self.scanDrive(mountPath)
            }
        }
    }

    func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func ejectDrive(_ path: String) {
        try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
    }
}

// MARK: - SwiftUI Views

struct Theme {
    static let bg = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let card = Color(red: 0.10, green: 0.12, blue: 0.17)
    static let cardBorder = Color.white.opacity(0.08)
    static let accentCyan = Color(red: 0.12, green: 0.85, blue: 0.72)
    static let accentBlue = Color(red: 0.24, green: 0.56, blue: 0.98)
    static let accentPurple = Color(red: 0.72, green: 0.42, blue: 0.98)
}

struct MainDashboardView: View {
    @ObservedObject var shieldVM: ShieldViewModel
    @ObservedObject var cleanerVM: CleanerViewModel
    @ObservedObject var externalVM: ExternalDrivesViewModel
    @ObservedObject var loginManager: LoginItemManager
    @ObservedObject var updateChecker: UpdateChecker
    @State private var selectedTab: Int = 0

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(colors: [Theme.accentCyan, Theme.accentBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Mac Shield & Cleaner")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text("v\(updateChecker.currentVersion)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(4)
                        }
                        Text(updateChecker.statusText ?? "Anti-Lag Shield  •  System Data & External Drive Cleaner")
                            .font(.system(size: 11))
                            .foregroundColor(updateChecker.updateAvailableVersion != nil ? .green : .white.opacity(0.55))
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if let newVer = updateChecker.updateAvailableVersion {
                            Button(action: { updateChecker.openReleasePage() }) {
                                StatusPill(icon: "arrow.down.circle.fill", text: "Update \(newVer)", color: .green)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: { updateChecker.checkForUpdates(silent: false) }) {
                                StatusPill(
                                    icon: updateChecker.isChecking ? "arrow.clockwise" : "arrow.triangle.2.circlepath",
                                    text: updateChecker.isChecking ? "Checking..." : "Check Updates",
                                    color: .white.opacity(0.75)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(updateChecker.isChecking)
                        }

                        StatusPill(
                            icon: shieldVM.isActive ? "bolt.shield.fill" : "shield",
                            text: shieldVM.isActive ? (shieldVM.selectedMode == "gaming" ? "Shield: Gaming" : "Shield: Streaming") : "Shield: Standby",
                            color: shieldVM.isActive ? .green : .gray
                        )
                        if cleanerVM.freeKB > 0 {
                            StatusPill(
                                icon: "internaldrive",
                                text: "\(formatKB(cleanerVM.freeKB)) Free",
                                color: Theme.accentCyan
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.black.opacity(0.25))

                HStack(spacing: 8) {
                    TabButton(title: "Anti-Lag Shield", icon: "bolt.shield.fill", isSelected: selectedTab == 0) {
                        selectedTab = 0
                    }
                    TabButton(title: "System Data & Cache Cleaner", icon: "sparkles", isSelected: selectedTab == 1) {
                        selectedTab = 1
                    }
                    TabButton(title: "External Drives (\(externalVM.drives.count))", icon: "externaldrive.fill", isSelected: selectedTab == 2) {
                        selectedTab = 2
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.15))

                Divider().background(Theme.cardBorder)

                if selectedTab == 0 {
                    ShieldTabView(vm: shieldVM, loginManager: loginManager)
                } else if selectedTab == 1 {
                    CleanerTabView(vm: cleanerVM)
                } else {
                    ExternalDrivesTabView(vm: externalVM)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 620)
    }
}

struct StatusPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15))
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
        .clipShape(Capsule())
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.accentBlue.opacity(0.28) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.accentBlue.opacity(0.6) : Color.clear, lineWidth: 1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Anti-Lag Shield View

struct ShieldTabView: View {
    @ObservedObject var vm: ShieldViewModel
    @ObservedObject var loginManager: LoginItemManager
    @State private var showNetworkOptions: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ModeCard(
                        title: "Gaming Mode",
                        subtitle: "Zero Latency • 0ms Instant ACK • 4MB Buffers • Auto VIP Boost for frontmost games, Steam, CrossOver & Emulators",
                        icon: "gamecontroller.fill",
                        accent: Theme.accentCyan,
                        selected: vm.selectedMode == "gaming",
                        disabled: vm.isActive || vm.isTransitioning
                    ) {
                        vm.selectedMode = "gaming"
                    }

                    ModeCard(
                        title: "Streaming & Media Mode",
                        subtitle: "Full Gigabit TSO • 32MB Dynamic TCP Buffers • Media Server (Stremio/Plex) & 4K Browser Priority Boost",
                        icon: "play.tv.fill",
                        accent: Theme.accentPurple,
                        selected: vm.selectedMode == "streaming",
                        disabled: vm.isActive || vm.isTransitioning
                    ) {
                        vm.selectedMode = "streaming"
                    }
                }

                // Optional Network / ARP Guard Configuration
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { withAnimation { showNetworkOptions.toggle() } }) {
                        HStack(spacing: 6) {
                            Image(systemName: showNetworkOptions ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                            Text("Advanced Gateway ARP Guard Settings")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(vm.lockGatewayARP ? "Auto-Learn Gateway MAC: ON" : "ARP Lock: OFF")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    if showNetworkOptions {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Auto-lock default gateway ARP entry while Shield is active (prevents ARP spoofing)", isOn: $vm.lockGatewayARP)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                                .foregroundColor(.white.opacity(0.85))
                                .disabled(vm.isActive)

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Optional Custom Gateway MAC (blank = auto-detect)")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.white.opacity(0.55))
                                    TextField("e.g. aa:bb:cc:dd:ee:ff", text: $vm.customGatewayMAC)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(vm.isActive)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Optional Rogue Spoofer MAC to Count")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.white.opacity(0.55))
                                    TextField("Optional MAC address", text: $vm.watchSpoofMAC)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(vm.isActive)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(12)
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
                .cornerRadius(10)

                HStack(spacing: 14) {
                    Button(action: {
                        if vm.isActive { vm.stopShield() } else { vm.startShield() }
                    }) {
                        HStack(spacing: 10) {
                            if vm.isTransitioning {
                                ProgressView().controlSize(.small).colorScheme(.dark)
                            } else {
                                Image(systemName: vm.isActive ? "stop.circle.fill" : "bolt.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            Text(vm.isTransitioning ? (vm.isActive ? "Restoring Defaults..." : "Authenticating...") : (vm.isActive ? "Stop Shield & Restore Defaults" : "Activate Anti-Lag Shield"))
                                .font(.system(size: 14, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(.white)
                        .background(
                            LinearGradient(
                                colors: vm.isActive
                                    ? [Color.red.opacity(0.85), Color.orange.opacity(0.8)]
                                    : (vm.selectedMode == "gaming" ? [Theme.accentCyan, Theme.accentBlue] : [Theme.accentPurple, Theme.accentBlue]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isTransitioning)
                }

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                let t = vm.telemetry
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    TelemetryCard(
                        title: "Link & Bus",
                        value: t.map { "\($0.interface ?? "en0") • \($0.cable_speed ?? "Active") / \($0.usb_speed ?? "Native")" } ?? "Standby",
                        icon: "cable.connector",
                        color: (t?.cable_speed == "100 Mbps" || t?.usb_speed == "480 Mbps") ? .red : Theme.accentCyan
                    )
                    TelemetryCard(
                        title: "Router Latency",
                        value: t?.router_ms.map { String(format: "%.1f ms", $0) } ?? "--",
                        icon: "wifi.router.fill",
                        color: pingColor(t?.router_ms, good: 2.5, warn: 10.0)
                    )
                    TelemetryCard(
                        title: "Internet Ping (1.1.1.1)",
                        value: t?.ping_ms.map { String(format: "%.1f ms", $0) } ?? "--",
                        subvalue: {
                            guard vm.isActive, let avg = vm.pingAvg, let minP = vm.pingMin else { return nil }
                            if let jit = vm.pingJitter {
                                return String(format: "±%.1fms jitter • min %.1f / avg %.1f", jit, minP, avg)
                            }
                            return String(format: "min %.1f / avg %.1f ms", minP, avg)
                        }(),
                        icon: "network",
                        color: pingColor(t?.ping_ms, good: 20.0, warn: 50.0)
                    )
                    TelemetryCard(
                        title: "Live Throughput",
                        value: t.map { "↓ \(formatBPS($0.rx_bps ?? 0))  ↑ \(formatBPS($0.tx_bps ?? 0))" } ?? "↓ 0 B/s  ↑ 0 B/s",
                        icon: "arrow.up.arrow.down",
                        color: Theme.accentBlue
                    )
                    TelemetryCard(
                        title: "VIP Priority Booster",
                        value: (t?.active_apps?.isEmpty == false)
                            ? (t!.active_apps!.prefix(2).joined(separator: " + ") + ((t?.stremio_4k_clients ?? 0) > 0 ? " [4K]" : ""))
                            : (vm.isActive ? "Scanning Targets..." : "Inactive"),
                        icon: "hare.fill",
                        color: (t?.active_apps?.isEmpty == false) ? .green : .gray
                    )
                    TelemetryCard(
                        title: "Gateway ARP Guard",
                        value: (t?.spoof_count ?? 0) > 0
                            ? "Spoof Blocked (\(t!.spoof_count!)x)"
                            : (vm.isActive ? (t?.arp_locked == true ? "Gateway Locked" : "Monitoring") : "Unlocked"),
                        icon: "lock.shield.fill",
                        color: (t?.spoof_count ?? 0) > 0 ? .yellow : .green
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Live Shield Log")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Toggle("Launch at Login", isOn: Binding(
                            get: { loginManager.isEnabled },
                            set: { loginManager.setEnabled($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                    }
                    if let loginNote = loginManager.statusMessage {
                        Text(loginNote)
                            .font(.system(size: 10.5))
                            .foregroundColor(.yellow.opacity(0.85))
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if vm.logs.isEmpty {
                                Text("Press 'Activate Anti-Lag Shield' to auto-lock your gateway ARP, pause Spotlight/AWDL, prevent sleep & prioritize active apps.")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.4))
                            } else {
                                ForEach(Array(vm.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(line.contains("[OK]") ? Theme.accentCyan : .white.opacity(0.8))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(height: 140)
                    .background(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
                    .cornerRadius(8)
                }
            }
            .padding(20)
        }
    }

    private func pingColor(_ ms: Double?, good: Double, warn: Double) -> Color {
        guard let ms = ms else { return .gray }
        if ms < good { return .green }
        if ms < warn { return .yellow }
        return .red
    }
}

struct ModeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let selected: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(selected ? accent : .white.opacity(0.5))
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(accent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? accent.opacity(0.12) : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent.opacity(0.75) : Theme.cardBorder, lineWidth: selected ? 1.5 : 1))
            .cornerRadius(12)
            .opacity(disabled && !selected ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct TelemetryCard: View {
    let title: String
    let value: String
    var subvalue: String? = nil
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let sub = subvalue {
                Text(sub)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
        .cornerRadius(10)
    }
}

// MARK: - Cleaner & System Data View

struct CleanerTabView: View {
    @ObservedObject var vm: CleanerViewModel
    @State private var showTrashConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Internal Macintosh HD Storage")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                            Text(vm.statusText)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        Spacer()
                        Button(action: { vm.scan() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                Text(vm.isScanning ? "Scanning..." : "Re-Scan")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isScanning || vm.isCleaning)
                    }

                    if vm.totalKB > 0 {
                        let ratio = min(max(Double(vm.usedKB) / Double(vm.totalKB), 0), 1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.1))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LinearGradient(colors: [Theme.accentBlue, Theme.accentPurple], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * ratio)
                            }
                        }
                        .frame(height: 10)

                        HStack {
                            Text("Used: \(formatKB(vm.usedKB))")
                            Spacer()
                            Text("Available: \(formatKB(vm.freeKB))")
                                .foregroundColor(Theme.accentCyan)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("Total: \(formatKB(vm.totalKB))")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                    }
                }
                .padding(14)
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder, lineWidth: 1))
                .cornerRadius(12)

                if !vm.openApps.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open apps detected (their live caches will be skipped)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                            Text(vm.openApps.joined(separator: ", "))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        Button("Quit These Apps") {
                            vm.quitOpenApps()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundColor(.yellow)
                        .cornerRadius(6)
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(Color.yellow.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
                    .cornerRadius(10)
                }

                if let summary = vm.cleanSummary {
                    let netFreed = max(summary.afterKB - summary.beforeKB, 0)
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cleanup Complete! \(formatKB(summary.cleanedKB)) Removed")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Free space: \(formatKB(summary.beforeKB)) → \(formatKB(summary.afterKB)) (+\(formatKB(netFreed)) net SSD freed)")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.75))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.4), lineWidth: 1))
                    .cornerRadius(10)
                }

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cache, Temp & System Data Categories")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: {
                            if vm.categories.first(where: { $0.id == "trash" })?.isSelected == true {
                                showTrashConfirm = true
                            } else {
                                vm.cleanSelected()
                            }
                        }) {
                            HStack(spacing: 8) {
                                if vm.isCleaning {
                                    ProgressView().controlSize(.small).colorScheme(.dark)
                                    Text("Cleaning...")
                                } else {
                                    Image(systemName: "sparkles")
                                    Text("Clean Selected (\(formatKB(vm.selectedTotalKB)))")
                                }
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(LinearGradient(colors: [Theme.accentCyan, Theme.accentBlue], startPoint: .leading, endPoint: .trailing))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isCleaning || vm.isScanning || vm.categories.allSatisfy { !$0.isSelected })
                        .alert("Empty Trash Permanently?", isPresented: $showTrashConfirm) {
                            Button("Cancel", role: .cancel) {}
                            Button("Empty Trash & Clean", role: .destructive) { vm.cleanSelected() }
                        } message: {
                            Text("Items in ~/.Trash will be permanently deleted and cannot be recovered.")
                        }
                    }

                    if vm.isCleaning {
                        ProgressView(value: vm.progress)
                            .tint(Theme.accentCyan)
                            .padding(.vertical, 4)
                    }

                    VStack(spacing: 6) {
                        ForEach($vm.categories) { $cat in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $cat.isSelected)
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .disabled(vm.isCleaning)

                                Image(systemName: cat.icon)
                                    .font(.system(size: 14))
                                    .foregroundColor(cat.isSelected ? Theme.accentCyan : .white.opacity(0.45))
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(cat.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                        if let badge = cat.badge {
                                            Text(badge)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(badge == "System Data" ? Theme.accentPurple : (badge == "Admin" ? .orange : .white.opacity(0.7)))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background((badge == "System Data" ? Theme.accentPurple : Color.white).opacity(0.15))
                                                .cornerRadius(4)
                                        }
                                    }
                                    Text(cat.subtitle)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.white.opacity(0.55))
                                }

                                Spacer()

                                Text(vm.isScanning ? "..." : formatKB(cat.kb))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(cat.kb > 500_000 ? .orange : (cat.kb > 0 ? .white.opacity(0.85) : .white.opacity(0.35)))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.card)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
                            .cornerRadius(8)
                        }
                    }
                }

                if !vm.topItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Data Space Inspector (Largest Folders)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)

                        VStack(spacing: 5) {
                            ForEach(vm.topItems) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.label)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text(item.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.45))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(formatKB(item.kb))
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.accentCyan)
                                    Button("Reveal") {
                                        vm.revealInFinder(item.path)
                                    }
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .foregroundColor(.white.opacity(0.85))
                                    .cornerRadius(5)
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.card)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - External Drives View

struct ExternalDrivesTabView: View {
    @ObservedObject var vm: ExternalDrivesViewModel
    @State private var showRootTempConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detected External HDDs & USB Drives")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Text("Auto-detects connected drives • Never deletes user files, games, or archives")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    Spacer()
                    Button(action: { vm.refreshDrives() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text(vm.isScanning ? "Scanning..." : "Refresh Drives")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isScanning || vm.isCleaning)
                }

                if vm.drives.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.35))
                        Text("No External Drives Connected")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        Text("Plug in any external HDD, SSD, or USB stick and it will appear here automatically.")
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(36)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder, lineWidth: 1))
                    .cornerRadius(12)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                        ForEach(vm.drives) { drive in
                            let isSel = vm.selectedDrive?.mountPath == drive.mountPath
                            let ratio = drive.totalKB > 0 ? min(max(Double(drive.usedKB) / Double(drive.totalKB), 0), 1) : 0
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "externaldrive.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(isSel ? Theme.accentCyan : .white.opacity(0.6))
                                    Text(drive.name)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(drive.formatName)
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(.white.opacity(0.75))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.12))
                                        .cornerRadius(4)
                                    Spacer()
                                    if isSel {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Theme.accentCyan)
                                    }
                                }

                                Text(drive.mountPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1))
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(LinearGradient(colors: [Theme.accentCyan, Theme.accentBlue], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: geo.size.width * ratio)
                                    }
                                }
                                .frame(height: 7)

                                HStack {
                                    Text("\(formatKB(drive.freeKB)) Free of \(formatKB(drive.totalKB))")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(Theme.accentCyan)
                                    Spacer()
                                    Button("Finder") { vm.openInFinder(drive.mountPath) }
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Color.white.opacity(0.08))
                                        .foregroundColor(.white.opacity(0.85))
                                        .cornerRadius(4)
                                        .buttonStyle(.plain)
                                    Button("Eject") { vm.ejectDrive(drive.mountPath) }
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundColor(.orange)
                                        .cornerRadius(4)
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSel ? Theme.accentCyan.opacity(0.10) : Theme.card)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSel ? Theme.accentCyan.opacity(0.7) : Theme.cardBorder, lineWidth: isSel ? 1.5 : 1))
                            .cornerRadius(12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.scanDrive(drive.mountPath)
                            }
                        }
                    }

                    if let summary = vm.cleanSummary {
                        let netFreed = max(summary.afterKB - summary.beforeKB, 0)
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("External Drive Cleaned! \(formatKB(summary.cleanedKB)) Removed")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                Text("Free space: \(formatKB(summary.beforeKB)) → \(formatKB(summary.afterKB)) (+\(formatKB(netFreed)) net freed)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.green.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.4), lineWidth: 1))
                        .cornerRadius(10)
                    }

                    if let err = vm.errorMessage {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let drive = vm.selectedDrive {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Cleanable Items on \(drive.name)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(vm.statusText)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.white.opacity(0.55))
                                }
                                Spacer()
                                Button(action: {
                                    if vm.categories.first(where: { $0.id == "ext_root_temp" })?.isSelected == true {
                                        showRootTempConfirm = true
                                    } else {
                                        vm.cleanSelectedDrive()
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        if vm.isCleaning {
                                            ProgressView().controlSize(.small).colorScheme(.dark)
                                            Text("Cleaning...")
                                        } else {
                                            Image(systemName: "sparkles")
                                            Text("Clean \(drive.name) (\(formatKB(vm.selectedTotalKB)))")
                                        }
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(LinearGradient(colors: [Theme.accentCyan, Theme.accentBlue], startPoint: .leading, endPoint: .trailing))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.isCleaning || vm.isScanning || vm.categories.allSatisfy { !$0.isSelected })
                                .alert("Clean Root Temp/ Folder?", isPresented: $showRootTempConfirm) {
                                    Button("Cancel", role: .cancel) {}
                                    Button("Clean Drive", role: .destructive) { vm.cleanSelectedDrive() }
                                } message: {
                                    Text("This will delete all contents inside \(drive.mountPath)/Temp along with your other selected categories.")
                                }
                            }

                            if vm.isCleaning {
                                ProgressView(value: vm.progress)
                                    .tint(Theme.accentCyan)
                                    .padding(.vertical, 4)
                            }

                            VStack(spacing: 6) {
                                ForEach($vm.categories) { $cat in
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: $cat.isSelected)
                                            .toggleStyle(.checkbox)
                                            .labelsHidden()
                                            .disabled(vm.isCleaning)

                                        Image(systemName: cat.icon)
                                            .font(.system(size: 14))
                                            .foregroundColor(cat.isSelected ? Theme.accentCyan : .white.opacity(0.45))
                                            .frame(width: 22)

                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 6) {
                                                Text(cat.title)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(.white)
                                                if let badge = cat.badge {
                                                    Text(badge)
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(badge == "ExFAT Boost" ? Theme.accentCyan : .white.opacity(0.7))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.white.opacity(0.12))
                                                        .cornerRadius(4)
                                                }
                                            }
                                            Text(cat.subtitle)
                                                .font(.system(size: 10.5))
                                                .foregroundColor(.white.opacity(0.55))
                                        }

                                        Spacer()

                                        Text(vm.isScanning ? "..." : (cat.id == "ext_appledouble" && vm.dotSampleCount > 0 ? "~\(formatKB(cat.kb))+" : formatKB(cat.kb)))
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(cat.kb > 10_240 ? .orange : (cat.kb > 0 ? .white.opacity(0.85) : .white.opacity(0.35)))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.card)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - AppDelegate & Entry Point

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var window: NSWindow?
    let shieldVM = ShieldViewModel()
    let cleanerVM = CleanerViewModel()
    let externalVM = ExternalDrivesViewModel()
    let loginManager = LoginItemManager()
    let updateChecker = UpdateChecker()
    private var lastMenuActive: Bool?
    private var lastMenuMode: String?
    private var lastMenuLoginEnabled: Bool?
    private var statsMenuItem: NSMenuItem?
    private var vipMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        shieldVM.onStatusChange = { [weak self] active, mode in
            self?.updateStatusItem(active: active, mode: mode, telemetry: self?.shieldVM.telemetry)
        }
        shieldVM.onTelemetryUpdate = { [weak self] telem in
            guard let self = self else { return }
            self.updateStatusItem(active: self.shieldVM.isActive, mode: self.shieldVM.selectedMode, telemetry: telem)
        }

        setupMainMenu()
        setupMenuBar()
        openMainWindow()
        updateChecker.checkForUpdates(silent: true)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(menuCheckUpdates), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Mac Shield & Cleaner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || window?.isVisible == false || window?.isMiniaturized == true {
            openMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shieldVM.stopSynchronouslyOnQuit()
    }

    @objc func openMainWindow() {
        if window == nil {
            let rootView = MainDashboardView(shieldVM: shieldVM, cleanerVM: cleanerVM, externalVM: externalVM, loginManager: loginManager, updateChecker: updateChecker)
            let hosting = NSHostingController(rootView: rootView)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Mac Shield & Cleaner"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 920, height: 680))
            win.center()
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            window = win
        }
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(active: shieldVM.isActive, mode: shieldVM.selectedMode, telemetry: shieldVM.telemetry)
    }

    private func updateStatusItem(active: Bool, mode: String, telemetry: ShieldTelemetry?) {
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: active ? "bolt.shield.fill" : "shield.lefthalf.filled", accessibilityDescription: "Mac Shield")
            if active {
                let modeText = (mode == "gaming") ? "Gaming" : "Stream"
                if let ping = telemetry?.ping_ms {
                    btn.title = String(format: " %@ • %.0fms", modeText, ping)
                } else {
                    btn.title = " \(modeText)"
                }
            } else {
                btn.title = ""
            }
        }

        if let t = telemetry, active {
            let rStr = t.router_ms.map { String(format: "%.1fms", $0) } ?? "--"
            let pStr = t.ping_ms.map { String(format: "%.1fms", $0) } ?? "--"
            statsMenuItem?.title = "Router: \(rStr)  |  Ping: \(pStr)"
            if let apps = t.active_apps, !apps.isEmpty {
                vipMenuItem?.title = "VIP Boost: \(apps.prefix(2).joined(separator: ", "))"
                vipMenuItem?.isHidden = false
            } else {
                vipMenuItem?.isHidden = true
            }
        }

        guard lastMenuActive != active || lastMenuMode != mode || lastMenuLoginEnabled != loginManager.isEnabled || statusItem?.menu == nil else {
            return
        }
        lastMenuActive = active
        lastMenuMode = mode
        lastMenuLoginEnabled = loginManager.isEnabled

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Mac Shield & Cleaner", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        if active {
            let sItem = NSMenuItem(title: "Router: --  |  Ping: --", action: nil, keyEquivalent: "")
            sItem.isEnabled = false
            statsMenuItem = sItem
            menu.addItem(sItem)

            let vItem = NSMenuItem(title: "VIP Boost: Standby", action: nil, keyEquivalent: "")
            vItem.isEnabled = false
            vItem.isHidden = true
            vipMenuItem = vItem
            menu.addItem(vItem)

            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Stop Anti-Lag Shield (Restore Defaults)", action: #selector(menuStopShield), keyEquivalent: "s"))
        } else {
            statsMenuItem = nil
            vipMenuItem = nil
            menu.addItem(NSMenuItem(title: "Start Gaming Shield", action: #selector(menuStartGaming), keyEquivalent: "g"))
            menu.addItem(NSMenuItem(title: "Start Streaming Shield", action: #selector(menuStartStreaming), keyEquivalent: "t"))
        }
        menu.addItem(NSMenuItem.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(menuToggleLogin), keyEquivalent: "")
        loginItem.state = loginManager.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(menuCheckUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func menuToggleLogin() {
        loginManager.setEnabled(!loginManager.isEnabled)
        updateStatusItem(active: shieldVM.isActive, mode: shieldVM.selectedMode, telemetry: shieldVM.telemetry)
    }

    @objc private func menuCheckUpdates() {
        updateChecker.checkForUpdates(silent: false)
        openMainWindow()
    }

    @objc private func menuStartGaming() {
        shieldVM.selectedMode = "gaming"
        shieldVM.startShield()
    }

    @objc private func menuStartStreaming() {
        shieldVM.selectedMode = "streaming"
        shieldVM.startShield()
    }

    @objc private func menuStopShield() {
        shieldVM.stopShield()
    }
}

@main
struct MacShieldCleanerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

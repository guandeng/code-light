import Cocoa
import Foundation

// ============================================================
// CodeLight — 配置与共享类型
// ============================================================

struct AppConfig {
    var serverURL = "http://127.0.0.1:8866"
    var pollInterval = 0.5
    var opacity = 1.0
    var blinkSpeed = 0.6
    var autoLaunch = false
    var showInDock = true
    var isFloating = true
    var notifyOnDone = true
    var completionSound: String = "Glass"  // 系统音效名: Glass, Hero, Ping, Pop, Purr, Tink, default, none
    var showOnFullscreen = true
    var horizontal = false
    var displayMode: String = "vertical"  // "vertical" | "horizontal" | "mini"
    var showStatusText = true
    var windowSize: Double = 40
    var windowX: Double?
    var windowY: Double?
    var edgeBar: String?  // "left" | "right" | nil
    var mascotType: String = "cow"  // "cow" | "cat" | "robot" | "horse" | "chicken"
    var theme: String = "dark"     // "dark" | "light" | "custom"
    var customColor: String = "#1C1E22"
    var weatherThemeEnabled: Bool = false
    var weatherCity: String = "深圳"
    var hookSetupDismissed = false
    var notifyOnPermission: Bool = true
    var autoAllowPermission: Bool = false  // deprecated, kept for migration
    var permissionMode: String = "popup"  // "always" | "rules" | "popup"
    var hookToolIndex: Int = 0  // 0=Claude Code, 1=Codex, 2=Cursor
    var statsWebhook: String = ""  // unused, kept for config compatibility
    var webdavURL: String = ""     // WebDAV 服务器地址，如 https://dav.jianguoyun.com/dav/
    var webdavUser: String = ""    // WebDAV 用户名
    var webdavPass: String = ""    // WebDAV 密码/应用专用密码
    var webdavPath: String = "/codelight/config.json"  // 远程配置文件路径
    var webdavAutoSync: Bool = false  // 自动同步开关
    // S3 同步
    var s3ProviderPreset: Int = 0                    // S3Sync.presets 索引
    var s3Endpoint: String = ""                      // 自定义 endpoint（覆盖预设）
    var s3Region: String = "us-east-1"               // 区域
    var s3Bucket: String = ""                        // 存储桶名
    var s3AccessKeyID: String = ""                   // Access Key ID
    var s3SecretAccessKey: String = ""               // Secret Access Key
    var s3RemotePath: String = "/codelight/config.json"  // 远程对象路径
    var s3AutoSync: Bool = false                     // S3 自动同步开关
    var skillsRepoURL: String = "anthropics/skills"   // owner/repo 格式
    var skillsCatalogPath: String = "skills"          // 仓库内 skills 目录路径

    /// 预置市场仓库列表
    static let presetRepos: [(name: String, owner: String, repo: String, path: String)] = [
        ("Anthropic 官方", "anthropics", "skills", "skills"),
        ("Vercel Agent Skills", "vercel-labs", "agent-skills", ""),
        ("Microsoft Azure", "microsoft", "azure-skills", ""),
    ]

    static func load() -> AppConfig {
        let ud = UserDefaults.standard
        var c = AppConfig()
        if let v = ud.string(forKey: "serverURL") { c.serverURL = v }
        if ud.double(forKey: "pollInterval") > 0 { c.pollInterval = ud.double(forKey: "pollInterval") }
        if ud.double(forKey: "opacity") > 0 { c.opacity = ud.double(forKey: "opacity") }
        if ud.double(forKey: "blinkSpeed") > 0 { c.blinkSpeed = ud.double(forKey: "blinkSpeed") }
        if let v = ud.string(forKey: "theme") { c.theme = v }
        c.autoLaunch = ud.bool(forKey: "autoLaunch")
        c.showInDock = ud.bool(forKey: "showInDock")
        if ud.object(forKey: "isFloating") != nil { c.isFloating = ud.bool(forKey: "isFloating") }
        if ud.object(forKey: "notifyOnDone") != nil { c.notifyOnDone = ud.bool(forKey: "notifyOnDone") }
        if ud.object(forKey: "showOnFullscreen") != nil { c.showOnFullscreen = ud.bool(forKey: "showOnFullscreen") }
        if let v = ud.string(forKey: "completionSound") { c.completionSound = v }
        if ud.object(forKey: "horizontal") != nil { c.horizontal = ud.bool(forKey: "horizontal") }
        if let v = ud.string(forKey: "displayMode") { c.displayMode = v }
        else if c.horizontal { c.displayMode = "horizontal" }
        if ud.object(forKey: "showStatusText") != nil { c.showStatusText = ud.bool(forKey: "showStatusText") }
        if ud.double(forKey: "windowSize") > 0 { c.windowSize = ud.double(forKey: "windowSize") }
        if ud.object(forKey: "windowX") != nil { c.windowX = ud.double(forKey: "windowX") }
        if ud.object(forKey: "windowY") != nil { c.windowY = ud.double(forKey: "windowY") }
        if let v = ud.string(forKey: "edgeBar") { c.edgeBar = v }
        if let v = ud.string(forKey: "mascotType") { c.mascotType = v }
        if let v = ud.string(forKey: "theme") { c.theme = v }
        if let v = ud.string(forKey: "customColor") { c.customColor = v }
        if ud.object(forKey: "weatherThemeEnabled") != nil { c.weatherThemeEnabled = ud.bool(forKey: "weatherThemeEnabled") }
        if let v = ud.string(forKey: "weatherCity") { c.weatherCity = v }
        c.hookSetupDismissed = ud.bool(forKey: "hookSetupDismissed")
        if ud.object(forKey: "notifyOnPermission") != nil { c.notifyOnPermission = ud.bool(forKey: "notifyOnPermission") }
        if ud.object(forKey: "autoAllowPermission") != nil { c.autoAllowPermission = ud.bool(forKey: "autoAllowPermission") }
        if let v = ud.string(forKey: "permissionMode") { c.permissionMode = v }
        else if c.autoAllowPermission { c.permissionMode = "always" }  // 旧配置迁移
        if ud.object(forKey: "hookToolIndex") != nil { c.hookToolIndex = ud.integer(forKey: "hookToolIndex") }
        if let v = ud.string(forKey: "statsWebhook") { c.statsWebhook = v }
        if let v = ud.string(forKey: "webdavURL") { c.webdavURL = v }
        if let v = ud.string(forKey: "webdavUser") { c.webdavUser = v }
        if let v = ud.string(forKey: "webdavPass") { c.webdavPass = v }
        if let v = ud.string(forKey: "webdavPath") { c.webdavPath = v }
        if ud.object(forKey: "webdavAutoSync") != nil { c.webdavAutoSync = ud.bool(forKey: "webdavAutoSync") }
        if let v = ud.string(forKey: "skillsRepoURL") { c.skillsRepoURL = v }
        if let v = ud.string(forKey: "skillsCatalogPath") { c.skillsCatalogPath = v }
        // S3 同步
        if ud.object(forKey: "s3ProviderPreset") != nil { c.s3ProviderPreset = ud.integer(forKey: "s3ProviderPreset") }
        if let v = ud.string(forKey: "s3Endpoint") { c.s3Endpoint = v }
        if let v = ud.string(forKey: "s3Region") { c.s3Region = v }
        if let v = ud.string(forKey: "s3Bucket") { c.s3Bucket = v }
        if let v = ud.string(forKey: "s3AccessKeyID") { c.s3AccessKeyID = v }
        if let v = ud.string(forKey: "s3SecretAccessKey") { c.s3SecretAccessKey = v }
        if let v = ud.string(forKey: "s3RemotePath") { c.s3RemotePath = v }
        if ud.object(forKey: "s3AutoSync") != nil { c.s3AutoSync = ud.bool(forKey: "s3AutoSync") }
        return c
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(serverURL, forKey: "serverURL")
        ud.set(pollInterval, forKey: "pollInterval")
        ud.set(opacity, forKey: "opacity")
        ud.set(blinkSpeed, forKey: "blinkSpeed")
        ud.set(theme, forKey: "theme")
        ud.set(autoLaunch, forKey: "autoLaunch")
        ud.set(showInDock, forKey: "showInDock")
        ud.set(isFloating, forKey: "isFloating")
        ud.set(notifyOnDone, forKey: "notifyOnDone")
        ud.set(completionSound, forKey: "completionSound")
        ud.set(showOnFullscreen, forKey: "showOnFullscreen")
        ud.set(horizontal, forKey: "horizontal")
        ud.set(displayMode, forKey: "displayMode")
        ud.set(showStatusText, forKey: "showStatusText")
        ud.set(windowSize, forKey: "windowSize")
        if let x = windowX { ud.set(x, forKey: "windowX") }
        if let y = windowY { ud.set(y, forKey: "windowY") }
        if let v = edgeBar { ud.set(v, forKey: "edgeBar") } else { ud.removeObject(forKey: "edgeBar") }
        ud.set(mascotType, forKey: "mascotType")
        ud.set(theme, forKey: "theme")
        ud.set(customColor, forKey: "customColor")
        ud.set(weatherThemeEnabled, forKey: "weatherThemeEnabled")
        ud.set(weatherCity, forKey: "weatherCity")
        ud.set(hookSetupDismissed, forKey: "hookSetupDismissed")
        ud.set(notifyOnPermission, forKey: "notifyOnPermission")
        ud.set(autoAllowPermission, forKey: "autoAllowPermission")
        ud.set(permissionMode, forKey: "permissionMode")
        ud.set(hookToolIndex, forKey: "hookToolIndex")
        ud.set(statsWebhook, forKey: "statsWebhook")
        ud.set(webdavURL, forKey: "webdavURL")
        ud.set(webdavUser, forKey: "webdavUser")
        ud.set(webdavPass, forKey: "webdavPass")
        ud.set(webdavPath, forKey: "webdavPath")
        ud.set(webdavAutoSync, forKey: "webdavAutoSync")
        ud.set(skillsRepoURL, forKey: "skillsRepoURL")
        ud.set(skillsCatalogPath, forKey: "skillsCatalogPath")
        // S3 同步
        ud.set(s3ProviderPreset, forKey: "s3ProviderPreset")
        ud.set(s3Endpoint, forKey: "s3Endpoint")
        ud.set(s3Region, forKey: "s3Region")
        ud.set(s3Bucket, forKey: "s3Bucket")
        ud.set(s3AccessKeyID, forKey: "s3AccessKeyID")
        ud.set(s3SecretAccessKey, forKey: "s3SecretAccessKey")
        ud.set(s3RemotePath, forKey: "s3RemotePath")
        ud.set(s3AutoSync, forKey: "s3AutoSync")
    }

    /// 导出为 JSON（用于 WebDAV 同步，排除设备相关的位置信息）
    func toJSON() -> [String: Any] {
        return [
            "opacity": opacity,
            "blinkSpeed": blinkSpeed,
            "isFloating": isFloating,
            "notifyOnDone": notifyOnDone,
            "completionSound": completionSound,
            "showOnFullscreen": showOnFullscreen,
            "displayMode": displayMode,
            "showStatusText": showStatusText,
            "windowSize": windowSize,
            "mascotType": mascotType,
            "theme": theme,
            "customColor": customColor,
            "weatherThemeEnabled": weatherThemeEnabled,
            "weatherCity": weatherCity,
            "notifyOnPermission": notifyOnPermission,
            "permissionMode": permissionMode,
            "pollInterval": pollInterval,
            "webdavAutoSync": webdavAutoSync,
            "skillsRepoURL": skillsRepoURL,
            "skillsCatalogPath": skillsCatalogPath,
            "allowRules": AlwaysAllowManager.shared.rules,
            "denyRules": BlacklistManager.shared.rules,
        ]
    }

    /// 从 JSON 导入配置（合并，不覆盖位置信息）
    mutating func applyJSON(_ dict: [String: Any]) {
        if let v = dict["opacity"] as? Double { opacity = v }
        if let v = dict["blinkSpeed"] as? Double { blinkSpeed = v }
        if let v = dict["isFloating"] as? Bool { isFloating = v }
        if let v = dict["notifyOnDone"] as? Bool { notifyOnDone = v }
        if let v = dict["completionSound"] as? String { completionSound = v }
        if let v = dict["showOnFullscreen"] as? Bool { showOnFullscreen = v }
        if let v = dict["displayMode"] as? String { displayMode = v }
        if let v = dict["showStatusText"] as? Bool { showStatusText = v }
        if let v = dict["windowSize"] as? Double { windowSize = v }
        if let v = dict["mascotType"] as? String { mascotType = v }
        if let v = dict["theme"] as? String { theme = v }
        if let v = dict["customColor"] as? String { customColor = v }
        if let v = dict["weatherThemeEnabled"] as? Bool { weatherThemeEnabled = v }
        if let v = dict["weatherCity"] as? String { weatherCity = v }
        if let v = dict["notifyOnPermission"] as? Bool { notifyOnPermission = v }
        if let v = dict["permissionMode"] as? String { permissionMode = v }
        if let v = dict["pollInterval"] as? Double { pollInterval = v }
        if let v = dict["webdavAutoSync"] as? Bool { webdavAutoSync = v }
        if let v = dict["skillsRepoURL"] as? String { skillsRepoURL = v }
        if let v = dict["skillsCatalogPath"] as? String { skillsCatalogPath = v }
        // 同步规则：覆盖本地规则文件
        if let allows = dict["allowRules"] as? [String] {
            AlwaysAllowManager.shared.replaceRules(allows)
        }
        if let denies = dict["denyRules"] as? [String] {
            BlacklistManager.shared.replaceRules(denies)
        }
        horizontal = (displayMode == "horizontal")
    }
}

struct LightStateDef {
    let red: Bool; let yellow: Bool; let green: Bool; let blink: Bool; let label: String
}

let STATES: [String: LightStateDef] = [
    "idle":     LightStateDef(red: false, yellow: false, green: true,  blink: false, label: "空闲中"),
    "thinking": LightStateDef(red: false, yellow: true,  green: false, blink: false, label: "思考中"),
    "working":  LightStateDef(red: true,  yellow: false, green: false, blink: true,  label: "执行中"),
    "fixing":   LightStateDef(red: false, yellow: true,  green: false, blink: true,  label: "修复中"),
    "error":    LightStateDef(red: true,  yellow: false, green: false, blink: false, label: "警告中"),
    "waiting":  LightStateDef(red: true,  yellow: false, green: false, blink: true,  label: "等待授权"),
]

let SEVERITY = ["error": 4, "working": 3, "fixing": 3, "thinking": 2, "waiting": 2, "idle": 0]

let CITIES: [(name: String, lat: Double, lon: Double)] = [
    ("北京", 39.90, 116.40), ("上海", 31.23, 121.47), ("广州", 23.13, 113.26),
    ("深圳", 22.55, 114.10), ("杭州", 30.27, 120.15), ("成都", 30.57, 104.07),
    ("武汉", 30.59, 114.31), ("南京", 32.06, 118.80), ("重庆", 29.56, 106.55),
    ("西安", 34.26, 108.94), ("苏州", 31.30, 120.62), ("天津", 39.13, 117.20),
    ("长沙", 28.23, 112.94), ("郑州", 34.75, 113.65), ("青岛", 36.07, 120.38),
    ("大连", 38.91, 121.60), ("厦门", 24.48, 118.09), ("昆明", 25.04, 102.68),
    ("哈尔滨", 45.75, 126.65), ("沈阳", 41.80, 123.43),
]

extension NSColor {
    convenience init?(fromHex hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green: CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(v & 0xFF) / 255.0,
                  alpha: 1.0)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// ============================================================
// AlwaysAllowManager — 总是运行规则管理（~/.codelight/config）
// ============================================================

class AlwaysAllowManager {
    static let shared = AlwaysAllowManager()
    private(set) var rules: [String] = []

    private var configPath: String { NSHomeDirectory() + "/.codelight/config" }

    private init() { loadRules() }

    func loadRules() {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        rules = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("allow ") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func saveRules() {
        let dir = (configPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // 保留文件中的 deny 行，只替换 allow 行
        var existingLines: [String] = []
        if let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
            existingLines = content.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("allow ") }
                .filter { !$0.isEmpty }
        }
        let allowLines = rules.map { "allow \($0)" }
        let allLines = existingLines + allowLines
        try? (allLines.joined(separator: "\n") + "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    func addRule(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !rules.contains(trimmed) else { return }
        rules.append(trimmed)
        saveRules()
    }

    func removeRule(at index: Int) {
        guard index >= 0, index < rules.count else { return }
        rules.remove(at: index)
        saveRules()
    }

    func clearAll() {
        rules.removeAll()
        saveRules()
    }

    /// 云同步用：用远端规则整体覆盖本地
    func replaceRules(_ newRules: [String]) {
        rules = newRules.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        saveRules()
    }

    func importDefaults() {
        let defaults = ["git", "ls", "cat", "head", "tail", "find", "grep",
                        "pwd", "echo", "which", "whoami", "date", "df", "du",
                        "ps", "wc", "sort", "uniq", "diff", "file", "stat",
                        "curl", "wget", "tree", "gh"]
        for rule in defaults where !rules.contains(rule) { rules.append(rule) }
        saveRules()
    }

    /// 前缀匹配：git → git status, git log, git commit 等
    func shouldAllow(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for rule in rules {
            if trimmed == rule || trimmed.hasPrefix(rule + " ") { return true }
        }
        return false
    }
}

// ============================================================
// BlacklistManager — 危险命令黑名单（~/.codelight/config deny 行）
// ============================================================

class BlacklistManager {
    static let shared = BlacklistManager()
    private(set) var rules: [String] = []

    private var configPath: String { NSHomeDirectory() + "/.codelight/config" }

    private init() { loadRules() }

    func loadRules() {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        rules = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("deny ") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func saveRules() {
        let dir = (configPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // 保留文件中的 allow 行，只替换 deny 行
        var existingLines: [String] = []
        if let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
            existingLines = content.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("deny ") }
                .filter { !$0.isEmpty }
        }
        let denyLines = rules.map { "deny \($0)" }
        let allLines = existingLines + denyLines
        try? (allLines.joined(separator: "\n") + "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    func addRule(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !rules.contains(trimmed) else { return }
        rules.append(trimmed)
        saveRules()
    }

    func removeRule(at index: Int) {
        guard index >= 0, index < rules.count else { return }
        rules.remove(at: index)
        saveRules()
    }

    func clearAll() {
        rules.removeAll()
        saveRules()
    }

    func importDefaults() {
        let defaults = ["rm", "rmdir", "sudo", "chmod", "chown", "mkfs",
                        "dd", "shutdown", "reboot", "kill", "pkill",
                        "killall", "format"]
        for rule in defaults where !rules.contains(rule) { rules.append(rule) }
        saveRules()
    }

    /// 云同步用：用远端规则整体覆盖本地
    func replaceRules(_ newRules: [String]) {
        rules = newRules.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        saveRules()
    }

    /// 前缀匹配：rm → rm -rf, rm -r /tmp 等
    func shouldDeny(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for rule in rules {
            if trimmed == rule || trimmed.hasPrefix(rule + " ") { return true }
        }
        return false
    }
}

// ============================================================
// StatsManager — AI 使用统计
// ============================================================

class StatsManager {
    static let shared = StatsManager()

    private struct Event: Codable {
        let ts: Double       // timeIntervalSince1970
        let state: String    // idle/thinking/working/fixing/error/waiting
        let message: String
        let session: String
    }

    private struct DailySummary: Codable {
        let date: String     // "yyyy-MM-dd"
        var totalDuration: Double = 0        // non-idle seconds
        var toolCalls: Int = 0               // working transitions count
        var sessionCount: Int = 0            // unique sessions
        var stateDurations: [String: Double] = [:]  // state → seconds
        var toolBreakdown: [String: Int] = [:]      // tool name → count (from message)
    }

    private var events: [Event] = []
    private let maxEvents = 10000
    private let retainDays = 30
    private let saveKey = "codelight.stats.v1"

    private init() {
        loadEvents()
    }

    func record(state: String, message: String, sessionId: String) {
        let event = Event(ts: Date().timeIntervalSince1970, state: state, message: message, session: sessionId)
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        purgeOldEvents()
        saveEvents()
    }

    // MARK: - Queries

    struct DayStats {
        let date: String
        let duration: TimeInterval   // active (non-idle) seconds
        let toolCalls: Int
        let sessions: Int
        let thinkingDur: TimeInterval
        let workingDur: TimeInterval
        let idleDur: TimeInterval
        let toolBreakdown: [(String, Int)]
    }

    func todayStats() -> DayStats {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return statsForDay(today)
    }

    func weekStats() -> [DayStats] {
        let cal = Calendar.current
        var result: [DayStats] = []
        for i in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let day = cal.startOfDay(for: d)
            result.append(statsForDay(day))
        }
        return result
    }

    private func statsForDay(_ dayStart: Date) -> DayStats {
        let dayEnd = dayStart.addingTimeInterval(86400)
        let dayEvents = events.filter { $0.ts >= dayStart.timeIntervalSince1970 && $0.ts < dayEnd.timeIntervalSince1970 }
        guard !dayEvents.isEmpty else {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            return DayStats(date: fmt.string(from: dayStart), duration: 0, toolCalls: 0, sessions: 0,
                            thinkingDur: 0, workingDur: 0, idleDur: 86400, toolBreakdown: [])
        }

        var durations: [String: Double] = [:]
        var sessions = Set<String>()
        var toolCalls = 0
        var toolBreakdown: [String: Int] = [:]

        for i in 0..<dayEvents.count {
            let e = dayEvents[i]
            sessions.insert(e.session)
            if e.state == "working" {
                toolCalls += 1
                let tool = extractTool(from: e.message)
                toolBreakdown[tool, default: 0] += 1
            }
            let nextTs: Double
            if i + 1 < dayEvents.count { nextTs = dayEvents[i + 1].ts }
            else { nextTs = min(Date().timeIntervalSince1970, dayEnd.timeIntervalSince1970) }
            let dur = max(nextTs - e.ts, 0)
            durations[e.state, default: 0] += dur
        }

        let activeDur = durations.filter { $0.key != "idle" }.values.reduce(0, +)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"

        let sorted = toolBreakdown.sorted { $0.value > $1.value }
        return DayStats(
            date: fmt.string(from: dayStart),
            duration: activeDur,
            toolCalls: toolCalls,
            sessions: sessions.count,
            thinkingDur: durations["thinking"] ?? 0,
            workingDur: durations["working"] ?? 0,
            idleDur: durations["idle"] ?? 0,
            toolBreakdown: sorted.map { ($0.key, $0.value) }
        )
    }

    private func extractTool(from message: String) -> String {
        // message patterns: "Tool: Bash", "tool_use: Edit", or plain tool name
        let lower = message.lowercased()
        for prefix in ["tool: ", "tool_use: ", "using "] {
            if let range = lower.range(of: prefix) {
                let rest = String(message[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(separator: " ").first.map(String.init) ?? rest
                return parts.isEmpty ? message : parts
            }
        }
        // fallback: first word
        let first = message.split(separator: " ").first.map(String.init) ?? message
        return first.isEmpty ? "unknown" : first
    }

    // MARK: - Persistence

    private func saveEvents() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }

    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let loaded = try? JSONDecoder().decode([Event].self, from: data) else { return }
        events = loaded
        purgeOldEvents()
    }

    private func purgeOldEvents() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retainDays, to: Date())?.timeIntervalSince1970 ?? 0
        events = events.filter { $0.ts >= cutoff }
    }

    func clearAll() {
        events.removeAll()
        UserDefaults.standard.removeObject(forKey: saveKey)
    }
}

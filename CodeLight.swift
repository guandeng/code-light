import Cocoa
import CoreLocation
import Foundation
import Network
import ServiceManagement
import UserNotifications

// ============================================================
// CodeLight — AI 编程助手红绿灯 macOS App
// ============================================================

// ============================================================
// LightServer — 内置 HTTP 服务（替代 Python Flask）
// ============================================================

class LightServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "codelight.server", qos: .userInteractive)
    private var sessions: [String: SessionEntry] = [:]
    private var history: [HistoryEntry] = []
    private let maxHistory = 2000
    private let sessionTimeout: TimeInterval = 300
    private let deadTimeout: TimeInterval = 3600
    var onLog: ((String) -> Void)?
    var onPermissionRequest: (([String: Any]) -> Void)?
    var statsWebhook: String = ""  // unused, kept for config compatibility

    private struct SessionEntry {
        var state: String; var message: String; var timestamp: Date
    }
    private struct HistoryEntry: Encodable {
        let timestamp: Double; let state: String; let message: String; let session_id: String; let light: [String: AnyCodable]
    }

    struct AnyCodable: Encodable {
        let value: Any
        init(_ v: Any) { value = v }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            if let v = value as? Bool { try c.encode(v) }
            else if let v = value as? Int { try c.encode(v) }
            else if let v = value as? Double { try c.encode(v) }
            else if let v = value as? String { try c.encode(v) }
            else { try c.encodeNil() }
        }
    }

    func start(port: UInt16) {
        let params = NWParameters.tcp
        let opts = NWProtocolTCP.Options()
        opts.connectionTimeout = 5
        params.defaultProtocolStack.transportProtocol = opts
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            onLog?("[服务] 监听失败: \(error)")
            return
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state { self.onLog?("[服务] HTTP 服务已启动: 端口 \(port)") }
            else if case .failed(let err) = state { self.onLog?("[服务] 监听失败: \(err)") }
        }
        listener?.newConnectionHandler = { conn in conn.start(queue: self.queue); self.handleConnection(conn) }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func iterateHistory(_ block: (Double, String, String, String) -> Void) {
        for h in history {
            block(h.timestamp, h.state, h.message, h.session_id)
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        var buf = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isDone, err in
                if let data = data { buf.append(data) }
                if let _ = err { conn.cancel(); return }
                if isDone { conn.cancel(); return }
                if self.tryParseRequest(buf, conn: conn) { return }
                readMore()
            }
        }
        readMore()
    }

    private func tryParseRequest(_ data: Data, conn: NWConnection) -> Bool {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerStr = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) ?? ""
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return false }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let method = String(parts[0]), path = String(parts[1])

        var contentLength = 0
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") { contentLength = Int(lower.trimmingCharacters(in: .whitespaces).split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let bodyStart = headEnd.upperBound
        let bodyData = data.count >= bodyStart + contentLength ? data[bodyStart..<bodyStart + contentLength] : nil
        if data.count < bodyStart + contentLength { return false }

        let body = bodyData.flatMap { String(data: $0, encoding: .utf8) }
        let response = route(method: method, path: path, body: body)
        sendResponse(conn: conn, status: response.status, body: response.body)
        return true
    }

    private struct RouteResult { let status: Int; let body: String }

    private func route(method: String, path: String, body: String?) -> RouteResult {
        cleanupStaleSessions()
        switch "\(method) \(path)" {
        case "GET /api/state":
            return .init(status: 200, body: jsonEncode(dictAggregateState()))
        case "GET /api/sessions":
            return .init(status: 200, body: jsonEncode(dictSessions()))
        case "GET /api/history":
            return .init(status: 200, body: jsonEncodeHistory())
        case "POST /api/state":
            return handlePostState(body: body)
        default:
            if method == "DELETE", path.hasPrefix("/api/session/") {
                let sid = String(path.dropFirst("/api/session/".count))
                return handleDeleteSession(sid)
            }
            if method == "POST", path == "/api/permission" {
                return handlePermissionRequest(body: body)
            }
            if method == "GET", path.hasPrefix("/api/permission/") {
                let remainder = String(path.dropFirst("/api/permission/".count))
                let parts = remainder.components(separatedBy: "/")
                let id = parts.first ?? remainder
                // GET /api/permission/<id>/decision — 轮询决策
                if parts.count == 2 && parts[1] == "decision" {
                    return handlePermissionDecision(id: id)
                }
                // GET /api/permission/<id>/allow or /deny — 设置决策
                if parts.count == 2 && (parts[1] == "allow" || parts[1] == "deny") {
                    return handleSetPermissionDecision(id: id, action: parts[1])
                }
                // GET /api/permission/<id> — 也返回决策（兼容）
                return handlePermissionDecision(id: id)
            }
            return .init(status: 404, body: "{\"ok\":false,\"error\":\"not found\"}")
        }
    }

    func updateState(name: String, message: String, sessionId: String) {
        guard STATES[name] != nil else { return }
        let sid = sessionId.isEmpty ? "default" : sessionId
        sessions[sid] = SessionEntry(state: name, message: message, timestamp: Date())
        history.append(HistoryEntry(timestamp: Date().timeIntervalSince1970, state: name, message: message, session_id: String(sid.prefix(8)), light: stateLightDict(name)))
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        onLog?("[状态] [\(sid.prefix(8))] \(name) — \(message)")
        StatsManager.shared.record(state: name, message: message, sessionId: sid)
    }

    private func handlePostState(body: String?) -> RouteResult {
        guard let body = body,
              let raw = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return .init(status: 400, body: "{\"ok\":false,\"error\":\"invalid json\"}")
        }
        let state = raw["state"] as? String ?? ""
        let message = raw["message"] as? String ?? ""
        var sessionId = raw["session_id"] as? String ?? ""
        if sessionId.isEmpty { sessionId = "default" }
        guard STATES[state] != nil else {
            return .init(status: 400, body: "{\"ok\":false,\"error\":\"invalid state: \(state)\"}")
        }
        updateState(name: state, message: message, sessionId: sessionId)
        return .init(status: 200, body: jsonEncode(dictAggregateState()))
    }

    private func handleDeleteSession(_ sid: String) -> RouteResult {
        if sessions.removeValue(forKey: sid) != nil {
            return .init(status: 200, body: "{\"ok\":true}")
        }
        return .init(status: 404, body: "{\"ok\":false,\"error\":\"not found\"}")
    }

    private func cleanupStaleSessions() {
        let now = Date()
        for (sid, s) in sessions where now.timeIntervalSince(s.timestamp) > sessionTimeout && s.state != "idle" {
            onLog?("[清理] 会话超时: \(sid.prefix(16)) \(s.state) → idle")
            sessions[sid] = SessionEntry(state: "idle", message: "超时", timestamp: now)
        }
        sessions = sessions.filter { now.timeIntervalSince($0.value.timestamp) <= deadTimeout }
    }

    // Permission request storage
    private var permissionRequests: [String: [String: Any]] = [:]

    func storeTestPermission(id: String, entry: [String: Any]) {
        permissionRequests[id] = entry
    }

    private func handlePermissionRequest(body: String?) -> RouteResult {
        guard let body = body,
              let raw = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return .init(status: 400, body: "{\"ok\":false,\"error\":\"invalid json\"}")
        }
        let id = "perm-\(Int(Date().timeIntervalSince1970 * 1000))-\(permissionRequests.count)"
        let entry: [String: Any] = [
            "id": id,
            "input": raw,
            "status": "pending",
            "decision": NSNull(),
            "timestamp": Date().timeIntervalSince1970
        ]
        permissionRequests[id] = entry
        onLog?("[权限] 收到请求: \(id)")
        DispatchQueue.main.async {
            self.onPermissionRequest?(entry)
        }
        return .init(status: 200, body: "{\"ok\":true,\"id\":\"\(id)\"}")
    }

    private func handlePermissionDecision(id: String) -> RouteResult {
        let cleanId = String(id.prefix(30))
        guard let entry = permissionRequests[cleanId] else {
            return .init(status: 404, body: "{\"status\":\"unknown\"}")
        }
        let status = entry["status"] as? String ?? "pending"
        if status == "pending" {
            return .init(status: 200, body: "{\"status\":\"pending\"}")
        }
        let decision = entry["decision"] ?? [:]
        return .init(status: 200, body: jsonEncode(["status": "done", "decision": decision] as [String: Any]))
    }

    private func handleSetPermissionDecision(id: String, action: String) -> RouteResult {
        let cleanId = String(id.prefix(30))
        guard permissionRequests[cleanId] != nil else {
            return .init(status: 404, body: "{\"ok\":false,\"error\":\"not found\"}")
        }
        setPermissionDecision(id: cleanId, behavior: action)
        return .init(status: 200, body: "{\"ok\":true}")
    }

    func setPermissionDecision(id: String, behavior: String, addRule: [String: Any]? = nil) {
        guard permissionRequests[id] != nil else { return }
        var decision: [String: Any] = ["decision": behavior]
        if let rule = addRule {
            decision["updatedPermissions"] = [["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "localSettings"]]
        }
        permissionRequests[id]?["status"] = "done"
        permissionRequests[id]?["decision"] = decision
        onLog?("[权限] 决策: \(id) → \(behavior)")
        // Cleanup old entries after decision
        let now = Date().timeIntervalSince1970
        permissionRequests = permissionRequests.filter { now - ($0.value["timestamp"] as? Double ?? 0) < 300 }
    }

    private func stateLightDict(_ state: String) -> [String: AnyCodable] {
        guard let def = STATES[state] else { return [:] }
        return ["red": .init(def.red ? 1 : 0), "yellow": .init(def.yellow ? 1 : 0), "green": .init(def.green ? 1 : 0), "label": .init(def.label), "blink": .init(def.blink)]
    }

    private func dictAggregateState() -> [String: Any] {
        if sessions.isEmpty {
            return ["state": "idle", "timestamp": Date().timeIntervalSince1970, "message": "", "light": stateLightDict("idle").mapValues { $0.value }, "sessions": [:], "active_count": 0] as [String: Any]
        }
        let worst = sessions.max { SEVERITY[$0.value.state] ?? 0 < SEVERITY[$1.value.state] ?? 0 }!
        let active = sessions.values.filter { $0.state != "idle" }.count
        let msg: String
        if sessions.count == 1 { msg = worst.value.message }
        else {
            var counts: [String: Int] = [:]
            for s in sessions.values where s.state != "idle" { counts[s.state, default: 0] += 1 }
            if !counts.isEmpty { msg = "共\(sessions.count)个会话: " + counts.map { "\(STATES[$0.key]?.label ?? $0.key)×\($0.value)" }.joined(separator: ", ") }
            else { msg = "\(sessions.count)个会话均空闲" }
        }
        let sessDict = sessions.mapValues { ["state": $0.state, "message": $0.message, "light": STATES[$0.state]?.label ?? $0.state] } as [String: Any]
        return ["state": worst.value.state, "timestamp": worst.value.timestamp.timeIntervalSince1970, "message": msg, "light": stateLightDict(worst.value.state).mapValues { $0.value }, "sessions": sessDict, "active_count": active] as [String: Any]
    }

    private func dictSessions() -> [String: Any] {
        let now = Date()
        let sess: [String: Any] = sessions.mapValues { s in
            ["state": s.state, "message": s.message, "age": "\(Int(now.timeIntervalSince(s.timestamp)))s", "light": STATES[s.state]?.label ?? s.state] as [String: Any]
        }
        return ["count": sessions.count, "sessions": sess] as [String: Any]
    }

    private func jsonEncode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func jsonEncodeHistory() -> String {
        let arr: [[String: Any]] = history.map { h in
            ["timestamp": h.timestamp, "state": h.state, "message": h.message, "session_id": h.session_id, "light": h.light.mapValues { $0.value }] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func sendResponse(conn: NWConnection, status: Int, body: String) {
        let statusText = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : "Error"
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let data = Data(header.utf8) + Data(body.utf8)
        conn.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// ============================================================
// AppDelegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var config = AppConfig.load()
    var lightWindow: NSWindow!
    var redView: RealTrafficLightView!
    var yellowView: RealTrafficLightView!
    var greenView: RealTrafficLightView!
    var statusLabel: NSTextField!
    var statusItem: NSStatusItem?
    var currentStateName = "idle"
    var lastActiveCount = 0
    var currentBlink = false
    var animPhase: CGFloat = 0  // 动画相位 0~1 循环
    var isRebuilding = false
    var isDragging = false
    var pollTimer: Timer?
    var animTimer: Timer?
    var marqueeText: String = ""
    var marqueeOffset: Int = 0
    var tooltipView: NSView?
    var settingsWindowController: SettingsWindowController?
    var timelineWindowController: TimelineWindowController?
    var mouseDownMonitor: Any?
    var mouseUpMonitor: Any?
    var mouseDragMonitor: Any?
    var edgeSnapTimer: Timer?
    var edgeSnapPending: String?  // "left" or "right" when snap is pending
    var edgePreviewWindow: NSWindow?
    var sessions: [String: [String: Any]] = [:]
    var shellView: ShellView?
    var trafficContainer: TrafficLightContainer?
    var weatherView: WeatherView?

    func log(_ msg: String) {
        let path = "/tmp/codelight.log"
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(data); handle.closeFile() }
            } else { try? data.write(to: URL(fileURLWithPath: path)) }
        }
    }

    var lightServer: LightServer?
    var permissionBubbles: [(id: String, window: NSWindow, toolName: String, command: String, timer: Timer?)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 添加 Edit 菜单支持文本编辑快捷键（Cmd+C/V/X/A/Z）
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem()
        mainMenu.addItem(appMenu)
        let appSubMenu = NSMenu(title: "CodeLight")
        appSubMenu.addItem(withTitle: "关于 CodeLight", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appSubMenu.addItem(NSMenuItem.separator())
        appSubMenu.addItem(withTitle: "隐藏 CodeLight", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appSubMenu.addItem(NSMenuItem.separator())
        appSubMenu.addItem(withTitle: "退出 CodeLight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.submenu = appSubMenu
        let editMenu = NSMenuItem()
        mainMenu.addItem(editMenu)
        let editSubMenu = NSMenu(title: "编辑")
        editSubMenu.addItem(withTitle: "撤销", action: Selector("undo:"), keyEquivalent: "z")
        editSubMenu.addItem(withTitle: "重做", action: Selector("redo:"), keyEquivalent: "Z")
        editSubMenu.addItem(NSMenuItem.separator())
        editSubMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editSubMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editSubMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editSubMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.submenu = editSubMenu
        NSApplication.shared.mainMenu = mainMenu

        // 防止多开：已有实例时激活并退出
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.codelight.app")
        if running.count > 1 {
            if let other = running.first(where: { $0 != NSRunningApplication.current }) {
                other.activate()
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.log("[通知] UN权限: \(granted), err: \(String(describing: error))")
        }
        buildAppMainMenu()
        startServer()
        buildMenuBar()
        buildLightWindow()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildLightWindow()
        }
        startTimers()
        pollState()
        if config.weatherThemeEnabled {
            WeatherManager.shared.onWeatherUpdate = { [weak self] condition, temp in
                self?.weatherView?.condition = condition
                self?.weatherView?.weatherCode = WeatherManager.shared.weatherCode
                self?.log("[天气] \(condition.displayName(code: WeatherManager.shared.weatherCode)) \(Int(temp))°C")
            }
            WeatherManager.shared.startPolling()
        }

        // 全局快捷键
        HotkeyManager.shared.onToggleWindow = { [weak self] in self?.toggleWindow() }
        HotkeyManager.shared.onCycleMode = { [weak self] in self?.handleDoubleClick(NSClickGestureRecognizer()) }
        HotkeyManager.shared.start()

        log("[启动] OK")
        checkHookSetup()
    }

    private func checkHookSetup() {
        if config.hookSetupDismissed { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if hasCodeLightHook(path: home + "/.claude/settings.json") { return }
        if hasCodeLightHook(path: home + "/.codex/hooks.json") { return }
        if hasCodeLightHook(path: home + "/.cursor/settings.json") { return }

        let alert = NSAlert()
        alert.messageText = "配置 Hook"
        alert.informativeText = "检测到尚未配置任何 AI 编程助手的 Hook，红绿灯无法自动切换状态。\n\n请在「设置 → 配置 Hook」中勾选你使用的工具并应用配置。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "去配置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        } else {
            config.hookSetupDismissed = true
            config.save()
        }
    }

    private func hasCodeLightHook(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        for (_, val) in hooks {
            if let arr = val as? [[String: Any]] {
                for entry in arr {
                    if let hookArr = entry["hooks"] as? [[String: Any]] {
                        for h in hookArr {
                            if let cmd = h["command"] as? String, cmd.contains("8866/api/state") { return true }
                        }
                    }
                }
            }
        }
        return false
    }

    func startServer() {
        let portStr = config.serverURL.components(separatedBy: ":").last ?? "8866"
        let port = UInt16(portStr) ?? 8866
        let server = LightServer()
        server.onLog = { [weak self] msg in DispatchQueue.main.async { self?.log(msg) } }
        server.onPermissionRequest = { [weak self] entry in DispatchQueue.main.async { self?.showPermissionBubble(entry) } }
        server.start(port: port)
        lightServer = server
        checkServerReachability()
    }

    func checkServerReachability() {
        guard let url = URL(string: "\(config.serverURL)/api/state") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200, data != nil {
                    self.log("[检测] 端口连通 ✓")
                } else {
                    let msg = error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    self.log("[检测] 端口不通: \(msg)")
                }
            }
        }.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lightServer?.stop()
        log("[退出] 服务已停止")
    }

    // Menu methods moved to MenuBuilder.swift

    // Permission bubble methods moved to PermissionBubble.swift


    // Light window + edge snap methods moved to LightWindowBuilder.swift

    // Animation + poll methods moved to LightAnimator.swift

    @objc func toggleWindow() {
        if lightWindow.isVisible { lightWindow.orderOut(nil) } else { lightWindow.makeKeyAndOrderFront(nil) }
    }
    @objc func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
        let modes = ["vertical", "horizontal", "mini", "edgebar"]
        let idx = modes.firstIndex(of: config.displayMode) ?? 0
        config.displayMode = modes[(idx + 1) % modes.count]
        config.horizontal = (config.displayMode == "horizontal")
        config.edgeBar = (config.displayMode == "edgebar") ? (config.edgeBar ?? "right") : nil
        config.save()
        rebuildWithCurrentConfig()
        settingsWindowController?.syncFromConfig()
    }
    @objc func openSettings() {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(appDelegate: self) }
        settingsWindowController?.syncFromConfig()
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openTimeline() {
        if timelineWindowController == nil { timelineWindowController = TimelineWindowController(appDelegate: self) }
        timelineWindowController?.loadHistory()
        timelineWindowController?.window?.center()
        timelineWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func resetWindowPosition() { resetPosition() }

    @objc func switchDisplayMode(_ sender: NSMenuItem) {
        let modes = ["vertical", "horizontal", "mini", "edgebar"]
        guard sender.tag < modes.count else { return }
        config.displayMode = modes[sender.tag]
        config.horizontal = (config.displayMode == "horizontal")
        config.edgeBar = (config.displayMode == "edgebar") ? (config.edgeBar ?? "right") : nil
        config.save()
        rebuildWithCurrentConfig()
        // 更新子菜单勾选状态
        if let menu = (statusItem?.menu?.items.first { $0.submenu?.title == "显示样式" })?.submenu {
            for item in menu.items { item.state = (item.tag == sender.tag) ? .on : .off }
        }
        settingsWindowController?.syncFromConfig()
    }

    @objc func menuCheckForUpdate() {
        let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["gh", "api", "repos/guandeng/code-light/releases/latest", "--jq", ".tag_name"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.launch()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let alert = NSAlert(); alert.messageText = "检查失败"; alert.informativeText = "请确认已安装 gh 并登录"; alert.runModal()
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tagName = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latestVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if latestVer.compare(currentVer, options: .numeric) == .orderedDescending {
            let alert = NSAlert(); alert.messageText = "发现新版本 \(tagName)"; alert.informativeText = "当前版本 v\(currentVer)"
            alert.addButton(withTitle: "去下载"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "https://github.com/guandeng/code-light/releases/latest") { NSWorkspace.shared.open(url) }
            }
        } else {
            let alert = NSAlert(); alert.messageText = "当前已是最新版本"; alert.informativeText = "v\(currentVer)"; alert.runModal()
        }
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/guandeng/code-light") { NSWorkspace.shared.open(url) }
    }

    @objc func resetPosition() {
        config.windowX = nil
        config.windowY = nil
        config.edgeBar = nil
        config.save()
        buildLightWindow()
    }

    /// 从磁盘重新加载配置并重建窗口（保存后调用）
    func restartWithNewConfig() {
        let oldHorizontal = config.horizontal
        config = AppConfig.load()
        rebuildWindow(from: oldHorizontal)
    }

    /// 用内存中当前 config 直接重建窗口（实时预览用，不读磁盘）
    func rebuildWithCurrentConfig() {
        let oldHorizontal = config.horizontal
        rebuildWindow(from: oldHorizontal)
    }

    private func rebuildWindow(from oldHorizontal: Bool) {
        let oldMode = ["vertical": 0, "horizontal": 1, "mini": 2][oldHorizontal ? "horizontal" : "vertical"] ?? 0
        let newMode = ["vertical": 0, "horizontal": 1, "mini": 2][config.displayMode] ?? 0
        NSApp.setActivationPolicy(.regular)

        if config.weatherThemeEnabled {
            WeatherManager.shared.onWeatherUpdate = { [weak self] condition, temp in
                self?.weatherView?.condition = condition
                self?.weatherView?.weatherCode = WeatherManager.shared.weatherCode
            }
            WeatherManager.shared.startPolling()
        } else {
            WeatherManager.shared.stopPolling()
        }

        if oldMode != newMode, let view = lightWindow.contentView {
            let transition = CATransition()
            transition.type = CATransitionType(rawValue: "flip")
            transition.subtype = newMode > oldMode ? .fromRight : .fromLeft
            transition.duration = 0.45
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(transition, forKey: "orientFlip")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                self.buildLightWindow(); self.startTimers(); self.pollState()
            }
        } else {
            buildLightWindow(); startTimers(); pollState()
        }
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// ============================================================
// WeatherManager — Open-Meteo 天气数据获取
// ============================================================


// ============================================================
// WeatherView — 天气动画背景层
// ============================================================


// ============================================================
// TrafficLightContainer — 自适应灯容器，resize 时自动调整灯的大小和位置
// ============================================================
// AppDelegate + UNUserNotificationCenterDelegate
// ============================================================

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// ============================================================


// ============================================================
// RealTrafficLightView — 仿真灯珠
// ============================================================


// ============================================================
// SettingsWindowController
// ============================================================

class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// ============================================================
// TimelineWindowController — 今日工作状态时间线窗口
// ============================================================

class TimelineWindowController: NSWindowController, NSWindowDelegate {
    let appDelegate: AppDelegate
    var timelineView: TimelineView!

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let rect = NSRect(x: 0, y: 0, width: 680, height: 260)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "今日 AI 工作时间线"
        win.minSize = NSSize(width: 500, height: 200)
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(white: 0.12, alpha: 1)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.level = .floating
        super.init(window: win)
        win.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let cv = window?.contentView else { return }
        timelineView = TimelineView(frame: cv.bounds)
        timelineView.autoresizingMask = [.width, .height]
        cv.addSubview(timelineView)
        loadHistory()
    }

    func loadHistory() {
        guard let server = appDelegate.lightServer else { return }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date()).timeIntervalSince1970
        var items: [TimelineEntry] = []
        // 通过反射访问 history（同进程）
        server.iterateHistory { ts, state, msg, sid in
            if ts >= todayStart {
                items.append(TimelineEntry(timestamp: ts, state: state, message: msg, sessionId: sid))
            }
        }
        timelineView.entries = items
    }

    func windowDidBecomeKey(_ notification: Notification) {
        loadHistory()
    }
}

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let appDelegate: AppDelegate
    var serverField: NSTextField!
    var portTestLabel: NSTextField!
    var updateStatusLabel: NSTextField!
    var pollSlider: NSSlider!; var pollLabel: NSTextField!
    var opacitySlider: NSSlider!; var opacityLabel: NSTextField!
    var blinkSlider: NSSlider!; var blinkLabel: NSTextField!
    var autoLaunchCheck: NSButton!
    var notifyCheck: NSButton!
    var soundSelect: NSPopUpButton!
    var permNotifyCheck: NSButton!
    var fullscreenCheck: NSButton!
    var floatingCheck: NSButton!
    var mascotSelect: NSPopUpButton!
    var horizontalCheck: NSButton!
    var displayModeSegment: NSSegmentedControl!
    var showStatusCheck: NSButton!
    var sizeSlider: NSSlider!; var sizeLabel: NSTextField!
    var rulesContainer: NSView!
    var hookContainer: NSView!
    var statsContainer: NSView!
    var statsRefreshTimer: Timer?
    var claudeCodeCheck: NSButton!
    var codexCheck: NSButton!
    var cursorCheck: NSButton!
    var hookStatusLabel: NSTextField!
    var themeSelect: NSPopUpButton!
    var colorWell: NSColorWell!
    var weatherCheck: NSButton!
    var weatherStatusLabel: NSTextField!
    var citySelect: NSPopUpButton!
    // Sidebar navigation
    var sidebarButtons: [NSButton] = []
    var containers: [NSView] = []
    var generalContainer: NSView!
    var appearanceContainer: NSView!
    var behaviorContainer: NSView!
    let sidebarItems = ["⚙️ 通用", "🎨 外观", "🎯 行为", "💡 灯效规则", "🔗 配置 Hook", "📊 统计"]

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "CodeLight 设置"; win.isReleasedWhenClosed = false
        super.init(window: win); win.delegate = self; buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    func syncFromConfig() {
        let c = appDelegate.config
        let modeIdx = ["vertical": 0, "horizontal": 1, "mini": 2, "edgebar": 3][c.displayMode] ?? 0
        displayModeSegment.selectedSegment = modeIdx
        opacitySlider.doubleValue = c.opacity; opacityLabel.stringValue = "\(Int(c.opacity * 100))%"
        pollSlider.doubleValue = c.pollInterval; pollLabel.stringValue = String(format: "%.1fs", c.pollInterval)
        blinkSlider.doubleValue = c.blinkSpeed; blinkLabel.stringValue = String(format: "%.1fs", c.blinkSpeed)
        sizeSlider.doubleValue = c.windowSize; sizeLabel.stringValue = "\(Int(c.windowSize))"
        let port = c.serverURL.components(separatedBy: ":").last ?? "8866"
        serverField.stringValue = port
        autoLaunchCheck.state = c.autoLaunch ? .on : .off
        notifyCheck.state = c.notifyOnDone ? .on : .off
        permNotifyCheck.state = c.notifyOnPermission ? .on : .off
        fullscreenCheck.state = c.showOnFullscreen ? .on : .off
        floatingCheck.state = c.isFloating ? .on : .off
        showStatusCheck.state = c.showStatusText ? .on : .off
        mascotSelect.selectItem(at: ["cow": 0, "cat": 1, "robot": 2, "horse": 3, "chicken": 4][c.mascotType] ?? 0)
        themeSelect.selectItem(at: ["dark": 0, "light": 1, "custom": 2][c.theme] ?? 0)
        colorWell.color = NSColor(fromHex: c.customColor) ?? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        colorWell.isHidden = c.theme != "custom"
        weatherCheck.state = c.weatherThemeEnabled ? .on : .off
        citySelect.selectItem(withTitle: c.weatherCity)
    }

    func buildUI() {
        guard let view = window?.contentView else { return }
        let c = appDelegate.config
        let sideW: CGFloat = 150
        let contentW: CGFloat = 430
        let contentH: CGFloat = 620
        let bottomH: CGFloat = 50
        let mainH = contentH - bottomH

        // --- Left Sidebar ---
        let sidebarBg = NSView(frame: NSRect(x: 0, y: 0, width: sideW, height: contentH))
        sidebarBg.wantsLayer = true
        sidebarBg.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.addSubview(sidebarBg)

        // Sidebar buttons (replacing NSTableView for reliable click handling)
        let btnH: CGFloat = 36
        let btnGap: CGFloat = 2
        let startY: CGFloat = contentH - 16 - btnH  // top area, non-flipped coords
        sidebarButtons = []
        for (i, title) in sidebarItems.enumerated() {
            let btn = NSButton(frame: NSRect(x: 0, y: startY - CGFloat(i) * (btnH + btnGap), width: sideW, height: btnH))
            btn.title = "  \(title)"
            btn.font = NSFont.systemFont(ofSize: 13, weight: i == 0 ? .semibold : .regular)
            btn.alignment = .left
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 4
            btn.tag = i
            btn.target = self
            btn.action = #selector(sidebarButtonClicked(_:))
            if i == 0 {
                btn.contentTintColor = NSColor.controlAccentColor
                btn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            }
            sidebarBg.addSubview(btn)
            sidebarButtons.append(btn)
        }

        let rightSep = NSView(frame: NSRect(x: sideW, y: 0, width: 1, height: contentH))
        rightSep.wantsLayer = true; rightSep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(rightSep)

        // --- Right Content Area ---
        let contentArea = NSView(frame: NSRect(x: sideW + 1, y: 0, width: contentW, height: contentH))
        view.addSubview(contentArea)

        generalContainer = FlippedView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: mainH))
        appearanceContainer = FlippedView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: mainH))
        behaviorContainer = FlippedView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: mainH))

        buildGeneralSection(generalContainer!, c)
        buildAppearanceSection(appearanceContainer!, c)
        buildBehaviorSection(behaviorContainer!, c)

        let rulesDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: 700))
        let rulesContentHeight = buildRulesTab(rulesDoc)
        rulesDoc.frame.size.height = max(rulesContentHeight, mainH)
        let rulesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        rulesScroll.documentView = rulesDoc
        rulesScroll.hasVerticalScroller = true
        rulesScroll.autohidesScrollers = true
        rulesScroll.drawsBackground = false
        rulesContainer = NSView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: mainH))
        rulesContainer.addSubview(rulesScroll)

        hookContainer = NSView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: mainH))
        buildHookTab(hookContainer!)

        let statsDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: 900))
        buildStatsTab(statsDoc, c)
        statsContainer = NSView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: mainH))
        statsContainer.wantsLayer = true
        statsContainer.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.95).cgColor
        let statsScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        statsScroll.documentView = statsDoc
        statsScroll.hasVerticalScroller = true
        statsScroll.autohidesScrollers = true
        statsScroll.drawsBackground = false
        statsScroll.backgroundColor = .clear
        statsContainer.addSubview(statsScroll)

        containers = [generalContainer!, appearanceContainer!, behaviorContainer!, rulesContainer!, hookContainer!, statsContainer!]
        for (i, container) in containers.enumerated() {
            contentArea.addSubview(container)
            container.isHidden = (i != 0)
        }

        // --- Bottom Bar ---
        let bottomSep = NSView(frame: NSRect(x: 0, y: bottomH, width: contentW, height: 1))
        bottomSep.wantsLayer = true; bottomSep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        contentArea.addSubview(bottomSep)

        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: bottomH))
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentArea.addSubview(bottomBar)

        let saveBtn = NSButton(frame: NSRect(x: 20, y: 12, width: 120, height: 32))
        saveBtn.title = "保存并应用"; saveBtn.bezelStyle = .rounded
        saveBtn.target = self; saveBtn.action = #selector(saveSettings)
        bottomBar.addSubview(saveBtn)

        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        let versionLabel = NSTextField(frame: NSRect(x: 160, y: 16, width: 120, height: 20))
        versionLabel.isEditable = false; versionLabel.isBordered = false; versionLabel.backgroundColor = .clear
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = NSColor.tertiaryLabelColor
        versionLabel.stringValue = "CodeLight v\(ver)"
        bottomBar.addSubview(versionLabel)
    }

    // MARK: - Section Builders

    func buildGeneralSection(_ view: NSView, _ c: AppConfig) {
        var y: CGFloat = 16
        let rx: CGFloat = 130

        func label(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 110, height: 24))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 13); l.alignment = .right
            view.addSubview(l)
        }

        func sectionTitle(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 300, height: 20))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            l.textColor = NSColor.secondaryLabelColor
            view.addSubview(l)
        }

        sectionTitle("连接", y); y += 28
        label("服务端口:", y)
        serverField = NSTextField(frame: NSRect(x: rx, y: y, width: 100, height: 24))
        let port = c.serverURL.components(separatedBy: ":").last ?? "8866"
        serverField.stringValue = port; serverField.font = NSFont.systemFont(ofSize: 12)
        serverField.placeholderString = "8866"
        view.addSubview(serverField)

        let testBtn = NSButton(frame: NSRect(x: rx + 108, y: y, width: 56, height: 24))
        testBtn.title = "测试"; testBtn.bezelStyle = .rounded; testBtn.font = NSFont.systemFont(ofSize: 11)
        testBtn.target = self; testBtn.action = #selector(testPortAction(_:))
        view.addSubview(testBtn)

        portTestLabel = NSTextField(frame: NSRect(x: rx + 170, y: y + 4, width: 140, height: 16))
        portTestLabel.isEditable = false; portTestLabel.isBordered = false
        portTestLabel.backgroundColor = .clear; portTestLabel.font = NSFont.systemFont(ofSize: 11)
        portTestLabel.stringValue = ""
        view.addSubview(portTestLabel); y += 36

        label("轮询间隔:", y + 4)
        pollSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        pollSlider.minValue = 0.1; pollSlider.maxValue = 3.0; pollSlider.doubleValue = c.pollInterval
        pollSlider.target = self; pollSlider.action = #selector(sliderChanged)
        view.addSubview(pollSlider)
        pollLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        pollLabel.isEditable = false; pollLabel.isBordered = false; pollLabel.backgroundColor = .clear
        pollLabel.stringValue = String(format: "%.1fs", c.pollInterval); pollLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(pollLabel); y += 36

        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        let checkUpdateBtn = NSButton(frame: NSRect(x: rx, y: y + 2, width: 80, height: 24))
        checkUpdateBtn.title = "检查更新"; checkUpdateBtn.bezelStyle = .rounded
        checkUpdateBtn.font = NSFont.systemFont(ofSize: 11)
        checkUpdateBtn.target = self; checkUpdateBtn.action = #selector(checkForUpdate)
        view.addSubview(checkUpdateBtn)
        updateStatusLabel = NSTextField(frame: NSRect(x: rx + 90, y: y + 4, width: 200, height: 20))
        updateStatusLabel.isEditable = false; updateStatusLabel.isBordered = false; updateStatusLabel.backgroundColor = .clear
        updateStatusLabel.font = NSFont.systemFont(ofSize: 11); updateStatusLabel.textColor = NSColor.tertiaryLabelColor
        updateStatusLabel.stringValue = "v\(ver)"
        view.addSubview(updateStatusLabel)
    }

    func buildAppearanceSection(_ view: NSView, _ c: AppConfig) {
        var y: CGFloat = 16
        let rx: CGFloat = 130

        func label(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 110, height: 24))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 13); l.alignment = .right
            view.addSubview(l)
        }

        func sectionTitle(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 300, height: 20))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            l.textColor = NSColor.secondaryLabelColor
            view.addSubview(l)
        }

        sectionTitle("外观", y); y += 28

        label("透明度:", y + 4)
        opacitySlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        opacitySlider.minValue = 0.3; opacitySlider.maxValue = 1.0; opacitySlider.doubleValue = c.opacity
        opacitySlider.target = self; opacitySlider.action = #selector(sliderChanged)
        view.addSubview(opacitySlider)
        opacityLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        opacityLabel.isEditable = false; opacityLabel.isBordered = false; opacityLabel.backgroundColor = .clear
        opacityLabel.stringValue = "\(Int(c.opacity * 100))%"; opacityLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(opacityLabel); y += 32

        label("吉祥物:", y + 4)
        mascotSelect = NSPopUpButton(frame: NSRect(x: rx, y: y + 2, width: 140, height: 24))
        mascotSelect.addItems(withTitles: ["🐂 小牛", "🐱 小猫", "🤖 机器人", "🐴 小马", "🏀 小鸡"])
        mascotSelect.selectItem(at: ["cow": 0, "cat": 1, "robot": 2, "horse": 3, "chicken": 4][c.mascotType] ?? 0)
        mascotSelect.target = self; mascotSelect.action = #selector(mascotChanged)
        view.addSubview(mascotSelect); y += 32

        label("主题:", y + 4)
        themeSelect = NSPopUpButton(frame: NSRect(x: rx, y: y + 2, width: 140, height: 24))
        themeSelect.addItems(withTitles: ["🌙 深色", "☀️ 浅色", "🎨 自定义"])
        themeSelect.selectItem(at: ["dark": 0, "light": 1, "custom": 2][c.theme] ?? 0)
        themeSelect.target = self; themeSelect.action = #selector(themeChanged)
        view.addSubview(themeSelect)

        colorWell = NSColorWell(frame: NSRect(x: rx + 150, y: y, width: 28, height: 24))
        colorWell.color = NSColor(fromHex: c.customColor) ?? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        colorWell.isHidden = c.theme != "custom"
        colorWell.target = self; colorWell.action = #selector(themeChanged)
        view.addSubview(colorWell); y += 32

        weatherCheck = NSButton(frame: NSRect(x: rx, y: y, width: 220, height: 24))
        weatherCheck.setButtonType(.switch); weatherCheck.title = "天气主题（实时天气背景）"
        weatherCheck.state = c.weatherThemeEnabled ? .on : .off
        weatherCheck.target = self; weatherCheck.action = #selector(toggleInstant(_:))
        view.addSubview(weatherCheck); y += 24

        weatherStatusLabel = NSTextField(frame: NSRect(x: rx + 10, y: y + 4, width: 200, height: 16))
        weatherStatusLabel.isEditable = false; weatherStatusLabel.isBordered = false
        weatherStatusLabel.backgroundColor = .clear; weatherStatusLabel.font = NSFont.systemFont(ofSize: 10)
        weatherStatusLabel.textColor = NSColor.tertiaryLabelColor
        weatherStatusLabel.toolTip = "双击循环切换天气预览"
        weatherStatusLabel.alignment = .left
        if c.weatherThemeEnabled {
            let wm = WeatherManager.shared
            weatherStatusLabel.stringValue = "\(wm.currentCondition.displayName(code: wm.weatherCode)) \(Int(wm.currentTemp))°C"
        }
        view.addSubview(weatherStatusLabel)

        let cityNames = CITIES.map { $0.name }
        citySelect = NSPopUpButton(frame: NSRect(x: rx + 210, y: y - 2, width: 90, height: 24))
        citySelect.addItems(withTitles: cityNames)
        citySelect.selectItem(withTitle: c.weatherCity)
        citySelect.target = self; citySelect.action = #selector(cityChanged)
        citySelect.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(citySelect)

        let dblClickView = DoubleClickView(frame: NSRect(x: rx + 10, y: y, width: 200, height: 24))
        dblClickView.onDoubleClick = { [weak self] in self?.cycleWeatherPreview() }
        view.addSubview(dblClickView)
        y += 32

        label("闪烁速度:", y + 4)
        blinkSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        blinkSlider.minValue = 0.2; blinkSlider.maxValue = 2.0; blinkSlider.doubleValue = c.blinkSpeed
        blinkSlider.target = self; blinkSlider.action = #selector(sliderChanged)
        view.addSubview(blinkSlider)
        blinkLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        blinkLabel.isEditable = false; blinkLabel.isBordered = false; blinkLabel.backgroundColor = .clear
        blinkLabel.stringValue = String(format: "%.1fs", c.blinkSpeed); blinkLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(blinkLabel); y += 32

        label("窗口大小:", y + 4)
        sizeSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        sizeSlider.minValue = 30; sizeSlider.maxValue = 120; sizeSlider.doubleValue = c.windowSize
        sizeSlider.target = self; sizeSlider.action = #selector(sizeSliderChanged)
        view.addSubview(sizeSlider)
        sizeLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        sizeLabel.isEditable = false; sizeLabel.isBordered = false; sizeLabel.backgroundColor = .clear
        sizeLabel.stringValue = "\(Int(c.windowSize))"; sizeLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(sizeLabel); y += 32

        label("显示样式:", y + 4)
        displayModeSegment = NSSegmentedControl(labels: ["竖向", "横向", "迷你", "磁吸"], trackingMode: .selectOne, target: self, action: #selector(displayModeChanged))
        displayModeSegment.frame = NSRect(x: rx, y: y, width: 240, height: 24)
        displayModeSegment.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let modeIdx = ["vertical": 0, "horizontal": 1, "mini": 2, "edgebar": 3][c.displayMode] ?? 0
        displayModeSegment.selectedSegment = modeIdx
        view.addSubview(displayModeSegment)

        horizontalCheck = NSButton(frame: NSRect(x: -999, y: -999, width: 1, height: 1))
        horizontalCheck.setButtonType(.switch); horizontalCheck.state = c.horizontal ? .on : .off
        view.addSubview(horizontalCheck); y += 36

        showStatusCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        showStatusCheck.setButtonType(.switch); showStatusCheck.title = "显示底部状态文字"
        showStatusCheck.state = c.showStatusText ? .on : .off
        showStatusCheck.target = self; showStatusCheck.action = #selector(toggleInstant(_:))
        view.addSubview(showStatusCheck)
    }

    func buildBehaviorSection(_ view: NSView, _ c: AppConfig) {
        var y: CGFloat = 16
        let rx: CGFloat = 130

        func sectionTitle(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 300, height: 20))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            l.textColor = NSColor.secondaryLabelColor
            view.addSubview(l)
        }

        sectionTitle("行为", y); y += 28

        autoLaunchCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        autoLaunchCheck.setButtonType(.switch); autoLaunchCheck.title = "开机自动启动"
        autoLaunchCheck.state = c.autoLaunch ? .on : .off
        autoLaunchCheck.target = self; autoLaunchCheck.action = #selector(toggleInstant(_:))
        view.addSubview(autoLaunchCheck); y += 32

        notifyCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        notifyCheck.setButtonType(.switch); notifyCheck.title = "任务完成时发送通知"
        notifyCheck.state = c.notifyOnDone ? .on : .off
        notifyCheck.target = self; notifyCheck.action = #selector(toggleInstant(_:))
        view.addSubview(notifyCheck); y += 32

        let soundLabel = NSTextField(labelWithString: "完成提示音:")
        soundLabel.frame = NSRect(x: rx, y: y + 4, width: 80, height: 18)
        view.addSubview(soundLabel)
        let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Tink", "default", "none"]
        soundSelect = NSPopUpButton(frame: NSRect(x: rx + 88, y: y, width: 150, height: 26))
        soundSelect.addItems(withTitles: sounds)
        if let idx = sounds.firstIndex(of: c.completionSound) { soundSelect.selectItem(at: idx) }
        view.addSubview(soundSelect); y += 36

        permNotifyCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        permNotifyCheck.setButtonType(.switch); permNotifyCheck.title = "权限请求弹窗确认"
        permNotifyCheck.state = c.notifyOnPermission ? .on : .off
        permNotifyCheck.target = self; permNotifyCheck.action = #selector(toggleInstant(_:))
        view.addSubview(permNotifyCheck); y += 32

        fullscreenCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        fullscreenCheck.setButtonType(.switch); fullscreenCheck.title = "全屏应用上层显示"
        fullscreenCheck.state = c.showOnFullscreen ? .on : .off
        fullscreenCheck.target = self; fullscreenCheck.action = #selector(toggleInstant(_:))
        view.addSubview(fullscreenCheck); y += 32

        floatingCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        floatingCheck.setButtonType(.switch); floatingCheck.title = "窗口悬浮置顶"
        floatingCheck.state = c.isFloating ? .on : .off
        floatingCheck.target = self; floatingCheck.action = #selector(toggleInstant(_:))
        view.addSubview(floatingCheck)
    }

    @discardableResult
    func buildRulesTab(_ view: NSView) -> CGFloat {
        var y: CGFloat = 16
        let rules = [
            ("🟢 绿灯常亮", "空闲中", "AI 待命中，无操作。绿灯纯色常亮，不闪烁。"),
            ("🟡 黄灯呼吸", "思考中", "AI 正在读代码、分析逻辑、检索上下文。亮度在 30%~100% 间平滑呼吸。"),
            ("🔴 红灯开关", "执行中", "AI 正在调用工具（Bash/Read/Edit 等）。红灯开关闪烁，约 1 秒一周期。"),
            ("🟡 黄灯快呼吸", "修复中", "工具调用失败后自动重试。黄灯快速呼吸，亮度 30%~100%。"),
            ("🔴 红灯快闪", "警告中", "会话异常终止或出错。红灯快速开关闪烁，约 0.5 秒一周期。"),
            ("🔴 红灯快闪", "等待授权", "AI 请求用户权限确认。红灯快速开关闪烁，提示需要操作。"),
        ]

        for (title, subtitle, desc) in rules {
            let titleField = NSTextField(frame: NSRect(x: 16, y: y, width: 320, height: 24))
            titleField.isEditable = false; titleField.isBordered = false; titleField.backgroundColor = .clear
            titleField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            titleField.stringValue = "\(title)  —  \(subtitle)"
            view.addSubview(titleField); y += 26

            let descField = NSTextField(frame: NSRect(x: 28, y: y, width: 300, height: 42))
            descField.isEditable = false; descField.isBordered = false; descField.backgroundColor = .clear
            descField.font = NSFont.systemFont(ofSize: 11)
            descField.textColor = NSColor(white: 0.45, alpha: 1.0)
            descField.stringValue = desc
            descField.cell?.wraps = true
            view.addSubview(descField); y += 54
        }

        // 分隔线
        let sep = NSView(frame: NSRect(x: 16, y: y, width: 328, height: 1))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(sep); y += 12

        // 测试体验标题
        let testTitle = NSTextField(frame: NSRect(x: 16, y: y, width: 300, height: 20))
        testTitle.isEditable = false; testTitle.isBordered = false; testTitle.backgroundColor = .clear
        testTitle.stringValue = "测试体验 — 点击按钮实时预览灯效"
        testTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        testTitle.textColor = NSColor.secondaryLabelColor
        view.addSubview(testTitle); y += 30

        // 5 个测试按钮 + 1 个恢复按钮，两行排列
        let testButtons: [(String, String)] = [
            ("空闲", "idle"), ("思考", "thinking"), ("执行", "working"), ("修复", "fixing"), ("错误", "error"),
        ]
        let btnW: CGFloat = 56, btnH: CGFloat = 26, gap: CGFloat = 4
        let startX: CGFloat = 16
        for (i, (label, state)) in testButtons.enumerated() {
            let btn = NSButton(frame: NSRect(x: startX + CGFloat(i) * (btnW + gap), y: y, width: btnW, height: btnH))
            btn.title = label; btn.bezelStyle = .rounded; btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            btn.tag = ["idle": 0, "thinking": 1, "working": 2, "fixing": 3, "error": 4][state] ?? 0
            btn.target = self; btn.action = #selector(testLightState(_:))
            view.addSubview(btn)
        }

        // 恢复按钮
        let resetBtn = NSButton(frame: NSRect(x: startX + 5 * (btnW + gap), y: y, width: btnW, height: btnH))
        resetBtn.title = "恢复"; resetBtn.bezelStyle = .rounded; resetBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        resetBtn.target = self; resetBtn.action = #selector(testLightReset(_:))
        view.addSubview(resetBtn)
        y += 32

        // 权限请求测试按钮
        let permTestBtn = NSButton(frame: NSRect(x: 16, y: y, width: 120, height: btnH))
        permTestBtn.title = "模拟权限请求"; permTestBtn.bezelStyle = .rounded
        permTestBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        permTestBtn.target = self; permTestBtn.action = #selector(testPermissionRequest(_:))
        view.addSubview(permTestBtn)
        y += 34

        // 测试状态标签
        let testStatusLabel = NSTextField(frame: NSRect(x: 16, y: y, width: 340, height: 18))
        testStatusLabel.isEditable = false; testStatusLabel.isBordered = false; testStatusLabel.backgroundColor = .clear
        testStatusLabel.font = NSFont.systemFont(ofSize: 11)
        testStatusLabel.textColor = NSColor.tertiaryLabelColor
        testStatusLabel.stringValue = "点击上方按钮，观察红绿灯实时切换效果"
        testStatusLabel.tag = 999
        view.addSubview(testStatusLabel)
        return y + 18
    }

    @objc func testLightState(_ sender: NSButton) {
        let states = ["idle", "thinking", "working", "fixing", "error"]
        let labels = ["空闲", "思考", "执行", "修复", "警告"]
        let idx = sender.tag
        guard idx >= 0, idx < states.count else { return }
        let state = states[idx]
        let label = labels[idx]
        let port = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/state") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"state\": \"\(state)\", \"message\": \"测试: \(label)\", \"session_id\": \"test-preview\"}".utf8)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let label = self.rulesContainer?.viewWithTag(999) as? NSTextField {
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                        label.stringValue = "当前预览: \(label)  ✅"
                        label.textColor = NSColor.systemGreen
                    } else {
                        label.stringValue = "切换失败，请检查服务"
                        label.textColor = NSColor.systemRed
                    }
                }
            }
        }.resume()
    }

    @objc func testLightReset(_ sender: NSButton) {
        let port = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        // 清除测试会话
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/session/test-preview") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let label = self.rulesContainer?.viewWithTag(999) as? NSTextField {
                    label.stringValue = "已恢复，点击上方按钮重新测试"
                    label.textColor = NSColor.tertiaryLabelColor
                }
            }
        }.resume()
    }

    @objc func testPermissionRequest(_ sender: NSButton) {
        let id = "test-\(Int(Date().timeIntervalSince1970 * 1000))"
        let testEntry: [String: Any] = [
            "id": id,
            "input": [
                "tool_name": "Bash",
                "tool_input": ["command": "npm run build --production"],
                "session_id": "test-session"
            ],
            "status": "pending",
            "timestamp": Date().timeIntervalSince1970
        ]
        appDelegate.lightServer?.storeTestPermission(id: id, entry: testEntry)
        appDelegate.showPermissionBubble(testEntry)
    }

    // ============================================================
    // Hook 配置页
    // ============================================================

    func buildHookTab(_ view: NSView) {
        var y: CGFloat = 540

        func sectionTitle(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 340, height: 20))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            l.textColor = NSColor.secondaryLabelColor
            view.addSubview(l)
        }

        func descLabel(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 28, y: yy - 8, width: 320, height: 32))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = NSColor(white: 0.45, alpha: 1.0)
            l.stringValue = text; l.cell?.wraps = true
            view.addSubview(l)
        }

        // 端口提示
        let currentPort = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        let portInfo = NSTextField(frame: NSRect(x: 16, y: y + 2, width: 340, height: 20))
        portInfo.isEditable = false; portInfo.isBordered = false; portInfo.backgroundColor = .clear
        portInfo.font = NSFont.systemFont(ofSize: 11)
        portInfo.textColor = NSColor.secondaryLabelColor
        portInfo.stringValue = "当前服务端口: \(currentPort)  (可在「设置」页修改)"
        view.addSubview(portInfo); y -= 28

        // 标题
        sectionTitle("选择要配置的工具", y + 2); y -= 12

        // Claude Code
        claudeCodeCheck = NSButton(frame: NSRect(x: 24, y: y, width: 340, height: 24))
        claudeCodeCheck.setButtonType(.radio)
        claudeCodeCheck.title = "Claude Code（~/.claude/settings.json）"
        claudeCodeCheck.state = .on
        claudeCodeCheck.target = self; claudeCodeCheck.action = #selector(hookRadioAction)
        view.addSubview(claudeCodeCheck); y -= 26
        descLabel("配置 PreToolUse / PostToolUse / Stop 三个 Hook 事件。", y); y -= 36

        // Codex
        codexCheck = NSButton(frame: NSRect(x: 24, y: y, width: 340, height: 24))
        codexCheck.setButtonType(.radio)
        codexCheck.title = "Codex（~/.codex/config.toml + hooks.json）"
        codexCheck.state = .off
        codexCheck.target = self; codexCheck.action = #selector(hookRadioAction)
        view.addSubview(codexCheck); y -= 26
        descLabel("配置 Codex 的 sandbox shell hook 事件。", y); y -= 36

        // Cursor
        cursorCheck = NSButton(frame: NSRect(x: 24, y: y, width: 340, height: 24))
        cursorCheck.setButtonType(.radio)
        cursorCheck.title = "Cursor（~/.cursor/settings.json）"
        cursorCheck.state = .off
        cursorCheck.target = self; cursorCheck.action = #selector(hookRadioAction)
        view.addSubview(cursorCheck); y -= 26
        descLabel("配置 Cursor Agent 的 Hook 事件（格式与 Claude Code 兼容）。", y); y -= 48

        // 说明
        let info = NSTextField(frame: NSRect(x: 16, y: y, width: 348, height: 44))
        info.isEditable = false; info.isBordered = false; info.backgroundColor = .clear
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = NSColor(white: 0.40, alpha: 1.0)
        info.stringValue = "点击「应用配置」将自动合并 Hook 到对应配置文件。\n已有配置会被保留，仅更新 CodeLight 相关的 Hook。"
        info.cell?.wraps = true
        view.addSubview(info); y -= 56

        // 应用按钮
        let applyBtn = NSButton(frame: NSRect(x: 60, y: y, width: 140, height: 40))
        applyBtn.title = "应用配置"
        applyBtn.bezelStyle = .rounded
        applyBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        applyBtn.target = self
        applyBtn.action = #selector(applyHookConfig)
        view.addSubview(applyBtn)

        // 复制按钮
        let copyBtn = NSButton(frame: NSRect(x: 220, y: y, width: 140, height: 40))
        copyBtn.title = "复制配置"
        copyBtn.bezelStyle = .rounded
        copyBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        copyBtn.target = self
        copyBtn.action = #selector(copyHookConfig)
        view.addSubview(copyBtn); y -= 52

        // 状态反馈
        hookStatusLabel = NSTextField(frame: NSRect(x: 16, y: y, width: 348, height: 44))
        hookStatusLabel.isEditable = false; hookStatusLabel.isBordered = false; hookStatusLabel.backgroundColor = .clear
        hookStatusLabel.font = NSFont.systemFont(ofSize: 11)
        hookStatusLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        hookStatusLabel.alignment = .center
        hookStatusLabel.stringValue = ""
        hookStatusLabel.cell?.wraps = true
        view.addSubview(hookStatusLabel)
    }

    @objc func hookRadioAction(_ sender: NSButton) {
        let radios = [claudeCodeCheck, codexCheck, cursorCheck]
        for r in radios { if r != sender { r?.state = .off } }
        sender.state = .on
    }

    @objc func copyHookConfig() {
        let port = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        var parts: [String] = []

        if claudeCodeCheck.state == .on {
            let hooks: [String: Any] = generateHooks(tool: "claude", port: port)
            let json = generateHooksJSON(hooks: hooks)
            parts.append("=== Claude Code — ~/.claude/settings.json ===\n\(json)")
        }
        if codexCheck.state == .on {
            let hooks: [String: Any] = generateHooks(tool: "codex", port: port)
            let json = generateHooksJSON(hooks: hooks)
            parts.append("=== Codex config.toml ===\n[features]\nhooks = true\n\n=== Codex hooks.json — ~/.codex/hooks.json ===\n\(json)")
        }
        if cursorCheck.state == .on {
            let hooks: [String: Any] = generateHooks(tool: "cursor", port: port)
            let json = generateHooksJSON(hooks: hooks)
            parts.append("=== Cursor — ~/.cursor/settings.json ===\n\(json)")
        }

        if parts.isEmpty {
            hookStatusLabel.stringValue = "请至少勾选一个工具"
            hookStatusLabel.textColor = NSColor.systemOrange
            return
        }

        let text = parts.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        hookStatusLabel.stringValue = "✅ 已复制到剪贴板"
        hookStatusLabel.textColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
    }

    // Hook config methods moved to HookConfig.swift

    @objc func sliderChanged() {
        pollLabel.stringValue = String(format: "%.1fs", pollSlider.doubleValue)
        opacityLabel.stringValue = "\(Int(opacitySlider.doubleValue * 100))%"
        blinkLabel.stringValue = String(format: "%.1fs", blinkSlider.doubleValue)

        // 实时预览：只更新属性，不重建窗口
        appDelegate.config.opacity = opacitySlider.doubleValue
        appDelegate.config.blinkSpeed = blinkSlider.doubleValue
        appDelegate.config.pollInterval = pollSlider.doubleValue
        if let w = appDelegate.lightWindow {
            w.alphaValue = opacitySlider.doubleValue
        }
    }

    private var sizeRebuildTimer: Timer?

    @objc func sizeSliderChanged() {
        sizeLabel.stringValue = "\(Int(sizeSlider.doubleValue))"
        appDelegate.config.windowSize = sizeSlider.doubleValue
        // 防抖：松手后 0.15s 才 rebuild，避免拖动时不断重建
        sizeRebuildTimer?.invalidate()
        sizeRebuildTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.appDelegate.rebuildWithCurrentConfig()
        }
    }

    @objc func displayModeChanged() {
        let modes = ["vertical", "horizontal", "mini", "edgebar"]
        appDelegate.config.displayMode = modes[displayModeSegment.indexOfSelectedItem]
        appDelegate.config.horizontal = (appDelegate.config.displayMode == "horizontal")
        appDelegate.config.edgeBar = (appDelegate.config.displayMode == "edgebar") ? (appDelegate.config.edgeBar ?? "right") : nil
        horizontalCheck.state = appDelegate.config.horizontal ? .on : .off
        appDelegate.rebuildWithCurrentConfig()
    }

    @objc func testPortAction(_ sender: NSButton) {
        let port = serverField.stringValue.isEmpty ? "8866" : serverField.stringValue
        let urlStr = "http://127.0.0.1:\(port)/api/state"
        guard let url = URL(string: urlStr) else {
            portTestLabel.stringValue = "地址无效"; portTestLabel.textColor = .systemRed
            return
        }
        portTestLabel.stringValue = "检测中..."; portTestLabel.textColor = .secondaryLabelColor
        sender.isEnabled = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                sender.isEnabled = true
                guard let self = self else { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 200, data != nil {
                    self.portTestLabel.stringValue = "连通 ✓"; self.portTestLabel.textColor = .systemGreen
                } else {
                    let msg = error?.localizedDescription ?? "无响应"
                    self.portTestLabel.stringValue = "不通: \(msg)"; self.portTestLabel.textColor = .systemRed
                }
            }
        }.resume()
    }

    @objc func mascotChanged() {
        let types = ["cow", "cat", "robot", "horse", "chicken"]
        let t = types[mascotSelect.indexOfSelectedItem]
        appDelegate.trafficContainer?.mascotType = t
        appDelegate.redView?.mascotType = t
    }

    @objc func themeChanged() {
        colorWell.isHidden = themeSelect.indexOfSelectedItem != 2
        let themes = ["dark", "light", "custom"]
        let theme = themes[themeSelect.indexOfSelectedItem]
        appDelegate.shellView?.theme = theme
        if theme == "custom" {
            appDelegate.shellView?.customColor = colorWell.color
        }
        let view = appDelegate.lightWindow?.contentView
        switch theme {
        case "light":
            view?.layer?.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor
        case "custom":
            view?.layer?.backgroundColor = colorWell.color.cgColor
        default:
            view?.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
        }
    }

    @objc func cityChanged() {
        guard let city = citySelect.titleOfSelectedItem else { return }
        appDelegate.config.weatherCity = city
        appDelegate.config.save()
        weatherStatusLabel.stringValue = "获取天气中..."
        WeatherManager.shared.fetchWeatherForCity()
    }

    @objc func weatherToggled() {
        let enabled = weatherCheck.state == .on
        if enabled {
            if appDelegate.weatherView == nil, let view = appDelegate.lightWindow?.contentView {
                let wv = WeatherView(frame: view.bounds)
                wv.autoresizingMask = [.width, .height]
                if let shell = appDelegate.shellView {
                    view.addSubview(wv, positioned: .above, relativeTo: shell)
                } else {
                    view.addSubview(wv)
                }
                appDelegate.weatherView = wv
            }
            appDelegate.weatherView?.condition = WeatherManager.shared.currentCondition
            appDelegate.weatherView?.weatherCode = WeatherManager.shared.weatherCode
            weatherStatusLabel.stringValue = "获取天气中..."
            weatherStatusLabel.textColor = NSColor.tertiaryLabelColor
            WeatherManager.shared.onWeatherUpdate = { [weak self] condition, temp in
                self?.weatherStatusLabel.stringValue = "\(condition.displayName(code: WeatherManager.shared.weatherCode)) \(Int(temp))°C"
            }
            WeatherManager.shared.startPolling()
        } else {
            appDelegate.weatherView?.removeFromSuperview()
            appDelegate.weatherView = nil
            WeatherManager.shared.stopPolling()
            weatherStatusLabel.stringValue = ""
        }
    }

    private var weatherPreviewIndex: Int = 0
    // 预览循环: 各种天气+强度组合
    private let weatherPresets: [(condition: WeatherCondition, code: Int, label: String)] = [
        (.sunny, 0, "☀️ 晴天"),
        (.cloudy, 3, "☁️ 阴天"),
        (.rainy, 51, "🌦️ 毛毛雨"),
        (.rainy, 61, "🌦️ 小雨"),
        (.rainy, 63, "🌧️ 中雨"),
        (.rainy, 65, "🌧️ 大雨"),
        (.rainy, 82, "⛈️ 暴雨"),
        (.snowy, 71, "🌨️ 小雪"),
        (.snowy, 73, "❄️ 中雪"),
        (.snowy, 75, "❄️ 大雪"),
        (.thunderstorm, 95, "⛈️ 雷暴"),
    ]

    @objc func cycleWeatherPreview() {
        weatherPreviewIndex = (weatherPreviewIndex + 1) % weatherPresets.count
        let preset = weatherPresets[weatherPreviewIndex]

        if appDelegate.weatherView == nil, let view = appDelegate.lightWindow?.contentView {
            let wv = WeatherView(frame: view.bounds)
            wv.autoresizingMask = [.width, .height]
            if let shell = appDelegate.shellView {
                view.addSubview(wv, positioned: .above, relativeTo: shell)
            } else {
                view.addSubview(wv)
            }
            appDelegate.weatherView = wv
        }
        appDelegate.weatherView?.condition = preset.condition
        appDelegate.weatherView?.weatherCode = preset.code
        appDelegate.log("[天气预览] 切换到: \(preset.label)")
        weatherStatusLabel.stringValue = "\(preset.label) 点击继续切换 →"
        weatherStatusLabel.textColor = NSColor.controlAccentColor
    }

    @objc func toggleInstant(_ sender: NSButton) {
        var c = appDelegate.config
        if sender == weatherCheck {
            c.weatherThemeEnabled = sender.state == .on
            if c.weatherThemeEnabled {
                weatherStatusLabel.stringValue = "获取天气中..."
                WeatherManager.shared.onWeatherUpdate = { [weak self] condition, temp in
                    self?.weatherStatusLabel.stringValue = "\(condition.displayName) \(Int(temp))°C"
                }
                WeatherManager.shared.startPolling()
            } else {
                WeatherManager.shared.stopPolling()
                weatherStatusLabel.stringValue = ""
            }
        } else if sender == showStatusCheck {
            c.showStatusText = sender.state == .on
        } else if sender == autoLaunchCheck {
            c.autoLaunch = sender.state == .on
            if c.autoLaunch { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        } else if sender == notifyCheck {
            c.notifyOnDone = sender.state == .on
        } else if sender == permNotifyCheck {
            c.notifyOnPermission = sender.state == .on
        } else if sender == fullscreenCheck {
            c.showOnFullscreen = sender.state == .on
        } else if sender == floatingCheck {
            c.isFloating = sender.state == .on
        }
        c.save()
        appDelegate.config = c
        appDelegate.restartWithNewConfig()
    }

    @objc func saveSettings() {
        var c = appDelegate.config
        c.serverURL = "http://127.0.0.1:" + serverField.stringValue
        c.pollInterval = pollSlider.doubleValue
        c.opacity = opacitySlider.doubleValue
        c.blinkSpeed = blinkSlider.doubleValue
        c.windowSize = sizeSlider.doubleValue
        c.autoLaunch = autoLaunchCheck.state == .on
        c.notifyOnDone = notifyCheck.state == .on
        c.notifyOnPermission = permNotifyCheck.state == .on
        c.completionSound = soundSelect.titleOfSelectedItem ?? "Glass"
        c.showOnFullscreen = fullscreenCheck.state == .on
        c.horizontal = horizontalCheck.state == .on
        let modes = ["vertical", "horizontal", "mini", "edgebar"]
        c.displayMode = modes[displayModeSegment.indexOfSelectedItem]
        c.horizontal = (c.displayMode == "horizontal")
        c.edgeBar = (c.displayMode == "edgebar") ? (c.edgeBar ?? "right") : nil
        c.showStatusText = showStatusCheck.state == .on
        c.isFloating = floatingCheck.state == .on
        c.mascotType = ["cow", "cat", "robot", "horse", "chicken"][mascotSelect.indexOfSelectedItem]
        c.theme = ["dark", "light", "custom"][themeSelect.indexOfSelectedItem]
        if let hex = colorWell.color.hexString { c.customColor = hex }
        c.weatherThemeEnabled = weatherCheck.state == .on
        appDelegate.log("[保存] mascotType=\(c.mascotType) theme=\(c.theme) weather=\(c.weatherThemeEnabled)")
        c.save()
        if c.autoLaunch { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        appDelegate.restartWithNewConfig()
        window?.close()
    }

    @objc func checkForUpdate() {
        updateStatusLabel.stringValue = "正在检查..."
        updateStatusLabel.textColor = NSColor.secondaryLabelColor
        let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["gh", "api", "repos/guandeng/code-light/releases/latest", "--jq", ".tag_name"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.launch()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                updateStatusLabel.stringValue = "检查失败（gh 未安装或未登录）"
                updateStatusLabel.textColor = NSColor.systemRed
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let tagName = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard tagName.hasPrefix("v") else {
                updateStatusLabel.stringValue = "检查失败"
                updateStatusLabel.textColor = NSColor.systemRed
                return
            }
            let latestVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if latestVer.compare(currentVer, options: .numeric) == .orderedDescending {
                updateStatusLabel.stringValue = "发现新版本 \(tagName)"
                updateStatusLabel.textColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
                let openTask = Process()
                openTask.launchPath = "/usr/bin/open"
                openTask.arguments = ["https://github.com/guandeng/code-light/releases/latest"]
                try? openTask.launch()
            } else {
                updateStatusLabel.stringValue = "当前已是最新版本 (\(currentVer))"
                updateStatusLabel.textColor = NSColor.secondaryLabelColor
            }
        } catch {
            updateStatusLabel.stringValue = "检查失败"
            updateStatusLabel.textColor = NSColor.systemRed
        }
    }

    // MARK: - Stats Tab

    private func buildStatsTab(_ view: NSView, _ c: AppConfig) {
        let stats = StatsManager.shared.todayStats()
        let weekData = StatsManager.shared.weekStats()
        var y: CGFloat = 16
        let cw: CGFloat = 400

        // Dark theme fixed colors
        let titleColor = NSColor(white: 1.0, alpha: 0.5)
        let cardTitleColor = NSColor(white: 1.0, alpha: 0.4)
        let cardValueColor = NSColor(white: 1.0, alpha: 0.9)
        let cardBgColor = NSColor(white: 1.0, alpha: 0.06)
        let legendTextColor = NSColor(white: 1.0, alpha: 0.45)
        let dayLabelColor = NSColor(white: 1.0, alpha: 0.35)
        let toolNameColor = NSColor(white: 1.0, alpha: 0.85)
        let countColor = NSColor(white: 1.0, alpha: 0.45)
        let barTrackColor = NSColor(white: 1.0, alpha: 0.06)
        let noDataColor = NSColor(white: 1.0, alpha: 0.3)
        let infoColor = NSColor(white: 1.0, alpha: 0.25)

        func sectionTitle(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: 16, y: yy, width: 300, height: 20))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            l.textColor = titleColor
            view.addSubview(l)
        }

        func statCard(x: CGFloat, y yy: CGFloat, w: CGFloat, title: String, value: String, color: NSColor) {
            let card = NSView(frame: NSRect(x: x, y: yy, width: w, height: 72))
            card.wantsLayer = true
            card.layer?.backgroundColor = cardBgColor.cgColor
            card.layer?.cornerRadius = 8
            let accent = NSView(frame: NSRect(x: 0, y: 69, width: w, height: 3))
            accent.wantsLayer = true
            accent.layer?.backgroundColor = color.cgColor
            card.addSubview(accent)
            let tl = NSTextField(frame: NSRect(x: 12, y: 44, width: w - 24, height: 18))
            tl.isEditable = false; tl.isBordered = false; tl.backgroundColor = .clear
            tl.stringValue = title; tl.font = NSFont.systemFont(ofSize: 11)
            tl.textColor = cardTitleColor
            card.addSubview(tl)
            let vl = NSTextField(frame: NSRect(x: 12, y: 8, width: w - 24, height: 32))
            vl.isEditable = false; vl.isBordered = false; vl.backgroundColor = .clear
            vl.stringValue = value; vl.font = NSFont.systemFont(ofSize: 22, weight: .bold)
            vl.textColor = cardValueColor
            card.addSubview(vl)
            view.addSubview(card)
        }

        sectionTitle("今日概览", y); y += 28

        let fmtDur = formatDuration(stats.duration)
        let cardW: CGFloat = (cw - 20) / 2
        statCard(x: 16, y: y, w: cardW, title: "使用时长", value: fmtDur, color: NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0))
        statCard(x: 16 + cardW + 8, y: y, w: cardW, title: "工具调用", value: "\(stats.toolCalls) 次", color: NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0))
        y += 80
        statCard(x: 16, y: y, w: cardW, title: "会话数", value: "\(stats.sessions) 个", color: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0))
        statCard(x: 16 + cardW + 8, y: y, w: cardW, title: "状态", value: appDelegate.currentStateName, color: NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1.0))
        y += 88

        // --- 状态分布 ---
        sectionTitle("状态分布", y); y += 24
        let totalDur = stats.thinkingDur + stats.workingDur + stats.idleDur
        let thinkPct = totalDur > 0 ? stats.thinkingDur / totalDur : 0
        let workPct = totalDur > 0 ? stats.workingDur / totalDur : 0
        let idlePct = totalDur > 0 ? stats.idleDur / totalDur : 0

        let barView = NSView(frame: NSRect(x: 16, y: y, width: cw, height: 28))
        barView.wantsLayer = true
        barView.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        barView.layer?.cornerRadius = 6
        barView.layer?.masksToBounds = true

        let thinkBar = NSView(frame: NSRect(x: 0, y: 0, width: cw * CGFloat(thinkPct), height: 28))
        thinkBar.wantsLayer = true
        thinkBar.layer?.backgroundColor = NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 0.8).cgColor
        barView.addSubview(thinkBar)

        let workBar = NSView(frame: NSRect(x: cw * CGFloat(thinkPct), y: 0, width: cw * CGFloat(workPct), height: 28))
        workBar.wantsLayer = true
        workBar.layer?.backgroundColor = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.8).cgColor
        barView.addSubview(workBar)

        let idleBar = NSView(frame: NSRect(x: cw * CGFloat(thinkPct + workPct), y: 0, width: cw * CGFloat(idlePct), height: 28))
        idleBar.wantsLayer = true
        idleBar.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        barView.addSubview(idleBar)
        view.addSubview(barView)
        y += 36

        func legendDot(x: CGFloat, y yy: CGFloat, color: NSColor, text: String) {
            let dot = NSView(frame: NSRect(x: x, y: yy + 2, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 4
            view.addSubview(dot)
            let l = NSTextField(frame: NSRect(x: x + 12, y: yy, width: 120, height: 16))
            l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear
            l.stringValue = text; l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = legendTextColor
            view.addSubview(l)
        }
        let legendY = y
        legendDot(x: 16, y: legendY, color: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0), text: "思考 \(formatDuration(stats.thinkingDur))")
        legendDot(x: 145, y: legendY, color: NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0), text: "执行 \(formatDuration(stats.workingDur))")
        legendDot(x: 274, y: legendY, color: NSColor(white: 1.0, alpha: 0.2), text: "空闲 \(formatDuration(stats.idleDur))")
        y += 28

        // --- 本周趋势 ---
        sectionTitle("本周趋势", y); y += 24
        let chartH: CGFloat = 120
        let chartView = NSView(frame: NSRect(x: 16, y: y, width: cw, height: chartH))
        let colW = cw / 7
        let dayLabels = ["一", "二", "三", "四", "五", "六", "日"]
        let maxDur = weekData.map { $0.duration }.max() ?? 1
        let todayStr = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
        }()

        for i in 0..<7 {
            let d = weekData[i]
            let cx = CGFloat(i) * colW + colW / 2
            let barMaxH = chartH - 24
            let barH = max(d.duration > 0 ? CGFloat(d.duration / maxDur) * barMaxH : 4, 4)
            let isToday = (d.date == todayStr)

            if d.duration > 0 {
                let vl = NSTextField(frame: NSRect(x: CGFloat(i) * colW + 2, y: chartH - 14, width: colW - 4, height: 14))
                vl.isEditable = false; vl.isBordered = false; vl.backgroundColor = .clear
                vl.stringValue = formatDuration(d.duration); vl.font = NSFont.systemFont(ofSize: 9)
                vl.textColor = NSColor(white: 1.0, alpha: 0.35); vl.alignment = .center
                chartView.addSubview(vl)
            }

            let bar = NSView(frame: NSRect(x: cx - 10, y: chartH - 18 - barH, width: 20, height: barH))
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 3
            if isToday {
                bar.layer?.backgroundColor = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 0.8).cgColor
            } else if d.duration > 0 {
                bar.layer?.backgroundColor = NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.6).cgColor
            } else {
                bar.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
            }
            chartView.addSubview(bar)

            let dl = NSTextField(frame: NSRect(x: CGFloat(i) * colW + 2, y: 0, width: colW - 4, height: 16))
            dl.isEditable = false; dl.isBordered = false; dl.backgroundColor = .clear
            dl.stringValue = dayLabels[i]; dl.font = NSFont.systemFont(ofSize: 10)
            dl.alignment = .center
            dl.textColor = isToday ? NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0) : dayLabelColor
            if isToday { dl.font = NSFont.systemFont(ofSize: 10, weight: .semibold) }
            chartView.addSubview(dl)
        }
        view.addSubview(chartView)
        y += chartH + 16

        // --- 高频工具 TOP 5 ---
        sectionTitle("高频工具", y); y += 24
        let top5 = Array(stats.toolBreakdown.prefix(5))
        if top5.isEmpty {
            let nl = NSTextField(frame: NSRect(x: 16, y: y, width: cw, height: 20))
            nl.isEditable = false; nl.isBordered = false; nl.backgroundColor = .clear
            nl.stringValue = "暂无数据 — 开始使用 AI 后自动统计"; nl.font = NSFont.systemFont(ofSize: 12)
            nl.textColor = noDataColor
            view.addSubview(nl)
            y += 28
        } else {
            for (tool, count) in top5 {
                let row = NSView(frame: NSRect(x: 16, y: y, width: cw, height: 28))
                let tl = NSTextField(frame: NSRect(x: 0, y: 4, width: 200, height: 20))
                tl.isEditable = false; tl.isBordered = false; tl.backgroundColor = .clear
                tl.stringValue = tool; tl.font = NSFont.systemFont(ofSize: 12)
                tl.textColor = toolNameColor
                row.addSubview(tl)
                let maxCount = top5.first?.1 ?? 1
                let ratio = CGFloat(count) / CGFloat(maxCount)
                let barBg = NSView(frame: NSRect(x: 140, y: 8, width: 180, height: 12))
                barBg.wantsLayer = true
                barBg.layer?.backgroundColor = barTrackColor.cgColor
                barBg.layer?.cornerRadius = 3
                row.addSubview(barBg)
                let barFill = NSView(frame: NSRect(x: 140, y: 8, width: 180 * ratio, height: 12))
                barFill.wantsLayer = true
                barFill.layer?.backgroundColor = NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.5).cgColor
                barFill.layer?.cornerRadius = 3
                row.addSubview(barFill)
                let cl = NSTextField(frame: NSRect(x: 340, y: 4, width: 60, height: 20))
                cl.isEditable = false; cl.isBordered = false; cl.backgroundColor = .clear
                cl.stringValue = "\(count) 次"; cl.font = NSFont.systemFont(ofSize: 11)
                cl.textColor = countColor; cl.alignment = .right
                row.addSubview(cl)
                view.addSubview(row)
                y += 32
            }
        }

        // --- 底部信息 ---
        y += 8
        let info = NSTextField(frame: NSRect(x: 16, y: y, width: cw, height: 16))
        info.isEditable = false; info.isBordered = false; info.backgroundColor = .clear
        info.stringValue = "数据保留 30 天 · 自动清理 · 仅本地存储"; info.font = NSFont.systemFont(ofSize: 10)
        info.textColor = infoColor
        view.addSubview(info)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - Sidebar Button Handler

    @objc func sidebarButtonClicked(_ sender: NSButton) {
        let row = sender.tag
        let isStatsTab = (row == sidebarItems.count - 1)
        for (i, c) in containers.enumerated() {
            c.isHidden = (i != row)
        }
        for (i, btn) in sidebarButtons.enumerated() {
            let isSelected = (i == row)
            btn.font = NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
            btn.contentTintColor = isSelected ? NSColor.controlAccentColor : NSColor.labelColor
            btn.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor : nil
        }
        statsRefreshTimer?.invalidate()
        if isStatsTab {
            rebuildStatsTab()
            statsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.rebuildStatsTab()
            }
        }
    }

    private func rebuildStatsTab() {
        guard let scroll = statsContainer.subviews.first as? NSScrollView,
              let docView = scroll.documentView else { return }
        docView.subviews.forEach { $0.removeFromSuperview() }
        buildStatsTab(docView, appDelegate.config)
    }

    func windowWillClose(_ notification: Notification) {
        statsRefreshTimer?.invalidate()
        appDelegate.settingsWindowController = nil
    }
}

// ============================================================
// Main — 入口在 main.swift
// ============================================================

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
    var onStateLeaveWaiting: (() -> Void)?
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
        // 状态离开 waiting 时自动关闭权限气泡（用户可能在编辑器里已处理）
        if name != "waiting" {
            onStateLeaveWaiting?()
        }
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
    var permissionBubbles: [(id: String, window: NSWindow, toolName: String, command: String, timer: Timer?, sessionId: String)] = []

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
        server.onStateLeaveWaiting = { [weak self] in DispatchQueue.main.async { self?.dismissAllPermissionBubbles() } }
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

    /// 保存配置 + 自�� WebDAV 同步
    func saveConfig() {
        config.save()
        if config.webdavAutoSync && !config.webdavURL.isEmpty {
            WebDAVSync.shared.uploadConfig(config) { success, msg in
                DispatchQueue.main.async {
                    self.log("[WebDAV] 自动同步: \(msg)")
                }
            }
        }
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
        let rect = NSRect(x: 0, y: 0, width: 800, height: 300)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "今日 AI 工作时间线"
        win.minSize = NSSize(width: 600, height: 220)
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
    var autoLaunchCheck: NSSwitch!
    var notifyCheck: NSSwitch!
    var soundSelect: NSPopUpButton!
    var permNotifyCheck: NSSwitch!
    var fullscreenCheck: NSSwitch!
    var floatingCheck: NSSwitch!
    var mascotSelect: NSPopUpButton!
    var horizontalCheck: NSButton!
    var displayModeSegment: NSSegmentedControl!
    var showStatusCheck: NSSwitch!
    var sizeSlider: NSSlider!; var sizeLabel: NSTextField!
    var rulesContainer: NSView!
    var hookContainer: NSView!
    var advancedContainer: NSView!
    var webdavURLField: NSTextField!
    var webdavUserField: NSTextField!
    var webdavPassField: NSSecureTextField!
    var webdavPathField: NSTextField!
    var webdavAutoSyncCheck: NSSwitch!
    var webdavStatusLabel: NSTextField!
    var logTextView: NSTextView!

    var statsContainer: NSView!
    var statsRefreshTimer: Timer?
    var hookToolSegment: NSSegmentedControl!
    var hookStatusLabel: NSTextField!
    var themeSelect: NSPopUpButton!
    var colorWell: NSColorWell!
    var weatherCheck: NSSwitch!
    var weatherStatusLabel: NSTextField!
    var citySelect: NSPopUpButton!
    // 总是运行选项卡
    var alwaysAllowContainer: NSView!
    var alwaysAllowRulesList: NSView!
    var addRuleField: NSTextField!
    var permissionModeSegment: NSSegmentedControl!
    var rulesViews: [NSView] = []  // 规则区域所有子视图，仅 rules 模式可见
    var rulesCard: NSView!
    // Sidebar navigation
    var sidebarButtons: [NSButton] = []
    var containers: [NSView] = []
    var generalContainer: NSView!
    var appearanceContainer: NSView!
    var behaviorContainer: NSView!
    var skillsContainer: NSView!
    // Skills tab UI state
    var skillsSegment: NSSegmentedControl!
    var skillsStatusLabel: NSTextField!
    var skillsListContainer: FlippedView!
    var skillsRepoConfigView: NSView!
    var skillsRepoField: NSTextField!
    var skillsPathField: NSTextField!
    var skillsListTopY: CGFloat = 0
    var skillsContainerHeight: CGFloat = 0
    var skillsInstalledListY: CGFloat = 0
    var skillsDiscoverListY: CGFloat = 0
    var skillsRemoteItems: [SkillItem] = []
    var skillsRemoteContents: [String: String] = [:]
    var installedFilterSegment: NSSegmentedControl!
    var installSourceSegment: NSSegmentedControl!
    var skillsRepoPopup: NSPopUpButton!
    var skillsMarketContainer: NSView!
    var skillsGitContainer: NSView!
    var skillsDirContainer: NSView!
    var skillsZipContainer: NSView!
    var skillsGitField: NSTextField!
    let sidebarItems = ["⚙️ 通用", "🎨 外观", "🎯 行为", "🚀 总是运行", "💡 灯效规则", "🔗 配置 Hook", "☁️ 高级", "📊 统计", "🧩 技能"]

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
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
        // 同步权限模式 segment
        if permissionModeSegment != nil {
            let modeIdx = ["popup": 0, "always": 1, "rules": 2][c.permissionMode] ?? 0
            permissionModeSegment.selectedSegment = modeIdx
            updateRulesSectionVisibility()
        }
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
        let contentW = (window?.frame.width ?? 800) - sideW - 1
        let contentH: CGFloat = 620
        let mainH = contentH

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
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(contentArea)

        generalContainer = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        appearanceContainer = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        behaviorContainer = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))

        buildGeneralSection(generalContainer!, c)
        buildAppearanceSection(appearanceContainer!, c)
        buildBehaviorSection(behaviorContainer!, c)

        alwaysAllowContainer = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        buildAlwaysAllowSection(alwaysAllowContainer!, c)

        let rulesDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: 700))
        let rulesContentHeight = buildRulesTab(rulesDoc)
        rulesDoc.frame.size.height = max(rulesContentHeight, mainH)
        let rulesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        rulesScroll.documentView = rulesDoc
        rulesScroll.hasVerticalScroller = false
        rulesScroll.drawsBackground = false
        rulesContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        rulesContainer.addSubview(rulesScroll)

        hookContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        buildHookTab(hookContainer!)

        let statsDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: 900))
        buildStatsTab(statsDoc, c)
        statsContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        statsContainer.wantsLayer = true
        statsContainer.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.95).cgColor
        let statsScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        statsScroll.documentView = statsDoc
        statsScroll.hasVerticalScroller = false
        statsScroll.drawsBackground = false
        statsScroll.backgroundColor = NSColor.clear
        statsContainer.addSubview(statsScroll)

        // ☁️ 高级选项卡
        let advancedDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: 700))
        buildAdvancedTab(advancedDoc, c)
        let advancedMaxY = advancedDoc.subviews.reduce(CGFloat(0)) { max($0, $1.frame.origin.y + $1.frame.height) }
        advancedDoc.frame.size.height = max(advancedMaxY + 20, mainH)
        let advancedScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        advancedScroll.documentView = advancedDoc
        advancedScroll.hasVerticalScroller = false
        advancedScroll.drawsBackground = false
        advancedContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        advancedContainer.addSubview(advancedScroll)

        // 🧩 技能选项卡
        let skillsDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentW, height: 900))
        buildSkillsTab(skillsDoc, c)
        let skillsMaxY = skillsDoc.subviews.reduce(CGFloat(0)) { max($0, $1.frame.origin.y + $1.frame.height) }
        skillsDoc.frame.size.height = max(skillsMaxY + 20, mainH)
        let skillsScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        skillsScroll.documentView = skillsDoc
        skillsScroll.hasVerticalScroller = false
        skillsScroll.drawsBackground = false
        skillsContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: mainH))
        skillsContainer.addSubview(skillsScroll)

        containers = [generalContainer!, appearanceContainer!, behaviorContainer!, alwaysAllowContainer!, rulesContainer!, hookContainer!, advancedContainer!, statsContainer!, skillsContainer!]
        for (i, container) in containers.enumerated() {
            contentArea.addSubview(container)
            container.isHidden = (i != 0)
        }
    }

    // MARK: - Section Builders

    func buildGeneralSection(_ container: NSView, _ c: AppConfig) {
        var y: CGFloat = 16

        // --- Group 1: 连接 ---
        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let port = c.serverURL.components(separatedBy: ":").last ?? "8866"
        portField.stringValue = port
        portField.font = NSFont.systemFont(ofSize: 12)
        portField.placeholderString = "8866"
        portField.onAction = { [weak self] in
            guard let self = self else { return }
            let p = self.serverField.stringValue.isEmpty ? "8866" : self.serverField.stringValue
            self.appDelegate.config.serverURL = "http://127.0.0.1:" + p
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        serverField = portField

        let testBtn = NSButton(frame: NSRect(x: 86, y: 0, width: 50, height: 24))
        testBtn.title = "测试"; testBtn.bezelStyle = .rounded; testBtn.font = NSFont.systemFont(ofSize: 11)
        testBtn.target = self; testBtn.action = #selector(testPortAction(_:))

        portTestLabel = NSTextField(frame: NSRect(x: 140, y: 4, width: 140, height: 16))
        portTestLabel.isEditable = false; portTestLabel.isBordered = false
        portTestLabel.backgroundColor = .clear; portTestLabel.font = NSFont.systemFont(ofSize: 11)
        portTestLabel.stringValue = ""

        let portAccessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        portAccessory.addSubview(portField)
        portAccessory.addSubview(testBtn)
        portAccessory.addSubview(portTestLabel!)

        let pollAccessory = SettingsRowView.makeSlider(value: c.pollInterval, min: 0.1, max: 3.0, format: "%.1fs") { [weak self] v in
            guard let self = self else { return }
            self.appDelegate.config.pollInterval = v
            self.appDelegate.saveConfig()
            self.pollSlider?.doubleValue = v
            if let lbl = self.pollLabel { lbl.stringValue = String(format: "%.1fs", v) }
        }
        // store references for syncFromConfig
        if let slider = pollAccessory.subviews.first(where: { $0 is NSSlider }) as? NSSlider {
            pollSlider = slider
        }
        if let lbl = pollAccessory.subviews.first(where: { $0 is NSTextField }) as? NSTextField {
            pollLabel = lbl
        }

        let connectGroup = SettingsGroupView(header: "连接", rows: [
            SettingsRowView(title: "服务端口", accessory: portAccessory, isFirst: true),
            SettingsRowView(title: "轮询间隔", subtitle: "每隔多久检查状态",
                            accessory: pollAccessory, isLast: true),
        ])
        connectGroup.frame.origin = NSPoint(x: 16, y: y)
        connectGroup.autoresizingMask = .width
        container.addSubview(connectGroup)
        y += connectGroup.frame.height + 8

        // --- Group 2: 启动 ---
        let launchToggle = SettingsRowView.makeToggle(isOn: c.autoLaunch) { [weak self] isOn in
            guard let self = self else { return }
            self.appDelegate.config.autoLaunch = isOn
            self.appDelegate.saveConfig()
            if isOn { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
        autoLaunchCheck = launchToggle

        let launchGroup = SettingsGroupView(header: "启动", rows: [
            SettingsRowView(title: "开机自动启动", subtitle: "随系统启动自动运行",
                            accessory: launchToggle, isFirst: true, isLast: true),
        ])
        launchGroup.frame.origin = NSPoint(x: 16, y: y)
        launchGroup.autoresizingMask = .width
        container.addSubview(launchGroup)
        y += launchGroup.frame.height + 8

        // --- Group 3: 更新 ---
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        let updateAccessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        let checkUpdateBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        checkUpdateBtn.title = "检查更新"; checkUpdateBtn.bezelStyle = .rounded
        checkUpdateBtn.font = NSFont.systemFont(ofSize: 11)
        checkUpdateBtn.target = self; checkUpdateBtn.action = #selector(checkForUpdate)
        updateAccessory.addSubview(checkUpdateBtn)

        updateStatusLabel = NSTextField(frame: NSRect(x: 88, y: 4, width: 180, height: 20))
        updateStatusLabel.isEditable = false; updateStatusLabel.isBordered = false
        updateStatusLabel.backgroundColor = .clear
        updateStatusLabel.font = NSFont.systemFont(ofSize: 11); updateStatusLabel.textColor = NSColor.tertiaryLabelColor
        updateStatusLabel.stringValue = "v\(ver)"
        updateAccessory.addSubview(updateStatusLabel!)

        let updateGroup = SettingsGroupView(header: "更新", rows: [
            SettingsRowView(title: "检查更新",
                            accessory: updateAccessory, isFirst: true, isLast: true),
        ])
        updateGroup.frame.origin = NSPoint(x: 16, y: y)
        updateGroup.autoresizingMask = .width
        container.addSubview(updateGroup)
    }

    func buildAppearanceSection(_ container: NSView, _ c: AppConfig) {
        var y: CGFloat = 16

        // --- Group 1: 外观 ---
        let opacityAcc = SettingsRowView.makeSlider(value: c.opacity, min: 0.3, max: 1.0, format: "%.0f%%") { [weak self] v in
            guard let self = self else { return }
            self.appDelegate.config.opacity = v
            self.appDelegate.saveConfig()
            self.appDelegate.lightWindow.alphaValue = v
            if let lbl = self.opacityLabel { lbl.stringValue = "\(Int(v * 100))%" }
        }
        if let slider = opacityAcc.subviews.first(where: { $0 is NSSlider }) as? NSSlider { opacitySlider = slider }
        if let lbl = opacityAcc.subviews.first(where: { $0 is NSTextField }) as? NSTextField { opacityLabel = lbl; lbl.stringValue = "\(Int(c.opacity * 100))%" }

        let blinkAcc = SettingsRowView.makeSlider(value: c.blinkSpeed, min: 0.2, max: 2.0, format: "%.1fs") { [weak self] v in
            guard let self = self else { return }
            self.appDelegate.config.blinkSpeed = v
            self.appDelegate.saveConfig()
        }
        if let slider = blinkAcc.subviews.first(where: { $0 is NSSlider }) as? NSSlider { blinkSlider = slider }
        if let lbl = blinkAcc.subviews.first(where: { $0 is NSTextField }) as? NSTextField { blinkLabel = lbl }

        let sizeAcc = SettingsRowView.makeSlider(value: c.windowSize, min: 30, max: 120, format: "%.0f") { [weak self] v in
            guard let self = self else { return }
            self.appDelegate.config.windowSize = v
            self.appDelegate.saveConfig()
            self.appDelegate.rebuildWithCurrentConfig()
        }
        if let slider = sizeAcc.subviews.first(where: { $0 is NSSlider }) as? NSSlider { sizeSlider = slider }
        if let lbl = sizeAcc.subviews.first(where: { $0 is NSTextField }) as? NSTextField { sizeLabel = lbl }

        let themeNames = ["🌙 深色", "☀️ 浅色", "🎨 自定义"]
        let themeIdx = ["dark": 0, "light": 1, "custom": 2][c.theme] ?? 0
        let themeAcc = SettingsRowView.makePopup(items: themeNames, selectedIndex: themeIdx) { [weak self] idx in
            guard let self = self else { return }
            let themes = ["dark", "light", "custom"]
            self.appDelegate.config.theme = themes[idx]
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        themeSelect = themeAcc

        // 自定义颜色选择器
        colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        colorWell.color = NSColor(fromHex: c.customColor) ?? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        colorWell.isHidden = c.theme != "custom"
        colorWell.onAction = { [weak self] in
            guard let self = self else { return }
            if let hex = self.colorWell.color.hexString {
                self.appDelegate.config.customColor = hex
                self.appDelegate.saveConfig()
                self.appDelegate.restartWithNewConfig()
            }
        }

        let mascotNames = ["🐂 小牛", "🐱 小猫", "🤖 机器人", "🐴 小马", "🏀 小鸡"]
        let mascotIdx = ["cow": 0, "cat": 1, "robot": 2, "horse": 3, "chicken": 4][c.mascotType] ?? 0
        let mascotAcc = SettingsRowView.makePopup(items: mascotNames, selectedIndex: mascotIdx) { [weak self] idx in
            guard let self = self else { return }
            let types = ["cow", "cat", "robot", "horse", "chicken"]
            self.appDelegate.config.mascotType = types[idx]
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        mascotSelect = mascotAcc

        let modeIdx = ["vertical": 0, "horizontal": 1, "mini": 2, "edgebar": 3][c.displayMode] ?? 0
        let modeAcc = SettingsRowView.makeSegmented(labels: ["竖向", "横向", "迷你", "磁吸"], selected: modeIdx) { [weak self] idx in
            guard let self = self else { return }
            let modes = ["vertical", "horizontal", "mini", "edgebar"]
            self.appDelegate.config.displayMode = modes[idx]
            self.appDelegate.config.horizontal = (modes[idx] == "horizontal")
            self.appDelegate.config.edgeBar = (modes[idx] == "edgebar") ? (self.appDelegate.config.edgeBar ?? "right") : nil
            self.appDelegate.saveConfig()
            self.appDelegate.rebuildWithCurrentConfig()
        }
        displayModeSegment = modeAcc

        let statusToggle = NSSwitch(frame: NSRect(x: 0, y: 0, width: 42, height: 24))
        statusToggle.state = c.showStatusText ? .on : .off
        statusToggle.onAction = { [weak self] in
            guard let self = self else { return }
            self.appDelegate.config.showStatusText = statusToggle.state == .on
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        showStatusCheck = statusToggle

        let appearanceGroup = SettingsGroupView(header: "外观", rows: [
            SettingsRowView(title: "透明度", accessory: opacityAcc, isFirst: true),
            SettingsRowView(title: "主题", accessory: themeAcc),
            SettingsRowView(title: "自定义颜色", accessory: colorWell),
            SettingsRowView(title: "吉祥物", accessory: mascotAcc),
            SettingsRowView(title: "显示样式", accessory: modeAcc),
            SettingsRowView(title: "窗口大小", accessory: sizeAcc),
            SettingsRowView(title: "闪烁速度", accessory: blinkAcc),
            SettingsRowView(title: "显示状态文字", subtitle: "灯下方显示当前状态",
                            accessory: statusToggle, isLast: true),
        ])
        appearanceGroup.frame.origin = NSPoint(x: 16, y: y)
        appearanceGroup.autoresizingMask = .width
        container.addSubview(appearanceGroup)
        y += appearanceGroup.frame.height + 8

        // --- Group 2: 天气 ---
        let weatherToggle = NSSwitch(frame: NSRect(x: 0, y: 0, width: 42, height: 24))
        weatherToggle.state = c.weatherThemeEnabled ? .on : .off
        weatherToggle.onAction = { [weak self] in
            guard let self = self else { return }
            self.appDelegate.config.weatherThemeEnabled = weatherToggle.state == .on
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        weatherCheck = weatherToggle

        let cityNames = CITIES.map { $0.name }
        let cityIdx = cityNames.firstIndex(of: c.weatherCity) ?? 0
        let cityAcc = SettingsRowView.makePopup(items: cityNames, selectedIndex: cityIdx) { [weak self] idx in
            guard let self = self else { return }
            self.appDelegate.config.weatherCity = cityNames[idx]
            self.appDelegate.saveConfig()
            WeatherManager.shared.startPolling()
        }
        citySelect = cityAcc

        let weatherGroup = SettingsGroupView(header: "天气", rows: [
            SettingsRowView(title: "天气主题", subtitle: "实时天气背景动画",
                            accessory: weatherToggle, isFirst: true),
            SettingsRowView(title: "城市", accessory: cityAcc, isLast: true),
        ])
        weatherGroup.frame.origin = NSPoint(x: 16, y: y)
        weatherGroup.autoresizingMask = .width
        container.addSubview(weatherGroup)
        y += weatherGroup.frame.height + 8

        // 天气状态标签（隐藏，仅作为方法引用目标）
        weatherStatusLabel = NSTextField(frame: NSRect(x: 32, y: y, width: 300, height: 16))
        weatherStatusLabel.isEditable = false; weatherStatusLabel.isBordered = false
        weatherStatusLabel.backgroundColor = .clear; weatherStatusLabel.drawsBackground = false
        weatherStatusLabel.font = NSFont.systemFont(ofSize: 10)
        weatherStatusLabel.textColor = NSColor.tertiaryLabelColor
        if c.weatherThemeEnabled {
            let wm = WeatherManager.shared
            weatherStatusLabel.stringValue = "\(wm.currentCondition.displayName(code: wm.weatherCode)) \(Int(wm.currentTemp))°C"
        }
        container.addSubview(weatherStatusLabel)
    }

    func buildBehaviorSection(_ container: NSView, _ c: AppConfig) {
        var y: CGFloat = 16

        // --- Group 1: 通知 ---
        let notifyToggle = SettingsRowView.makeToggle(isOn: c.notifyOnDone) { [weak self] isOn in
            guard let self = self else { return }
            self.appDelegate.config.notifyOnDone = isOn
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        notifyCheck = notifyToggle

        let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Tink", "default", "none"]
        let soundIdx = sounds.firstIndex(of: c.completionSound) ?? 0
        let soundPopup = SettingsRowView.makePopup(items: sounds, selectedIndex: soundIdx) { [weak self] idx in
            guard let self = self else { return }
            self.appDelegate.config.completionSound = sounds[idx]
            self.appDelegate.saveConfig()
        }
        soundSelect = soundPopup

        let permNotifyToggle = SettingsRowView.makeToggle(isOn: c.notifyOnPermission) { [weak self] isOn in
            guard let self = self else { return }
            self.appDelegate.config.notifyOnPermission = isOn
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        permNotifyCheck = permNotifyToggle

        let notifyGroup = SettingsGroupView(header: "通知", rows: [
            SettingsRowView(title: "任务完成通知", accessory: notifyToggle, isFirst: true),
            SettingsRowView(title: "完成提示音", accessory: soundPopup),
            SettingsRowView(title: "权限请求弹窗确认", subtitle: "收到权限请求时弹出气泡",
                            accessory: permNotifyToggle, isLast: true),
        ])
        notifyGroup.frame.origin = NSPoint(x: 16, y: y)
        notifyGroup.autoresizingMask = .width
        container.addSubview(notifyGroup)
        y += notifyGroup.frame.height + 8

        // --- Group 2: 窗口 ---
        let fullscreenToggle = SettingsRowView.makeToggle(isOn: c.showOnFullscreen) { [weak self] isOn in
            guard let self = self else { return }
            self.appDelegate.config.showOnFullscreen = isOn
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        fullscreenCheck = fullscreenToggle

        let floatingToggle = SettingsRowView.makeToggle(isOn: c.isFloating) { [weak self] isOn in
            guard let self = self else { return }
            self.appDelegate.config.isFloating = isOn
            self.appDelegate.saveConfig()
            self.appDelegate.restartWithNewConfig()
        }
        floatingCheck = floatingToggle

        let windowGroup = SettingsGroupView(header: "窗口", rows: [
            SettingsRowView(title: "全屏应用上层显示", accessory: fullscreenToggle, isFirst: true),
            SettingsRowView(title: "窗口悬浮置顶", accessory: floatingToggle, isLast: true),
        ])
        windowGroup.frame.origin = NSPoint(x: 16, y: y)
        windowGroup.autoresizingMask = .width
        container.addSubview(windowGroup)
    }

    // MARK: - 总是运行选项卡

    func buildAlwaysAllowSection(_ view: NSView, _ c: AppConfig) {
        var y: CGFloat = 16

        // --- Group: 权限处理模式 ---
        let mode = c.permissionMode
        let modeIdx = ["popup": 0, "always": 1, "rules": 2][mode] ?? 0

        let modeSeg = SettingsRowView.makeSegmented(labels: ["弹窗确认", "总是运行", "规则运行"], selected: modeIdx) { [weak self] idx in
            guard let self = self else { return }
            let modes = ["popup", "always", "rules"]
            var c = self.appDelegate.config
            c.permissionMode = modes[idx]
            c.autoAllowPermission = (c.permissionMode == "always")
            c.save()
            self.appDelegate.config = c
            self.updateRulesSectionVisibility()
        }
        permissionModeSegment = modeSeg

        let modeGroup = SettingsGroupView(header: "权限处理模式", rows: [
            SettingsRowView(title: "处理模式", subtitle: "控制权限请求的确认方式",
                            accessory: modeSeg, isFirst: true, isLast: true),
        ])
        modeGroup.frame.origin = NSPoint(x: 16, y: y)
        modeGroup.autoresizingMask = .width
        view.addSubview(modeGroup)
        y += modeGroup.frame.height + 8

        // --- 规则区域（仅 rules 模式可见）---
        rulesViews = []

        // 规则卡片容器
        rulesCard = NSView(frame: NSRect(x: 16, y: y, width: view.bounds.width - 32, height: 0))
        rulesCard.wantsLayer = true
        rulesCard.layer?.cornerRadius = 10
        rulesCard.layer?.masksToBounds = true
        view.addSubview(rulesCard)
        rulesViews.append(rulesCard)

        var ry: CGFloat = 0

        let rulesTitle = NSTextField(frame: NSRect(x: 12, y: ry, width: 300, height: 20))
        rulesTitle.isEditable = false; rulesTitle.isBordered = false; rulesTitle.backgroundColor = .clear
        rulesTitle.stringValue = "命令规则（读取 ~/.codelight/config）"
        rulesTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        rulesTitle.textColor = NSColor.secondaryLabelColor
        rulesCard.addSubview(rulesTitle); rulesViews.append(rulesTitle); ry += 24

        let ruleDesc = NSTextField(frame: NSRect(x: 12, y: ry, width: 400, height: 18))
        ruleDesc.isEditable = false; ruleDesc.isBordered = false; ruleDesc.backgroundColor = .clear
        ruleDesc.font = NSFont.systemFont(ofSize: 10)
        ruleDesc.textColor = NSColor.tertiaryLabelColor
        ruleDesc.stringValue = "前缀匹配：git → git status, git log, git commit 等"
        rulesCard.addSubview(ruleDesc); rulesViews.append(ruleDesc); ry += 28

        // 可滚动规则列表
        let listH: CGFloat = 220
        alwaysAllowRulesList = FlippedView(frame: NSRect(x: 0, y: 0, width: rulesCard.frame.width - 24, height: listH))
        alwaysAllowRulesList.wantsLayer = true
        alwaysAllowRulesList.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        alwaysAllowRulesList.layer?.cornerRadius = 6

        let scrollView = NSScrollView(frame: NSRect(x: 12, y: ry, width: rulesCard.frame.width - 24, height: listH))
        scrollView.documentView = alwaysAllowRulesList
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        rulesCard.addSubview(scrollView); rulesViews.append(scrollView)
        rebuildAlwaysAllowRulesList()
        ry += listH + 12

        // 添加规则输入框
        addRuleField = NSTextField(frame: NSRect(x: 12, y: ry, width: rulesCard.frame.width - 100, height: 26))
        addRuleField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        addRuleField.placeholderString = "输入命令前缀，如 git, ls, find"
        addRuleField.target = self; addRuleField.action = #selector(addAlwaysAllowRule)
        rulesCard.addSubview(addRuleField); rulesViews.append(addRuleField)

        let addBtn = NSButton(frame: NSRect(x: rulesCard.frame.width - 80, y: ry, width: 68, height: 26))
        addBtn.title = "添加"; addBtn.bezelStyle = .rounded
        addBtn.font = NSFont.systemFont(ofSize: 12)
        addBtn.target = self; addBtn.action = #selector(addAlwaysAllowRule)
        rulesCard.addSubview(addBtn); rulesViews.append(addBtn); ry += 36

        // 导入默认 + 清空按钮
        let importBtn = NSButton(frame: NSRect(x: 12, y: ry, width: 140, height: 26))
        importBtn.title = "导入默认安全命令"; importBtn.bezelStyle = .rounded
        importBtn.font = NSFont.systemFont(ofSize: 11)
        importBtn.target = self; importBtn.action = #selector(importDefaultRules)
        rulesCard.addSubview(importBtn); rulesViews.append(importBtn)

        let clearBtn = NSButton(frame: NSRect(x: 160, y: ry, width: 80, height: 26))
        clearBtn.title = "清空全部"; clearBtn.bezelStyle = .rounded
        clearBtn.font = NSFont.systemFont(ofSize: 11)
        clearBtn.target = self; clearBtn.action = #selector(clearAllRules)
        rulesCard.addSubview(clearBtn); rulesViews.append(clearBtn); ry += 36

        // 配置文件路径提示
        let pathInfo = NSTextField(frame: NSRect(x: 12, y: ry, width: 400, height: 18))
        pathInfo.isEditable = false; pathInfo.isBordered = false; pathInfo.backgroundColor = .clear
        pathInfo.font = NSFont.systemFont(ofSize: 10)
        pathInfo.textColor = NSColor.tertiaryLabelColor
        pathInfo.stringValue = "配置文件: ~/.codelight/config"
        rulesCard.addSubview(pathInfo); rulesViews.append(pathInfo)
        ry += 24

        rulesCard.frame.size.height = ry

        // 根据 mode 控制规则区域可见性
        updateRulesSectionVisibility()
    }

    func updateRulesSectionVisibility() {
        let hide = (appDelegate.config.permissionMode != "rules")
        for v in rulesViews { v.isHidden = hide }
    }

    func rebuildAlwaysAllowRulesList() {
        guard let list = alwaysAllowRulesList else { return }
        list.subviews.forEach { $0.removeFromSuperview() }
        AlwaysAllowManager.shared.loadRules()
        let rules = AlwaysAllowManager.shared.rules
        let listW = list.frame.width

        if rules.isEmpty {
            let empty = NSTextField(frame: NSRect(x: 12, y: 8, width: listW - 24, height: 20))
            empty.isEditable = false; empty.isBordered = false; empty.backgroundColor = .clear
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = NSColor.tertiaryLabelColor
            empty.stringValue = "暂无规则 — 添加命令或导入默认规则"
            list.addSubview(empty)
            list.frame.size.height = 40
            return
        }

        let chipFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let chipH: CGFloat = 28
        let chipGap: CGFloat = 6
        let padX: CGFloat = 10
        let closeW: CGFloat = 16
        var cx: CGFloat = 8
        var cy: CGFloat = 8

        for (i, rule) in rules.enumerated() {
            let textW = (rule as NSString).size(withAttributes: [.font: chipFont]).width
            let chipW = textW + padX + closeW + padX

            // 换行
            if cx + chipW > listW - 8 {
                cx = 8
                cy += chipH + chipGap
            }

            // 芯片背景
            let chip = NSView(frame: NSRect(x: cx, y: cy, width: chipW, height: chipH))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            chip.layer?.cornerRadius = 6
            chip.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            chip.layer?.borderWidth = 0.5
            list.addSubview(chip)

            // 规则文字
            let label = NSTextField(frame: NSRect(x: padX, y: 4, width: textW + 4, height: 20))
            label.isEditable = false; label.isBordered = false; label.backgroundColor = .clear
            label.font = chipFont
            label.stringValue = rule
            chip.addSubview(label)

            // × 删除按钮
            let closeBtn = NSButton(frame: NSRect(x: chipW - closeW - 4, y: (chipH - closeW) / 2, width: closeW, height: closeW))
            closeBtn.title = "×"
            closeBtn.isBordered = false
            closeBtn.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            closeBtn.contentTintColor = NSColor.tertiaryLabelColor
            closeBtn.tag = i
            closeBtn.target = self; closeBtn.action = #selector(removeAlwaysAllowRule(_:))
            chip.addSubview(closeBtn)

            cx += chipW + chipGap
        }

        list.frame.size.height = max(cy + chipH + 8, 40)
    }

    @objc func addAlwaysAllowRule() {
        guard let text = addRuleField?.stringValue.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
        AlwaysAllowManager.shared.addRule(text)
        addRuleField.stringValue = ""
        rebuildAlwaysAllowRulesList()
    }

    @objc func removeAlwaysAllowRule(_ sender: NSButton) {
        AlwaysAllowManager.shared.removeRule(at: sender.tag)
        rebuildAlwaysAllowRulesList()
    }

    @objc func importDefaultRules() {
        AlwaysAllowManager.shared.importDefaults()
        rebuildAlwaysAllowRulesList()
    }

    @objc func clearAllRules() {
        AlwaysAllowManager.shared.clearAll()
        rebuildAlwaysAllowRulesList()
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
        // hookContainer is a plain NSView (non-flipped), y descends from top
        var y: CGFloat = view.bounds.height - 16

        // Port info
        let currentPort = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        let portInfo = NSTextField(frame: NSRect(x: 16, y: y - 16, width: 340, height: 20))
        portInfo.isEditable = false; portInfo.isBordered = false; portInfo.backgroundColor = .clear
        portInfo.font = NSFont.systemFont(ofSize: 11)
        portInfo.textColor = NSColor.secondaryLabelColor
        portInfo.stringValue = "当前服务端口: \(currentPort)  (可在「设置」页修改)"
        view.addSubview(portInfo)
        y -= 40

        // --- Group: 选择工具 ---
        let toolSeg = SettingsRowView.makeSegmented(labels: ["Claude Code", "Codex", "Cursor"], selected: appDelegate.config.hookToolIndex) { [weak self] idx in
            guard let self = self else { return }
            self.appDelegate.config.hookToolIndex = idx
            self.appDelegate.saveConfig()
        }
        hookToolSegment = toolSeg

        let toolGroup = SettingsGroupView(header: "选择工具", rows: [
            SettingsRowView(title: "配置目标", subtitle: "选择要配置 Hook 的工具",
                            accessory: toolSeg, isFirst: true, isLast: true),
        ])
        toolGroup.frame.origin = NSPoint(x: 16, y: y - toolGroup.frame.height)
        toolGroup.autoresizingMask = [.minXMargin, .maxYMargin, .width]
        view.addSubview(toolGroup)
        y -= toolGroup.frame.height + 20

        // --- Group: 操作 ---
        let applyBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        applyBtn.title = "应用配置"; applyBtn.bezelStyle = .rounded
        applyBtn.font = NSFont.systemFont(ofSize: 12)
        applyBtn.target = self; applyBtn.action = #selector(applyHookConfig)

        let copyBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        copyBtn.title = "复制配置"; copyBtn.bezelStyle = .rounded
        copyBtn.font = NSFont.systemFont(ofSize: 12)
        copyBtn.target = self; copyBtn.action = #selector(copyHookConfig)

        let actionGroup = SettingsGroupView(header: "操作", rows: [
            SettingsRowView(title: "应用配置", subtitle: "自动合并 Hook 到配置文件",
                            accessory: applyBtn, isFirst: true),
            SettingsRowView(title: "复制配置", subtitle: "复制到剪贴板",
                            accessory: copyBtn, isLast: true),
        ])
        actionGroup.frame.origin = NSPoint(x: 16, y: y - actionGroup.frame.height)
        actionGroup.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(actionGroup)
        y -= actionGroup.frame.height + 16

        // 状态反馈
        hookStatusLabel = NSTextField(frame: NSRect(x: 16, y: y - 40, width: 348, height: 44))
        hookStatusLabel.isEditable = false; hookStatusLabel.isBordered = false; hookStatusLabel.backgroundColor = .clear
        hookStatusLabel.font = NSFont.systemFont(ofSize: 11)
        hookStatusLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        hookStatusLabel.alignment = .center
        hookStatusLabel.stringValue = ""
        hookStatusLabel.cell?.wraps = true
        view.addSubview(hookStatusLabel)
    }

    @objc func copyHookConfig() {
        let port = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        let seg = hookToolSegment.selectedSegment
        var parts: [String] = []

        if seg == 0 {
            let hooks: [String: Any] = generateHooks(tool: "claude", port: port)
            let json = generateHooksJSON(hooks: hooks)
            parts.append("=== Claude Code — ~/.claude/settings.json ===\n\(json)")
        }
        if seg == 1 {
            let hooks: [String: Any] = generateHooks(tool: "codex", port: port)
            let json = generateHooksJSON(hooks: hooks)
            parts.append("=== Codex config.toml ===\n[features]\nhooks = true\n\n=== Codex hooks.json — ~/.codex/hooks.json ===\n\(json)")
        }
        if seg == 2 {
            let hooks: [String: Any] = generateHooks(tool: "cursor", port: port)
            let json = generateHooksJSON(hooks: hooks)
            parts.append("=== Cursor — ~/.cursor/settings.json ===\n\(json)")
        }

        if parts.isEmpty {
            hookStatusLabel.stringValue = "请至少选择一个工具"
            hookStatusLabel.textColor = NSColor.systemOrange
            return
        }

        let text = parts.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        hookStatusLabel.stringValue = "已复制到剪贴板"
        hookStatusLabel.textColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
    }

    // Hook config methods moved to HookConfig.swift

    @objc func sliderChanged() {
        if pollLabel != nil { pollLabel.stringValue = String(format: "%.1fs", pollSlider.doubleValue) }
        opacityLabel.stringValue = "\(Int(opacitySlider.doubleValue * 100))%"
        blinkLabel.stringValue = String(format: "%.1fs", blinkSlider.doubleValue)

        // 实时预览：只更新属性，不重建窗口
        appDelegate.config.opacity = opacitySlider.doubleValue
        appDelegate.config.blinkSpeed = blinkSlider.doubleValue
        appDelegate.config.pollInterval = pollSlider.doubleValue
        if let w = appDelegate.lightWindow {
            w.alphaValue = opacitySlider.doubleValue
        }
        appDelegate.config.save()
    }

    private var sizeRebuildTimer: Timer?

    @objc func sizeSliderChanged() {
        sizeLabel.stringValue = "\(Int(sizeSlider.doubleValue))"
        appDelegate.config.windowSize = sizeSlider.doubleValue
        appDelegate.config.save()
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
        appDelegate.config.save()
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
        appDelegate.config.mascotType = t
        appDelegate.config.save()
        appDelegate.trafficContainer?.mascotType = t
        appDelegate.redView?.mascotType = t
    }

    @objc func themeChanged() {
        colorWell.isHidden = themeSelect.indexOfSelectedItem != 2
        let themes = ["dark", "light", "custom"]
        let theme = themes[themeSelect.indexOfSelectedItem]
        appDelegate.config.theme = theme
        if theme == "custom", let hex = colorWell.color.hexString {
            appDelegate.config.customColor = hex
        }
        appDelegate.config.save()
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

    @objc func toggleInstant(_ sender: Any) {
        var c = appDelegate.config
        let isOn = (sender as? NSSwitch)?.state == .on || (sender as? NSButton)?.state == .on
        if let s = sender as? NSObject, s == weatherCheck {
            c.weatherThemeEnabled = isOn
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
        } else if let s = sender as? NSObject, s == showStatusCheck {
            c.showStatusText = isOn
        }
        c.save()
        appDelegate.config = c
        appDelegate.restartWithNewConfig()
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

    // MARK: - Advanced Tab (WebDAV Sync)

    private func buildAdvancedTab(_ view: NSView, _ c: AppConfig) {
        var y: CGFloat = 16
        let contentW = view.bounds.width - 32

        // WebDAV 内容直接平铺
        let webdavContent = FlippedView(frame: NSRect(x: 16, y: y, width: contentW, height: 400))
        buildWebDAVContent(webdavContent, c, width: contentW)
        // 计算实际内容高度
        var maxY: CGFloat = 0
        for sub in webdavContent.subviews {
            let bottom = sub.frame.origin.y + sub.frame.height
            if bottom > maxY { maxY = bottom }
        }
        webdavContent.frame.size.height = maxY + 16
        view.addSubview(webdavContent)
        y += webdavContent.frame.height + 16

        // 运行日志
        let logContent = FlippedView(frame: NSRect(x: 16, y: y, width: contentW, height: 220))
        buildLogContent(logContent, width: contentW)
        var logMaxY: CGFloat = 0
        for sub in logContent.subviews {
            let bottom = sub.frame.origin.y + sub.frame.height
            if bottom > logMaxY { logMaxY = bottom }
        }
        logContent.frame.size.height = logMaxY + 16
        view.addSubview(logContent)
    }

    private func buildWebDAVContent(_ view: NSView, _ c: AppConfig, width: CGFloat) {
        let contentW = width
        var y: CGFloat = 0

        // Description
        let desc = NSTextField(frame: NSRect(x: 10, y: y, width: contentW - 20, height: 16))
        desc.isEditable = false; desc.isBordered = false; desc.backgroundColor = .clear; desc.drawsBackground = false
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = NSColor.tertiaryLabelColor
        desc.stringValue = "通过 WebDAV 同步配置到坚果云、NextCloud、群晖等"
        view.addSubview(desc)
        y += 24

        // --- Group: WebDAV 连接 ---
        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        urlField.font = NSFont.systemFont(ofSize: 12)
        urlField.placeholderString = "https://dav.jianguoyun.com/dav/"
        urlField.stringValue = c.webdavURL
        urlField.lineBreakMode = .byTruncatingMiddle
        webdavURLField = urlField

        let userField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        userField.font = NSFont.systemFont(ofSize: 12)
        userField.placeholderString = "邮箱或用户名"
        userField.stringValue = c.webdavUser
        webdavUserField = userField

        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        passField.font = NSFont.systemFont(ofSize: 12)
        passField.placeholderString = "应用专用密码"
        passField.stringValue = c.webdavPass
        webdavPassField = passField

        let pathField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        pathField.font = NSFont.systemFont(ofSize: 12)
        pathField.placeholderString = "/codelight/config.json"
        pathField.stringValue = c.webdavPath
        pathField.lineBreakMode = .byTruncatingMiddle
        webdavPathField = pathField

        let connectGroup = SettingsGroupView(header: "WebDAV 连接", rows: [
            SettingsRowView(title: "服务器地址", accessory: urlField, isFirst: true),
            SettingsRowView(title: "用户名", accessory: userField),
            SettingsRowView(title: "密码", accessory: passField),
            SettingsRowView(title: "远程路径", accessory: pathField, isLast: true),
        ])
        connectGroup.frame.origin = NSPoint(x: 0, y: y)
        connectGroup.autoresizingMask = .width
        view.addSubview(connectGroup)
        y += connectGroup.frame.height + 8

        // --- Group: 同步 ---
        let autoSyncToggle = SettingsRowView.makeToggle(isOn: c.webdavAutoSync) { [weak self] isOn in
            guard let self = self else { return }
            self.appDelegate.config.webdavAutoSync = isOn
            self.appDelegate.saveConfig()
        }
        webdavAutoSyncCheck = autoSyncToggle

        // Buttons row
        let btnW: CGFloat = 80, btnGap: CGFloat = 8
        let testBtn = NSButton(frame: NSRect(x: 0, y: 0, width: btnW, height: 26))
        testBtn.title = "测试连接"; testBtn.bezelStyle = .rounded
        testBtn.font = NSFont.systemFont(ofSize: 11)
        testBtn.target = self; testBtn.action = #selector(webdavTestConnection(_:))

        let uploadBtn = NSButton(frame: NSRect(x: btnW + btnGap, y: 0, width: btnW, height: 26))
        uploadBtn.title = "上传配置"; uploadBtn.bezelStyle = .rounded
        uploadBtn.font = NSFont.systemFont(ofSize: 11)
        uploadBtn.target = self; uploadBtn.action = #selector(webdavUpload(_:))

        let downloadBtn = NSButton(frame: NSRect(x: (btnW + btnGap) * 2, y: 0, width: btnW, height: 26))
        downloadBtn.title = "下载配置"; downloadBtn.bezelStyle = .rounded
        downloadBtn.font = NSFont.systemFont(ofSize: 11)
        downloadBtn.target = self; downloadBtn.action = #selector(webdavDownload(_:))

        let buttonsView = NSView(frame: NSRect(x: 0, y: 0, width: (btnW + btnGap) * 3, height: 26))
        buttonsView.addSubview(testBtn)
        buttonsView.addSubview(uploadBtn)
        buttonsView.addSubview(downloadBtn)

        let syncGroup = SettingsGroupView(header: "同步", rows: [
            SettingsRowView(title: "自动同步", subtitle: "保存设置时自动上传",
                            accessory: autoSyncToggle, isFirst: true),
            SettingsRowView(title: "操作", accessory: buttonsView, isLast: true),
        ])
        syncGroup.frame.origin = NSPoint(x: 0, y: y)
        syncGroup.autoresizingMask = .width
        view.addSubview(syncGroup)
        y += syncGroup.frame.height + 8

        // Status label
        webdavStatusLabel = NSTextField(frame: NSRect(x: 10, y: y, width: contentW - 20, height: 18))
        webdavStatusLabel.isEditable = false; webdavStatusLabel.isBordered = false
        webdavStatusLabel.backgroundColor = .clear; webdavStatusLabel.drawsBackground = false
        webdavStatusLabel.font = NSFont.systemFont(ofSize: 11)
        webdavStatusLabel.textColor = NSColor.secondaryLabelColor
        webdavStatusLabel.stringValue = ""
        view.addSubview(webdavStatusLabel)
        y += 24

        // Help text
        let helpText = NSTextField(frame: NSRect(x: 10, y: y, width: contentW - 20, height: 16))
        helpText.isEditable = false; helpText.isBordered = false; helpText.backgroundColor = .clear; helpText.drawsBackground = false
        helpText.font = NSFont.systemFont(ofSize: 10)
        helpText.textColor = NSColor.tertiaryLabelColor
        helpText.stringValue = "\u{1f4a1} 坚果云用应用专用密码 | 同步：偏好设置，不含窗口位置"
        view.addSubview(helpText)
    }

    private func buildLogContent(_ view: NSView, width: CGFloat) {
        let rx: CGFloat = 10
        let logW = width - rx * 2

        let refreshLogBtn = NSButton(frame: NSRect(x: rx, y: 0, width: 70, height: 24))
        refreshLogBtn.title = "刷新"; refreshLogBtn.bezelStyle = .rounded
        refreshLogBtn.font = NSFont.systemFont(ofSize: 11)
        refreshLogBtn.target = self; refreshLogBtn.action = #selector(refreshLog(_:))
        view.addSubview(refreshLogBtn)

        let clearLogBtn = NSButton(frame: NSRect(x: rx + 78, y: 0, width: 70, height: 24))
        clearLogBtn.title = "清空"; clearLogBtn.bezelStyle = .rounded
        clearLogBtn.font = NSFont.systemFont(ofSize: 11)
        clearLogBtn.target = self; clearLogBtn.action = #selector(clearLog(_:))
        view.addSubview(clearLogBtn)

        logTextView = NSTextView(frame: NSRect(x: rx, y: 28, width: logW, height: 180))
        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = NSColor(white: 0.7, alpha: 1.0)
        logTextView.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        logTextView.drawsBackground = true
        logTextView.isRichText = false
        view.addSubview(logTextView)
    }

    // MARK: - Advanced Tab Helpers

    private func fieldLabel(_ text: String, x: CGFloat, lx: CGFloat, y: CGFloat) -> NSTextField {
        let l = NSTextField(frame: NSRect(x: x, y: y, width: lx - x - 6, height: 20))
        l.isEditable = false; l.isBordered = false; l.backgroundColor = .clear; l.drawsBackground = false
        l.font = NSFont.systemFont(ofSize: 12)
        l.stringValue = text; l.alignment = .right
        return l
    }

    private func labeledField(_ label: String, placeholder: String, value: String, x: CGFloat, lx: CGFloat, y: CGFloat, fieldW: CGFloat, in view: NSView) -> NSTextField {
        let l = fieldLabel(label, x: x, lx: lx, y: y)
        view.addSubview(l)
        let f = NSTextField(frame: NSRect(x: lx, y: y, width: fieldW, height: 22))
        f.font = NSFont.systemFont(ofSize: 12)
        f.placeholderString = placeholder
        f.stringValue = value
        f.lineBreakMode = .byTruncatingMiddle
        view.addSubview(f)
        return f
    }

    @objc private func refreshLog(_ sender: NSButton) {
        loadLogContent()
    }

    @objc private func clearLog(_ sender: NSButton) {
        let path = "/tmp/codelight.log"
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        if logTextView != nil { logTextView.string = "" }
    }

    private func loadLogContent() {
        guard logTextView != nil else { return }
        let path = "/tmp/codelight.log"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            logTextView.string = "（暂无日志）"
            return
        }
        let lines = content.components(separatedBy: "\n")
        let tail = lines.suffix(200).joined(separator: "\n")
        logTextView.string = tail
        logTextView.scrollRangeToVisible(NSRange(location: tail.count, length: 0))
    }

    @objc private func webdavTestConnection(_ sender: NSButton) {
        var c = appDelegate.config
        c.webdavURL = webdavURLField.stringValue.trimmingCharacters(in: .whitespaces)
        c.webdavUser = webdavUserField.stringValue
        c.webdavPass = webdavPassField.stringValue

        webdavStatusLabel.stringValue = "正在测试连接..."
        webdavStatusLabel.textColor = NSColor.secondaryLabelColor
        sender.isEnabled = false

        WebDAVSync.shared.testConnection(c) { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.webdavStatusLabel.stringValue = msg
                self?.webdavStatusLabel.textColor = success ? NSColor.systemGreen : NSColor.systemRed
                sender.isEnabled = true
            }
        }
    }

    @objc private func webdavUpload(_ sender: NSButton) {
        var c = collectWebDAVConfig()
        c.webdavAutoSync = webdavAutoSyncCheck.state == .on

        webdavStatusLabel.stringValue = "正在上传..."
        webdavStatusLabel.textColor = NSColor.secondaryLabelColor
        sender.isEnabled = false

        WebDAVSync.shared.uploadConfig(c) { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.webdavStatusLabel.stringValue = msg
                self?.webdavStatusLabel.textColor = success ? NSColor.systemGreen : NSColor.systemRed
                sender.isEnabled = true
            }
        }
    }

    @objc private func webdavDownload(_ sender: NSButton) {
        let c = collectWebDAVConfig()

        webdavStatusLabel.stringValue = "正在下载..."
        webdavStatusLabel.textColor = NSColor.secondaryLabelColor
        sender.isEnabled = false

        WebDAVSync.shared.downloadConfig(c) { [weak self] (success: Bool, msg: String, json: [String: Any]?) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                sender.isEnabled = true
                if success, let json = json {
                    var config = self.appDelegate.config
                    config.applyJSON(json)
                    config.webdavURL = c.webdavURL
                    config.webdavUser = c.webdavUser
                    config.webdavPass = c.webdavPass
                    config.webdavPath = c.webdavPath
                    config.save()
                    self.syncFromConfig()
                    self.webdavStatusLabel.stringValue = "下载成功，配置已应用 ✓"
                    self.webdavStatusLabel.textColor = NSColor.systemGreen
                } else {
                    self.webdavStatusLabel.stringValue = msg
                    self.webdavStatusLabel.textColor = NSColor.systemRed
                }
            }
        }
    }

    private func collectWebDAVConfig() -> AppConfig {
        var c = appDelegate.config
        c.webdavURL = webdavURLField.stringValue.trimmingCharacters(in: .whitespaces)
        c.webdavUser = webdavUserField.stringValue
        c.webdavPass = webdavPassField.stringValue
        c.webdavPath = webdavPathField.stringValue.trimmingCharacters(in: .whitespaces)
        if c.webdavPath.isEmpty { c.webdavPath = "/codelight/config.json" }
        return c
    }

    // MARK: - Stats Tab

    private func buildStatsTab(_ view: NSView, _ c: AppConfig) {
        let stats = StatsManager.shared.todayStats()
        let weekData = StatsManager.shared.weekStats()
        var y: CGFloat = 16
        let cw: CGFloat = view.bounds.width - 32

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
        let isStatsTab = (row == sidebarItems.count - 2)  // 统计是倒数第2个
        let isAlwaysAllowTab = (row == 3)
        let isSkillsTab = (row == sidebarItems.count - 1)  // 技能是最后一个
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
        if isAlwaysAllowTab {
            rebuildAlwaysAllowRulesList()
        }
        if isSkillsTab {
            if skillsSegment.selectedSegment == 0 {
                rebuildSkillsList()
            } else {
                if skillsRemoteItems.isEmpty { skillsRefreshRemote(self) }
                else { rebuildSkillsDiscoverList() }
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

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
    private let maxHistory = 100
    private let sessionTimeout: TimeInterval = 300
    private let deadTimeout: TimeInterval = 3600
    var onLog: ((String) -> Void)?

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
            return .init(status: 404, body: "{\"ok\":false,\"error\":\"not found\"}")
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
        sessions[sessionId] = SessionEntry(state: state, message: message, timestamp: Date())
        history.append(HistoryEntry(timestamp: Date().timeIntervalSince1970, state: state, message: message, session_id: String(sessionId.prefix(8)), light: stateLightDict(state)))
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        onLog?("[状态] [\(sessionId.prefix(8))] \(state) — \(message)")
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
    var mouseDownMonitor: Any?
    var mouseUpMonitor: Any?
    var sessions: [String: [String: Any]] = [:]
    var shellView: ShellView?
    var trafficContainer: TrafficLightContainer?
    var weatherView: WeatherView?
    var notificationCenter: UNUserNotificationCenter?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        setupNotifications()
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

    func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else {
            log("[通知] 跳过: 缺少 Bundle Identifier")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        notificationCenter = center
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.log("[通知] UN权限: \(granted), err: \(String(describing: error))")
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

    func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = drawMenuIcon(state: "idle")
            button.image?.isTemplate = false
            button.toolTip = "CodeLight — 空闲"
        }
        let menu = NSMenu()

        // 状态标题（不可点击）
        let stateItem = NSMenuItem(title: "● 空闲", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "显示/隐藏", action: #selector(toggleWindow), keyEquivalent: "w")
        menu.addItem(withTitle: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    func drawMenuIcon(state: String) -> NSImage {
        let s: CGFloat = 22
        let img = config.horizontal
            ? NSImage(size: NSSize(width: s * 1.4, height: s))
            : NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

        let w = img.size.width, h = img.size.height
        let lampR: CGFloat = 3.2

        // 国标色值
        let red = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)
        let yellow = NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)
        let green = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
        let dimRed = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.25)
        let dimYellow = NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 0.25)
        let dimGreen = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 0.25)

        let redOn = state == "working" || state == "error"
        let yellowOn = state == "thinking" || state == "fixing"
        let greenOn = state == "idle"

        if config.horizontal {
            // 横向：红(左)、黄(中)、绿(右)
            let cy = h / 2
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1.0).cgColor)
            let shell = NSBezierPath(roundedRect: NSRect(x: 1, y: cy - 5.5, width: w - 2, height: 11), xRadius: 4, yRadius: 4)
            shell.fill()
            let lamps: [(CGFloat, Bool, NSColor, NSColor)] = [
                (5.5, redOn, red, dimRed),
                (w / 2, yellowOn, yellow, dimYellow),
                (w - 5.5, greenOn, green, dimGreen),
            ]
            for (cx, isOn, onColor, offColor) in lamps {
                let path = CGPath(ellipseIn: CGRect(x: cx - lampR, y: cy - lampR, width: lampR * 2, height: lampR * 2), transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(isOn ? onColor.cgColor : offColor.cgColor)
                ctx.fillPath()
            }
        } else {
            // 竖向：红(上)、黄(中)、绿(下)
            let cx = w / 2
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1.0).cgColor)
            let shell = NSBezierPath(roundedRect: NSRect(x: cx - 5.5, y: 1, width: 11, height: h - 2), xRadius: 4, yRadius: 4)
            shell.fill()
            let lamps: [(CGFloat, Bool, NSColor, NSColor)] = [
                (h - 5.5, redOn, red, dimRed),
                (h / 2, yellowOn, yellow, dimYellow),
                (5.5, greenOn, green, dimGreen),
            ]
            for (cy, isOn, onColor, offColor) in lamps {
                let path = CGPath(ellipseIn: CGRect(x: cx - lampR, y: cy - lampR, width: lampR * 2, height: lampR * 2), transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(isOn ? onColor.cgColor : offColor.cgColor)
                ctx.fillPath()
            }
        }

        img.unlockFocus()
        return img
    }

    func buildLightWindow() {
        isRebuilding = true
        defer { isRebuilding = false }
        let initSize = CGFloat(config.windowSize)
        let isEdgeBar = config.edgeBar != nil
        let isMini = config.displayMode == "mini"
        let lightW: CGFloat, lightH: CGFloat
        let statusH: CGFloat = config.showStatusText ? 26 : 0
        if isEdgeBar {
            lightW = 10
            lightH = initSize * 3 + 14 * 2 - 28
        } else if isMini {
            lightW = initSize + 4
            lightH = initSize + 4
        } else if config.horizontal {
            lightW = initSize * 3 + 14 * 2 + 18 * 2
            lightH = initSize + 40 + statusH
        } else {
            lightW = initSize + 40
            lightH = initSize * 3 + 14 * 2 + 18 * 2 + (config.showStatusText ? 32 : 0)
        }
        let screen = NSScreen.main!.frame
        let screenVisible = NSScreen.main!.visibleFrame
        let defaultX: CGFloat, defaultY: CGFloat
        if isEdgeBar {
            if config.edgeBar == "left" {
                defaultX = screen.minX
            } else {
                defaultX = screen.maxX - lightW
            }
            defaultY = screen.midY - lightH / 2
        } else {
            defaultX = screen.width - lightW - 16
            defaultY = screen.height - lightH - 80
        }
        var posX: CGFloat = isEdgeBar ? defaultX : (config.windowX ?? defaultX)
        var posY: CGFloat = config.windowY ?? defaultY

        // 确保窗口完全在屏幕可见区域内
        if !isEdgeBar {
            let sf = NSScreen.main!.visibleFrame
            posX = max(sf.minX, min(posX, sf.maxX - lightW))
            posY = max(sf.minY, min(posY, sf.maxY - lightH))
        }

        if lightWindow != nil {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: lightWindow)
            lightWindow.close()
        }

        let edgeBarStyle: NSWindow.StyleMask = isEdgeBar ? [.nonactivatingPanel, .fullSizeContentView] : [.nonactivatingPanel, .resizable, .fullSizeContentView]
        lightWindow = NSPanel(
            contentRect: NSRect(x: posX, y: posY, width: lightW, height: lightH),
            styleMask: edgeBarStyle,
            backing: .buffered, defer: false
        )
        lightWindow.level = config.isFloating ? (config.showOnFullscreen ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow))) : .floating) : .normal
        lightWindow.collectionBehavior = config.showOnFullscreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        lightWindow.isMovableByWindowBackground = true
        lightWindow.isOpaque = false; lightWindow.hasShadow = true
        lightWindow.minSize = isEdgeBar ? NSSize(width: 10, height: 100) : NSSize(width: 60, height: 120)
        lightWindow.backgroundColor = .clear

        let view = lightWindow.contentView!
        view.wantsLayer = true
        // 主题背景色
        let bgColor: NSColor
        switch config.theme {
        case "light":
            bgColor = NSColor(white: 0.92, alpha: config.opacity)
        case "custom":
            bgColor = (NSColor(fromHex: config.customColor) ?? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)).withAlphaComponent(config.opacity)
        default:
            bgColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: config.opacity)
        }
        view.layer?.backgroundColor = isEdgeBar ? NSColor.black.cgColor : bgColor.cgColor
        view.layer?.cornerRadius = isEdgeBar ? 3 : (isMini ? lightW / 2 : min(lightW, lightH) / 2)
        view.layer?.masksToBounds = true

        if isEdgeBar {
            // Edge bar: three colored segments stacked vertically
            let segH = lightH / 3
            redView = RealTrafficLightView()
            redView.lampColor = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)
            redView.frame = NSRect(x: 0, y: segH * 2, width: lightW, height: segH)
            yellowView = RealTrafficLightView()
            yellowView.lampColor = NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)
            yellowView.frame = NSRect(x: 0, y: segH, width: lightW, height: segH)
            greenView = RealTrafficLightView()
            greenView.lampColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
            greenView.frame = NSRect(x: 0, y: 0, width: lightW, height: segH)
            view.addSubview(redView)
            view.addSubview(yellowView)
            view.addSubview(greenView)
        } else if isMini {
            // Mini 模式：单圆形，颜色随状态变化
            redView = RealTrafficLightView()
            redView.lampColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
            redView.frame = view.bounds
            view.addSubview(redView)
            yellowView = RealTrafficLightView(); yellowView.frame = NSRect.zero
            greenView = RealTrafficLightView(); greenView.frame = NSRect.zero
            shellView = nil; trafficContainer = nil
        } else {
            let shell = ShellView(frame: view.bounds)
            shell.theme = config.theme
            shell.customColor = NSColor(fromHex: config.customColor) ?? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
            shell.autoresizingMask = [.width, .height]
            view.addSubview(shell)
            shellView = shell

            if config.weatherThemeEnabled {
                let wv = WeatherView(frame: view.bounds)
                wv.autoresizingMask = [.width, .height]
                wv.condition = WeatherManager.shared.currentCondition
                wv.weatherCode = WeatherManager.shared.weatherCode
                view.addSubview(wv, positioned: .above, relativeTo: shell)
                weatherView = wv
            } else {
                weatherView = nil
            }

            let container = TrafficLightContainer(frame: view.bounds)
            container.isHorizontal = config.horizontal
            container.showStatusText = config.showStatusText
            container.mascotType = config.mascotType
            container.autoresizingMask = [.width, .height]
            view.addSubview(container)
            trafficContainer = container

            redView = RealTrafficLightView()
            redView.lampColor = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)

            yellowView = RealTrafficLightView()
            yellowView.lampColor = NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)

            greenView = RealTrafficLightView()
            greenView.lampColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)

            container.addSubview(redView)
            container.addSubview(yellowView)
            container.addSubview(greenView)
            container.redView = redView
            container.yellowView = yellowView
            container.greenView = greenView
            container.mascotType = config.mascotType
            container.layout()
        }

        if !isEdgeBar && !isMini {
            statusLabel = NSTextField(frame: NSRect(x: 0, y: 6, width: view.bounds.width, height: 18))
            statusLabel.isEditable = false; statusLabel.isBordered = false
            statusLabel.backgroundColor = .clear
            statusLabel.textColor = NSColor(white: 0.55, alpha: 0.6)
            statusLabel.alignment = .center
            statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            statusLabel.stringValue = "..."
            statusLabel.autoresizingMask = []
            statusLabel.cell?.truncatesLastVisibleLine = true
            statusLabel.isHidden = !config.showStatusText
            view.addSubview(statusLabel)
            let tooltipArea = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 28))
            tooltipArea.autoresizingMask = [.width]
            tooltipArea.isHidden = !config.showStatusText
            view.addSubview(tooltipArea)
            self.tooltipView = tooltipArea
        } else {
            statusLabel = nil
            tooltipView = nil
        }

        let rightMenu = NSMenu()
        rightMenu.addItem(withTitle: "设置...", action: #selector(openSettings), keyEquivalent: "")
        rightMenu.addItem(NSMenuItem.separator())
        rightMenu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "")
        view.menu = rightMenu

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)

        lightWindow.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: lightWindow, queue: .main) { [weak self] _ in
            guard let self = self, let w = self.lightWindow else { return }
            guard !self.isRebuilding else { return }
            // 拖动中只记录位置，不做磁吸判断
            if self.isDragging {
                self.config.windowX = Double(w.frame.origin.x)
                self.config.windowY = Double(w.frame.origin.y)
                return
            }
            guard let screen = NSScreen.main else { return }
            let sf = screen.frame
            let wf = w.frame
            let snap: CGFloat = 20

            var newEdgeBar: String? = self.config.edgeBar

            if wf.minX - sf.minX < snap {
                newEdgeBar = "left"
            } else if sf.maxX - wf.maxX < snap {
                newEdgeBar = "right"
            } else if self.config.edgeBar != nil {
                newEdgeBar = nil
            }

            if newEdgeBar != self.config.edgeBar {
                self.config.edgeBar = newEdgeBar
                self.config.windowX = Double(wf.midX)
                self.config.windowY = Double(wf.midY)
                self.config.save()
                self.buildLightWindow()
                return
            }

            // 记录位置
            self.config.windowX = Double(wf.origin.x)
            self.config.windowY = Double(wf.origin.y)
            self.config.save()
        }

        // 鼠标按下/松开追踪拖动状态
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            if event.window === self?.lightWindow { self?.isDragging = true }
            return event
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            if self.isDragging {
                self.isDragging = false
                guard let w = self.lightWindow, let screen = NSScreen.main else { return event }
                let sf = screen.frame
                let wf = w.frame
                let snap: CGFloat = 20
                var newEdgeBar: String? = self.config.edgeBar
                if wf.minX - sf.minX < snap {
                    newEdgeBar = "left"
                } else if sf.maxX - wf.maxX < snap {
                    newEdgeBar = "right"
                } else if self.config.edgeBar != nil {
                    newEdgeBar = nil
                }
                if newEdgeBar != self.config.edgeBar {
                    self.config.edgeBar = newEdgeBar
                    self.config.windowX = Double(wf.midX)
                    self.config.windowY = Double(wf.midY)
                    self.config.save()
                    self.buildLightWindow()
                } else {
                    self.config.windowX = Double(wf.origin.x)
                    self.config.windowY = Double(wf.origin.y)
                    self.config.save()
                }
            }
            return event
        }
    }

    func startTimers() {
        pollTimer?.invalidate(); animTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { _ in self.pollState() }
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in self.animateLight() }
    }

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
    }
    @objc func openSettings() {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(appDelegate: self) }
        settingsWindowController?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.center()
    }
    @objc func quitApp() { NSApp.terminate(nil) }

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

    func animateLight() {
        let state = currentStateName
        animPhase += 0.04
        if animPhase > 1 { animPhase -= 1 }

        // 只有非 idle 状态才高频更新（闪烁/呼吸/吉祥物动画）
        // idle 状态每 25 帧（~1.25s）更新一次吉祥物即可
        // Mini 模式 idle 状态完全跳过动画
        let isMiniIdle = config.displayMode == "mini" && state == "idle"
        let needsAnim = isMiniIdle ? false : (state != "idle" || Int(animPhase * 100) % 25 == 0)
        if needsAnim {
            redView.mascotPhase = animPhase
            yellowView.mascotPhase = animPhase
            greenView.mascotPhase = animPhase
        }
        redView.tickMascotFade()
        yellowView.tickMascotFade()
        greenView.tickMascotFade()

        // Mini 模式：单灯颜色随状态切换
        if config.displayMode == "mini" {
            let miniColors: [String: NSColor] = [
                "idle": NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0),
                "thinking": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0),
                "working": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
                "fixing": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0),
                "error": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
            ]
            redView.lampColor = miniColors[state] ?? miniColors["idle"]!
            redView.isOn = true
            switch state {
            case "thinking":
                redView.brightness = CGFloat(0.3 + 0.7 * (0.5 + 0.5 * sin(Double(animPhase) * .pi * 2)))
            case "working":
                redView.brightness = sin(Double(animPhase) * .pi * 2) > 0 ? 1.0 : 0.15
            case "fixing":
                redView.brightness = CGFloat(0.3 + 0.7 * (0.5 + 0.5 * sin(Double(animPhase) * .pi * 3)))
            case "error":
                redView.brightness = sin(Double(animPhase) * .pi * 4) > 0 ? 1.0 : 0.15
            default:
                redView.brightness = 1.0
            }
        } else {
            switch state {
            case "thinking":
                let breath = CGFloat(0.3 + 0.7 * (0.5 + 0.5 * sin(Double(animPhase) * .pi * 2)))
                yellowView.isOn = true; yellowView.brightness = breath
                yellowView.mascotState = "thinking"
                redView.isOn = false; redView.mascotState = ""
                greenView.isOn = false; greenView.mascotState = ""

            case "working":
                let slow = sin(Double(animPhase) * .pi * 2) > 0
                redView.isOn = slow; redView.brightness = 1.0
                redView.mascotState = "working"
                yellowView.isOn = false; yellowView.mascotState = ""
                greenView.isOn = false; greenView.mascotState = ""

            case "fixing":
                let slow = CGFloat(0.3 + 0.7 * (0.5 + 0.5 * sin(Double(animPhase) * .pi * 3)))
                yellowView.isOn = true; yellowView.brightness = slow
                yellowView.mascotState = "fixing"
                redView.isOn = false; redView.mascotState = ""
                greenView.isOn = false; greenView.mascotState = ""

            case "error":
                let fast = sin(Double(animPhase) * .pi * 4) > 0
                redView.isOn = fast; redView.brightness = 1.0
                redView.mascotState = "error"
                yellowView.isOn = false; yellowView.mascotState = ""
                greenView.isOn = false; greenView.mascotState = ""

            default: // idle
                greenView.isOn = true; greenView.brightness = 1.0
                greenView.mascotState = "idle"
                redView.isOn = false; redView.mascotState = ""
                yellowView.isOn = false; yellowView.mascotState = ""
            }
        }

        // 外框/边框颜色跟随当前状态
        let stateColors: [String: NSColor] = [
            "idle": NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0),
            "thinking": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0),
            "working": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
            "fixing": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0),
            "error": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
        ]
        let activeColor = stateColors[state] ?? stateColors["idle"]!
        if config.displayMode == "mini" {
            lightWindow.contentView?.layer?.borderColor = activeColor.withAlphaComponent(0.5).cgColor
            lightWindow.contentView?.layer?.borderWidth = 2.5
        }

        // 跑马灯：文字超过可见宽度时滚动（文字隐藏时跳过）
        if !marqueeText.isEmpty && statusLabel != nil && !statusLabel.isHidden {
            let windowWidth = lightWindow?.frame.width ?? 100
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let textWidth = (marqueeText as NSString).size(withAttributes: [.font: font]).width
            let maxVisibleWidth = windowWidth - 16

            if textWidth > maxVisibleWidth {
                // 每 20 帧移动一个字符（约 1 秒/字）
                if Int(animPhase * 100) % 20 == 0 {
                    marqueeOffset += 1
                    if marqueeOffset > marqueeText.count + 3 { marqueeOffset = 0 }
                }
                let text = marqueeText
                let idx = min(marqueeOffset, text.count)
                let start = text.index(text.startIndex, offsetBy: idx)
                var visible = String(text[start...])
                if marqueeOffset > 0 { visible = "…" + visible }
                while (visible as NSString).size(withAttributes: [.font: font]).width > maxVisibleWidth && visible.count > 2 {
                    visible = String(visible.dropLast())
                }
                statusLabel.stringValue = visible
            }
        }
    }

    func pollState() {
        guard let url = URL(string: "\(config.serverURL)/api/state") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let sn = json["state"] as? String ?? "idle"
            let msg = json["message"] as? String ?? ""
            let light = json["light"] as? [String: Any] ?? [:]
            let label = light["label"] as? String ?? sn
            let blink = light["blink"] as? Bool ?? false
            DispatchQueue.main.async {
                let prevState = self.currentStateName
                let prevActive = self.lastActiveCount
                self.currentStateName = sn; self.currentBlink = blink
                let activeCount = json["active_count"] as? Int ?? 0
                self.lastActiveCount = activeCount

                // 通知：活跃数从 >0 变为 0（所有会话都完成了）
                if prevActive > 0 && activeCount == 0 && self.config.notifyOnDone, let notificationCenter = self.notificationCenter {
                    let sessionCount = prevActive
                    let title = sessionCount == 1 ? "Claude Code 任务完成" : "\(sessionCount) 个任务全部完成"
                    let body = msg.isEmpty ? "所有会话已空闲" : msg
                    self.log("[通知] 触发: active \(prevActive) → 0, msg: \(msg)")
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    content.sound = .default
                    let id = "claude-done-\(Int(Date().timeIntervalSince1970))"
                    let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                    notificationCenter.add(req) { error in
                        self.log("[通知] UN结果: \(error?.localizedDescription ?? "ok")")
                    }
                }
                let s = STATES[sn] ?? STATES["idle"]!
                if self.config.displayMode != "mini" {
                    if !blink {
                        self.redView.isOn = s.red
                        self.yellowView.isOn = s.yellow
                    }
                    self.greenView.isOn = s.green
                }
                // 底部文字颜色跟随灯色
                let stateColors: [String: NSColor] = [
                    "idle": NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 0.8),
                    "thinking": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 0.8),
                    "working": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.8),
                    "fixing": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 0.8),
                    "error": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.8),
                ]
                self.statusLabel?.textColor = stateColors[sn] ?? NSColor(white: 0.55, alpha: 0.6)
                // 底部文字：只显示三种
                let simpleLabels: [String: String] = [
                    "idle": "空闲中", "thinking": "思考中", "working": "执行中",
                    "fixing": "执行中", "error": "执行中"
                ]
                let displayText = simpleLabels[sn] ?? "空闲中"
                self.statusLabel?.stringValue = displayText
                self.statusLabel?.isHidden = !self.config.showStatusText
                self.statusLabel?.toolTip = displayText
                self.tooltipView?.toolTip = displayText
                self.tooltipView?.isHidden = !self.config.showStatusText
                // 跑马灯：仅文字变化时重置偏移
                if self.marqueeText != displayText {
                    self.marqueeText = displayText
                    self.marqueeOffset = 0
                }
                if let btn = self.statusItem?.button {
                    let icon = self.drawMenuIcon(state: sn)
                    icon.isTemplate = false
                    btn.image = icon
                    btn.toolTip = "CodeLight — \(label)"
                    // 更新菜单第一项的状态文字
                    if let menu = self.statusItem?.menu, menu.items.count > 0 {
                        let stateColors: [String: String] = ["idle": "🟢", "thinking": "🟡", "working": "🔴", "fixing": "🟡", "error": "🔴"]
                        let emoji = stateColors[sn] ?? "⚪"
                        menu.items[0].title = "\(emoji) \(label)\(msg.isEmpty ? "" : ": \(msg)")"
                    }
                }
            }
        }.resume()
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
    var fullscreenCheck: NSButton!
    var floatingCheck: NSButton!
    var mascotSelect: NSPopUpButton!
    var horizontalCheck: NSButton!
    var displayModeSegment: NSSegmentedControl!
    var showStatusCheck: NSButton!
    var sizeSlider: NSSlider!; var sizeLabel: NSTextField!
    var containerView: NSView!
    var settingsContainer: NSView!
    var rulesContainer: NSView!
    var hookContainer: NSView!
    var segmentedControl: NSSegmentedControl!
    var claudeCodeCheck: NSButton!
    var codexCheck: NSButton!
    var cursorCheck: NSButton!
    var hookStatusLabel: NSTextField!
    var themeSelect: NSPopUpButton!
    var colorWell: NSColorWell!
    var weatherCheck: NSButton!
    var weatherStatusLabel: NSTextField!
    var citySelect: NSPopUpButton!

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "CodeLight 设置"; win.isReleasedWhenClosed = false
        super.init(window: win); win.delegate = self; buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func switchTab(_ sender: NSSegmentedControl) {
        settingsContainer.isHidden = sender.selectedSegment != 0
        rulesContainer.isHidden = sender.selectedSegment != 1
        hookContainer.isHidden = sender.selectedSegment != 2
    }

    func buildUI() {
        guard let view = window?.contentView else { return }
        let c = appDelegate.config
        let contentW: CGFloat = 380
        let contentX: CGFloat = (420 - contentW) / 2

        // Segmented control — 顶部 tab 切换
        segmentedControl = NSSegmentedControl(labels: ["设置", "灯效规则", "配置 Hook"], trackingMode: .selectOne, target: self, action: #selector(switchTab))
        segmentedControl.frame = NSRect(x: contentX, y: 580, width: contentW, height: 24)
        segmentedControl.selectedSegment = 0
        view.addSubview(segmentedControl)

        // 分隔线
        let sepLine = NSView(frame: NSRect(x: contentX, y: 574, width: contentW, height: 1))
        sepLine.wantsLayer = true; sepLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(sepLine)

        // 内容容器 — 从分隔线往下到窗口底部
        containerView = NSView(frame: NSRect(x: contentX, y: 0, width: contentW, height: 570))
        view.addSubview(containerView)

        // === 设置页 ===
        settingsContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: 570))
        buildSettingsTab(settingsContainer, c)
        containerView.addSubview(settingsContainer)

        // === 灯效规则页 ===
        rulesContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: 570))
        buildRulesTab(rulesContainer)
        rulesContainer.isHidden = true
        containerView.addSubview(rulesContainer)

        // === Hook 配置页 ===
        hookContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: 570))
        buildHookTab(hookContainer)
        hookContainer.isHidden = true
        containerView.addSubview(hookContainer)
    }

    func buildSettingsTab(_ view: NSView, _ c: AppConfig) {
        var y: CGFloat = 540
        let lx: CGFloat = 10, rx: CGFloat = 140

        func label(_ text: String, _ yy: CGFloat) {
            let l = NSTextField(frame: NSRect(x: lx, y: yy, width: 120, height: 24))
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

        func separator(_ yy: CGFloat) {
            let line = NSView(frame: NSRect(x: 16, y: yy, width: 328, height: 1))
            line.wantsLayer = true; line.layer?.backgroundColor = NSColor.separatorColor.cgColor
            view.addSubview(line)
        }

        sectionTitle("连接", y + 2)
        y -= 8
        label("服务端口:", y)
        serverField = NSTextField(frame: NSRect(x: rx, y: y, width: 100, height: 24))
        let port = c.serverURL.components(separatedBy: ":").last ?? "8866"
        serverField.stringValue = port; serverField.font = NSFont.systemFont(ofSize: 12)
        serverField.placeholderString = "8866"
        view.addSubview(serverField)

        let testBtn = NSButton(frame: NSRect(x: rx + 108, y: y, width: 56, height: 24))
        testBtn.title = "测试"
        testBtn.bezelStyle = .rounded
        testBtn.font = NSFont.systemFont(ofSize: 11)
        testBtn.target = self
        testBtn.action = #selector(testPortAction(_:))
        view.addSubview(testBtn)

        portTestLabel = NSTextField(frame: NSRect(x: rx + 170, y: y + 4, width: 120, height: 16))
        portTestLabel.isEditable = false; portTestLabel.isBordered = false
        portTestLabel.backgroundColor = .clear; portTestLabel.font = NSFont.systemFont(ofSize: 11)
        portTestLabel.stringValue = ""
        view.addSubview(portTestLabel)
        y -= 32

        label("轮询间隔:", y + 4)
        pollSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        pollSlider.minValue = 0.1; pollSlider.maxValue = 3.0; pollSlider.doubleValue = c.pollInterval
        pollSlider.target = self; pollSlider.action = #selector(sliderChanged)
        view.addSubview(pollSlider)
        pollLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        pollLabel.isEditable = false; pollLabel.isBordered = false; pollLabel.backgroundColor = .clear
        pollLabel.stringValue = String(format: "%.1fs", c.pollInterval); pollLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(pollLabel); y -= 36

        y -= 6; separator(y + 2); y -= 18
        sectionTitle("外观", y + 2); y -= 8

        label("透明度:", y + 4)
        opacitySlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        opacitySlider.minValue = 0.3; opacitySlider.maxValue = 1.0; opacitySlider.doubleValue = c.opacity
        opacitySlider.target = self; opacitySlider.action = #selector(sliderChanged)
        view.addSubview(opacitySlider)
        opacityLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        opacityLabel.isEditable = false; opacityLabel.isBordered = false; opacityLabel.backgroundColor = .clear
        opacityLabel.stringValue = "\(Int(c.opacity * 100))%"; opacityLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(opacityLabel); y -= 28

        label("吉祥物:", y + 4)
        mascotSelect = NSPopUpButton(frame: NSRect(x: rx, y: y + 2, width: 140, height: 24))
        mascotSelect.addItems(withTitles: ["🐂 小牛", "🐱 小猫", "🤖 机器人"])
        mascotSelect.selectItem(at: ["cow": 0, "cat": 1, "robot": 2][c.mascotType] ?? 0)
        mascotSelect.target = self; mascotSelect.action = #selector(mascotChanged)
        view.addSubview(mascotSelect); y -= 28

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
        view.addSubview(colorWell); y -= 28

        weatherCheck = NSButton(frame: NSRect(x: rx, y: y, width: 200, height: 24))
        weatherCheck.setButtonType(.switch); weatherCheck.title = "天气主题（实时天气背景）"
        weatherCheck.state = c.weatherThemeEnabled ? .on : .off
        weatherCheck.target = self; weatherCheck.action = #selector(weatherToggled)
        view.addSubview(weatherCheck); y -= 20

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

        // 城市选择
        let cityNames = CITIES.map { $0.name }
        let cityX = rx + 200
        citySelect = NSPopUpButton(frame: NSRect(x: cityX, y: y - 2, width: 90, height: 24))
        citySelect.addItems(withTitles: cityNames)
        citySelect.selectItem(withTitle: c.weatherCity)
        citySelect.target = self; citySelect.action = #selector(cityChanged)
        citySelect.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(citySelect)

        // 双击天气标签区域切换预览
        let dblClickView = DoubleClickView(frame: NSRect(x: rx + 10, y: y, width: 200, height: 24))
        dblClickView.onDoubleClick = { [weak self] in
            self?.cycleWeatherPreview()
        }
        view.addSubview(dblClickView)
        y -= 28

        label("闪烁速度:", y + 4)
        blinkSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        blinkSlider.minValue = 0.2; blinkSlider.maxValue = 2.0; blinkSlider.doubleValue = c.blinkSpeed
        blinkSlider.target = self; blinkSlider.action = #selector(sliderChanged)
        view.addSubview(blinkSlider)
        blinkLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        blinkLabel.isEditable = false; blinkLabel.isBordered = false; blinkLabel.backgroundColor = .clear
        blinkLabel.stringValue = String(format: "%.1fs", c.blinkSpeed); blinkLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(blinkLabel); y -= 28

        label("窗口大小:", y + 4)
        sizeSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        sizeSlider.minValue = 30; sizeSlider.maxValue = 120; sizeSlider.doubleValue = c.windowSize
        sizeSlider.target = self; sizeSlider.action = #selector(sizeSliderChanged)
        view.addSubview(sizeSlider)
        sizeLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        sizeLabel.isEditable = false; sizeLabel.isBordered = false; sizeLabel.backgroundColor = .clear
        sizeLabel.stringValue = "\(Int(c.windowSize))"; sizeLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(sizeLabel); y -= 28

        label("显示样式:", y + 4)
        displayModeSegment = NSSegmentedControl(labels: ["竖向", "横向", "迷你", "磁吸"], trackingMode: .selectOne, target: self, action: #selector(displayModeChanged))
        displayModeSegment.frame = NSRect(x: rx, y: y, width: 240, height: 24)
        displayModeSegment.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let modeIdx = ["vertical": 0, "horizontal": 1, "mini": 2, "edgebar": 3][c.displayMode] ?? 0
        displayModeSegment.selectedSegment = modeIdx
        view.addSubview(displayModeSegment)
        // 保留 hidden checkbox 兼容 saveSettings
        horizontalCheck = NSButton(frame: NSRect(x: -999, y: -999, width: 1, height: 1))
        horizontalCheck.setButtonType(.switch); horizontalCheck.state = c.horizontal ? .on : .off
        view.addSubview(horizontalCheck); y -= 32

        showStatusCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        showStatusCheck.setButtonType(.switch); showStatusCheck.title = "显示底部状态文字"
        showStatusCheck.state = c.showStatusText ? .on : .off
        view.addSubview(showStatusCheck); y -= 36

        separator(y + 2); y -= 18
        sectionTitle("行为", y + 2); y -= 8

        autoLaunchCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        autoLaunchCheck.setButtonType(.switch); autoLaunchCheck.title = "开机自动启动"
        autoLaunchCheck.state = c.autoLaunch ? .on : .off
        view.addSubview(autoLaunchCheck); y -= 28

        notifyCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        notifyCheck.setButtonType(.switch); notifyCheck.title = "任务完成时发送通知"
        notifyCheck.state = c.notifyOnDone ? .on : .off
        view.addSubview(notifyCheck); y -= 28

        fullscreenCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        fullscreenCheck.setButtonType(.switch); fullscreenCheck.title = "全屏应用上层显示"
        fullscreenCheck.state = c.showOnFullscreen ? .on : .off
        view.addSubview(fullscreenCheck); y -= 28

        floatingCheck = NSButton(frame: NSRect(x: rx, y: y, width: 240, height: 24))
        floatingCheck.setButtonType(.switch); floatingCheck.title = "窗口悬浮置顶"
        floatingCheck.state = c.isFloating ? .on : .off
        view.addSubview(floatingCheck); y -= 40

        let saveBtn = NSButton(frame: NSRect(x: 110, y: y, width: 160, height: 32))
        saveBtn.title = "保存并应用"; saveBtn.bezelStyle = .rounded
        saveBtn.target = self; saveBtn.action = #selector(saveSettings)
        view.addSubview(saveBtn)

        let versionLabel = NSTextField(frame: NSRect(x: 0, y: y - 30, width: 300, height: 20))
        versionLabel.isEditable = false; versionLabel.isBordered = false; versionLabel.backgroundColor = .clear
        versionLabel.alignment = .right
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = NSColor.tertiaryLabelColor
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        versionLabel.stringValue = "CodeLight v\(ver)"
        view.addSubview(versionLabel)

        let checkUpdateBtn = NSButton(frame: NSRect(x: 310, y: y - 30, width: 100, height: 20))
        checkUpdateBtn.title = "检查更新"
        checkUpdateBtn.bezelStyle = .inline
        checkUpdateBtn.font = NSFont.systemFont(ofSize: 11)
        checkUpdateBtn.target = self
        checkUpdateBtn.action = #selector(checkForUpdate)
        view.addSubview(checkUpdateBtn)

        updateStatusLabel = NSTextField(frame: NSRect(x: 30, y: y - 55, width: 360, height: 20))
        updateStatusLabel.isEditable = false; updateStatusLabel.isBordered = false; updateStatusLabel.backgroundColor = .clear
        updateStatusLabel.alignment = .center
        updateStatusLabel.font = NSFont.systemFont(ofSize: 11)
        updateStatusLabel.textColor = NSColor.secondaryLabelColor
        updateStatusLabel.stringValue = ""
        view.addSubview(updateStatusLabel)
    }

    func buildRulesTab(_ view: NSView) {
        var y: CGFloat = 540
        let rules = [
            ("🟢 绿灯常亮", "空闲中", "当前无操作，AI 待命中。纯色常亮不闪烁。"),
            ("🟡 黄灯呼吸", "思考中", "AI 正在读代码、分析逻辑、检索上下文。亮度在 30%~100% 间 sin 曲线平滑呼吸。"),
            ("🔴 红灯快闪", "执行中", "AI 正在调用工具（Bash/Read/Edit 等）。高频开关约 4Hz，表示激烈操作中。"),
            ("🔴 红灯慢闪", "警告中", "会话异常终止。低频慢闪约 0.5Hz，警告级节奏。"),
            ("🟡 黄灯流水", "修复中", "工具调用失败后自动重试。中等频率闪烁，表示正在迭代修复代码。"),
        ]

        for (title, subtitle, desc) in rules {
            let titleField = NSTextField(frame: NSRect(x: 16, y: y, width: 320, height: 24))
            titleField.isEditable = false; titleField.isBordered = false; titleField.backgroundColor = .clear
            titleField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            titleField.stringValue = "\(title)  —  \(subtitle)"
            view.addSubview(titleField); y -= 26

            let descField = NSTextField(frame: NSRect(x: 28, y: y - 10, width: 300, height: 42))
            descField.isEditable = false; descField.isBordered = false; descField.backgroundColor = .clear
            descField.font = NSFont.systemFont(ofSize: 11)
            descField.textColor = NSColor(white: 0.45, alpha: 1.0)
            descField.stringValue = desc
            descField.cell?.wraps = true
            view.addSubview(descField); y -= 54
        }

        // 分隔线
        let sep = NSView(frame: NSRect(x: 16, y: y + 2, width: 328, height: 1))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(sep); y -= 12

        // 测试体验标题
        let testTitle = NSTextField(frame: NSRect(x: 16, y: y, width: 300, height: 20))
        testTitle.isEditable = false; testTitle.isBordered = false; testTitle.backgroundColor = .clear
        testTitle.stringValue = "测试体验 — 点击按钮实时预览灯效"
        testTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        testTitle.textColor = NSColor.secondaryLabelColor
        view.addSubview(testTitle); y -= 30

        // 5 个测试按钮 + 1 个恢复按钮，两行排列
        let testButtons: [(String, String, NSColor)] = [
            ("🟢 空闲", "idle", NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)),
            ("🟡 思考", "thinking", NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)),
            ("🔴 执行", "working", NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)),
            ("🟡 修复", "fixing", NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)),
            ("🔴 警告", "error", NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)),
        ]
        let btnW: CGFloat = 60, btnH: CGFloat = 28, gap: CGFloat = 6
        let startX: CGFloat = 16
        for (i, (label, state, _)) in testButtons.enumerated() {
            let btn = NSButton(frame: NSRect(x: startX + CGFloat(i) * (btnW + gap), y: y, width: btnW, height: btnH))
            btn.title = label; btn.bezelStyle = .rounded; btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            btn.tag = ["idle": 0, "thinking": 1, "working": 2, "fixing": 3, "error": 4][state] ?? 0
            btn.target = self; btn.action = #selector(testLightState(_:))
            view.addSubview(btn)
        }

        // 恢复按钮
        let resetBtn = NSButton(frame: NSRect(x: startX + 5 * (btnW + gap), y: y, width: btnW, height: btnH))
        resetBtn.title = "⏹ 恢复"; resetBtn.bezelStyle = .rounded; resetBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        resetBtn.target = self; resetBtn.action = #selector(testLightReset(_:))
        view.addSubview(resetBtn)
        y -= 34

        // 测试状态标签
        let testStatusLabel = NSTextField(frame: NSRect(x: 16, y: y, width: 340, height: 18))
        testStatusLabel.isEditable = false; testStatusLabel.isBordered = false; testStatusLabel.backgroundColor = .clear
        testStatusLabel.font = NSFont.systemFont(ofSize: 11)
        testStatusLabel.textColor = NSColor.tertiaryLabelColor
        testStatusLabel.stringValue = "点击上方按钮，观察红绿灯实时切换效果"
        testStatusLabel.tag = 999
        view.addSubview(testStatusLabel)
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

    func generateHooks(tool: String, port: String) -> [String: Any] {
        let toolName = tool == "claude" ? "$CLAUDE_TOOL_NAME" : (tool == "cursor" ? "$CURSOR_TOOL_NAME" : "")
        let sessionId = tool == "claude" ? "$CLAUDE_SESSION_ID" : (tool == "cursor" ? "$CURSOR_SESSION_ID" : "codex")
        return [
            "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "sh -c 'curl -s --max-time 1 -o /dev/null -X POST http://127.0.0.1:\(port)/api/state -H '\\''Content-Type: application/json'\\'' -d '\\''{\"state\": \"working\", \"message\": \"executing \(toolName)\", \"session_id\": \"\(sessionId)\"}'\\'' || true; printf '\\''{}'\\'''"]]]],
            "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "sh -c 'curl -s --max-time 1 -o /dev/null -X POST http://127.0.0.1:\(port)/api/state -H '\\''Content-Type: application/json'\\'' -d '\\''{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"\(sessionId)\"}'\\'' || true; printf '\\''{}'\\'''"]]]],
            "Stop": [["matcher": "", "hooks": [["type": "command", "command": "sh -c 'curl -s --max-time 1 -o /dev/null -X POST http://127.0.0.1:\(port)/api/state -H '\\''Content-Type: application/json'\\'' -d '\\''{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"\(sessionId)\"}'\\'' || true; printf '\\''{}'\\'''"]]]],
        ]
    }

    func generateHooksJSON(hooks: [String: Any]) -> String {
        let wrapper: [String: Any] = ["hooks": hooks]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    @objc func applyHookConfig() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let port = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        var results: [String] = []

        // --- Claude Code ---
        if claudeCodeCheck.state == .on {
            let path = home + "/.claude/settings.json"
            let hooks: [String: Any] = [
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing $CLAUDE_TOOL_NAME\", \"session_id\": \"$CLAUDE_SESSION_ID\"}' || echo '{}'"]]]],
                "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"$CLAUDE_SESSION_ID\"}' || echo '{}'"]]]],
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"$CLAUDE_SESSION_ID\"}' || echo '{}'"]]]],
            ]
            let ok = writeHooksToFile(path: path, hooks: hooks, fm: fm)
            results.append(ok ? "✅ Claude Code" : "❌ Claude Code")
            appDelegate.log("[Hook] Claude Code: \(ok ? "ok" : "failed") \(path)")
        }

        // --- Codex ---
        if codexCheck.state == .on {
            let dir = home + "/.codex"
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            // 1) config.toml: 启用 hooks
            let configToml = "[features]\nhooks = true\n"
            var codexOk = true
            do { try configToml.write(toFile: dir + "/config.toml", atomically: true, encoding: .utf8) }
            catch { codexOk = false; appDelegate.log("[Hook] Codex config.toml: \(error)") }
            // 2) hooks.json: hook 配置（格式与 Claude Code 一致）
            let hooksPath = dir + "/hooks.json"
            let hooks: [String: Any] = [
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "sh -c 'curl -s --max-time 1 -o /dev/null -X POST http://127.0.0.1:\(port)/api/state -H '\\''Content-Type: application/json'\\'' -d '\\''{\"state\": \"working\", \"message\": \"executing\", \"session_id\": \"codex\"}'\\'' || true; printf '\\''{}'\\'''"]]]],
                "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "sh -c 'curl -s --max-time 1 -o /dev/null -X POST http://127.0.0.1:\(port)/api/state -H '\\''Content-Type: application/json'\\'' -d '\\''{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"codex\"}'\\'' || true; printf '\\''{}'\\'''"]]]],
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "sh -c 'curl -s --max-time 1 -o /dev/null -X POST http://127.0.0.1:\(port)/api/state -H '\\''Content-Type: application/json'\\'' -d '\\''{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"codex\"}'\\'' || true; printf '\\''{}'\\'''"]]]],
            ]
            if !writeHooksToFile(path: hooksPath, hooks: hooks, fm: fm) { codexOk = false }
            results.append(codexOk ? "✅ Codex" : "❌ Codex")
            appDelegate.log("[Hook] Codex: \(codexOk ? "ok" : "failed") \(dir)/config.toml + hooks.json")
        }

        // --- Cursor ---
        if cursorCheck.state == .on {
            let dir = home + "/.cursor"
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            let path = dir + "/settings.json"
            let hooks: [String: Any] = [
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing $CURSOR_TOOL_NAME\", \"session_id\": \"$CURSOR_SESSION_ID\"}' || echo '{}'"]]]],
                "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"$CURSOR_SESSION_ID\"}' || echo '{}'"]]]],
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"$CURSOR_SESSION_ID\"}' || echo '{}'"]]]],
            ]
            let ok = writeHooksToFile(path: path, hooks: hooks, fm: fm)
            results.append(ok ? "✅ Cursor" : "❌ Cursor")
            appDelegate.log("[Hook] Cursor: \(ok ? "ok" : "failed") \(path)")
        }

        if results.isEmpty {
            hookStatusLabel.stringValue = "请至少勾选一个工具"
            hookStatusLabel.textColor = NSColor.systemOrange
        } else {
            hookStatusLabel.stringValue = results.joined(separator: "  ")
            hookStatusLabel.textColor = results.allSatisfy({ $0.hasPrefix("✅") })
                ? NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
                : NSColor.systemRed
        }
    }

    func writeHooksToFile(path: String, hooks: [String: Any], fm: FileManager) -> Bool {
        // 读取现有配置
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }
        // 确保目录存在
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // 合并 hooks
        var mergedHooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, hookConfig) in hooks {
            mergedHooks[event] = hookConfig
        }
        settings["hooks"] = mergedHooks
        // 写回
        guard let jsonData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try jsonData.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            appDelegate.log("[Hook] 写入失败: \(path) \(error)")
            return false
        }
    }

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
        let types = ["cow", "cat", "robot"]
        appDelegate.trafficContainer?.mascotType = types[mascotSelect.indexOfSelectedItem]
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

    @objc func saveSettings() {
        var c = appDelegate.config
        c.serverURL = "http://127.0.0.1:" + serverField.stringValue
        c.pollInterval = pollSlider.doubleValue
        c.opacity = opacitySlider.doubleValue
        c.blinkSpeed = blinkSlider.doubleValue
        c.windowSize = sizeSlider.doubleValue
        c.autoLaunch = autoLaunchCheck.state == .on
        c.notifyOnDone = notifyCheck.state == .on
        c.showOnFullscreen = fullscreenCheck.state == .on
        c.horizontal = horizontalCheck.state == .on
        let modes = ["vertical", "horizontal", "mini", "edgebar"]
        c.displayMode = modes[displayModeSegment.indexOfSelectedItem]
        c.horizontal = (c.displayMode == "horizontal")
        c.edgeBar = (c.displayMode == "edgebar") ? (c.edgeBar ?? "right") : nil
        c.showStatusText = showStatusCheck.state == .on
        c.isFloating = floatingCheck.state == .on
        c.mascotType = ["cow", "cat", "robot"][mascotSelect.indexOfSelectedItem]
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
        guard let url = URL(string: "https://api.github.com/repos/guandeng/code-light/releases/latest") else {
            updateStatusLabel.stringValue = "检查失败"
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    self.updateStatusLabel.stringValue = "检查失败，请稍后重试"
                    self.updateStatusLabel.textColor = NSColor.systemRed
                    return
                }
                let latestVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                if latestVer.compare(currentVer, options: .numeric) == .orderedDescending {
                    self.updateStatusLabel.stringValue = "发现新版本 \(tagName)"
                    self.updateStatusLabel.textColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
                    if let htmlUrl = json["html_url"] as? String, let releaseUrl = URL(string: htmlUrl) {
                        NSWorkspace.shared.open(releaseUrl)
                    }
                } else {
                    self.updateStatusLabel.stringValue = "当前已是最新版本"
                    self.updateStatusLabel.textColor = NSColor.secondaryLabelColor
                }
            }
        }.resume()
    }

    func windowWillClose(_ notification: Notification) { appDelegate.settingsWindowController = nil }
}

// ============================================================
// Main — 入口在 main.swift
// ============================================================

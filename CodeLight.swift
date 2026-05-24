import Cocoa
import Foundation
import ServiceManagement
import UserNotifications

// ============================================================
// CodeLight — AI 编程助手红绿灯 macOS App
// ============================================================

struct AppConfig {
    var serverURL = "http://127.0.0.1:8866"
    var pollInterval = 0.5
    var opacity = 1.0
    var blinkSpeed = 0.6
    var theme = "dark"
    var autoLaunch = false
    var showInDock = false
    var isFloating = true
    var notifyOnDone = true
    var showOnFullscreen = true
    var horizontal = false
    var showStatusText = true
    var windowSize: Double = 40
    var windowX: Double?
    var windowY: Double?

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
        if ud.object(forKey: "horizontal") != nil { c.horizontal = ud.bool(forKey: "horizontal") }
        if ud.object(forKey: "showStatusText") != nil { c.showStatusText = ud.bool(forKey: "showStatusText") }
        if ud.double(forKey: "windowSize") > 0 { c.windowSize = ud.double(forKey: "windowSize") }
        if ud.object(forKey: "windowX") != nil { c.windowX = ud.double(forKey: "windowX") }
        if ud.object(forKey: "windowY") != nil { c.windowY = ud.double(forKey: "windowY") }
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
        ud.set(showOnFullscreen, forKey: "showOnFullscreen")
        ud.set(horizontal, forKey: "horizontal")
        ud.set(showStatusText, forKey: "showStatusText")
        ud.set(windowSize, forKey: "windowSize")
        if let x = windowX { ud.set(x, forKey: "windowX") }
        if let y = windowY { ud.set(y, forKey: "windowY") }
    }
}

struct LightStateDef {
    let red: Bool; let yellow: Bool; let green: Bool; let blink: Bool; let label: String
}

let STATES: [String: LightStateDef] = [
    "idle":     LightStateDef(red: false, yellow: false, green: true,  blink: false, label: "完成"),
    "thinking": LightStateDef(red: false, yellow: true,  green: false, blink: false, label: "思考中"),
    "working":  LightStateDef(red: true,  yellow: false, green: false, blink: true,  label: "执行中"),
    "fixing":   LightStateDef(red: false, yellow: true,  green: false, blink: true,  label: "修复中"),
    "error":    LightStateDef(red: true,  yellow: false, green: false, blink: false, label: "报错"),
]

let SEVERITY = ["error": 4, "working": 3, "fixing": 3, "thinking": 2, "idle": 0]

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
    var pollTimer: Timer?
    var animTimer: Timer?
    var marqueeText: String = ""
    var marqueeOffset: Int = 0
    var tooltipView: NSView?
    var settingsWindowController: SettingsWindowController?
    var sessions: [String: [String: Any]] = [:]

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

    var serverProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        UNUserNotificationCenter.current().delegate = self
        NSUserNotificationCenter.default.delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.log("[通知] UN权限: \(granted), err: \(String(describing: error))")
        }
        startServer()
        buildMenuBar()
        buildLightWindow()
        startTimers()
        pollState()
        log("[启动] OK")
    }

    func startServer() {
        let resourceScript = Bundle.main.resourcePath! + "/light-server.py"
        let devScript = "/Users/guandeng/www/python/code-light/light-server.py"
        let scriptPath: String
        if FileManager.default.fileExists(atPath: resourceScript) {
            scriptPath = resourceScript
        } else if FileManager.default.fileExists(atPath: devScript) {
            scriptPath = devScript
        } else {
            log("[服务] 未找到 light-server.py")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptPath]
        // 检查 flask 是否安装
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", "-c", "import flask"]
        do {
            try check.run()
            check.waitUntilExit()
            if check.terminationStatus != 0 {
                log("[服务] 安装 flask...")
                let install = Process()
                install.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                install.arguments = ["python3", "-m", "pip", "install", "flask", "--break-system-packages", "--quiet"]
                try? install.run()
                install.waitUntilExit()
            }
        } catch { log("[服务] 检查 flask 失败: \(error)") }

        do {
            try process.run()
            serverProcess = process
            log("[服务] Python 服务已启动: \(scriptPath)")
        } catch {
            log("[服务] 启动失败: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverProcess?.terminate()
        log("[退出] Python 服务已停止")
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
        let yellow = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
        let green = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
        let dimRed = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.25)
        let dimYellow = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.25)
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
        let initSize = CGFloat(config.windowSize)
        let lightW: CGFloat, lightH: CGFloat
        let statusH: CGFloat = config.showStatusText ? 26 : 0
        if config.horizontal {
            lightW = initSize * 3 + 14 * 2 + 18 * 2
            lightH = initSize + 40 + statusH
        } else {
            lightW = initSize + 40
            lightH = initSize * 3 + 14 * 2 + 18 * 2 + (config.showStatusText ? 32 : 0)
        }
        let screen = NSScreen.main!.frame
        let defaultX = screen.width - lightW - 16
        let defaultY = screen.height - lightH - 80
        let posX = config.windowX ?? defaultX
        let posY = config.windowY ?? defaultY

        if lightWindow != nil { lightWindow.close() }

        lightWindow = NSPanel(
            contentRect: NSRect(x: posX, y: posY, width: lightW, height: lightH),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        lightWindow.level = config.isFloating ? (config.showOnFullscreen ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow))) : .floating) : .normal
        lightWindow.collectionBehavior = config.showOnFullscreen ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        lightWindow.isMovableByWindowBackground = true
        lightWindow.isOpaque = false; lightWindow.hasShadow = true
        lightWindow.minSize = NSSize(width: 60, height: 120)
        lightWindow.backgroundColor = .clear

        let view = lightWindow.contentView!
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: config.opacity).cgColor
        view.layer?.cornerRadius = min(lightW, lightH) / 2
        view.layer?.masksToBounds = true

        let shell = ShellView(frame: view.bounds)
        shell.autoresizingMask = [.width, .height]
        view.addSubview(shell)

        // 自适应容器
        let container = TrafficLightContainer(frame: view.bounds)
        container.isHorizontal = config.horizontal
        container.showStatusText = config.showStatusText
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)

        redView = RealTrafficLightView()
        redView.lampColor = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)  // #D90000 国标红灯

        yellowView = RealTrafficLightView()
        yellowView.lampColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)  // #FFCC00 国标黄灯

        greenView = RealTrafficLightView()
        greenView.lampColor = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)  // #00B329 国标绿灯

        container.addSubview(redView)
        container.addSubview(yellowView)
        container.addSubview(greenView)
        container.redView = redView
        container.yellowView = yellowView
        container.greenView = greenView

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
        // tooltip 区域：覆盖整个底部文字区域
        let tooltipArea = NSView(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 28))
        tooltipArea.autoresizingMask = [.width]
        tooltipArea.isHidden = !config.showStatusText
        view.addSubview(tooltipArea)
        self.tooltipView = tooltipArea

        let rightMenu = NSMenu()
        rightMenu.addItem(withTitle: "切换悬浮", action: #selector(toggleFloating), keyEquivalent: "")
        rightMenu.addItem(withTitle: "设置...", action: #selector(openSettings), keyEquivalent: "")
        rightMenu.addItem(NSMenuItem.separator())
        rightMenu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "")
        view.menu = rightMenu

        lightWindow.makeKeyAndOrderFront(nil)
        container.layout()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: lightWindow, queue: .main) { [weak self] _ in
            guard let self = self, let w = self.lightWindow else { return }
            self.config.windowX = Double(w.frame.origin.x)
            self.config.windowY = Double(w.frame.origin.y)
            self.config.save()
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
    @objc func toggleFloating() {
        config.isFloating = !config.isFloating; config.save()
        lightWindow.level = config.isFloating ? (config.showOnFullscreen ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow))) : .floating) : .normal
        lightWindow.collectionBehavior = (config.isFloating && config.showOnFullscreen) ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }
    @objc func openSettings() {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(appDelegate: self) }
        settingsWindowController?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.center()
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    func restartWithNewConfig() {
        config = AppConfig.load()
        log("[重启] horizontal=\(config.horizontal)")
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        buildLightWindow(); startTimers(); pollState()
    }

    func animateLight() {
        let state = currentStateName
        animPhase += 0.04
        if animPhase > 1 { animPhase -= 1 }

        // 所有灯更新 mascot
        redView.mascotPhase = animPhase
        yellowView.mascotPhase = animPhase
        greenView.mascotPhase = animPhase

        switch state {
        case "thinking":
            let breath = CGFloat(0.3 + 0.7 * (0.5 + 0.5 * sin(Double(animPhase) * .pi * 2)))
            yellowView.isOn = true; yellowView.brightness = breath
            yellowView.mascotState = "thinking"
            redView.isOn = false; redView.mascotState = ""
            greenView.isOn = false; greenView.mascotState = ""

        case "working":
            let fast = sin(Double(animPhase) * .pi * 4) > 0
            redView.isOn = fast; redView.brightness = 1.0
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
            let warn = sin(Double(animPhase) * .pi * 2) > 0
            redView.isOn = warn; redView.brightness = 1.0
            redView.mascotState = "error"
            yellowView.isOn = false; yellowView.mascotState = ""
            greenView.isOn = false; greenView.mascotState = ""

        default: // idle
            greenView.isOn = true; greenView.brightness = 1.0
            greenView.mascotState = "idle"
            redView.isOn = false; redView.mascotState = ""
            yellowView.isOn = false; yellowView.mascotState = ""
        }

        // 跑马灯：文字超过可见宽度时滚动（文字隐藏时跳过）
        if !marqueeText.isEmpty && !statusLabel.isHidden {
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
                if prevActive > 0 && activeCount == 0 && self.config.notifyOnDone {
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
                    UNUserNotificationCenter.current().add(req) { error in
                        self.log("[通知] UN结果: \(error?.localizedDescription ?? "ok")")
                    }
                    let notification = NSUserNotification()
                    notification.title = title
                    notification.informativeText = body
                    notification.soundName = NSUserNotificationDefaultSoundName
                    NSUserNotificationCenter.default.deliver(notification)
                    self.log("[通知] NSUserNotification 已发送")
                }
                let s = STATES[sn] ?? STATES["idle"]!
                if !blink {
                    self.redView.isOn = s.red
                    self.yellowView.isOn = s.yellow
                }
                self.greenView.isOn = s.green
                // 底部文字颜色跟随灯色
                let stateColors: [String: NSColor] = [
                    "idle": NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 0.8),
                    "thinking": NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.8),
                    "working": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.8),
                    "fixing": NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.8),
                    "error": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.8),
                ]
                self.statusLabel.textColor = stateColors[sn] ?? NSColor(white: 0.55, alpha: 0.6)
                // 底部文字：标签 + 消息
                let displayText: String
                if sn == "idle" || msg.isEmpty {
                    displayText = label
                } else {
                    var cleanMsg = msg
                    if cleanMsg.hasPrefix("完成") { cleanMsg = String(cleanMsg.dropFirst(2)) }
                    cleanMsg = cleanMsg.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                    displayText = cleanMsg.isEmpty ? label : "\(label): \(cleanMsg)"
                }
                self.statusLabel.stringValue = displayText
                self.statusLabel.isHidden = !self.config.showStatusText
                self.statusLabel.toolTip = displayText
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
// TrafficLightContainer — 自适应灯容器，resize 时自动调整灯的大小和位置
// ============================================================
// AppDelegate + UNUserNotificationCenterDelegate
// ============================================================

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// NSUserNotification 前台也显示
extension AppDelegate: NSUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {}
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
}

// ============================================================

class TrafficLightContainer: NSView {
    var redView: RealTrafficLightView!
    var yellowView: RealTrafficLightView!
    var greenView: RealTrafficLightView!
    var isHorizontal = false
    var showStatusText = true

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        if isHorizontal {
            layoutHorizontal(w: w, h: h)
        } else {
            layoutVertical(w: w, h: h)
        }
    }

    private func layoutVertical(w: CGFloat, h: CGFloat) {
        let bottomBar: CGFloat = showStatusText ? 26 : 0
        let padding: CGFloat = min(w * 0.12, 18)
        let gap: CGFloat = min(w * 0.08, 14)
        let availH = h - bottomBar - padding * 2
        let availW = w - padding * 2

        let maxDiam = min(availW, (availH - gap * 2) / 3)
        let diam = max(maxDiam, 20)

        let cx = w / 2
        let gy = bottomBar + padding
        let yy = gy + diam + gap
        let ry = yy + diam + gap

        greenView.frame = NSRect(x: cx - diam/2, y: gy, width: diam, height: diam)
        yellowView.frame = NSRect(x: cx - diam/2, y: yy, width: diam, height: diam)
        redView.frame = NSRect(x: cx - diam/2, y: ry, width: diam, height: diam)
    }

    private func layoutHorizontal(w: CGFloat, h: CGFloat) {
        let bottomBar: CGFloat = showStatusText ? 26 : 0
        let padding: CGFloat = min(h * 0.12, 18)
        let gap: CGFloat = min(h * 0.08, 14)
        let availH = h - bottomBar - padding * 2
        let availW = w - padding * 2

        let maxDiam = min(availH, (availW - gap * 2) / 3)
        let diam = max(maxDiam, 20)

        let cy = bottomBar + (h - bottomBar) / 2
        let rx = padding
        let yx = rx + diam + gap
        let gx = yx + diam + gap

        redView.frame = NSRect(x: rx, y: cy - diam/2, width: diam, height: diam)
        yellowView.frame = NSRect(x: yx, y: cy - diam/2, width: diam, height: diam)
        greenView.frame = NSRect(x: gx, y: cy - diam/2, width: diam, height: diam)
    }
}

// ============================================================
// ShellView — 金属拉丝外壳
// ============================================================

class ShellView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let r = min(rect.width, rect.height) / 2
        // 胶囊形外壳 — 两端半圆，模拟圆柱信号灯
        let grad = NSGradient(colors: [
            NSColor(white: 0.18, alpha: 1.0),
            NSColor(white: 0.10, alpha: 1.0),
            NSColor(white: 0.14, alpha: 1.0),
        ])
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        grad?.draw(in: path, angle: 90)

        // 内边框
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: r - 1.5, yRadius: r - 1.5)
        NSColor(white: 0.25, alpha: 0.3).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

// ============================================================
// RealTrafficLightView — 仿真灯珠
// ============================================================

class RealTrafficLightView: NSView {
    var lampColor: NSColor = .red
    var isOn: Bool = false { didSet { needsDisplay = true } }
    var brightness: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var mascotState: String = "idle" { didSet { needsDisplay = true } }
    var mascotPhase: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let fullR = min(bounds.width, bounds.height) / 2
        let center = NSPoint(x: bounds.midX, y: bounds.midY)

        // 灯孔 — 小凹槽
        let holePath = NSBezierPath()
        holePath.appendArc(withCenter: center, radius: fullR - 1, startAngle: 0, endAngle: 360)
        NSColor(white: 0.06, alpha: 1.0).setFill()
        holePath.fill()

        // 灯珠底色
        let lampR = fullR - 3
        let lampPath = NSBezierPath()
        lampPath.appendArc(withCenter: center, radius: lampR, startAngle: 0, endAngle: 360)
        if isOn {
            lampColor.withAlphaComponent(brightness * 0.15).setFill()
        } else {
            NSColor(white: 0.08, alpha: 1.0).setFill()
        }
        lampPath.fill()

        // LED 点阵 — 六角密排小圆点
        let dotR: CGFloat = max(lampR / 16, 1.0)
        let spacing = dotR * 2.8
        let rows = Int((lampR + spacing) / (spacing * 0.866)) + 1
        let onColor = lampColor.withAlphaComponent(brightness)
        let offColor = NSColor(white: 0.12, alpha: 1.0)

        // 先裁切到灯珠圆形区域
        let clipPath = NSBezierPath()
        clipPath.appendArc(withCenter: center, radius: lampR, startAngle: 0, endAngle: 360)
        clipPath.addClip()

        for row in -rows...rows {
            let yOffset = CGFloat(row) * spacing * 0.866
            let offset = (row % 2 != 0) ? spacing * 0.5 : 0
            let maxDx = sqrt(max(0, Double(lampR * lampR - yOffset * yOffset)))
            let cols = Int((maxDx + spacing) / spacing)
            for col in -cols...cols {
                let dx = CGFloat(col) * spacing + offset
                let dy = yOffset
                let dist = sqrt(dx * dx + dy * dy)
                if dist > lampR + dotR { continue }
                let dotPath = NSBezierPath()
                dotPath.appendArc(withCenter: NSPoint(x: center.x + dx, y: center.y + dy), radius: dotR, startAngle: 0, endAngle: 360)
                if isOn {
                    onColor.setFill()
                } else {
                    offColor.setFill()
                }
                dotPath.fill()
            }
        }

        // 吉祥物 — 灯亮时在灯珠上画小牛马
        if isOn && lampR > 12 {
            drawMascot(center: center, size: lampR * 1.1)
        }
    }

    func drawMascot(center: NSPoint, size: CGFloat) {
        let cx = center.x
        let cy = center.y
        let s = size
        let cowBody = NSColor(white: 1.0, alpha: 0.9)
        let cowSpot = NSColor(red: 0.35, green: 0.25, blue: 0.15, alpha: 0.7)
        let eyeColor = NSColor(white: 0.1, alpha: 0.9)
        let noseColor = NSColor(red: 1.0, green: 0.65, blue: 0.7, alpha: 0.9)
        let hornColor = NSColor(red: 0.95, green: 0.9, blue: 0.7, alpha: 0.9)

        // 画牛头（所有状态共用）
        func drawHead(hx: CGFloat, hy: CGFloat, faceUp: Bool = true) {
            // 头
            let headR = s * 0.22
            let head = NSBezierPath()
            head.appendArc(withCenter: NSPoint(x: hx, y: hy), radius: headR, startAngle: 0, endAngle: 360)
            cowBody.setFill(); head.fill()
            // 角（两个小三角）
            hornColor.setFill()
            let hLen = s * 0.1
            for dx: CGFloat in [-s*0.1, s*0.1] {
                let hornPath = NSBezierPath()
                if faceUp {
                    hornPath.move(to: NSPoint(x: hx + dx - s*0.03, y: hy + headR - s*0.02))
                    hornPath.line(to: NSPoint(x: hx + dx, y: hy + headR + hLen))
                    hornPath.line(to: NSPoint(x: hx + dx + s*0.03, y: hy + headR - s*0.02))
                } else {
                    hornPath.move(to: NSPoint(x: hx + dx - s*0.03, y: hy - headR + s*0.02))
                    hornPath.line(to: NSPoint(x: hx + dx, y: hy - headR - hLen))
                    hornPath.line(to: NSPoint(x: hx + dx + s*0.03, y: hy - headR + s*0.02))
                }
                hornPath.fill()
            }
            // 花斑
            cowSpot.setFill()
            let spot = NSBezierPath()
            spot.appendArc(withCenter: NSPoint(x: hx + s*0.06, y: hy - s*0.02), radius: s*0.07, startAngle: 0, endAngle: 360)
            spot.fill()
        }

        // 画眼睛
        func drawEyes(ex: CGFloat, ey: CGFloat, closed: Bool = false, lookUp: Bool = false) {
            if closed {
                // 闭眼 — 弧线
                NSColor(white: 0.2, alpha: 0.7).setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: ex - s*0.06, y: ey))
                line.line(to: NSPoint(x: ex + s*0.06, y: ey))
                line.lineWidth = 1.5; line.stroke()
            } else {
                eyeColor.setFill()
                let eyeOff: CGFloat = lookUp ? s*0.02 : 0
                NSBezierPath(ovalIn: NSRect(x: ex - s*0.07, y: ey - s*0.03 + eyeOff, width: s*0.05, height: s*0.06)).fill()
                NSBezierPath(ovalIn: NSRect(x: ex + s*0.03, y: ey - s*0.03 + eyeOff, width: s*0.05, height: s*0.06)).fill()
                // 高光
                NSColor.white.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: NSRect(x: ex - s*0.05, y: ey + eyeOff, width: s*0.02, height: s*0.02)).fill()
                NSBezierPath(ovalIn: NSRect(x: ex + s*0.05, y: ey + eyeOff, width: s*0.02, height: s*0.02)).fill()
            }
        }

        // 画鼻子
        func drawNose(nx: CGFloat, ny: CGFloat, faceUp: Bool = true) {
            noseColor.setFill()
            let nR = s * 0.06
            let nPath = NSBezierPath(roundedRect: NSRect(x: nx - nR, y: ny - nR*0.6, width: nR*2, height: nR*1.2), xRadius: nR*0.4, yRadius: nR*0.4)
            nPath.fill()
            // 鼻孔
            NSColor(red: 0.85, green: 0.5, blue: 0.55, alpha: 0.8).setFill()
            let holeR = s * 0.015
            NSBezierPath(ovalIn: NSRect(x: nx - nR*0.5, y: ny - holeR, width: holeR*2, height: holeR*2)).fill()
            NSBezierPath(ovalIn: NSRect(x: nx + nR*0.2, y: ny - holeR, width: holeR*2, height: holeR*2)).fill()
        }

        // 画身体+四条腿
        func drawBody(bx: CGFloat, by: CGFloat, legAnim: CGFloat = 0, lying: Bool = false) {
            if lying {
                // 躺平 — 扁椭圆
                cowBody.setFill()
                let body = NSBezierPath(ovalIn: NSRect(x: bx - s*0.28, y: by - s*0.12, width: s*0.56, height: s*0.24))
                body.fill()
                cowSpot.setFill()
                NSBezierPath(ovalIn: NSRect(x: bx - s*0.1, y: by - s*0.05, width: s*0.15, height: s*0.1)).fill()
            } else {
                // 站立 — 圆润身体
                cowBody.setFill()
                let body = NSBezierPath(ovalIn: NSRect(x: bx - s*0.2, y: by - s*0.25, width: s*0.4, height: s*0.45))
                body.fill()
                cowSpot.setFill()
                NSBezierPath(ovalIn: NSRect(x: bx + s*0.02, y: by - s*0.1, width: s*0.12, height: s*0.15)).fill()
                // 四条腿
                cowBody.setFill()
                let legW = s * 0.06
                let legH = s * 0.15
                NSBezierPath(roundedRect: NSRect(x: bx - s*0.15, y: by - s*0.28 - legH + legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx - s*0.05, y: by - s*0.28 - legH - legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx + s*0.05, y: by - s*0.28 - legH + legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx + s*0.13, y: by - s*0.28 - legH - legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
            }
        }

        // 尾巴
        func drawTail(tx: CGFloat, ty: CGFloat, wag: CGFloat) {
            NSColor(white: 0.7, alpha: 0.6).setStroke()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: tx - s*0.2, y: ty))
            let cpx = tx - s*0.3 + wag * s * 0.05
            tail.curve(to: NSPoint(x: tx - s*0.25, y: ty + s*0.12), controlPoint1: NSPoint(x: cpx, y: ty + s*0.05), controlPoint2: NSPoint(x: cpx, y: ty + s*0.1))
            tail.lineWidth = 1.5; tail.stroke()
            // 尾巴尖
            cowSpot.setFill()
            NSBezierPath(ovalIn: NSRect(x: tx - s*0.28, y: ty + s*0.1, width: s*0.05, height: s*0.05)).fill()
        }

        switch mascotState {
        case "working":
            // 🐂 小牛耕地 — 低头用力走
            let legAnim = sin(Double(mascotPhase) * .pi * 6) * s * 0.04
            let sway = sin(Double(mascotPhase) * .pi * 6) * s * 0.03
            let bx = cx + sway
            drawBody(bx: bx, by: cy - s*0.05, legAnim: CGFloat(legAnim))
            drawHead(hx: bx - s*0.05, hy: cy + s*0.25)
            drawEyes(ex: bx - s*0.05, ey: cy + s*0.22)  // 朝前看
            drawNose(nx: bx - s*0.05, ny: cy + s*0.15)
            drawTail(tx: bx, ty: cy + s*0.05, wag: CGFloat(sin(Double(mascotPhase) * .pi * 4)))
            // 头上汗滴
            let sweatAlpha = CGFloat(0.3 + 0.4 * sin(Double(mascotPhase) * .pi * 3))
            NSColor(red: 0.5, green: 0.8, blue: 1.0, alpha: sweatAlpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: bx + s*0.1, y: cy + s*0.4, width: s*0.04, height: s*0.06)).fill()

        case "thinking":
            // 🐄 小牛思考 — 坐着托腮
            drawBody(bx: cx, by: cy - s*0.05)
            drawHead(hx: cx, hy: cy + s*0.28)
            drawEyes(ex: cx, ey: cy + s*0.26, lookUp: true)
            drawNose(nx: cx, ny: cy + s*0.18)
            drawTail(tx: cx, ty: cy + s*0.05, wag: CGFloat(sin(Double(mascotPhase) * .pi * 2)))
            // 问号呼吸
            let qAlpha = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            let font = NSFont.systemFont(ofSize: s * 0.4, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(qAlpha)]
            NSAttributedString(string: "?", attributes: attrs).draw(at: NSPoint(x: cx + s*0.2, y: cy + s*0.35))

        case "fixing":
            // 🐂 小牛修 bug — 拿锤子
            let hammerOff = sin(Double(mascotPhase) * .pi * 4) * s * 0.06
            drawBody(bx: cx, by: cy - s*0.05)
            drawHead(hx: cx, hy: cy + s*0.28)
            drawEyes(ex: cx, ey: cy + s*0.25)  // 眯眼用力
            drawNose(nx: cx, ny: cy + s*0.18)
            drawTail(tx: cx, ty: cy + s*0.05, wag: CGFloat(sin(Double(mascotPhase) * .pi * 3)))
            // 锤子
            NSColor(white: 0.6, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: cx + s*0.15, y: cy + s*0.3 + CGFloat(hammerOff), width: s*0.15, height: s*0.07), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0.5, alpha: 0.7).setFill()
            NSBezierPath(rect: NSRect(x: cx + s*0.2, y: cy + s*0.15 + CGFloat(hammerOff), width: s*0.03, height: s*0.16)).fill()

        case "error":
            // 🐮 小牛倒地 — 晕
            let tilt = CGFloat(sin(Double(mascotPhase) * .pi * 2)) * s * 0.03
            drawBody(bx: cx + tilt, by: cy - s*0.08, lying: true)
            drawHead(hx: cx + s*0.25 + tilt, hy: cy + s*0.05, faceUp: false)
            drawEyes(ex: cx + s*0.25 + tilt, ey: cy + s*0.02, closed: true)
            drawNose(nx: cx + s*0.25 + tilt, ny: cy - s*0.05, faceUp: false)
            // 星星
            let starAlpha = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 4))
            let font = NSFont.systemFont(ofSize: s * 0.3, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.yellow.withAlphaComponent(starAlpha)]
            NSAttributedString(string: "★", attributes: attrs).draw(at: NSPoint(x: cx + s*0.15, y: cy + s*0.2))

        default: // idle
            // 🐄 小牛躺平休息 — Zzz
            drawBody(bx: cx - s*0.05, by: cy - s*0.08, lying: true)
            drawHead(hx: cx + s*0.2, hy: cy + s*0.06, faceUp: false)
            drawEyes(ex: cx + s*0.2, ey: cy + s*0.03, closed: true)
            drawNose(nx: cx + s*0.2, ny: cy - s*0.04, faceUp: false)
            // Zzz 呼吸
            let zAlpha = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            let font = NSFont.systemFont(ofSize: s * 0.25, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(zAlpha)]
            NSAttributedString(string: "z z z", attributes: attrs).draw(at: NSPoint(x: cx - s*0.15, y: cy + s*0.2))
        }
    }
}

// ============================================================
// SettingsWindowController
// ============================================================

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let appDelegate: AppDelegate
    var serverField: NSTextField!
    var pollSlider: NSSlider!; var pollLabel: NSTextField!
    var opacitySlider: NSSlider!; var opacityLabel: NSTextField!
    var blinkSlider: NSSlider!; var blinkLabel: NSTextField!
    var autoLaunchCheck: NSButton!
    var showDockCheck: NSButton!
    var notifyCheck: NSButton!
    var fullscreenCheck: NSButton!
    var horizontalCheck: NSButton!
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
        view.addSubview(serverField); y -= 32

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
        view.addSubview(opacityLabel); y -= 32

        label("闪烁速度:", y + 4)
        blinkSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        blinkSlider.minValue = 0.2; blinkSlider.maxValue = 2.0; blinkSlider.doubleValue = c.blinkSpeed
        blinkSlider.target = self; blinkSlider.action = #selector(sliderChanged)
        view.addSubview(blinkSlider)
        blinkLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        blinkLabel.isEditable = false; blinkLabel.isBordered = false; blinkLabel.backgroundColor = .clear
        blinkLabel.stringValue = String(format: "%.1fs", c.blinkSpeed); blinkLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(blinkLabel); y -= 32

        label("窗口大小:", y + 4)
        sizeSlider = NSSlider(frame: NSRect(x: rx, y: y + 4, width: 120, height: 20))
        sizeSlider.minValue = 30; sizeSlider.maxValue = 120; sizeSlider.doubleValue = c.windowSize
        sizeSlider.target = self; sizeSlider.action = #selector(sliderChanged)
        view.addSubview(sizeSlider)
        sizeLabel = NSTextField(frame: NSRect(x: rx + 130, y: y + 4, width: 50, height: 20))
        sizeLabel.isEditable = false; sizeLabel.isBordered = false; sizeLabel.backgroundColor = .clear
        sizeLabel.stringValue = "\(Int(c.windowSize))"; sizeLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(sizeLabel); y -= 32

        horizontalCheck = NSButton(frame: NSRect(x: lx + 30, y: y, width: 260, height: 24))
        horizontalCheck.setButtonType(.switch); horizontalCheck.title = "横向排列红绿灯"
        horizontalCheck.state = c.horizontal ? .on : .off
        view.addSubview(horizontalCheck); y -= 32

        showStatusCheck = NSButton(frame: NSRect(x: lx + 30, y: y, width: 260, height: 24))
        showStatusCheck.setButtonType(.switch); showStatusCheck.title = "显示底部状态文字"
        showStatusCheck.state = c.showStatusText ? .on : .off
        view.addSubview(showStatusCheck); y -= 36

        y -= 6; separator(y + 2); y -= 18
        sectionTitle("行为", y + 2); y -= 8

        autoLaunchCheck = NSButton(frame: NSRect(x: lx + 30, y: y, width: 200, height: 24))
        autoLaunchCheck.setButtonType(.switch); autoLaunchCheck.title = "开机自动启动"
        autoLaunchCheck.state = c.autoLaunch ? .on : .off
        view.addSubview(autoLaunchCheck); y -= 30

        showDockCheck = NSButton(frame: NSRect(x: lx + 30, y: y, width: 200, height: 24))
        showDockCheck.setButtonType(.switch); showDockCheck.title = "在 Dock 栏显示图标"
        showDockCheck.state = c.showInDock ? .on : .off
        view.addSubview(showDockCheck); y -= 30

        notifyCheck = NSButton(frame: NSRect(x: lx + 30, y: y, width: 260, height: 24))
        notifyCheck.setButtonType(.switch); notifyCheck.title = "任务完成时发送通知"
        notifyCheck.state = c.notifyOnDone ? .on : .off
        view.addSubview(notifyCheck); y -= 30

        fullscreenCheck = NSButton(frame: NSRect(x: lx + 30, y: y, width: 260, height: 24))
        fullscreenCheck.setButtonType(.switch); fullscreenCheck.title = "全屏应用上层显示"
        fullscreenCheck.state = c.showOnFullscreen ? .on : .off
        view.addSubview(fullscreenCheck); y -= 36

        let saveBtn = NSButton(frame: NSRect(x: 110, y: y, width: 120, height: 32))
        saveBtn.title = "保存并应用"; saveBtn.bezelStyle = .rounded
        saveBtn.target = self; saveBtn.action = #selector(saveSettings)
        view.addSubview(saveBtn)
    }

    func buildRulesTab(_ view: NSView) {
        var y: CGFloat = 540
        let rules = [
            ("🟢 绿灯常亮", "完成 / 空闲", "任务完成，当前无操作。纯色常亮不闪烁。"),
            ("🟡 黄灯呼吸", "思考中", "AI 正在读代码、分析逻辑、检索上下文。亮度在 30%~100% 间 sin 曲线平滑呼吸。"),
            ("🔴 红灯快闪", "执行中", "AI 正在调用工具（Bash/Read/Edit 等）。高频开关约 4Hz，表示激烈操作中。"),
            ("🟡 黄灯流水", "修复中", "工具调用失败后自动重试。中等频率闪烁，表示正在迭代修复代码。"),
            ("🔴 红灯慢闪", "报错 / 异常", "Claude Code 会话异常终止。低频慢闪约 0.5Hz，警告级节奏。"),
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
        claudeCodeCheck.setButtonType(.switch)
        claudeCodeCheck.title = "Claude Code（~/.claude/settings.json）"
        claudeCodeCheck.state = .on
        view.addSubview(claudeCodeCheck); y -= 26
        descLabel("配置 PreToolUse / PostToolUse / Stop 三个 Hook 事件。", y); y -= 36

        // Codex
        codexCheck = NSButton(frame: NSRect(x: 24, y: y, width: 340, height: 24))
        codexCheck.setButtonType(.switch)
        codexCheck.title = "Codex（~/.codex/config.json）"
        codexCheck.state = .off
        view.addSubview(codexCheck); y -= 26
        descLabel("配置 Codex 的 sandbox shell hook 事件。", y); y -= 36

        // Cursor
        cursorCheck = NSButton(frame: NSRect(x: 24, y: y, width: 340, height: 24))
        cursorCheck.setButtonType(.switch)
        cursorCheck.title = "Cursor（~/.cursor/settings.json）"
        cursorCheck.state = .off
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
        let applyBtn = NSButton(frame: NSRect(x: 90, y: y, width: 200, height: 40))
        applyBtn.title = "应用配置"
        applyBtn.bezelStyle = .rounded
        applyBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        applyBtn.target = self
        applyBtn.action = #selector(applyHookConfig)
        view.addSubview(applyBtn); y -= 52

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

    @objc func applyHookConfig() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let port = appDelegate.config.serverURL.components(separatedBy: ":").last ?? "8866"
        var results: [String] = []

        // --- Claude Code ---
        if claudeCodeCheck.state == .on {
            let path = home + "/.claude/settings.json"
            let hooks: [String: Any] = [
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing $CLAUDE_TOOL_NAME\", \"session_id\": \"$CLAUDE_SESSION_ID\"}'"]]]],
                "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"$CLAUDE_SESSION_ID\"}'"]]]],
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"$CLAUDE_SESSION_ID\"}'"]]]],
            ]
            let ok = writeHooksToFile(path: path, hooks: hooks, fm: fm)
            results.append(ok ? "✅ Claude Code" : "❌ Claude Code")
            appDelegate.log("[Hook] Claude Code: \(ok ? "ok" : "failed") \(path)")
        }

        // --- Codex ---
        if codexCheck.state == .on {
            let dir = home + "/.codex"
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            let path = dir + "/config.json"
            // Codex 使用 shell_command 类型的 hook
            let hooks: [String: Any] = [
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing\", \"session_id\": \"codex\"}'"]]]],
                "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"codex\"}'"]]]],
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"codex\"}'"]]]],
            ]
            let ok = writeHooksToFile(path: path, hooks: hooks, fm: fm)
            results.append(ok ? "✅ Codex" : "❌ Codex")
            appDelegate.log("[Hook] Codex: \(ok ? "ok" : "failed") \(path)")
        }

        // --- Cursor ---
        if cursorCheck.state == .on {
            let dir = home + "/.cursor"
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            let path = dir + "/settings.json"
            let hooks: [String: Any] = [
                "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing $CURSOR_TOOL_NAME\", \"session_id\": \"$CURSOR_SESSION_ID\"}'"]]]],
                "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"$CURSOR_SESSION_ID\"}'"]]]],
                "Stop": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"$CURSOR_SESSION_ID\"}'"]]]],
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
        sizeLabel.stringValue = "\(Int(sizeSlider.doubleValue))"
    }

    @objc func saveSettings() {
        var c = AppConfig()
        c.serverURL = "http://127.0.0.1:" + serverField.stringValue
        c.pollInterval = pollSlider.doubleValue
        c.opacity = opacitySlider.doubleValue
        c.blinkSpeed = blinkSlider.doubleValue
        c.windowSize = sizeSlider.doubleValue
        c.autoLaunch = autoLaunchCheck.state == .on
        c.showInDock = showDockCheck.state == .on
        c.notifyOnDone = notifyCheck.state == .on
        c.showOnFullscreen = fullscreenCheck.state == .on
        c.horizontal = horizontalCheck.state == .on
        c.showStatusText = showStatusCheck.state == .on
        c.isFloating = appDelegate.config.isFloating
        appDelegate.log("[保存] horizontal=\(c.horizontal) windowSize=\(c.windowSize)")
        c.save()
        if c.autoLaunch { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        appDelegate.restartWithNewConfig()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { appDelegate.settingsWindowController = nil }
}

// ============================================================
// Main
// ============================================================

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

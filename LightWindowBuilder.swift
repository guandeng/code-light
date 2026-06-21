import Cocoa

// ============================================================
// AppDelegate — 灯窗口构建 + 边缘吸附扩展
// ============================================================

extension AppDelegate {

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
        let targetScreen: NSScreen
        if let wx = config.windowX {
            targetScreen = NSScreen.screens.first { wx >= $0.frame.minX && wx <= $0.frame.maxX } ?? NSScreen.main!
        } else {
            targetScreen = NSScreen.main!
        }
        let screen = targetScreen.frame
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
        var posY: CGFloat = isEdgeBar ? defaultY : (config.windowY ?? defaultY)

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
        lightWindow.animationBehavior = .none
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
            redView.mascotType = config.mascotType
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
        rightMenu.addItem(withTitle: L10n.s("设置..."), action: #selector(openSettings), keyEquivalent: "")
        rightMenu.addItem(NSMenuItem.separator())
        rightMenu.addItem(withTitle: L10n.s("退出 CodeLight"), action: #selector(quitApp), keyEquivalent: "")
        view.menu = rightMenu
        // 子视图也设置菜单，确保右键能响应
        for sub in view.subviews { sub.menu = rightMenu }

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)

        lightWindow.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: lightWindow, queue: .main) { [weak self] _ in
            guard let self = self, let w = self.lightWindow else { return }
            guard !self.isRebuilding else { return }
            // 拖动中检测边缘停留
            if self.isDragging {
                let wf = w.frame
                let midX = wf.midX
                let screen = NSScreen.screens.first { midX >= $0.frame.minX && midX <= $0.frame.maxX } ?? NSScreen.main
                guard let sf = screen?.frame else { return }
                let snap: CGFloat = 20

                if wf.minX - sf.minX < snap {
                    self.startEdgeSnapTimer(side: "left", screenFrame: sf)
                } else if sf.maxX - wf.maxX < snap {
                    self.startEdgeSnapTimer(side: "right", screenFrame: sf)
                } else {
                    self.cancelEdgeSnap()
                }
                return
            }
            // 非拖动（编程移动），直接记录位置
            self.config.windowX = Double(w.frame.origin.x)
            self.config.windowY = Double(w.frame.origin.y)
            self.config.save()
        }

        // 鼠标按下/松开追踪拖动状态
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            if event.window === self?.lightWindow {
                self?.isDragging = true
                NSApp.activate(ignoringOtherApps: true)
            }
            return event
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            if self.isDragging {
                self.isDragging = false
                if let pending = self.edgeSnapPending {
                    self.config.edgeBar = pending
                    self.config.displayMode = "edgebar"
                    self.config.horizontal = false
                    self.config.windowX = Double(self.lightWindow?.frame.midX ?? 0)
                    self.config.windowY = Double(self.lightWindow?.frame.midY ?? 0)
                    self.config.save()
                    self.buildLightWindow()
                    self.startTimers()
                    self.pollState()
                    self.cancelEdgeSnap()
                    self.settingsWindowController?.syncFromConfig()
                } else {
                    // 从边缘栏拖出来：超过边缘栏宽度 → 恢复竖向；否则弹回边缘栏
                    if self.config.edgeBar != nil {
                        let wf = self.lightWindow?.frame ?? .zero
                        let midX = wf.midX
                        let screen = NSScreen.screens.first { midX >= $0.frame.minX && midX <= $0.frame.maxX } ?? NSScreen.main
                        let sf = screen?.frame ?? .zero
                        let edgeWidth: CGFloat = 20
                        let fromLeft = self.config.edgeBar == "left"
                        let dist = fromLeft ? (wf.minX - sf.minX) : (sf.maxX - wf.maxX)

                        if abs(dist) > edgeWidth {
                            // 拖离边缘够远 → 恢复竖向
                            self.config.edgeBar = nil
                            self.config.displayMode = "vertical"
                            self.config.horizontal = false
                            self.config.windowX = Double(wf.origin.x)
                            self.config.windowY = Double(wf.origin.y)
                            self.config.save()
                            self.cancelEdgeSnap()
                            self.buildLightWindow(); self.startTimers(); self.pollState()
                            self.settingsWindowController?.syncFromConfig()
                        } else {
                            // 拖得不够 → 弹回边缘栏
                            self.config.windowX = Double(wf.origin.x)
                            self.config.windowY = Double(wf.origin.y)
                            self.config.save()
                            self.buildLightWindow(); self.startTimers(); self.pollState()
                        }
                    } else {
                        self.config.windowX = Double(self.lightWindow?.frame.origin.x ?? 0)
                        self.config.windowY = Double(self.lightWindow?.frame.origin.y ?? 0)
                        self.config.save()
                    }
                }
            }
            return event
        }
    }

    // MARK: - 边缘吸附（停留 0.5s 触发预览，松手确认）

    func startEdgeSnapTimer(side: String, screenFrame: NSRect) {
        guard edgeSnapPending != side else { return }  // 已经在计时
        cancelEdgeSnap()
        edgeSnapPending = side
        edgeSnapTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.showEdgePreview(side: side, screenFrame: screenFrame)
        }
    }

    func cancelEdgeSnap() {
        edgeSnapTimer?.invalidate()
        edgeSnapTimer = nil
        edgeSnapPending = nil
        edgePreviewWindow?.close()
        edgePreviewWindow = nil
    }

    func showEdgePreview(side: String, screenFrame: NSRect) {
        edgePreviewWindow?.close()
        let barWidth: CGFloat = 12
        let barHeight = screenFrame.height * 0.5
        let x = (side == "left") ? screenFrame.minX : screenFrame.maxX - barWidth
        let y = screenFrame.midY - barHeight / 2
        let preview = NSPanel(
            contentRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.level = .floating
        preview.hasShadow = false
        let view = preview.contentView!
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 0.3).cgColor
        view.layer?.cornerRadius = 3
        preview.makeKeyAndOrderFront(nil)
        edgePreviewWindow = preview
    }
}

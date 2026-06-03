import Cocoa

// ============================================================
// ChatBubbleView — 聊天气泡样式
// ============================================================

class ChatBubbleView: NSView {
    var tailOnRight = true  // true=尾巴在右侧指向右，false=尾巴在左侧指向左

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let tailW: CGFloat = 12
        let bodyW = w - tailW
        let r: CGFloat = 14
        let tailY = h * 0.7  // 尾巴垂直位置

        let path = NSBezierPath()
        if tailOnRight {
            // 尾巴在右侧，指向右边的红绿灯
            // 从左上角顺时针
            path.move(to: NSPoint(x: r, y: h))
            path.curve(to: NSPoint(x: 0, y: h - r), controlPoint1: NSPoint(x: 0, y: h), controlPoint2: NSPoint(x: 0, y: h - r))
            path.line(to: NSPoint(x: 0, y: r))
            path.curve(to: NSPoint(x: r, y: 0), controlPoint1: NSPoint(x: 0, y: 0), controlPoint2: NSPoint(x: r, y: 0))
            path.line(to: NSPoint(x: bodyW - r, y: 0))
            path.curve(to: NSPoint(x: bodyW, y: r), controlPoint1: NSPoint(x: bodyW, y: 0), controlPoint2: NSPoint(x: bodyW, y: r))
            // 右边 + 尾巴
            path.line(to: NSPoint(x: bodyW, y: tailY - tailW / 2))
            path.line(to: NSPoint(x: w, y: tailY))  // 尾巴尖端
            path.line(to: NSPoint(x: bodyW, y: tailY + tailW / 2))
            path.line(to: NSPoint(x: bodyW, y: h - r))
            path.curve(to: NSPoint(x: bodyW - r, y: h), controlPoint1: NSPoint(x: bodyW, y: h), controlPoint2: NSPoint(x: bodyW - r, y: h))
        } else {
            // 尾巴在左侧，指向左边的红绿灯
            // 从右上角逆时针
            path.move(to: NSPoint(x: w - r, y: h))
            path.curve(to: NSPoint(x: w, y: h - r), controlPoint1: NSPoint(x: w, y: h), controlPoint2: NSPoint(x: w, y: h - r))
            path.line(to: NSPoint(x: w, y: r))
            path.curve(to: NSPoint(x: w - r, y: 0), controlPoint1: NSPoint(x: w, y: 0), controlPoint2: NSPoint(x: w - r, y: 0))
            path.line(to: NSPoint(x: tailW + r, y: 0))
            path.curve(to: NSPoint(x: tailW, y: r), controlPoint1: NSPoint(x: tailW, y: 0), controlPoint2: NSPoint(x: tailW, y: r))
            // 左边 + 尾巴
            path.line(to: NSPoint(x: tailW, y: tailY - tailW / 2))
            path.line(to: NSPoint(x: 0, y: tailY))  // 尾巴尖端
            path.line(to: NSPoint(x: tailW, y: tailY + tailW / 2))
            path.line(to: NSPoint(x: tailW, y: h - r))
            path.curve(to: NSPoint(x: tailW + r, y: h), controlPoint1: NSPoint(x: tailW, y: h), controlPoint2: NSPoint(x: tailW + r, y: h))
        }
        path.close()

        NSColor(white: 0.15, alpha: 0.95).setFill()
        path.fill()

        NSColor(white: 0.25, alpha: 0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// ============================================================
// AppDelegate — 权限气泡扩展
// ============================================================

extension AppDelegate {

    func showPermissionBubble(_ entry: [String: Any]) {
        guard config.notifyOnPermission else { return }
        guard let lightWindow = lightWindow else { return }

        let id = entry["id"] as? String ?? ""
        let input = entry["input"] as? [String: Any] ?? [:]
        let toolName = input["tool_name"] as? String ?? "unknown"
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let command = toolInput["command"] as? String ?? toolInput["file_path"] as? String ?? ""

        // 权限模式判断：always / rules / popup
        let mode = config.permissionMode
        if mode == "always" {
            // 总是运行：直接放行
            if let ls = lightServer {
                ls.setPermissionDecision(id: id, behavior: "allow")
            }
            log("[权限] 总是运行: \(toolName)")
            return
        }

        if mode == "rules" {
            // 规则运行：匹配规则则放行，否则弹窗
            if AlwaysAllowManager.shared.shouldAllow(command: command) {
                if let ls = lightServer {
                    ls.setPermissionDecision(id: id, behavior: "allow")
                }
                log("[权限] 规则匹配自动允许: \(String(command.prefix(80)))")
                return
            }
            // 不匹配规则，继续弹窗确认
        }

        // popup 模式或 rules 未匹配：弹窗确认

        let bubbleW: CGFloat = 280, bubbleH: CGFloat = 150, bubbleGap: CGFloat = 8
        let tailW: CGFloat = 12
        let wf = lightWindow.frame
        let sf = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let screenMidX = sf.midX
        let winMidX = wf.midX
        let onRight = winMidX > screenMidX

        // 堆叠偏移：已有几个气泡就往下移几个
        let stackIndex = permissionBubbles.count
        let yOffset = CGFloat(stackIndex) * (bubbleH + bubbleGap)

        let bx: CGFloat
        let by: CGFloat
        if onRight {
            by = wf.maxY - bubbleH - yOffset
            bx = wf.minX - bubbleW - tailW - 4
        } else {
            by = wf.maxY - bubbleH - yOffset
            bx = wf.maxX + 4
        }
        let totalW = onRight ? bubbleW + tailW : tailW + bubbleW

        let bubble = NSPanel(contentRect: NSRect(x: bx, y: by, width: totalW, height: bubbleH),
                             styleMask: [.nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        bubble.isFloatingPanel = true
        bubble.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        bubble.backgroundColor = .clear
        bubble.isOpaque = false
        bubble.hasShadow = true
        bubble.isMovableByWindowBackground = false

        // 聊天冒泡背景
        let bubbleView = ChatBubbleView(frame: NSRect(x: 0, y: 0, width: totalW, height: bubbleH))
        bubbleView.tailOnRight = onRight
        bubble.contentView?.addSubview(bubbleView)

        let contentX = onRight ? 14.0 : 12.0 + tailW
        // Title
        let title = NSTextField(frame: NSRect(x: contentX, y: bubbleH - 30, width: bubbleW - 28, height: 20))
        title.isEditable = false; title.isBordered = false; title.backgroundColor = .clear
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.white
        title.stringValue = "\(toolName) 请求权限"
        title.drawsBackground = false
        bubbleView.addSubview(title)

        // Command detail
        let detail = NSTextField(frame: NSRect(x: contentX, y: bubbleH - 102, width: bubbleW - 28, height: 62))
        detail.isEditable = false; detail.isBordered = false; detail.backgroundColor = .clear
        detail.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = NSColor(white: 0.6, alpha: 1.0)
        detail.stringValue = String(command.prefix(300))
        detail.lineBreakMode = .byCharWrapping
        detail.cell?.wraps = true
        detail.drawsBackground = false
        bubbleView.addSubview(detail)

        // 气泡 tooltip 显示完整命令（macOS tooltip 限制约 800 字符）
        let shortCmd = command.count > 600 ? String(command.prefix(600)) + "…" : command
        bubbleView.toolTip = "\(toolName) 请求权限\n\n\(shortCmd)"

        // 允许 + 拒绝 按钮（用 identifier 存 permission id，不依赖数组索引）
        let btnW = (bubbleW - 36) / 2
        let denyBtn = NSButton(frame: NSRect(x: contentX, y: 20, width: btnW, height: 28))
        denyBtn.bezelStyle = .rounded
        let denyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.systemRed]
        denyBtn.attributedTitle = NSAttributedString(string: "拒绝", attributes: denyAttrs)
        denyBtn.target = self
        denyBtn.action = #selector(denyPermission(_:))
        denyBtn.identifier = NSUserInterfaceItemIdentifier("deny:\(id)")
        bubbleView.addSubview(denyBtn)

        let allowBtn = NSButton(frame: NSRect(x: contentX + btnW + 8, y: 20, width: btnW, height: 28))
        allowBtn.bezelStyle = .rounded
        let allowAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.systemGreen]
        allowBtn.attributedTitle = NSAttributedString(string: "允许", attributes: allowAttrs)
        allowBtn.target = self
        allowBtn.action = #selector(allowPermission(_:))
        allowBtn.identifier = NSUserInterfaceItemIdentifier("allow:\(id)")
        bubbleView.addSubview(allowBtn)

        bubble.orderFront(nil)

        // 35 秒超时自动关闭（hook 命令轮询 30 秒超时，多给 5 秒缓冲）
        let permId = id
        let permSessionId = sessionId
        let timeout = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            // 超时时清除该会话的 waiting 状态，避免灯一直红
            self?.lightServer?.updateState(name: "idle", message: "超时", sessionId: permSessionId)
            self?.dismissPermissionBubble(id: permId)
        }
        permissionBubbles.append((id: id, window: bubble, toolName: toolName, command: String(command.prefix(60)), timer: timeout, sessionId: sessionId))
    }

    func dismissPermissionBubble(id: String) {
        guard let idx = permissionBubbles.firstIndex(where: { $0.id == id }) else { return }
        permissionBubbles[idx].timer?.invalidate()
        permissionBubbles[idx].window.close()
        permissionBubbles.remove(at: idx)
        relayoutPermissionBubbles()
    }

    func dismissAllPermissionBubbles() {
        for b in permissionBubbles { b.timer?.invalidate(); b.window.close() }
        permissionBubbles.removeAll()
    }

    private func relayoutPermissionBubbles() {
        guard let lightWindow = lightWindow else { return }
        let bubbleH: CGFloat = 150, bubbleGap: CGFloat = 8
        let wf = lightWindow.frame
        let sf = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let onRight = wf.midX > sf.midX

        for (i, b) in permissionBubbles.enumerated() {
            let yOffset = CGFloat(i) * (bubbleH + bubbleGap)
            var frame = b.window.frame
            frame.origin.y = wf.maxY - bubbleH - yOffset
            b.window.setFrame(frame, display: true)
        }
    }

    @objc func denyPermission(_ sender: NSButton) {
        guard let ident = sender.identifier?.rawValue, ident.hasPrefix("deny:") else { return }
        let id = String(ident.dropFirst(5))
        lightServer?.setPermissionDecision(id: id, behavior: "deny")
        dismissPermissionBubble(id: id)
    }

    @objc func allowPermission(_ sender: NSButton) {
        guard let ident = sender.identifier?.rawValue, ident.hasPrefix("allow:") else { return }
        let id = String(ident.dropFirst(6))
        lightServer?.setPermissionDecision(id: id, behavior: "allow")
        dismissPermissionBubble(id: id)
    }
}

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
        permissionBubbleWindow?.close()

        let id = entry["id"] as? String ?? ""
        let input = entry["input"] as? [String: Any] ?? [:]
        let toolName = input["tool_name"] as? String ?? "unknown"
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let command = toolInput["command"] as? String ?? toolInput["file_path"] as? String ?? ""

        // Switch to waiting state
        permissionBubbleId = id
        permissionToolName = toolName
        permissionCommand = String(command.prefix(60))
        let sessionId = input["session_id"] as? String ?? "default"
        if let ls = lightServer {
            ls.updateState(name: "waiting", message: "permission: \(toolName)", sessionId: sessionId)
        }

        let bubbleW: CGFloat = 280, bubbleH: CGFloat = 150
        let tailW: CGFloat = 12
        let wf = lightWindow.frame
        let sf = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let screenMidX = sf.midX
        let winMidX = wf.midX
        // 根据窗口在屏幕的哪一侧决定气泡方向
        let onRight = winMidX > screenMidX
        let bx: CGFloat, by: CGFloat
        if onRight {
            // 窗口在右半边，气泡在左侧，尾巴向右
            by = wf.maxY - bubbleH
            bx = wf.minX - bubbleW - tailW - 4
        } else {
            // 窗口在左半边，气泡在右侧，尾巴向左
            by = wf.maxY - bubbleH
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
        let detail = NSTextField(frame: NSRect(x: contentX, y: bubbleH - 96, width: bubbleW - 28, height: 56))
        detail.isEditable = false; detail.isBordered = false; detail.backgroundColor = .clear
        detail.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = NSColor(white: 0.6, alpha: 1.0)
        detail.stringValue = String(command.prefix(200))
        detail.lineBreakMode = .byCharWrapping
        detail.cell?.wraps = true
        detail.drawsBackground = false
        bubbleView.addSubview(detail)

        // 气泡 tooltip 显示完整命令
        bubbleView.toolTip = "\(toolName) 请求权限\n\n\(command)"

        // 允许 + 拒绝 按钮
        let btnW = (bubbleW - 36) / 2
        let denyBtn = NSButton(frame: NSRect(x: contentX, y: 20, width: btnW, height: 28))
        denyBtn.bezelStyle = .rounded
        let denyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.systemRed]
        denyBtn.attributedTitle = NSAttributedString(string: "拒绝", attributes: denyAttrs)
        denyBtn.target = self
        denyBtn.action = #selector(denyPermission)
        bubbleView.addSubview(denyBtn)

        let allowBtn = NSButton(frame: NSRect(x: contentX + btnW + 8, y: 20, width: btnW, height: 28))
        allowBtn.bezelStyle = .rounded
        let allowAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.systemGreen]
        allowBtn.attributedTitle = NSAttributedString(string: "允许", attributes: allowAttrs)
        allowBtn.target = self
        allowBtn.action = #selector(allowPermission)
        bubbleView.addSubview(allowBtn)

        bubble.orderFront(nil)
        permissionBubbleWindow = bubble
    }

    func dismissPermissionBubble() {
        permissionBubbleWindow?.close()
        permissionBubbleWindow = nil
        permissionBubbleId = nil
        permissionAlwaysCheck = nil
        permissionToolName = nil
        permissionCommand = nil
    }

    @objc func okPermission() {
        dismissPermissionBubble()
    }

    @objc func denyPermission() {
        guard let id = permissionBubbleId, !id.isEmpty else { return }
        lightServer?.setPermissionDecision(id: id, behavior: "deny")
        dismissPermissionBubble()
    }

    @objc func allowPermission() {
        guard let id = permissionBubbleId, !id.isEmpty else { return }
        var rule: [String: Any]? = nil
        if permissionAlwaysCheck?.tag == 1 {
            rule = ["toolName": permissionToolName ?? "", "ruleContent": permissionCommand ?? ""]
        }
        lightServer?.setPermissionDecision(id: id, behavior: "allow", addRule: rule)
        dismissPermissionBubble()
    }
}

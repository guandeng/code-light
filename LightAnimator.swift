import Cocoa
import UserNotifications

// ============================================================
// AppDelegate — 灯动画 + 状态轮询扩展
// ============================================================

extension AppDelegate {

    func startTimers() {
        pollTimer?.invalidate(); animTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { _ in self.pollState() }
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in self.animateLight() }
    }

    func animateLight() {
        let state = currentStateName
        animPhase += 0.04
        if animPhase > 1 { animPhase -= 1 }

        // 只有非 idle 状态才高频更新（闪烁/呼吸/吉祥物动画）
        // idle 状态每 25 帧（~1.25s）更新一次吉祥物即可
        // Mini 模式 idle 状态完全跳过动画
        let isMiniIdle = config.displayMode == "mini" && config.edgeBar == nil && state == "idle"
        let needsAnim = isMiniIdle ? false : (state != "idle" || Int(animPhase * 100) % 25 == 0)
        if needsAnim {
            redView.mascotPhase = animPhase
            yellowView.mascotPhase = animPhase
            greenView.mascotPhase = animPhase
        }
        redView.tickMascotFade()
        yellowView.tickMascotFade()
        greenView.tickMascotFade()

        // Mini 模式：单灯颜色随状态切换（边缘栏用三色，不走这个分支）
        if config.displayMode == "mini" && config.edgeBar == nil {
            // 只有纯迷你模式才走单灯分支
            let miniColors: [String: NSColor] = [
                "idle": NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0),
                "thinking": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0),
                "working": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
                "fixing": NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0),
                "error": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
                "waiting": NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0),
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

            case "waiting":
                let fast = sin(Double(animPhase) * .pi * 4) > 0
                redView.isOn = fast; redView.brightness = 1.0
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
        if config.displayMode == "mini" && config.edgeBar == nil {
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
                    // 自定义提示音
                    let soundName = self.config.completionSound
                    if soundName != "none", let sound = NSSound(named: NSSound.Name(soundName)) {
                        sound.play()
                    }
                }
                let s = STATES[sn] ?? STATES["idle"]!
                if self.config.displayMode != "mini" || self.config.edgeBar != nil {
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
}

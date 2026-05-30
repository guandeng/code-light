import Cocoa

// ============================================================
// SettingsWindowController — Hook 配置扩展
// ============================================================

extension SettingsWindowController {

    func generateHooks(tool: String, port: String) -> [String: Any] {
        let toolName = tool == "claude" ? "$CLAUDE_TOOL_NAME" : (tool == "cursor" ? "$CURSOR_TOOL_NAME" : "")
        let sessionId = tool == "claude" ? "$CLAUDE_SESSION_ID" : (tool == "cursor" ? "$CURSOR_SESSION_ID" : "codex")
        var hooks: [String: Any] = [
            "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing \(toolName)\", \"session_id\": \"\(sessionId)\"}' || echo '{}'"]]]],
            "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"\(sessionId)\"}' || echo '{}'"]]]],
            "Stop": [["matcher": "", "hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"\(sessionId)\"}' || echo '{}'"]]]],
        ]
        if appDelegate.config.notifyOnPermission {
            let permCmd = "curl -s -X POST http://127.0.0.1:\(port)/api/permission -d \"$(cat)\" -H 'Content-Type: application/json' | python3 -c \"import sys,json,urllib.request,time;rid=json.load(sys.stdin).get('id','');n=0\nwhile n<100:\n try:r2=json.loads(urllib.request.urlopen(f'http://127.0.0.1:\(port)/api/permission/'+rid+'/decision').read())\n except:break\n if r2.get('status')=='done':b=r2.get('decision',{}).get('decision','');print(json.dumps({'hookSpecificOutput':{'hookEventName':'PermissionRequest','decision':{'behavior':b}}}));break\n time.sleep(0.3);n+=1\" || true"
            hooks["PermissionRequest"] = [["matcher": "", "hooks": [["type": "command", "command": permCmd]]]]
        }
        return hooks
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
            let hooks = generateHooks(tool: "claude", port: port)
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
            let hooks = generateHooks(tool: "codex", port: port)
            if !writeHooksToFile(path: hooksPath, hooks: hooks, fm: fm) { codexOk = false }
            results.append(codexOk ? "✅ Codex" : "❌ Codex")
            appDelegate.log("[Hook] Codex: \(codexOk ? "ok" : "failed") \(dir)/config.toml + hooks.json")
        }

        // --- Cursor ---
        if cursorCheck.state == .on {
            let dir = home + "/.cursor"
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            let path = dir + "/settings.json"
            let hooks = generateHooks(tool: "cursor", port: port)
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
}

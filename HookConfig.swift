import Cocoa

// ============================================================
// SettingsWindowController — Hook 配置扩展
// ============================================================

extension SettingsWindowController {

    func generateHooks(tool: String, port: String) -> [String: Any] {
        // 从 stdin JSON 提取 tool_name 和 session_id 的内联脚本
        let readStdin = "INPUT=$(cat); TOOL=$(echo \"$INPUT\" | python3 -c \"import sys,json;d=json.load(sys.stdin);print(d.get('tool_name',''))\" 2>/dev/null); SID=$(echo \"$INPUT\" | python3 -c \"import sys,json;d=json.load(sys.stdin);print(d.get('session_id',''))\" 2>/dev/null)"

        // PreToolUse: stdin 有 tool_name + session_id
        let preCmd = "\(readStdin); curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d \"{\\\"state\\\": \\\"working\\\", \\\"message\\\": \\\"executing $TOOL\\\", \\\"session_id\\\": \\\"$SID\\\"}\" || echo '{}'"
        // PostToolUse: 状态更新 + worklog 记录
        let postStateCmd = "\(readStdin); curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d \"{\\\"state\\\": \\\"thinking\\\", \\\"message\\\": \\\"analyzing\\\", \\\"session_id\\\": \\\"$SID\\\"}\" || echo '{}'"
        let worklogCmd = "\(readStdin); curl -s -X POST http://127.0.0.1:\(port)/api/worklog -H 'Content-Type: application/json' -d \"{\\\"tool_name\\\": \\\"$TOOL\\\", \\\"session_id\\\": \\\"$SID\\\"}\" || true"
        // Stop: 用环境变量 CLAUDE_CODE_SESSION_ID（Stop hook stdin 无 tool_name）
        let sidEnv = tool == "claude" ? "$CLAUDE_CODE_SESSION_ID" : (tool == "cursor" ? "$CURSOR_SESSION_ID" : "codex")
        let stopCmd = "curl -s -X POST http://127.0.0.1:\(port)/api/state -H 'Content-Type: application/json' -d \"{\\\"state\\\": \\\"idle\\\", \\\"message\\\": \\\"done\\\", \\\"session_id\\\": \\\"\(sidEnv)\\\"}\" || echo '{}'"
        let summaryCmd = "LINES=$(git diff --stat HEAD 2>/dev/null | tail -1); if [ -n \"$LINES\" ]; then curl -s -X POST http://127.0.0.1:\(port)/api/worklog -H 'Content-Type: application/json' -d \"{\\\"tool_name\\\": \\\"stop\\\", \\\"session_id\\\": \\\"\(sidEnv)\\\", \\\"detail\\\": \\\"改动: $LINES\\\"}\" || true; fi"

        var hooks: [String: Any] = [
            "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": preCmd]]]],
            "PostToolUse": [["matcher": "", "hooks": [["type": "command", "command": "\(postStateCmd); \(worklogCmd)"]]]],
            "Stop": [["matcher": "", "hooks": [["type": "command", "command": "\(stopCmd); \(summaryCmd)"]]]],
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

        let seg = hookToolSegment.selectedSegment

        // --- Claude Code ---
        if seg == 0 {
            let path = home + "/.claude/settings.json"
            let hooks = generateHooks(tool: "claude", port: port)
            let ok = writeHooksToFile(path: path, hooks: hooks, fm: fm)
            results.append(ok ? "Claude Code ok" : "Claude Code failed")
            appDelegate.log("[Hook] Claude Code: \(ok ? "ok" : "failed") \(path)")
        }

        // --- Codex ---
        if seg == 1 {
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
            results.append(codexOk ? "Codex ok" : "Codex failed")
            appDelegate.log("[Hook] Codex: \(codexOk ? "ok" : "failed") \(dir)/config.toml + hooks.json")
        }

        // --- Cursor ---
        if seg == 2 {
            let dir = home + "/.cursor"
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            let path = dir + "/settings.json"
            let hooks = generateHooks(tool: "cursor", port: port)
            let ok = writeHooksToFile(path: path, hooks: hooks, fm: fm)
            results.append(ok ? "Cursor ok" : "Cursor failed")
            appDelegate.log("[Hook] Cursor: \(ok ? "ok" : "failed") \(path)")
        }

        if results.isEmpty {
            hookStatusLabel.stringValue = "请至少选择一个工具"
            hookStatusLabel.textColor = NSColor.systemOrange
        } else {
            hookStatusLabel.stringValue = results.joined(separator: "  ")
            let allOk = results.allSatisfy { $0.hasSuffix("ok") }
            hookStatusLabel.textColor = allOk
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

#!/usr/bin/env swift
// CodeLight CLI — 终端状态查看工具
// 编译: swiftc -O -o codelight codelight-cli.swift
// 用法: codelight [state|sessions|history|watch|help]

import Foundation

let defaultURL = "http://127.0.0.1:8866"

// ── 颜色输出 ──
func esc(_ code: String) -> String { "\u{001B}[\(code)m" }
let RST = esc("0"), BOLD = esc("1"), DIM = esc("2")
let RED = esc("31"), GRN = esc("32"), YEL = esc("33"), BLU = esc("34"), MAG = esc("35"), CYN = esc("36")

// ── 状态颜色映射 ──
let stateColor: [String: String] = [
    "idle": GRN, "thinking": YEL, "working": RED,
    "fixing": YEL, "error": RED, "waiting": MAG,
]
let stateLabel: [String: String] = [
    "idle": "空闲", "thinking": "思考", "working": "执行",
    "fixing": "修复", "error": "错误", "waiting": "等待",
]
let stateIcon: [String: String] = [
    "idle": "🟢", "thinking": "🟡", "working": "🔴",
    "fixing": "🟡", "error": "🔴", "waiting": "🔴",
]

func fetch(_ path: String, baseURL: String = defaultURL) -> Any? {
    guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
    let sem = DispatchSemaphore(value: 0)
    var result: Any?
    var req = URLRequest(url: url)
    req.timeoutInterval = 3
    URLSession.shared.dataTask(with: req) { data, response, error in
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) {
            result = json
        }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

func printState() {
    guard let json = fetch("/api/state") as? [String: Any] else {
        print("\(RED)✗ 无法连接 CodeLight 服务 (\(defaultURL))\(RST)")
        print("  确认 CodeLight 正在运行")
        return
    }
    let state = json["state"] as? String ?? "unknown"
    let msg = json["message"] as? String ?? ""
    let active = json["active_count"] as? Int ?? 0
    let col = stateColor[state] ?? CYN
    let label = stateLabel[state] ?? state
    let icon = stateIcon[state] ?? "⚪"

    print()
    print("  \(icon) \(BOLD)\(col)\(label)\(RST)  \(msg)")
    if active > 0 {
        print("  \(DIM)活跃会话: \(active)\(RST)")
    }
    print()
}

func printSessions() {
    guard let json = fetch("/api/sessions") as? [String: Any] else {
        print("\(RED)✗ 无法连接 CodeLight 服务\(RST)"); return
    }
    let count = json["count"] as? Int ?? 0
    let sessions = json["sessions"] as? [String: [String: Any]] ?? [:]
    print()
    print("  \(BOLD)会话列表 (\(count))\(RST)")
    print("  \(DIM)─────────────────────────────────\(RST)")
    for (id, info) in sessions.sorted(by: { $0.key < $1.key }) {
        let s = info["state"] as? String ?? "?"
        let m = info["message"] as? String ?? ""
        let age = info["age"] as? String ?? ""
        let col = stateColor[s] ?? CYN
        let label = stateLabel[s] ?? s
        let short = String(id.prefix(12))
        print("  \(col)●\(RST) \(BOLD)\(short)\(RST)  \(col)\(label)\(RST)  \(m)  \(DIM)\(age)\(RST)")
    }
    print()
}

func printHistory() {
    guard let json = fetch("/api/history") as? [[String: Any]] else {
        print("\(RED)✗ 无法连接 CodeLight 服务\(RST)"); return
    }
    let recent = Array(json.suffix(20))
    print()
    print("  \(BOLD)最近状态变更 (\(recent.count))\(RST)")
    print("  \(DIM)─────────────────────────────────\(RST)")
    for entry in recent {
        let ts = entry["timestamp"] as? Double ?? 0
        let s = entry["state"] as? String ?? "?"
        let m = entry["message"] as? String ?? ""
        let sid = entry["session_id"] as? String ?? "?"
        let col = stateColor[s] ?? CYN
        let label = stateLabel[s] ?? s
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        print("  \(DIM)\(fmt.string(from: date))\(RST)  \(col)\(label)\(RST)  \(m)  \(DIM)[\(sid)]\(RST)")
    }
    print()
}

func watchMode(interval: Double = 1.0) {
    print("\(CYN)⏳ 监控中... (Ctrl+C 退出)\(RST)\n")
    while true {
        guard let json = fetch("/api/state") as? [String: Any] else {
            print("\r\(RED)● 连接中断...\(RST)", terminator: ""); fflush(stdout)
            Thread.sleep(forTimeInterval: interval)
            continue
        }
        let state = json["state"] as? String ?? "?"
        let msg = json["message"] as? String ?? ""
        let active = json["active_count"] as? Int ?? 0
        let col = stateColor[state] ?? CYN
        let label = stateLabel[state] ?? state
        let icon = stateIcon[state] ?? "⚪"
        let now = DateFormatter(); now.dateFormat = "HH:mm:ss"
        let extra = active > 0 ? "  \(DIM)×\(active)\(RST)" : ""
        print("\r  \(icon) \(now.string(from: Date())) \(col)\(label)\(RST)  \(msg)\(extra)            ", terminator: "")
        fflush(stdout)
        Thread.sleep(forTimeInterval: interval)
    }
}

func printHelp() {
    print()
    print("  \(BOLD)CodeLight CLI\(RST)  —  终端状态查看工具")
    print()
    print("  \(BOLD)用法:\(RST)")
    print("    \(CYN)codelight\(RST)              显示当前状态")
    print("    \(CYN)codelight state\(RST)         显示当前状态")
    print("    \(CYN)codelight sessions\(RST)      列出所有会话")
    print("    \(CYN)codelight history\(RST)       最近状态变更")
    print("    \(CYN)codelight watch\(RST)         持续监控模式")
    print("    \(CYN)codelight help\(RST)          显示帮助")
    print()
    print("  \(BOLD)环境变量:\(RST)")
    print("    \(CYN)CODELIGHT_URL\(RST)   服务地址 (默认: \(defaultURL))")
    print()
}

// ── 入口 ──
let args = CommandLine.arguments.dropFirst()
let cmd = args.first?.lowercased() ?? "state"

switch cmd {
case "state": printState()
case "sessions", "session", "s": printSessions()
case "history", "hist", "h": printHistory()
case "watch", "w": watchMode()
case "help", "--help", "-h": printHelp()
default:
    print("\(RED)未知命令: \(cmd)\(RST)")
    printHelp()
}

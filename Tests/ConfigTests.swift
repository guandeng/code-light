// CodeLight 单元测试 — 纯逻辑，不依赖 AppKit
import Foundation

// 从项目源文件复制��试所需的类型和函数
// （单文件编译，无法 import 项目模块，这里只测纯逻辑）

var pass = 0, fail = 0

func assert(_ desc: String, _ condition: Bool) {
    if condition { pass += 1; print("  ✅ \(desc)") }
    else { fail += 1; print("  ❌ \(desc)") }
}

// ==== SEVERITY 排序测试 ====
print("🧪 SEVERITY 排序")

let SEVERITY = ["error": 4, "working": 3, "fixing": 3, "thinking": 2, "waiting": 2, "idle": 0]

assert("error 优先级最高", SEVERITY["error"]! > SEVERITY["working"]!)
assert("working > thinking", SEVERITY["working"]! > SEVERITY["thinking"]!)
assert("thinking > idle", SEVERITY["thinking"]! > SEVERITY["idle"]!)
assert("fixing == working", SEVERITY["fixing"] == SEVERITY["working"])
assert("waiting == thinking", SEVERITY["waiting"] == SEVERITY["thinking"])

// 模拟聚合：取最严重状态
let sessions: [String: Int] = ["s1": SEVERITY["idle"]!, "s2": SEVERITY["working"]!, "s3": SEVERITY["thinking"]!]
let worst = sessions.max { $0.value < $1.value }!
assert("聚合取最严重状态", worst.key == "s2" && worst.value == 3)

// ==== Hex 颜色测试 ====
print("")
print("🧪 Hex 颜色转换")

func hexToRGB(_ hex: String) -> (r: Int, g: Int, b: Int)? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
    return (Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
}

assert("#1C1E22 正确解析", hexToRGB("#1C1E22") != nil && hexToRGB("#1C1E22")!.r == 0x1C)
assert("#FF0000 红色", hexToRGB("#FF0000") != nil && hexToRGB("#FF0000")!.r == 255)
assert("#00FF00 绿色", hexToRGB("#00FF00") != nil && hexToRGB("#00FF00")!.g == 255)
assert("无效 hex 返回 nil", hexToRGB("xyz") == nil)
assert("空字符串返回 nil", hexToRGB("") == nil)
assert("无 # 前缀也能解析", hexToRGB("FF0000") != nil && hexToRGB("FF0000")!.r == 255)

// ==== 字符串工具 ====
print("")
print("🧪 字符串工具")

let cmd = "npm run build --production --minify --output=dist"
assert("prefix(80) 截断", String(cmd.prefix(80)) == cmd)
assert("prefix(10) 截断", String(cmd.prefix(10)) == "npm run bu")

// ==== 路由 ID 提取 ====
print("")
print("🧪 路由 ID 提取")

func extractPermissionId(from path: String) -> String {
    let prefix = "/api/permission/"
    guard path.hasPrefix(prefix) else { return "" }
    let remainder = String(path.dropFirst(prefix.count))
    return remainder.components(separatedBy: "/").first ?? remainder
}

assert("提取决策轮询 id", extractPermissionId(from: "/api/permission/perm-123/decision") == "perm-123")
assert("提取允许操作 id", extractPermissionId(from: "/api/permission/perm-456/allow") == "perm-456")
assert("提取无后缀 id", extractPermissionId(from: "/api/permission/perm-789") == "perm-789")
assert("无效路径返回空", extractPermissionId(from: "/api/other") == "")

// ==== 汇总 ====
print("")
print("━━━━━━━━━━━━━━━━━━━━")
print("通过: \(pass)  失败: \(fail)")
if fail > 0 { print("❌ 有测试失败"); exit(1) }
else { print("✅ 全部通过") }

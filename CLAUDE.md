# CodeLight 项目指南

## 发版流程

发版前必须完成以下检查项：

1. **更新 README.md 版本号**
   - 第 5 行下载徽章：`⬇️_下载-vX.Y.Z` 改为新版本号
   - 检查 README 中是否有其他硬编码的版本引用

2. **提交代码**
   ```bash
   git add -A
   git commit -m "feat: xxx"
   git push origin main
   ```

3. **发版命令**
   ```bash
   make release VERSION=X.Y.Z
   ```
   会自动：编译 → codesign → 打包 zip → 创建 GitHub Release

4. **验证**
   - 确认 GitHub Release 页面出现新版本
   - 确认 zip 可下载

## 架构

- `main.swift` — 入口，创建 AppDelegate 和 status bar
- `CodeLight.swift` — 核心：LightServer (NWListener HTTP)、灯窗口管理、设置面板、Hook 生成、权限气泡
- `Config.swift` — AppConfig (UserDefaults 持久化)、状态定义 STATES、城市列表
- `UI.swift` — 纯绘制：ShellView、RealTrafficLightView、吉祥物绘制 (cow/cat/robot/horse)
- `Weather.swift` — Open-Meteo 天气 API、WeatherView 渐变背景
- `Makefile` — build/package/release 自动化

## 关键约束

- **macOS 13.0+** (target: `arm64-apple-macosx13.0`)
- 不能用 `cgPath`（macOS 14+），用 `NSBezierPath` + `draw()` 代替
- NSButton 不支持 `textColor`，用 `attributedTitle` 或 `contentTintColor`
- `NSButton.switch` checkbox 在自定义深色面板上不可见，用自定义按钮模拟
- 非活跃灯用 `lampColor.withAlphaComponent(0.05~0.08)` 淡色，不用纯黑

## Hook 配置

Claude Code hooks 通过 `~/.claude/settings.json` 配置：
- PreToolUse → working 状态
- PostToolUse → thinking 状态
- Stop → idle 状态
- PermissionRequest → 弹出气泡通知（纯通知模式，不阻塞）

Hook 命令末尾加 `|| true` 或 `|| echo '{}'` 兜底，防止 CodeLight 未运行时报错。

## 气泡弹窗

- 权限请求时弹出微信风格聊天气泡
- 自动根据红绿灯在屏幕左/右半区决定气泡方向
- 气泡有圆角 + 小三角尾巴指向红绿灯
- 气泡层级 `popUpMenuWindow + 1`，确保在最上层

# CodeLight 项目指南

## 发版流程

发版前必须完成以下检查项：

1. **更新版本号**（三处必须一致）
   - **Info.plist** — `CFBundleVersion` 和 `CFBundleShortVersionString` 改为新版本号
   - **README.md** — 第 5 行下载徽章：`⬇️_下载-vX.Y.Z` 改为新版本号
   - 检查 README 中是否有其他硬编码的版本引用

2. **提交代码**
   ```bash
   git add -A
   git commit -m "feat: xxx"
   git push origin main
   ```

## Push 前检查（每次必须执行）

每次 `git push` 前必须完成以下检查：

1. **安全审查** — 检查变更中是否包含：
   - 硬编码的密钥/token/密码/API key
   - 敏感文件（.env、credentials、私钥）
   - 内部 URL 或邮箱泄漏
   - 命令注入风险（未过滤的用户输入拼入 shell 命令）

2. **Code Review** — 审查变更代码：
   - 是否有明显的逻辑错误或边界问题
   - 是否引入了不安全的 API 调用
   - 是否有未使用的 debug 代码或临时代码
   - 改动是否符合最小化原则（不多改）

3. **编译验证** — `make build` 必须通过，无新增 error

3. **发版命令**
   ```bash
   make release VERSION=X.Y.Z
   ```
   会自动：编译 → 嵌入 Sparkle → codesign → 打包 → 创建 GitHub Release

   > **注意**：
   > - GitHub Release 的 description 必须说明本次发布包含的功能/改进，不要留空。
   > - 编译产物为 Universal Binary，同时支持 Apple Silicon (arm64) 和 Intel (x86_64)。

4. **更新 appcast.xml**（Sparkle 自动更新源）
   - 用 `./sparkle-tools/sign_update CodeLight-vX.Y.Z.zip` 获取 EdDSA 签名
   - 在 `appcast.xml` 中添加新的 `<item>`，包含签名、文件大小、下载 URL
   - 提交并推送 appcast.xml

5. **验证**
   - 确认 GitHub Release 页面出现新版本
   - 确认 zip 可下载
   - 确认 appcast.xml 新版本条目指向正确的下载 URL
   - 运行 `lipo -info CodeLight.app/Contents/MacOS/CodeLight` 确认包含 `x86_64 arm64`

## 架构

- `main.swift` — 入口，创建 AppDelegate 和 status bar
- `CodeLight.swift` — 核心：LightServer (NWListener HTTP)、灯窗口管理、设置面板、Hook 生成、权限气泡
- `Config.swift` — AppConfig (UserDefaults 持久化)、状态定义 STATES、城市列表
- `UI.swift` — 纯绘制：ShellView、RealTrafficLightView、吉祥物绘制、TimelineView
- `Weather.swift` — Open-Meteo 天气 API、WeatherView 渐变背景
- `HotkeyManager.swift` — 全局快捷键管理（NSEvent monitor）
- `MenuBuilder.swift` — macOS 标准应用菜单（关于/偏好设置/视图/窗口/帮助）
- `PermissionBubble.swift` — 权限请求气泡弹窗
- `HookConfig.swift` — Claude Code Hook 配置管理
- `LightWindowBuilder.swift` — 灯窗口构建
- `LightAnimator.swift` — 灯动画逻辑
- `WebDAVSync.swift` — WebDAV 配置同步
- `SettingsUI.swift` — 设置面板组件（SettingsRowView、SettingsGroupView、NSSwitch 开关）
- `SkillsManager.swift` — 技能管理：本地扫描、GitHub 远程发现、安装/卸载
- `SkillsTab.swift` — 设置面板「🧩 技能」标签页 UI（SettingsWindowController 扩展）
- `codelight-cli.swift` — CLI 终端工具（state/sessions/history/watch）
- `Makefile` — build/package/release 自动化

## 关键约束

- **macOS 13.0+**，Universal Binary 同时支持 arm64 和 x86_64
- 不能用 `cgPath`（macOS 14+），用 `NSBezierPath` + `draw()` 代替
- NSButton ��支持 `textColor`，用 `attributedTitle` 或 `contentTintColor`
- 非活跃灯用 `lampColor.withAlphaComponent(0.05~0.08)` 淡色，不用纯黑

## 安装与运行（单一来源）

- **唯一运行实例必须装在 `/Applications/CodeLight.app`**，避免开发版/安装版多份混淆
- 开发流程：`make build` → `make install`（拷贝到 /Applications 并刷新 LaunchServices）
- **禁止**在 `~/Downloads`、桌面、工作目录直接双击运行残留的旧 bundle
- 多份安装会导致：①改了不生效（点错 app）②LaunchServices 注册混乱（`open` 打不开）③状态栏出现多个图标
- 清理：`sudo rm -rf /Applications/CodeLight.app ~/Downloads/CodeLight.app`，只保留 /Applications 一份

## 设置面板规范

- macOS System Settings 风格：分组圆角卡片 + 右侧 NSSwitch 开关
- **所有控件即时生效**：切换即 `config.save()` + rebuild，无需保存按钮
- 使用 `SettingsUI.swift` 的 `SettingsRowView` + `SettingsGroupView` 组件
- **不带图标**（`SettingsRowView` 不传 `icon` 参数）
- 控件工厂方法：`makeToggle`、`makeSlider`、`makePopup`、`makeSegmented`
- 使用 `NSSwitch`（非 `NSButton.switch`）作为开关控件
- **所有 NSScrollView 必须隐藏滚动条**：`hasVerticalScroller = false`，支持滚动但不显示滚动条

## 多语言（i18n）

设置面板支持中/英双语切换，由 `L10n.swift`（轻量查表）+ `config.language`（auto/zh/en）驱动。

### 新增可见文案时必须做

- **所有用户可见的中文文案必须用 `L10n.s("中文")` 包裹**，不能直接写裸中文字面量
  ```swift
  // ✅ 正确
  SettingsRowView(title: L10n.s("服务端口"), accessory: portField)
  btn.title = L10n.s("测试连接")
  // ❌ 错误（英文模式下不会翻译）
  SettingsRowView(title: "服务端口", accessory: portField)
  ```
- 适用场景：`title:`、`withTitle:`、`placeholderString =`、`.stringValue =`、按钮 `.title =`、菜单项标题、`subtitle:` 等
- 高频/关键文案优先用枚举 key：`L10n.tr(.tabGeneral)`（编译期检查）

### 翻译表维护

- 新增中文文案后，在 `L10n.swift` 的 `dict`（中文→英文）里补对应翻译
- `L10n.s()` 找不到翻译时回退原中文，不会崩溃，但英文模式下会显示中文（需补全）
- 枚举表 `enumTable` 用于高频文案（状态名、tab 名、通用按钮）

### 语言切换机制

- 通用页「界面语言」下拉（跟随系统 / 中文 / English）
- 切换调用 `rebuildUI()` 实时重建设置面板（不重启 app）
- `L10n.update(preference:)` 在 app 启动时（`applicationDidFinishLaunching`）和切换时调用
- `language` 偏好持久化到 UserDefaults，并随云同步（toJSON/applyJSON）

### ⚠️ 红线

- **禁止新增裸中文字面量到 UI**：Code Review 必查 `title: "` / `withTitle: "` / `.title = "` 是否带 `L10n.s()`
- 纯英文/纯变量/技术术语（如 `Endpoint`、`Bucket`）可不包

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

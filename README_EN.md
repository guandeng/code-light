# CodeLight — AI Coding Assistant Traffic Light

**English** | [简体中文](./README.md) | [繁體中文](#繁體中文)

<p>
  <a href="https://github.com/guandeng/code-light/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_Download-v1.2.2-green?style=for-the-badge" alt="Download" />
  </a>
  <a href="https://github.com/guandeng/code-light/releases">
    <img src="https://img.shields.io/github/v/release/guandeng/code-light?style=flat-square&label=Release" alt="Release" />
  </a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" />
</p>

A macOS menu bar app that shows the working status of AI coding assistants (Claude Code / Codex / Cursor) in real time via a simulated traffic light.

Red light = executing, green light = task done — see at a glance where the AI is in its workflow.

## ✨ Features

### 🚦 Real-time Status Light

| Light | Status | Meaning |
|-------|--------|---------|
| 🟢 Solid Green | Idle | Task done, no current action |
| 🟡 Yellow Pulse | Thinking | AI reading code, analyzing logic |
| 🔴 Red Blink | Working | AI calling tools (Bash/Read/Edit, etc.) |
| 🔴 Red Slow Blink | Error | Session terminated abnormally |
| 🟡 Yellow Blink | Fixing | Tool call failed, retrying |
| 🔴 Red Blink | Waiting | Awaiting user permission approval |

### 🎨 Four Display Modes

| Mode | Description |
|------|-------------|
| Vertical | Classic 3-lamp vertical, compact |
| Horizontal | 3 lamps in a row, fits tight spaces |
| Mini | Single dot, ultra-minimal |
| Edge Bar | 10px thin bar, snaps to screen edge |

- Drag to screen edge to auto-snap; drag away to release
- Double-click to switch modes; window position is remembered
- Customizable opacity, size, blink speed

### 🐄 Five Mascots

Cow, cat, robot, horse, chicken — each with independent status animations (walking, dozing, hammering, fainting). Supports custom mascot images.

### 🌤️ Weather Theme

When enabled, the light window shows live weather animation: sunny, cloudy, rainy, snowy, thunderstorm — auto-switches day/night by city and time. Supports 20 Chinese cities.

### 🔔 Permission Bubble

When the AI requests permission, a WeChat-style chat bubble pops up showing tool name and command details, with Allow/Deny buttons. Three modes:

| Mode | Behavior |
|------|----------|
| 🔔 Popup Confirm | All requests pop a bubble, manual handling (default) |
| 🚀 Always Allow | All requests auto-approved |
| 📋 Rules-based | Matching rules auto-approve; others pop up |

### 📊 Work Statistics

- **Today**: active time, tool call count, session count
- **Status Distribution**: thinking/working/idle time ratio
- **Weekly Trend**: 7-day daily active time
- **Top 5 Tools**: most-used tools
- **Today's Timeline**: 24-hour colored timeline
- Data stored locally, 30-day retention with auto-cleanup

### 🧩 Skills Management

- **Installed**: scans local `~/.claude/skills/`, `~/.claude/commands/`
- **Discover**: browse & install from GitHub (Anthropic / Vercel / Microsoft Azure)
- Supports Git clone, local folder import, Zip import
- One-click install/uninstall, tag filtering

### 🔄 WebDAV Sync

Sync config across devices via WebDAV (Jianguoyun, etc.), supports auto-sync.

### ⬆️ Auto Update

Auto-check for updates via GitHub Releases API; pops up when a new version is available, one-click to download.

### 🌐 Multi-language (ZH / ZH-Hant / EN)

The settings panel supports **简体中文 / 繁體中文 / English**, switching in real time without restart.

**How to switch**:
1. Right-click the status bar light → Settings (or menu bar CodeLight → Preferences)
2. Go to the "⚙️ General" tab
3. Top "Interface Language" dropdown:
   - **Follow System** — auto-match macOS system language
   - **简体中文** / **繁體中文** / **English** — manual override
4. The UI switches immediately upon selection

> Light status names (Idle/Thinking/Working…), menus, field titles, stats page, etc. are all localized.

### ⌨️ Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧F15` | Show/Hide light window |
| `⌘⇧F14` | Switch display mode |
| `⌘,` | Open Settings |
| `⌘T` | Toggle window visibility |
| `⌘D` | Switch display mode |
| `⌘L` | Open today's timeline |
| `⌘R` | Reset window position |
| `⌘U` | Check for updates |

### 🖥️ CLI Tool

```bash
codelight            # Show current status
codelight sessions   # List all sessions
codelight history    # Recent status changes
codelight watch      # Continuous monitoring (1s refresh)
```

## 📸 Screenshots

<p align="center">
  <img src="images/t-h.png" width="280" alt="Horizontal mode" />
  <img src="images/t-l.png" width="280" alt="Vertical mode" />
  <img src="images/t-hong.png" width="280" alt="Working - Red" />
</p>

## 🚀 Quick Start

[**⬇️ Download Latest**](https://github.com/guandeng/code-light/releases/latest) (macOS 13.0+, Universal Binary for Apple Silicon + Intel)

Double-click `CodeLight.app` to run. If you see a "damaged" warning, run in terminal:

```bash
xattr -cr CodeLight.app
```

Open App Settings, go to the "Configure Hook" tab, check the tools you want to support (Claude Code / Codex / Cursor), and click "Apply Config" to write hooks automatically.

Or configure manually. The hook sends state via curl to the local server (`http://127.0.0.1:8866/api/state`), mapping PreToolUse→working, PostToolUse→thinking, Stop→idle. See the [Chinese README](./README.md#🚀-快速开始) for full JSON examples for each tool.

Once configured, the traffic light switches automatically as the AI starts working, finishes, or pauses to think.

## License

MIT

---

## 繁體中文

CodeLight 是一個 macOS 選單列小工具，用仿真交通號誌即時顯示 AI 程式設計助手（Claude Code / Codex / Cursor）的工作狀態。

紅燈亮起代表正在執行，綠燈亮了代表任務完成 — 一眼看出 AI 進度。

### 🌐 多語言切換

設定面板支援**簡體中文 / 繁體中文 / English**，即時切換無需重啟。

**切換方法**：
1. 右鍵狀態列紅綠燈 → 設定（或選單列 CodeLight → 偏好設定）
2. 進入「⚙️ 一般」標籤頁
3. 頂部「介面語言」下拉選擇：跟隨系統 / 簡體中文 / 繁體中文 / English
4. 選擇後介面立即切換

完整功能說明請見[簡體中文 README](./README.md)。

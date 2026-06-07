# CodeLight — AI 编程助手红绿灯

<p>
  <a href="https://github.com/guandeng/code-light/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_下载-v1.1.0-green?style=for-the-badge" alt="Download" />
  </a>
  <a href="https://github.com/guandeng/code-light/releases">
    <img src="https://img.shields.io/github/v/release/guandeng/code-light?style=flat-square&label=Release" alt="Release" />
  </a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" />
</p>

一个 macOS 菜单栏小工具，用仿真交通信号灯实时显示 AI 编程助手（Claude Code / Codex / Cursor）的工作状态。

红灯亮起说明正在执行，绿灯亮了说明任务完成 — 一眼就能看出 AI 干活干到哪了。

## 状态说明

| 灯效 | 状态 | 含义 |
|------|------|------|
| 🟢 绿灯常亮 | 空闲 | 任务完成，当前无操作 |
| 🟡 黄灯呼吸 | 思考中 | AI 正在读代码、分析逻辑 |
| 🔴 红灯快闪 | 执行中 | AI 正在调用工具（Bash/Read/Edit 等） |
| 🔴 红灯慢闪 | 报错 | 会话异常终止 |
| 🟡 黄灯闪烁 | 修复中 | 工具调用失败，正在重试 |

## 截图

<p align="center">
  <img src="images/t-h.png" width="280" alt="横版模式" />
  <img src="images/t-l.png" width="280" alt="纵版模式" />
  <img src="images/t-hong.png" width="280" alt="执行中 - 红灯" />
</p>
<p align="center">
  <img src="images/s-h.png" width="120" alt="竖模式" />
  <img src="images/s-l.png" width="120" alt="竖模式" />
  <img src="images/s-hong.png" width="120" alt="执行中 - 红灯" />
</p>


## 快速开始

[**⬇️ 下载最新版**](https://github.com/guandeng/code-light/releases/latest)（macOS 13.0+）

双击 `CodeLight.app` 即可运行。若提示"已损坏"，在终端执行：

```bash
xattr -cr CodeLight.app
```

打开 App 设置，切换到「配置 Hook」选项卡，勾选你要支持的工具（Claude Code / Codex / Cursor），点击「应用配置」即可一键写入。

也可以手动配置：

**Claude Code** — `~/.claude/settings.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing $CLAUDE_TOOL_NAME\", \"session_id\": \"$CLAUDE_SESSION_ID\"}' || echo '{}'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"$CLAUDE_SESSION_ID\"}' || echo '{}'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"$CLAUDE_SESSION_ID\"}' || echo '{}'"
          }
        ]
      }
    ]
  }
}
```

**Codex** — 两步配置：

1. `~/.codex/config.toml` 启用 hooks：
```toml
[features]
hooks = true
```

2. `~/.codex/hooks.json` 配置 hook（格式与 Claude Code 一致）：
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing\", \"session_id\": \"codex\"}' || echo '{}'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"codex\"}' || echo '{}'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"codex\"}' || echo '{}'"
          }
        ]
      }
    ]
  }
}
```

**Cursor** — `~/.cursor/settings.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"working\", \"message\": \"executing $CURSOR_TOOL_NAME\", \"session_id\": \"$CURSOR_SESSION_ID\"}' || echo '{}'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"thinking\", \"message\": \"analyzing\", \"session_id\": \"$CURSOR_SESSION_ID\"}' || echo '{}'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://127.0.0.1:8866/api/state -H 'Content-Type: application/json' -d '{\"state\": \"idle\", \"message\": \"done\", \"session_id\": \"$CURSOR_SESSION_ID\"}' || echo '{}'"
          }
        ]
      }
    ]
  }
}
```

配置完成后，AI 助手开始工作、完成工作、或停下来思考时，红绿灯会自动切换。

## 权限处理模式

设置 →「🚀 总是运行」选项卡提供三种权限处理模式：

| 模式 | 行为 |
|------|------|
| 🔔 弹窗确认 | 所有权限请求弹出气泡，手动允许或拒绝（默认） |
| 🚀 总是运行 | 所有权限请求自动通过，不弹窗 |
| 📋 规则运行 | 匹配规则的命令自动通过，其余弹窗确认 |

### 规则运行

规则存储在 `~/.codelight/config`，格式为命令前缀匹配：

```
allow git
allow ls
allow cat
allow go
allow make
```

规则 `git` 会自动匹配 `git status`、`git log`、`git commit` 等所有以 `git` 开头的命令。

也可以直接编辑配置文件，或在设置界面通过芯片标签式 UI 添加/删除规则。

## 权限气泡

当 AI 助手请求权限时（如执行 Bash 命令），CodeLight 会在红绿灯旁弹出微信风格聊天气泡：

- 自动根据红绿灯位置决定气泡方向（左/右）
- 显示工具名和命令详情
- 提供允许/拒绝按钮
- 35 秒超时自动关闭

## License

MIT

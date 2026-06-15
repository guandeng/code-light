import Cocoa

// ============================================================
// AppDelegate — 菜单构建扩展
// ============================================================

extension AppDelegate {

    func buildAppMainMenu() {
        let mainMenu = NSMenu()
        let appName = "CodeLight"

        // —— CodeLight 应用菜单 ——
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem(); appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // —— 文件菜单 ——
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "重置窗口位置", action: #selector(resetWindowPosition), keyEquivalent: "r")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileMenuItem = NSMenuItem(); fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // —— 视图菜单 ——
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(withTitle: "显示/隐藏灯", action: #selector(toggleWindow), keyEquivalent: "t")
        viewMenu.addItem(withTitle: "切换显示模式", action: #selector(handleDoubleClick(_:)), keyEquivalent: "d")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "今日工作时间线", action: #selector(openTimeline), keyEquivalent: "l")
        let viewMenuItem = NSMenuItem(); viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // —— 窗口菜单 ——
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem(); windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // —— 帮助菜单 ——
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(withTitle: "\(appName) 帮助", action: #selector(openGitHub), keyEquivalent: "")
        let checkUpdateItem = helpMenu.addItem(withTitle: "检查更新...", action: #selector(AppDelegate.checkForGHUpdate), keyEquivalent: "")
        let helpMenuItem = NSMenuItem(); helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func showAbout() {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let icon = drawMenuIcon(state: "idle")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CodeLight",
            .applicationIcon: icon,
            .applicationVersion: "版本 \(ver)",
            .version: ver,
        ])
    }

    func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = drawMenuIcon(state: "idle")
            button.image?.isTemplate = false
            button.toolTip = "CodeLight — 空闲"
        }
        let menu = NSMenu()

        // 应用名称 + 版本（不可点击）
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let titleItem = NSMenuItem(title: "CodeLight v\(ver)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        // 状态标题（不可点击）
        let stateItem = NSMenuItem(title: "● 空闲", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "显示/隐藏", action: #selector(toggleWindow), keyEquivalent: "w")
        menu.addItem(withTitle: "设置...", action: #selector(openSettings), keyEquivalent: ",")

        // 显示样式子菜单
        let modeMenu = NSMenu(title: "显示样式")
        let modes = [("vertical", "竖向"), ("horizontal", "横向"), ("mini", "迷你"), ("edgebar", "边缘栏")]
        for (idx, (key, label)) in modes.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(switchDisplayMode(_:)), keyEquivalent: "")
            item.tag = idx
            if config.displayMode == key { item.state = .on }
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "显示样式", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(withTitle: "重置窗口位置", action: #selector(resetWindowPosition), keyEquivalent: "r")
        menu.addItem(withTitle: "今日工作时间线", action: #selector(openTimeline), keyEquivalent: "l")
        menu.addItem(NSMenuItem.separator())
        let statusCheckUpdateItem = menu.addItem(withTitle: "检查更新...", action: #selector(AppDelegate.checkForGHUpdate), keyEquivalent: "u")
        menu.addItem(withTitle: "GitHub", action: #selector(openGitHub), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 CodeLight", action: #selector(quitApp), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    func drawMenuIcon(state: String) -> NSImage {
        let s: CGFloat = 22
        let img = config.horizontal
            ? NSImage(size: NSSize(width: s * 1.4, height: s))
            : NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

        let w = img.size.width, h = img.size.height
        let lampR: CGFloat = 3.2

        // 国标色值
        let red = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)
        let yellow = NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 1.0)
        let green = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 1.0)
        let dimRed = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 0.25)
        let dimYellow = NSColor(red: 1.0, green: 0.92, blue: 0.0, alpha: 0.25)
        let dimGreen = NSColor(red: 0.0, green: 0.70, blue: 0.16, alpha: 0.25)

        let redOn = state == "working" || state == "error"
        let yellowOn = state == "thinking" || state == "fixing"
        let greenOn = state == "idle"

        if config.horizontal {
            // 横向：红(左)、黄(中)、绿(右)
            let cy = h / 2
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1.0).cgColor)
            let shell = NSBezierPath(roundedRect: NSRect(x: 1, y: cy - 5.5, width: w - 2, height: 11), xRadius: 4, yRadius: 4)
            shell.fill()
            let lamps: [(CGFloat, Bool, NSColor, NSColor)] = [
                (5.5, redOn, red, dimRed),
                (w / 2, yellowOn, yellow, dimYellow),
                (w - 5.5, greenOn, green, dimGreen),
            ]
            for (cx, isOn, onColor, offColor) in lamps {
                let path = CGPath(ellipseIn: CGRect(x: cx - lampR, y: cy - lampR, width: lampR * 2, height: lampR * 2), transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(isOn ? onColor.cgColor : offColor.cgColor)
                ctx.fillPath()
            }
        } else {
            // 竖向：红(上)、黄(中)、绿(下)
            let cx = w / 2
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1.0).cgColor)
            let shell = NSBezierPath(roundedRect: NSRect(x: cx - 5.5, y: 1, width: 11, height: h - 2), xRadius: 4, yRadius: 4)
            shell.fill()
            let lamps: [(CGFloat, Bool, NSColor, NSColor)] = [
                (h - 5.5, redOn, red, dimRed),
                (h / 2, yellowOn, yellow, dimYellow),
                (5.5, greenOn, green, dimGreen),
            ]
            for (cy, isOn, onColor, offColor) in lamps {
                let path = CGPath(ellipseIn: CGRect(x: cx - lampR, y: cy - lampR, width: lampR * 2, height: lampR * 2), transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(isOn ? onColor.cgColor : offColor.cgColor)
                ctx.fillPath()
            }
        }

        img.unlockFocus()
        return img
    }
}

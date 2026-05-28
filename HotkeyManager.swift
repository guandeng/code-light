// CodeLight — 全局快捷键管理

import Cocoa

class HotkeyManager {
    static let shared = HotkeyManager()
    private var globalMonitors: [Any] = []

    // 默认快捷键
    var toggleKey: UInt16 = 125   // F15
    var toggleModifiers: NSEvent.ModifierFlags = [.command, .shift]
    var cycleKey: UInt16 = 126    // F14
    var cycleModifiers: NSEvent.ModifierFlags = [.command, .shift]

    var onToggleWindow: (() -> Void)?
    var onCycleMode: (() -> Void)?

    private init() {}

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.keyDown]
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        globalMonitors.append(monitor)
        // App 内部的按键也需要监听
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        globalMonitors.append(localMonitor)
    }

    func stop() {
        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = event.keyCode

        // Cmd+Shift+F15 → 显示/隐藏
        if code == toggleKey && mods == toggleModifiers {
            onToggleWindow?()
        }
        // Cmd+Shift+F14 → 切换模式
        if code == cycleKey && mods == cycleModifiers {
            onCycleMode?()
        }
    }
}

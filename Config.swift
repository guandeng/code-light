import Cocoa
import Foundation

// ============================================================
// CodeLight — 配置与共享类型
// ============================================================

struct AppConfig {
    var serverURL = "http://127.0.0.1:8866"
    var pollInterval = 0.5
    var opacity = 1.0
    var blinkSpeed = 0.6
    var autoLaunch = false
    var showInDock = true
    var isFloating = true
    var notifyOnDone = true
    var showOnFullscreen = true
    var horizontal = false
    var displayMode: String = "vertical"  // "vertical" | "horizontal" | "mini"
    var showStatusText = true
    var windowSize: Double = 40
    var windowX: Double?
    var windowY: Double?
    var edgeBar: String?  // "left" | "right" | nil
    var mascotType: String = "cow"  // "cow" | "cat" | "robot"
    var theme: String = "dark"     // "dark" | "light" | "custom"
    var customColor: String = "#1C1E22"
    var weatherThemeEnabled: Bool = false
    var weatherCity: String = "深圳"
    var hookSetupDismissed = false

    static func load() -> AppConfig {
        let ud = UserDefaults.standard
        var c = AppConfig()
        if let v = ud.string(forKey: "serverURL") { c.serverURL = v }
        if ud.double(forKey: "pollInterval") > 0 { c.pollInterval = ud.double(forKey: "pollInterval") }
        if ud.double(forKey: "opacity") > 0 { c.opacity = ud.double(forKey: "opacity") }
        if ud.double(forKey: "blinkSpeed") > 0 { c.blinkSpeed = ud.double(forKey: "blinkSpeed") }
        if let v = ud.string(forKey: "theme") { c.theme = v }
        c.autoLaunch = ud.bool(forKey: "autoLaunch")
        c.showInDock = ud.bool(forKey: "showInDock")
        if ud.object(forKey: "isFloating") != nil { c.isFloating = ud.bool(forKey: "isFloating") }
        if ud.object(forKey: "notifyOnDone") != nil { c.notifyOnDone = ud.bool(forKey: "notifyOnDone") }
        if ud.object(forKey: "showOnFullscreen") != nil { c.showOnFullscreen = ud.bool(forKey: "showOnFullscreen") }
        if ud.object(forKey: "horizontal") != nil { c.horizontal = ud.bool(forKey: "horizontal") }
        if let v = ud.string(forKey: "displayMode") { c.displayMode = v }
        else if c.horizontal { c.displayMode = "horizontal" }
        if ud.object(forKey: "showStatusText") != nil { c.showStatusText = ud.bool(forKey: "showStatusText") }
        if ud.double(forKey: "windowSize") > 0 { c.windowSize = ud.double(forKey: "windowSize") }
        if ud.object(forKey: "windowX") != nil { c.windowX = ud.double(forKey: "windowX") }
        if ud.object(forKey: "windowY") != nil { c.windowY = ud.double(forKey: "windowY") }
        if let v = ud.string(forKey: "edgeBar") { c.edgeBar = v }
        if let v = ud.string(forKey: "mascotType") { c.mascotType = v }
        if let v = ud.string(forKey: "theme") { c.theme = v }
        if let v = ud.string(forKey: "customColor") { c.customColor = v }
        if ud.object(forKey: "weatherThemeEnabled") != nil { c.weatherThemeEnabled = ud.bool(forKey: "weatherThemeEnabled") }
        if let v = ud.string(forKey: "weatherCity") { c.weatherCity = v }
        c.hookSetupDismissed = ud.bool(forKey: "hookSetupDismissed")
        return c
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(serverURL, forKey: "serverURL")
        ud.set(pollInterval, forKey: "pollInterval")
        ud.set(opacity, forKey: "opacity")
        ud.set(blinkSpeed, forKey: "blinkSpeed")
        ud.set(theme, forKey: "theme")
        ud.set(autoLaunch, forKey: "autoLaunch")
        ud.set(showInDock, forKey: "showInDock")
        ud.set(isFloating, forKey: "isFloating")
        ud.set(notifyOnDone, forKey: "notifyOnDone")
        ud.set(showOnFullscreen, forKey: "showOnFullscreen")
        ud.set(horizontal, forKey: "horizontal")
        ud.set(displayMode, forKey: "displayMode")
        ud.set(showStatusText, forKey: "showStatusText")
        ud.set(windowSize, forKey: "windowSize")
        if let x = windowX { ud.set(x, forKey: "windowX") }
        if let y = windowY { ud.set(y, forKey: "windowY") }
        if let v = edgeBar { ud.set(v, forKey: "edgeBar") } else { ud.removeObject(forKey: "edgeBar") }
        ud.set(mascotType, forKey: "mascotType")
        ud.set(theme, forKey: "theme")
        ud.set(customColor, forKey: "customColor")
        ud.set(weatherThemeEnabled, forKey: "weatherThemeEnabled")
        ud.set(weatherCity, forKey: "weatherCity")
        ud.set(hookSetupDismissed, forKey: "hookSetupDismissed")
    }
}

struct LightStateDef {
    let red: Bool; let yellow: Bool; let green: Bool; let blink: Bool; let label: String
}

let STATES: [String: LightStateDef] = [
    "idle":     LightStateDef(red: false, yellow: false, green: true,  blink: false, label: "空闲中"),
    "thinking": LightStateDef(red: false, yellow: true,  green: false, blink: false, label: "思考中"),
    "working":  LightStateDef(red: true,  yellow: false, green: false, blink: true,  label: "执行中"),
    "fixing":   LightStateDef(red: false, yellow: true,  green: false, blink: true,  label: "修复中"),
    "error":    LightStateDef(red: true,  yellow: false, green: false, blink: false, label: "警告中"),
]

let SEVERITY = ["error": 4, "working": 3, "fixing": 3, "thinking": 2, "idle": 0]

let CITIES: [(name: String, lat: Double, lon: Double)] = [
    ("北京", 39.90, 116.40), ("上海", 31.23, 121.47), ("广州", 23.13, 113.26),
    ("深圳", 22.55, 114.10), ("杭州", 30.27, 120.15), ("成都", 30.57, 104.07),
    ("武汉", 30.59, 114.31), ("南京", 32.06, 118.80), ("重庆", 29.56, 106.55),
    ("西安", 34.26, 108.94), ("苏州", 31.30, 120.62), ("天津", 39.13, 117.20),
    ("长沙", 28.23, 112.94), ("郑州", 34.75, 113.65), ("青岛", 36.07, 120.38),
    ("大连", 38.91, 121.60), ("厦门", 24.48, 118.09), ("昆明", 25.04, 102.68),
    ("哈尔滨", 45.75, 126.65), ("沈阳", 41.80, 123.43),
]

extension NSColor {
    convenience init?(fromHex hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green: CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(v & 0xFF) / 255.0,
                  alpha: 1.0)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

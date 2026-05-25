// CodeLight — 天气主题

import Cocoa
import CoreLocation
import Foundation

// ============================================================
// WeatherManager — Open-Meteo 天气数据获取
// ============================================================

enum WeatherCondition: String {
    case sunny = "sunny"
    case cloudy = "cloudy"
    case rainy = "rainy"
    case snowy = "snowy"
    case thunderstorm = "thunderstorm"

    // 天气强度 0.0~1.0，影响粒子大小/速度/密度
    var intensity: Double {
        switch self {
        case .sunny: return 0.5
        case .cloudy: return 0.3
        case .rainy: return 0.6
        case .snowy: return 0.5
        case .thunderstorm: return 1.0
        }
    }

    static func from(code: Int) -> WeatherCondition {
        switch code {
        case 0: return .sunny
        case 1...3: return .cloudy
        case 45...48: return .cloudy      // 雾
        case 51...55: return .rainy       // 毛毛雨~细雨 (intensity 低)
        case 56...57: return .rainy       // 冻毛毛雨
        case 61...63: return .rainy       // 小雨~中雨
        case 65: return .rainy            // 大雨
        case 66...67: return .rainy       // 冻雨
        case 71...73: return .snowy       // 小雪~中雪
        case 75...77: return .snowy       // 大雪/雪粒
        case 80: return .rainy            // 小阵雨
        case 81: return .rainy            // 中阵雨
        case 82: return .rainy            // 大阵雨 (intensity 高)
        case 85: return .snowy            // 小阵雪
        case 86: return .snowy            // 大阵雪
        case 95: return .thunderstorm     // 雷暴
        case 96...99: return .thunderstorm // 雷暴+冰雹
        default: return .cloudy
        }
    }

    /// 根据 weather code 返回带强度的显示名
    func displayName(code: Int) -> String {
        switch self {
        case .sunny: return "☀️ 晴天"
        case .cloudy:
            switch code {
            case 45...48: return "🌫️ 雾"
            default: return "☁️ 多云"
            }
        case .rainy:
            switch code {
            case 51...55: return "🌦️ 毛毛雨"
            case 56...57: return "🌧️ 冻毛毛雨"
            case 61: return "🌦️ 小雨"
            case 63: return "🌧️ 中雨"
            case 65: return "🌧️ 大雨"
            case 66...67: return "🌧️ 冻雨"
            case 80: return "🌦️ 阵雨"
            case 81: return "🌧️ 中阵雨"
            case 82: return "⛈️ 暴雨"
            default: return "🌧️ 雨天"
            }
        case .snowy:
            switch code {
            case 71: return "🌨️ 小雪"
            case 73: return "❄️ 中雪"
            case 75...77: return "❄️ 大雪"
            case 85: return "🌨️ 阵雪"
            case 86: return "❄️ 暴雪"
            default: return "❄️ 雪天"
            }
        case .thunderstorm:
            switch code {
            case 95: return "⛈️ 雷暴"
            case 96...99: return "⛈️ 冰雹"
            default: return "⛈️ 雷暴"
            }
        }
    }

    var displayName: String { displayName(code: 0) }

    /// weather code → 强度 0.0~1.0
    static func intensityFrom(code: Int) -> Double {
        switch code {
        case 0: return 0.5
        case 1: return 0.2
        case 2: return 0.4
        case 3: return 0.7
        case 45...48: return 0.3
        case 51: return 0.15   // 毛毛雨
        case 53: return 0.3   // 细雨
        case 55: return 0.4   // 密毛毛雨
        case 56...57: return 0.35
        case 61: return 0.35  // 小雨
        case 63: return 0.6   // 中雨
        case 65: return 0.9   // 大雨
        case 66...67: return 0.5
        case 71: return 0.3   // 小雪
        case 73: return 0.55  // 中雪
        case 75: return 0.85  // 大雪
        case 77: return 0.7
        case 80: return 0.3   // 小阵雨
        case 81: return 0.6   // 中阵雨
        case 82: return 1.0   // 暴雨
        case 85: return 0.3   // 小阵雪
        case 86: return 0.9   // 大阵雪
        case 95: return 0.8   // 雷暴
        case 96...99: return 1.0
        default: return 0.4
        }
    }
}

// 双击手势辅助视图
class DoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

class WeatherManager: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherManager()
    private var locationManager: CLLocationManager?
    private var timer: Timer?
    var currentCondition: WeatherCondition = .sunny
    var currentTemp: Double = 0
    var weatherCode: Int = 0
    var onWeatherUpdate: ((WeatherCondition, Double) -> Void)?

    private override init() {
        super.init()
    }

    func startPolling() {
        if locationManager == nil {
            let lm = CLLocationManager()
            lm.delegate = self
            lm.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager = lm
        }
        locationManager?.requestLocation()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.locationManager?.requestLocation()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        fetchWeather(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fetchWeather(lat: 39.9, lon: 116.4)
    }

    private func fetchWeather(lat: Double, lon: Double) {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true"
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let current = json["current_weather"] as? [String: Any],
                   let code = current["weathercode"] as? Int,
                   let temp = current["temperature"] as? Double {
                    DispatchQueue.main.async {
                        self.weatherCode = code
                        self.currentTemp = temp
                        self.currentCondition = WeatherCondition.from(code: code)
                        self.onWeatherUpdate?(self.currentCondition, temp)
                    }
                }
            } catch { }
        }.resume()
    }
}

// ============================================================
// WeatherView — 天气动画背景层
// ============================================================

class WeatherView: NSView {
    var condition: WeatherCondition = .sunny {
        didSet { updateWeather() }
    }
    var weatherCode: Int = 0 {
        didSet { updateWeather() }
    }

    private var intensity: Double { WeatherCondition.intensityFrom(code: weatherCode) }
    private var gradientLayer: CAGradientLayer?
    private var lightningTimer: Timer?
    private var rainTimer: Timer?
    private var snowTimer: Timer?
    private var miscTimer: Timer?
    private var particleLayers: [CAShapeLayer] = []
    private var cleanupCounter: Int = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        updateWeather()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func clearLayers() {
        for p in particleLayers {
            p.removeAllAnimations()
            p.removeFromSuperlayer()
        }
        particleLayers.removeAll()
        gradientLayer?.removeFromSuperlayer()
        gradientLayer = nil
        lightningTimer?.invalidate(); lightningTimer = nil
        rainTimer?.invalidate(); rainTimer = nil
        snowTimer?.invalidate(); snowTimer = nil
        miscTimer?.invalidate(); miscTimer = nil
    }

    private func updateWeather() {
        clearLayers()
        guard let layer = layer else { return }
        let I = intensity  // 0.0~1.0

        let grad = CAGradientLayer()
        grad.frame = bounds
        grad.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        switch condition {
        case .sunny:
            grad.colors = [
                NSColor(red: 0.30, green: 0.55, blue: 0.88, alpha: 0.6).cgColor,
                NSColor(red: 0.85, green: 0.70, blue: 0.35, alpha: 0.4).cgColor,
            ]
            addSunGlows()
        case .cloudy:
            let dark = 0.65 - I * 0.15
            grad.colors = [
                NSColor(white: dark + 0.1, alpha: 0.5).cgColor,
                NSColor(white: dark, alpha: 0.4).cgColor,
            ]
            addCloudDrifts()
        case .rainy:
            // 小雨亮一点，暴雨暗很多
            let top = 0.45 - I * 0.25  // 0.45(毛毛雨) → 0.20(暴雨)
            let bot = 0.35 - I * 0.25  // 0.35 → 0.10
            grad.colors = [
                NSColor(white: top, alpha: 0.6).cgColor,
                NSColor(white: bot, alpha: 0.5).cgColor,
            ]
            addRain()
        case .snowy:
            let alpha = 0.3 + I * 0.25
            grad.colors = [
                NSColor(red: 0.72, green: 0.80, blue: 0.92, alpha: alpha).cgColor,
                NSColor(white: 0.92, alpha: alpha - 0.1).cgColor,
            ]
            addSnow()
        case .thunderstorm:
            grad.colors = [
                NSColor(white: 0.12, alpha: 0.7).cgColor,
                NSColor(white: 0.08, alpha: 0.6).cgColor,
            ]
            addRain()
            startLightning()
        }

        layer.insertSublayer(grad, at: 0)
        gradientLayer = grad
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
    }

    private func cleanupParticles() {
        cleanupCounter += 1
        if cleanupCounter % 20 == 0 {
            particleLayers.removeAll { $0.superlayer == nil }
        }
        if particleLayers.count > 200 {
            let excess = particleLayers.prefix(particleLayers.count - 200)
            for p in excess { p.removeFromSuperlayer() }
            particleLayers.removeFirst(particleLayers.count - 200)
        }
    }

    // MARK: - Rain

    private func addRain() {
        let I = intensity
        // 小雨稀疏(10颗, 0.12s间隔), 大雨密集(40颗, 0.03s间隔)
        let burstCount = Int(10 + I * 30)
        let spawnBatch = max(1, Int(1 + I * 5))
        let interval = 0.14 - I * 0.11  // 0.14s → 0.03s

        for _ in 0..<burstCount { spawnRainDrop() }
        rainTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            guard let self = self, self.condition == .rainy || self.condition == .thunderstorm else { return }
            for _ in 0..<spawnBatch { self.spawnRainDrop() }
            self.cleanupParticles()
        }
    }

    private func spawnRainDrop() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let I = intensity

        let drop = CAShapeLayer()
        // 小雨: 细短(4~8px), 大雨: 粗长(10~24px)
        let dropH = CGFloat.random(in: (4 + I * 6)...(8 + I * 16))
        let dropW = CGFloat.random(in: (0.8 + I * 0.5)...(1.2 + I * 1.5))
        drop.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: dropW, height: dropH),
                           cornerWidth: dropW / 2, cornerHeight: dropW / 2, transform: nil)
        // 小雨浅蓝透明, 大雨深蓝浓
        let alphaMin = 0.15 + I * 0.25
        let alphaMax = 0.35 + I * 0.45
        let blueShift = 0.85 + I * 0.15  // 大雨更蓝
        drop.fillColor = NSColor(red: 0.45, green: 0.55, blue: blueShift,
                                  alpha: CGFloat.random(in: alphaMin...alphaMax)).cgColor

        let startX = CGFloat.random(in: -10...(w + 10))
        let startY = h + CGFloat.random(in: 10...40)
        drop.bounds = CGRect(x: 0, y: 0, width: dropW, height: dropH)
        drop.position = CGPoint(x: startX, y: startY)
        layer?.addSublayer(drop)
        particleLayers.append(drop)

        // 小雨慢(1.5~2.5s), 大雨快(0.4~0.9s)
        let durMin = 1.8 - I * 1.4   // 1.8s → 0.4s
        let durMax = 2.8 - I * 1.9   // 2.8s → 0.9s
        let duration = TimeInterval.random(in: max(durMin, 0.3)...max(durMax, 0.5))

        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = startY
        fall.toValue = -30
        fall.duration = duration
        fall.timingFunction = CAMediaTimingFunction(name: .linear)

        // 大雨风偏更大
        let windMax = 5 + I * 20
        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = startX
        drift.toValue = startX + CGFloat.random(in: -2...windMax)
        drift.duration = duration
        drift.timingFunction = CAMediaTimingFunction(name: .linear)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        // 大雨快到底才消失, 小雨中途就淡出
        let fadeStart = 0.5 + I * 0.35
        fade.beginTime = duration * fadeStart
        fade.duration = duration * (1.0 - fadeStart)

        let group = CAAnimationGroup()
        group.animations = [fall, drift, fade]
        group.duration = duration
        group.isRemovedOnCompletion = true
        drop.add(group, forKey: "rainFall")
    }

    // MARK: - Snow

    private func addSnow() {
        let I = intensity
        let burstCount = Int(5 + I * 20)
        let interval = 0.25 - I * 0.15  // 0.25s → 0.10s

        for _ in 0..<burstCount { spawnSnowFlake() }
        snowTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(interval, 0.08)), repeats: true) { [weak self] _ in
            guard let self = self, self.condition == .snowy else { return }
            self.spawnSnowFlake()
            self.cleanupParticles()
        }
    }

    private func spawnSnowFlake() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let I = intensity

        let flake = CAShapeLayer()
        // 小雪: 小雪花(1.5~3), 大雪: 大雪花(3~8)
        let r = CGFloat.random(in: (1.5 + I * 1.5)...(3 + I * 5))
        let path = CGMutablePath()
        let arms = Int.random(in: 4...6)
        for i in 0..<arms {
            let angle = CGFloat(i) * (2 * .pi / CGFloat(arms))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: cos(angle) * r, y: sin(angle) * r))
        }
        flake.path = path
        let alphaMin = 0.25 + I * 0.3
        let alphaMax = 0.5 + I * 0.4
        flake.strokeColor = NSColor.white.withAlphaComponent(CGFloat.random(in: alphaMin...alphaMax)).cgColor
        flake.fillColor = nil
        flake.lineWidth = CGFloat.random(in: (0.6 + I * 0.4)...(1.0 + I * 1.0))

        let startX = CGFloat.random(in: -10...(w + 10))
        let startY = h + CGFloat.random(in: 5...20)
        flake.bounds = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        flake.position = CGPoint(x: startX, y: startY)
        layer?.addSublayer(flake)
        particleLayers.append(flake)

        // 小雪飘得慢(3~6s), 大雪飘得快(1.5~3.5s)
        let durMin = 3.5 - I * 2.0   // 3.5s → 1.5s
        let durMax = 6.0 - I * 2.5   // 6.0s → 3.5s
        let duration = TimeInterval.random(in: max(durMin, 1.0)...max(durMax, 2.0))
        let endY: CGFloat = -20
        let swayAmount = CGFloat.random(in: (5 + I * 5)...(15 + I * 25))

        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = startY
        fall.toValue = endY
        fall.duration = duration
        fall.timingFunction = CAMediaTimingFunction(name: .linear)

        let sway = CAKeyframeAnimation(keyPath: "position.x")
        var vals = [CGFloat]()
        for i in 0...6 {
            let t = CGFloat(i) / 6.0
            vals.append(startX + sin(t * .pi * 2 + startX * 0.1) * swayAmount)
        }
        sway.values = vals
        sway.duration = duration

        let rotate = CABasicAnimation(keyPath: "transform.rotation")
        rotate.fromValue = 0
        rotate.toValue = CGFloat.random(in: -(.pi)...(.pi))
        rotate.duration = duration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = duration * 0.75
        fade.duration = duration * 0.25

        let group = CAAnimationGroup()
        group.animations = [fall, sway, rotate, fade]
        group.duration = duration
        group.isRemovedOnCompletion = true
        flake.add(group, forKey: "snowFall")
    }

    // MARK: - Sun glows

    private func addSunGlows() {
        for _ in 0..<6 { spawnSunGlow() }
        miscTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self, self.condition == .sunny else { return }
            self.spawnSunGlow()
            self.cleanupParticles()
        }
    }

    private func spawnSunGlow() {
        let w = bounds.width, h = bounds.height
        let glow = CAShapeLayer()
        let r = CGFloat.random(in: 4...12)
        glow.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        glow.fillColor = NSColor(red: 1.0, green: 0.9, blue: 0.4, alpha: CGFloat.random(in: 0.2...0.5)).cgColor

        let cx = w * 0.8, cy = h * 0.8
        let startX = cx + CGFloat.random(in: -20...20)
        let startY = cy + CGFloat.random(in: -20...20)
        glow.position = CGPoint(x: startX, y: startY)
        layer?.addSublayer(glow)
        particleLayers.append(glow)

        let duration = TimeInterval.random(in: 1.5...3.0)

        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 0.5
        expand.toValue = 2.5
        expand.duration = duration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = duration

        let drift = CABasicAnimation(keyPath: "position.y")
        drift.fromValue = startY
        drift.toValue = startY + CGFloat.random(in: -15...(-5))
        drift.duration = duration

        let group = CAAnimationGroup()
        group.animations = [expand, fade, drift]
        group.duration = duration
        group.isRemovedOnCompletion = true
        glow.add(group, forKey: "sunGlow")
    }

    // MARK: - Cloud drifts

    private func addCloudDrifts() {
        for _ in 0..<3 { spawnCloud() }
        miscTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, self.condition == .cloudy else { return }
            self.spawnCloud()
            self.cleanupParticles()
        }
    }

    private func spawnCloud() {
        let w = bounds.width, h = bounds.height
        let cloud = CAShapeLayer()
        let cw = CGFloat.random(in: 30...60)
        let ch = cw * 0.4
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 0, y: ch * 0.2, width: cw * 0.4, height: ch * 0.6))
        path.addEllipse(in: CGRect(x: cw * 0.25, y: 0, width: cw * 0.5, height: ch * 0.8))
        path.addEllipse(in: CGRect(x: cw * 0.5, y: ch * 0.15, width: cw * 0.45, height: ch * 0.65))
        cloud.path = path
        cloud.fillColor = NSColor(white: 1.0, alpha: CGFloat.random(in: 0.08...0.18)).cgColor

        let startY = CGFloat.random(in: h * 0.2...h * 0.8)
        cloud.position = CGPoint(x: -cw, y: startY)
        layer?.addSublayer(cloud)
        particleLayers.append(cloud)

        let duration = TimeInterval.random(in: 8...15)

        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = -cw
        drift.toValue = w + cw + 40
        drift.duration = duration
        drift.timingFunction = CAMediaTimingFunction(name: .linear)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = duration * 0.7
        fade.duration = duration * 0.3

        let group = CAAnimationGroup()
        group.animations = [drift, fade]
        group.duration = duration
        group.isRemovedOnCompletion = true
        cloud.add(group, forKey: "cloudDrift")
    }

    // MARK: - Lightning

    private func startLightning() {
        lightningTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.flashLightning()
        }
    }

    private func flashLightning() {
        guard let layer = layer else { return }
        let flash1 = CABasicAnimation(keyPath: "backgroundColor")
        flash1.fromValue = NSColor(white: 1.0, alpha: 0.5).cgColor
        flash1.toValue = layer.backgroundColor
        flash1.duration = 0.08
        flash1.autoreverses = true

        let flash2 = CABasicAnimation(keyPath: "backgroundColor")
        flash2.fromValue = NSColor(white: 1.0, alpha: 0.35).cgColor
        flash2.toValue = layer.backgroundColor
        flash2.duration = 0.12
        flash2.beginTime = 0.2
        flash2.autoreverses = true

        let group = CAAnimationGroup()
        group.animations = [flash1, flash2]
        group.duration = 0.4
        layer.add(group, forKey: "lightning")
    }
}

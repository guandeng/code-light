// CodeLight — UI 组件
import Cocoa

// ============================================================

class TrafficLightContainer: NSView {
    var redView: RealTrafficLightView!
    var yellowView: RealTrafficLightView!
    var greenView: RealTrafficLightView!
    var isHorizontal = false
    var showStatusText = true
    var mascotType: String = "cow" {
        didSet { redView?.mascotType = mascotType; yellowView?.mascotType = mascotType; greenView?.mascotType = mascotType }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        if isHorizontal {
            layoutHorizontal(w: w, h: h)
        } else {
            layoutVertical(w: w, h: h)
        }
    }

    private func layoutVertical(w: CGFloat, h: CGFloat) {
        let bottomBar: CGFloat = showStatusText ? 26 : 0
        let padding: CGFloat = min(w * 0.12, 18)
        let gap: CGFloat = min(w * 0.08, 14)
        let availH = h - bottomBar - padding * 2
        let availW = w - padding * 2

        let maxDiam = min(availW, (availH - gap * 2) / 3)
        let diam = max(maxDiam, 20)

        let cx = w / 2
        let gy = bottomBar + padding
        let yy = gy + diam + gap
        let ry = yy + diam + gap

        greenView.frame = NSRect(x: cx - diam/2, y: gy, width: diam, height: diam)
        yellowView.frame = NSRect(x: cx - diam/2, y: yy, width: diam, height: diam)
        redView.frame = NSRect(x: cx - diam/2, y: ry, width: diam, height: diam)
    }

    private func layoutHorizontal(w: CGFloat, h: CGFloat) {
        let bottomBar: CGFloat = showStatusText ? 26 : 0
        let padding: CGFloat = min(h * 0.12, 18)
        let gap: CGFloat = min(h * 0.08, 14)
        let availH = h - bottomBar - padding * 2
        let availW = w - padding * 2

        let maxDiam = min(availH, (availW - gap * 2) / 3)
        let diam = max(maxDiam, 20)

        let cy = bottomBar + (h - bottomBar) / 2
        let rx = padding
        let yx = rx + diam + gap
        let gx = yx + diam + gap

        redView.frame = NSRect(x: rx, y: cy - diam/2, width: diam, height: diam)
        yellowView.frame = NSRect(x: yx, y: cy - diam/2, width: diam, height: diam)
        greenView.frame = NSRect(x: gx, y: cy - diam/2, width: diam, height: diam)
    }
}

// ============================================================
// ShellView — 金属拉丝外壳
// ============================================================

class ShellView: NSView {
    var theme: String = "dark" { didSet { needsDisplay = true } }
    var customColor: NSColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let r = min(rect.width, rect.height) / 2

        let grad: NSGradient
        let borderColor: NSColor
        switch theme {
        case "light":
            grad = NSGradient(colors: [
                NSColor(white: 0.85, alpha: 1.0),
                NSColor(white: 0.72, alpha: 1.0),
                NSColor(white: 0.80, alpha: 1.0),
            ])!
            borderColor = NSColor(white: 0.6, alpha: 0.4)
        case "custom":
            let c = customColor
            let lighter = c.highlight(withLevel: 0.15) ?? c
            let darker = c.shadow(withLevel: 0.15) ?? c
            grad = NSGradient(colors: [lighter, darker, c])!
            borderColor = NSColor(white: 0.4, alpha: 0.3)
        default: // dark
            grad = NSGradient(colors: [
                NSColor(white: 0.18, alpha: 1.0),
                NSColor(white: 0.10, alpha: 1.0),
                NSColor(white: 0.14, alpha: 1.0),
            ])!
            borderColor = NSColor(white: 0.25, alpha: 0.3)
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        grad.draw(in: path, angle: 90)

        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        let ip = NSBezierPath(roundedRect: inner, xRadius: r - 1.5, yRadius: r - 1.5)
        borderColor.setStroke()
        ip.lineWidth = 1
        ip.stroke()
    }
}

// ============================================================
// RealTrafficLightView — 仿真灯珠
// ============================================================

class RealTrafficLightView: NSView {
    var lampColor: NSColor = .red {
        didSet { if !lampColor.isEqual(oldValue) { needsDisplay = true } }
    }
    var isOn: Bool = false {
        didSet {
            if isOn != oldValue {
                needsDisplay = true
                if isOn && !oldValue {
                    triggerBounce()
                }
            }
        }
    }
    var brightness: CGFloat = 1.0 {
        didSet {
            if abs(brightness - oldValue) > 0.01 { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    private func triggerBounce() {
        guard let layer = layer else { return }
        // Phase 1: 快速放大
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.0
        pop.toValue = 1.12
        pop.duration = 0.08
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pop.fillMode = .forwards
        pop.isRemovedOnCompletion = false

        // Phase 2: CASpringAnimation 弹回 1.0
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1.12
        spring.toValue = 1.0
        spring.damping = 10.0
        spring.stiffness = 400.0
        spring.mass = 0.3
        spring.initialVelocity = 0
        spring.beginTime = 0.08
        spring.duration = spring.settlingDuration
        spring.isRemovedOnCompletion = true
        spring.fillMode = .backwards

        let group = CAAnimationGroup()
        group.animations = [pop, spring]
        group.duration = 0.08 + spring.settlingDuration
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "lampBounce")
    }
    var mascotState: String = "idle" {
        didSet {
            if mascotState != oldValue {
                mascotAlpha = 0.0
                mascotFadeStart = CACurrentMediaTime()
            }
            needsDisplay = true
        }
    }
    var mascotPhase: CGFloat = 0 { didSet { needsDisplay = true } }
    var mascotType: String = "cow" { didSet { needsDisplay = true } }
    private var mascotAlpha: CGFloat = 1.0
    private var mascotFadeStart: CFTimeInterval = 0

    func tickMascotFade() {
        guard mascotFadeStart > 0 else { return }
        let elapsed = CACurrentMediaTime() - mascotFadeStart
        let duration: Double = 0.35
        if elapsed >= duration {
            mascotAlpha = 1.0
            mascotFadeStart = 0
        } else {
            mascotAlpha = CGFloat(elapsed / duration)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if bounds.width < 20 {
            if isOn {
                lampColor.setFill()
            } else {
                lampColor.withAlphaComponent(0.25).setFill()
            }
            bounds.fill()
            return
        }

        let fullR = min(bounds.width, bounds.height) / 2
        let center = NSPoint(x: bounds.midX, y: bounds.midY)

        // 发光光晕 — 灯亮时用 shadow 模拟真实灯光扩散
        if isOn && brightness > 0.3 {
            let glowPath = NSBezierPath()
            glowPath.appendArc(withCenter: center, radius: fullR * 0.6, startAngle: 0, endAngle: 360)
            let glowColor = lampColor.withAlphaComponent(brightness * 0.5)
            let shadow = NSShadow()
            shadow.shadowColor = glowColor
            shadow.shadowBlurRadius = fullR * 0.6
            shadow.shadowOffset = NSSize(width: 0, height: 0)
            shadow.set()
            NSColor.clear.setFill()
            glowPath.fill()
            NSShadow().set()
        }

        // 灯孔 — 凹槽，灯亮时带灯色
        let holePath = NSBezierPath()
        holePath.appendArc(withCenter: center, radius: fullR - 1, startAngle: 0, endAngle: 360)
        if isOn {
            lampColor.withAlphaComponent(0.25).setFill()
        } else {
            lampColor.withAlphaComponent(0.05).setFill()
        }
        holePath.fill()

        // 灯珠底色
        let lampR = fullR - 3
        let lampPath = NSBezierPath()
        lampPath.appendArc(withCenter: center, radius: lampR, startAngle: 0, endAngle: 360)
        if isOn {
            lampColor.withAlphaComponent(brightness * 0.15).setFill()
        } else {
            lampColor.withAlphaComponent(0.06).setFill()
        }
        lampPath.fill()

        // LED 点阵 — 六角密排小圆点
        let dotR: CGFloat = max(lampR / 16, 1.0)
        let spacing = dotR * 2.8
        let rows = Int((lampR + spacing) / (spacing * 0.866)) + 1
        let onColor = lampColor.withAlphaComponent(brightness)
        let offColor = lampColor.withAlphaComponent(0.08)

        // 先裁切到灯珠圆形区域
        let clipPath = NSBezierPath()
        clipPath.appendArc(withCenter: center, radius: lampR, startAngle: 0, endAngle: 360)
        clipPath.addClip()

        for row in -rows...rows {
            let yOffset = CGFloat(row) * spacing * 0.866
            let offset = (row % 2 != 0) ? spacing * 0.5 : 0
            let maxDx = sqrt(max(0, Double(lampR * lampR - yOffset * yOffset)))
            let cols = Int((maxDx + spacing) / spacing)
            for col in -cols...cols {
                let dx = CGFloat(col) * spacing + offset
                let dy = yOffset
                let dist = sqrt(dx * dx + dy * dy)
                if dist > lampR + dotR { continue }
                let dotPath = NSBezierPath()
                dotPath.appendArc(withCenter: NSPoint(x: center.x + dx, y: center.y + dy), radius: dotR, startAngle: 0, endAngle: 360)
                if isOn {
                    onColor.setFill()
                } else {
                    offColor.setFill()
                }
                dotPath.fill()
            }
        }

        // 吉祥物 — 灯亮时在灯珠上画小牛马
        if isOn && lampR > 12 {
            if mascotType == "chicken" {
                // 小鸡模式：篮球占满灯，灯色=篮球色
                drawMascot(center: center, size: lampR * 1.2, lampColor: lampColor)
            } else {
                NSGraphicsContext.saveGraphicsState()
                if mascotAlpha < 1.0 {
                    NSGraphicsContext.current?.cgContext.setAlpha(mascotAlpha)
                }
                // 半透明衬底，提升吉祥物可辨识度
                NSColor(white: 0.0, alpha: 0.35).setFill()
                let bg = NSBezierPath()
                bg.appendArc(withCenter: center, radius: lampR * 0.6, startAngle: 0, endAngle: 360)
                bg.fill()
                drawMascot(center: center, size: lampR * 1.2, lampColor: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    func drawMascot(center: NSPoint, size: CGFloat, lampColor: NSColor?) {
        // 优先加载外部图片
        if let img = loadMascotImage(name: mascotType) {
            let s = size * 2
            let rect = NSRect(x: center.x - s/2, y: center.y - s/2, width: s, height: s)
            img.draw(in: rect)
            return
        }
        // 回退到代码绘制
        switch mascotType {
        case "cat": drawCatMascot(center: center, size: size)
        case "robot": drawRobotMascot(center: center, size: size)
        case "horse": drawHorseMascot(center: center, size: size)
        case "chicken": drawChickenMascot(center: center, size: size, ballColor: lampColor)
        default: drawCowMascot(center: center, size: size)
        }
    }

    func loadMascotImage(name: String) -> NSImage? {
        // 1. 用户自定义目录
        let userPath = NSHomeDirectory() + "/.codelight/mascots/\(name).png"
        if FileManager.default.fileExists(atPath: userPath) {
            return NSImage(contentsOfFile: userPath)
        }
        // 2. App Resources
        if let bundlePath = Bundle.main.resourcePath {
            let appPath = bundlePath + "/mascots/\(name).png"
            if FileManager.default.fileExists(atPath: appPath) {
                return NSImage(contentsOfFile: appPath)
            }
        }
        return nil
    }

    func drawCowMascot(center: NSPoint, size: CGFloat) {
        let cx = center.x
        let cy = center.y
        let s = size
        let cowBody = NSColor(white: 1.0, alpha: 0.9)
        let cowSpot = NSColor(red: 0.35, green: 0.25, blue: 0.15, alpha: 0.7)
        let eyeColor = NSColor(white: 0.1, alpha: 0.9)
        let noseColor = NSColor(red: 1.0, green: 0.65, blue: 0.7, alpha: 0.9)
        let hornColor = NSColor(red: 0.95, green: 0.9, blue: 0.7, alpha: 0.9)

        // 画牛头（所有状态共用）
        func drawHead(hx: CGFloat, hy: CGFloat, faceUp: Bool = true) {
            // 头
            let headR = s * 0.22
            let head = NSBezierPath()
            head.appendArc(withCenter: NSPoint(x: hx, y: hy), radius: headR, startAngle: 0, endAngle: 360)
            cowBody.setFill(); head.fill()
            // 角（两个小三角）
            hornColor.setFill()
            let hLen = s * 0.1
            for dx: CGFloat in [-s*0.1, s*0.1] {
                let hornPath = NSBezierPath()
                if faceUp {
                    hornPath.move(to: NSPoint(x: hx + dx - s*0.03, y: hy + headR - s*0.02))
                    hornPath.line(to: NSPoint(x: hx + dx, y: hy + headR + hLen))
                    hornPath.line(to: NSPoint(x: hx + dx + s*0.03, y: hy + headR - s*0.02))
                } else {
                    hornPath.move(to: NSPoint(x: hx + dx - s*0.03, y: hy - headR + s*0.02))
                    hornPath.line(to: NSPoint(x: hx + dx, y: hy - headR - hLen))
                    hornPath.line(to: NSPoint(x: hx + dx + s*0.03, y: hy - headR + s*0.02))
                }
                hornPath.fill()
            }
            // 花斑
            cowSpot.setFill()
            let spot = NSBezierPath()
            spot.appendArc(withCenter: NSPoint(x: hx + s*0.06, y: hy - s*0.02), radius: s*0.07, startAngle: 0, endAngle: 360)
            spot.fill()
        }

        // 画眼睛
        func drawEyes(ex: CGFloat, ey: CGFloat, closed: Bool = false, lookUp: Bool = false) {
            if closed {
                // 闭眼 — 弧线
                NSColor(white: 0.2, alpha: 0.7).setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: ex - s*0.06, y: ey))
                line.line(to: NSPoint(x: ex + s*0.06, y: ey))
                line.lineWidth = 1.5; line.stroke()
            } else {
                eyeColor.setFill()
                let eyeOff: CGFloat = lookUp ? s*0.02 : 0
                NSBezierPath(ovalIn: NSRect(x: ex - s*0.07, y: ey - s*0.03 + eyeOff, width: s*0.05, height: s*0.06)).fill()
                NSBezierPath(ovalIn: NSRect(x: ex + s*0.03, y: ey - s*0.03 + eyeOff, width: s*0.05, height: s*0.06)).fill()
                // 高光
                NSColor.white.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: NSRect(x: ex - s*0.05, y: ey + eyeOff, width: s*0.02, height: s*0.02)).fill()
                NSBezierPath(ovalIn: NSRect(x: ex + s*0.05, y: ey + eyeOff, width: s*0.02, height: s*0.02)).fill()
            }
        }

        // 画鼻子
        func drawNose(nx: CGFloat, ny: CGFloat, faceUp: Bool = true) {
            noseColor.setFill()
            let nR = s * 0.06
            let nPath = NSBezierPath(roundedRect: NSRect(x: nx - nR, y: ny - nR*0.6, width: nR*2, height: nR*1.2), xRadius: nR*0.4, yRadius: nR*0.4)
            nPath.fill()
            // 鼻孔
            NSColor(red: 0.85, green: 0.5, blue: 0.55, alpha: 0.8).setFill()
            let holeR = s * 0.015
            NSBezierPath(ovalIn: NSRect(x: nx - nR*0.5, y: ny - holeR, width: holeR*2, height: holeR*2)).fill()
            NSBezierPath(ovalIn: NSRect(x: nx + nR*0.2, y: ny - holeR, width: holeR*2, height: holeR*2)).fill()
        }

        // 画身体+四条腿
        func drawBody(bx: CGFloat, by: CGFloat, legAnim: CGFloat = 0, lying: Bool = false) {
            if lying {
                // 躺平 — 扁椭圆
                cowBody.setFill()
                let body = NSBezierPath(ovalIn: NSRect(x: bx - s*0.28, y: by - s*0.12, width: s*0.56, height: s*0.24))
                body.fill()
                cowSpot.setFill()
                NSBezierPath(ovalIn: NSRect(x: bx - s*0.1, y: by - s*0.05, width: s*0.15, height: s*0.1)).fill()
            } else {
                // 站立 — 圆润身体
                cowBody.setFill()
                let body = NSBezierPath(ovalIn: NSRect(x: bx - s*0.2, y: by - s*0.25, width: s*0.4, height: s*0.45))
                body.fill()
                cowSpot.setFill()
                NSBezierPath(ovalIn: NSRect(x: bx + s*0.02, y: by - s*0.1, width: s*0.12, height: s*0.15)).fill()
                // 四条腿
                cowBody.setFill()
                let legW = s * 0.06
                let legH = s * 0.15
                NSBezierPath(roundedRect: NSRect(x: bx - s*0.15, y: by - s*0.28 - legH + legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx - s*0.05, y: by - s*0.28 - legH - legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx + s*0.05, y: by - s*0.28 - legH + legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx + s*0.13, y: by - s*0.28 - legH - legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
            }
        }

        // 尾巴
        func drawTail(tx: CGFloat, ty: CGFloat, wag: CGFloat) {
            NSColor(white: 0.7, alpha: 0.6).setStroke()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: tx - s*0.2, y: ty))
            let cpx = tx - s*0.3 + wag * s * 0.05
            tail.curve(to: NSPoint(x: tx - s*0.25, y: ty + s*0.12), controlPoint1: NSPoint(x: cpx, y: ty + s*0.05), controlPoint2: NSPoint(x: cpx, y: ty + s*0.1))
            tail.lineWidth = 1.5; tail.stroke()
            // 尾巴尖
            cowSpot.setFill()
            NSBezierPath(ovalIn: NSRect(x: tx - s*0.28, y: ty + s*0.1, width: s*0.05, height: s*0.05)).fill()
        }

        switch mascotState {
        case "working":
            // 🐂 小牛耕地 — 关键帧步态走路
            let walkKeyframes: [CGFloat] = [0, 0.7, 1.0, 0.7, 0, -0.5, -0.7, -0.5]
            let walkIdx = Int(mascotPhase * CGFloat(walkKeyframes.count)) % walkKeyframes.count
            let nextIdx = (walkIdx + 1) % walkKeyframes.count
            let frac = mascotPhase * CGFloat(walkKeyframes.count) - CGFloat(walkIdx)
            let legAnim = (walkKeyframes[walkIdx] + (walkKeyframes[nextIdx] - walkKeyframes[walkIdx]) * frac) * s * 0.05
            let sway = sin(Double(mascotPhase) * .pi * 6) * s * 0.03
            let bx = cx + sway
            drawBody(bx: bx, by: cy - s*0.05, legAnim: legAnim)
            drawHead(hx: bx - s*0.05, hy: cy + s*0.25)
            drawEyes(ex: bx - s*0.05, ey: cy + s*0.22)
            drawNose(nx: bx - s*0.05, ny: cy + s*0.15)
            drawTail(tx: bx, ty: cy + s*0.05, wag: CGFloat(sin(Double(mascotPhase) * .pi * 4)))
            // 头上汗滴
            let sweatAlpha = CGFloat(0.3 + 0.4 * sin(Double(mascotPhase) * .pi * 3))
            NSColor(red: 0.5, green: 0.8, blue: 1.0, alpha: sweatAlpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: bx + s*0.1, y: cy + s*0.4, width: s*0.04, height: s*0.06)).fill()

        case "thinking":
            // 🐄 小牛思考 — 坐着托腮，问号旋转
            drawBody(bx: cx, by: cy - s*0.05)
            drawHead(hx: cx, hy: cy + s*0.28)
            drawEyes(ex: cx, ey: cy + s*0.26, lookUp: true)
            drawNose(nx: cx, ny: cy + s*0.18)
            drawTail(tx: cx, ty: cy + s*0.05, wag: CGFloat(sin(Double(mascotPhase) * .pi * 2)))
            // 问号旋转 — CABasicAnimation 风格旋转（用 CGContext transform）
            let qRot = CGFloat(sin(Double(mascotPhase) * .pi * 2)) * 0.3
            let qPt = NSPoint(x: cx + s*0.25, y: cy + s*0.42)
            NSGraphicsContext.saveGraphicsState()
            var qTransform = NSAffineTransform()
            qTransform.translateX(by: qPt.x, yBy: qPt.y)
            qTransform.rotate(byDegrees: qRot * 180 / .pi)
            qTransform.translateX(by: -qPt.x, yBy: -qPt.y)
            qTransform.concat()
            let font = NSFont.systemFont(ofSize: s * 0.4, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
            NSAttributedString(string: "?", attributes: attrs).draw(at: NSPoint(x: cx + s*0.15, y: cy + s*0.35))
            NSGraphicsContext.restoreGraphicsState()

        case "fixing":
            // 🐂 小牛修 bug — 锤子旋转挥动
            drawBody(bx: cx, by: cy - s*0.05)
            drawHead(hx: cx, hy: cy + s*0.28)
            drawEyes(ex: cx, ey: cy + s*0.25)
            drawNose(nx: cx, ny: cy + s*0.18)
            drawTail(tx: cx, ty: cy + s*0.05, wag: CGFloat(sin(Double(mascotPhase) * .pi * 3)))
            // 锤子旋转 — CABasicAnimation 风格挥动
            let hammerAngle = CGFloat(sin(Double(mascotPhase) * .pi * 4)) * 25
            let pivot = NSPoint(x: cx + s*0.21, y: cy + s*0.15)
            NSGraphicsContext.saveGraphicsState()
            var hammerTransform = NSAffineTransform()
            hammerTransform.translateX(by: pivot.x, yBy: pivot.y)
            hammerTransform.rotate(byDegrees: hammerAngle)
            hammerTransform.translateX(by: -pivot.x, yBy: -pivot.y)
            hammerTransform.concat()
            NSColor(white: 0.6, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: cx + s*0.15, y: cy + s*0.3, width: s*0.15, height: s*0.07), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0.5, alpha: 0.7).setFill()
            NSBezierPath(rect: NSRect(x: cx + s*0.2, y: cy + s*0.15, width: s*0.03, height: s*0.16)).fill()
            NSGraphicsContext.restoreGraphicsState()

        case "error":
            // 🐮 小牛倒地 — 晕
            let tilt = CGFloat(sin(Double(mascotPhase) * .pi * 2)) * s * 0.03
            drawBody(bx: cx + tilt, by: cy - s*0.08, lying: true)
            drawHead(hx: cx + s*0.25 + tilt, hy: cy + s*0.05, faceUp: false)
            drawEyes(ex: cx + s*0.25 + tilt, ey: cy + s*0.02, closed: true)
            drawNose(nx: cx + s*0.25 + tilt, ny: cy - s*0.05, faceUp: false)
            // 星星
            let starAlpha = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 4))
            let font = NSFont.systemFont(ofSize: s * 0.3, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.yellow.withAlphaComponent(starAlpha)]
            NSAttributedString(string: "★", attributes: attrs).draw(at: NSPoint(x: cx + s*0.15, y: cy + s*0.2))

        default: // idle
            // 🐄 小牛躺平休息 — Zzz
            drawBody(bx: cx - s*0.05, by: cy - s*0.08, lying: true)
            drawHead(hx: cx + s*0.2, hy: cy + s*0.06, faceUp: false)
            drawEyes(ex: cx + s*0.2, ey: cy + s*0.03, closed: true)
            drawNose(nx: cx + s*0.2, ny: cy - s*0.04, faceUp: false)
            // Zzz 呼吸
            let zAlpha = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            let font = NSFont.systemFont(ofSize: s * 0.25, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(zAlpha)]
            NSAttributedString(string: "z z z", attributes: attrs).draw(at: NSPoint(x: cx - s*0.15, y: cy + s*0.2))
        }
    }

    func drawCatMascot(center: NSPoint, size: CGFloat) {
        let cx = center.x, cy = center.y, s = size
        let bodyColor = NSColor(red: 1.0, green: 0.75, blue: 0.4, alpha: 0.9)
        let spotColor = NSColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 0.7)
        let earColor = NSColor(red: 1.0, green: 0.6, blue: 0.7, alpha: 0.8)
        let catEye = NSColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 0.9)

        func drawCatHead(hx: CGFloat, hy: CGFloat) {
            let headR = s * 0.22
            let head = NSBezierPath()
            head.appendArc(withCenter: NSPoint(x: hx, y: hy), radius: headR, startAngle: 0, endAngle: 360)
            bodyColor.setFill(); head.fill()
            for dx: CGFloat in [-s*0.12, s*0.12] {
                let ear = NSBezierPath()
                ear.move(to: NSPoint(x: hx + dx - s*0.06, y: hy + headR - s*0.02))
                ear.line(to: NSPoint(x: hx + dx, y: hy + headR + s*0.12))
                ear.line(to: NSPoint(x: hx + dx + s*0.06, y: hy + headR - s*0.02))
                ear.close(); bodyColor.setFill(); ear.fill()
                let inner = NSBezierPath()
                inner.move(to: NSPoint(x: hx + dx - s*0.03, y: hy + headR))
                inner.line(to: NSPoint(x: hx + dx, y: hy + headR + s*0.07))
                inner.line(to: NSPoint(x: hx + dx + s*0.03, y: hy + headR))
                inner.close(); earColor.setFill(); inner.fill()
            }
            for dx: CGFloat in [-s*0.06, s*0.06] {
                catEye.setFill(); NSBezierPath(ovalIn: NSRect(x: hx + dx - s*0.025, y: hy - s*0.02, width: s*0.05, height: s*0.06)).fill()
            }
            let nose = NSBezierPath()
            nose.move(to: NSPoint(x: hx, y: hy - s*0.04))
            nose.line(to: NSPoint(x: hx - s*0.03, y: hy - s*0.07))
            nose.line(to: NSPoint(x: hx + s*0.03, y: hy - s*0.07))
            nose.close(); NSColor(red: 0.9, green: 0.4, blue: 0.5, alpha: 0.9).setFill(); nose.fill()
        }

        switch mascotState {
        case "working":
            let legAnim = sin(Double(mascotPhase) * .pi * 6) * s * 0.04
            bodyColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - s*0.15, y: cy - s*0.12 + legAnim, width: s*0.35, height: s*0.2)).fill()
            spotColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx + s*0.02, y: cy - s*0.05 + legAnim, width: s*0.1, height: s*0.08)).fill()
            drawCatHead(hx: cx + s*0.22, hy: cy + s*0.1 + legAnim)
        case "thinking":
            bodyColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - s*0.15, y: cy - s*0.1, width: s*0.35, height: s*0.18)).fill()
            drawCatHead(hx: cx + s*0.18, hy: cy + s*0.1)
            let qA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "?", attributes: [.font: NSFont.systemFont(ofSize: s * 0.22, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(qA)]).draw(at: NSPoint(x: cx - s*0.1, y: cy + s*0.18))
        case "fixing":
            bodyColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - s*0.15, y: cy - s*0.1, width: s*0.35, height: s*0.18)).fill()
            drawCatHead(hx: cx + s*0.22, hy: cy + s*0.1)
            let pA = sin(Double(mascotPhase) * .pi * 4) * s * 0.04
            bodyColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx + s*0.02 + pA, y: cy + s*0.05, width: s*0.08, height: s*0.05)).fill()
        case "error":
            let tilt = CGFloat(sin(Double(mascotPhase) * .pi * 2)) * s * 0.03
            bodyColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - s*0.15, y: cy - s*0.1 + tilt, width: s*0.35, height: s*0.18)).fill()
            drawCatHead(hx: cx + s*0.22, hy: cy + s*0.1 + tilt)
            let sA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 4))
            NSAttributedString(string: "* *", attributes: [.font: NSFont.systemFont(ofSize: s * 0.2, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(sA)]).draw(at: NSPoint(x: cx - s*0.08, y: cy + s*0.2))
        default:
            bodyColor.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - s*0.15, y: cy - s*0.1, width: s*0.35, height: s*0.18)).fill()
            drawCatHead(hx: cx + s*0.2, hy: cy + s*0.08)
            let zA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "z z z", attributes: [.font: NSFont.systemFont(ofSize: s * 0.22, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(zA)]).draw(at: NSPoint(x: cx - s*0.15, y: cy + s*0.2))
        }
    }

    func drawRobotMascot(center: NSPoint, size: CGFloat) {
        let cx = center.x, cy = center.y, s = size
        let bodyColor = NSColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1.0)
        let accent = NSColor(red: 0.2, green: 0.75, blue: 1.0, alpha: 1.0)
        let ledColor = NSColor(red: 0.0, green: 1.0, blue: 0.8, alpha: 1.0)

        func drawRobotHead(hx: CGFloat, hy: CGFloat) {
            let r = s * 0.2
            bodyColor.setFill(); NSBezierPath(roundedRect: NSRect(x: hx - r, y: hy - r, width: r*2, height: r*2), xRadius: s*0.04, yRadius: s*0.04).fill()
            NSColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0).set()
            NSBezierPath.defaultLineWidth = 1.5
            let ant = NSBezierPath(); ant.move(to: NSPoint(x: hx, y: hy + r)); ant.line(to: NSPoint(x: hx, y: hy + r + s*0.1)); ant.stroke()
            accent.setFill(); NSBezierPath(ovalIn: NSRect(x: hx - s*0.025, y: hy + r + s*0.08, width: s*0.05, height: s*0.05)).fill()
            let bl = CGFloat(0.5 + 0.5 * sin(Double(mascotPhase) * .pi * 3))
            for dx: CGFloat in [-s*0.07, s*0.07] {
                ledColor.withAlphaComponent(bl).setFill()
                NSBezierPath(roundedRect: NSRect(x: hx + dx - s*0.03, y: hy - s*0.05, width: s*0.06, height: s*0.05), xRadius: 1, yRadius: 1).fill()
            }
            NSColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0).set()
            NSBezierPath.defaultLineWidth = 1
            let m = NSBezierPath(); m.move(to: NSPoint(x: hx - s*0.06, y: hy - s*0.09)); m.line(to: NSPoint(x: hx + s*0.06, y: hy - s*0.09)); m.stroke()
        }

        switch mascotState {
        case "working":
            let bounce = sin(Double(mascotPhase) * .pi * 6) * s * 0.03
            bodyColor.setFill(); NSBezierPath(roundedRect: NSRect(x: cx - s*0.15, y: cy - s*0.12 + bounce, width: s*0.3, height: s*0.2), xRadius: s*0.03, yRadius: s*0.03).fill()
            accent.setFill(); NSBezierPath(roundedRect: NSRect(x: cx - s*0.08, y: cy - s*0.05 + bounce, width: s*0.16, height: s*0.04), xRadius: 2, yRadius: 2).fill()
            drawRobotHead(hx: cx + s*0.22, hy: cy + s*0.12 + bounce)
        case "thinking":
            bodyColor.setFill(); NSBezierPath(roundedRect: NSRect(x: cx - s*0.15, y: cy - s*0.1, width: s*0.3, height: s*0.18), xRadius: s*0.03, yRadius: s*0.03).fill()
            drawRobotHead(hx: cx + s*0.18, hy: cy + s*0.1)
            let dA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "...", attributes: [.font: NSFont.systemFont(ofSize: s * 0.22, weight: .medium), .foregroundColor: accent.withAlphaComponent(dA)]).draw(at: NSPoint(x: cx - s*0.08, y: cy + s*0.18))
        case "fixing":
            bodyColor.setFill(); NSBezierPath(roundedRect: NSRect(x: cx - s*0.15, y: cy - s*0.1, width: s*0.3, height: s*0.18), xRadius: s*0.03, yRadius: s*0.03).fill()
            drawRobotHead(hx: cx + s*0.22, hy: cy + s*0.1)
            let tA = sin(Double(mascotPhase) * .pi * 4) * s * 0.05
            accent.setFill(); NSBezierPath(ovalIn: NSRect(x: cx + s*0.02 + tA, y: cy + s*0.03, width: s*0.06, height: s*0.06)).fill()
        case "error":
            let shake = CGFloat(sin(Double(mascotPhase) * .pi * 8)) * s * 0.02
            bodyColor.setFill(); NSBezierPath(roundedRect: NSRect(x: cx - s*0.15 + shake, y: cy - s*0.1, width: s*0.3, height: s*0.18), xRadius: s*0.03, yRadius: s*0.03).fill()
            drawRobotHead(hx: cx + s*0.22 + shake, hy: cy + s*0.1)
            let eA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 4))
            NSAttributedString(string: "! !", attributes: [.font: NSFont.systemFont(ofSize: s * 0.18, weight: .bold), .foregroundColor: NSColor.red.withAlphaComponent(eA)]).draw(at: NSPoint(x: cx - s*0.06, y: cy + s*0.2))
        default:
            bodyColor.setFill(); NSBezierPath(roundedRect: NSRect(x: cx - s*0.15, y: cy - s*0.1, width: s*0.3, height: s*0.18), xRadius: s*0.03, yRadius: s*0.03).fill()
            drawRobotHead(hx: cx + s*0.2, hy: cy + s*0.08)
            let zA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "z z z", attributes: [.font: NSFont.systemFont(ofSize: s * 0.22, weight: .medium), .foregroundColor: accent.withAlphaComponent(zA)]).draw(at: NSPoint(x: cx - s*0.15, y: cy + s*0.2))
        }
    }

    func drawHorseMascot(center: NSPoint, size: CGFloat) {
        let cx = center.x, cy = center.y, s = size
        let bodyColor = NSColor(red: 0.72, green: 0.45, blue: 0.25, alpha: 0.9)
        let maneColor = NSColor(white: 0.15, alpha: 0.85)
        let hoofColor = NSColor(white: 0.25, alpha: 0.8)
        let eyeColor = NSColor(white: 0.1, alpha: 0.9)
        let noseColor = NSColor(red: 0.55, green: 0.3, blue: 0.2, alpha: 0.9)

        func drawHorseHead(hx: CGFloat, hy: CGFloat, faceUp: Bool = true) {
            let dir: CGFloat = faceUp ? 1 : -1
            bodyColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: hx - s*0.12, y: hy - s*0.08*dir, width: s*0.24, height: s*0.22)).fill()
            noseColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: hx - s*0.08, y: hy - s*0.06*dir, width: s*0.16, height: s*0.12)).fill()
            NSColor(white: 0.2, alpha: 0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: hx - s*0.04, y: hy - s*0.03*dir, width: s*0.025, height: s*0.02)).fill()
            NSBezierPath(ovalIn: NSRect(x: hx + s*0.02, y: hy - s*0.03*dir, width: s*0.025, height: s*0.02)).fill()
            eyeColor.setFill()
            let ey = hy + s*0.04*dir
            NSBezierPath(ovalIn: NSRect(x: hx - s*0.07, y: ey - s*0.025, width: s*0.04, height: s*0.05)).fill()
            NSBezierPath(ovalIn: NSRect(x: hx + s*0.04, y: ey - s*0.025, width: s*0.04, height: s*0.05)).fill()
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: hx - s*0.055, y: ey + s*0.01, width: s*0.015, height: s*0.015)).fill()
            NSBezierPath(ovalIn: NSRect(x: hx + s*0.055, y: ey + s*0.01, width: s*0.015, height: s*0.015)).fill()
            for dx: CGFloat in [-s*0.07, s*0.07] {
                bodyColor.setFill()
                let ear = NSBezierPath()
                ear.move(to: NSPoint(x: hx + dx - s*0.03, y: hy + s*0.08*dir))
                ear.line(to: NSPoint(x: hx + dx, y: hy + s*0.16*dir))
                ear.line(to: NSPoint(x: hx + dx + s*0.03, y: hy + s*0.08*dir))
                ear.close(); ear.fill()
            }
            maneColor.setFill()
            let mane = NSBezierPath()
            mane.move(to: NSPoint(x: hx, y: hy + s*0.08*dir))
            mane.curve(to: NSPoint(x: hx + s*0.15, y: hy + s*0.02*dir),
                       controlPoint1: NSPoint(x: hx + s*0.08, y: hy + s*0.12*dir),
                       controlPoint2: NSPoint(x: hx + s*0.14, y: hy + s*0.08*dir))
            mane.curve(to: NSPoint(x: hx + s*0.2, y: hy - s*0.02*dir),
                       controlPoint1: NSPoint(x: hx + s*0.16, y: hy + s*0.0*dir),
                       controlPoint2: NSPoint(x: hx + s*0.2, y: hy + s*0.02*dir))
            mane.lineWidth = s * 0.04; mane.stroke()
        }

        func drawHorseBody(bx: CGFloat, by: CGFloat, legAnim: CGFloat = 0, lying: Bool = false) {
            if lying {
                bodyColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: bx - s*0.28, y: by - s*0.12, width: s*0.56, height: s*0.24)).fill()
            } else {
                bodyColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: bx - s*0.2, y: by - s*0.22, width: s*0.4, height: s*0.38)).fill()
                let legW = s * 0.05, legH = s * 0.18
                hoofColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: bx - s*0.14, y: by - s*0.25 - legH + legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx - s*0.05, y: by - s*0.25 - legH - legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx + s*0.05, y: by - s*0.25 - legH + legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
                NSBezierPath(roundedRect: NSRect(x: bx + s*0.12, y: by - s*0.25 - legH - legAnim, width: legW, height: legH), xRadius: legW*0.3, yRadius: legW*0.3).fill()
            }
            maneColor.setStroke()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: bx - s*0.2, y: by))
            tail.curve(to: NSPoint(x: bx - s*0.28, y: by + s*0.12),
                       controlPoint1: NSPoint(x: bx - s*0.28, y: by + s*0.04),
                       controlPoint2: NSPoint(x: bx - s*0.3, y: by + s*0.08))
            tail.lineWidth = s * 0.03; tail.stroke()
        }

        switch mascotState {
        case "working":
            let runKeys: [CGFloat] = [0, 0.8, 1.0, 0.8, 0, -0.6, -0.8, -0.6]
            let idx = Int(mascotPhase * CGFloat(runKeys.count)) % runKeys.count
            let nxt = (idx + 1) % runKeys.count
            let frac = mascotPhase * CGFloat(runKeys.count) - CGFloat(idx)
            let legAnim = (runKeys[idx] + (runKeys[nxt] - runKeys[idx]) * frac) * s * 0.05
            let sway = sin(Double(mascotPhase) * .pi * 6) * s * 0.03
            let bx = cx + sway
            drawHorseBody(bx: bx, by: cy - s*0.05, legAnim: legAnim)
            drawHorseHead(hx: bx + s*0.28, hy: cy + s*0.18)
            let wA = CGFloat(0.2 + 0.3 * sin(Double(mascotPhase) * .pi * 4))
            NSColor.white.withAlphaComponent(wA).setStroke()
            for i in 0..<3 {
                let ly = cy + s*0.05 * CGFloat(i - 1)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: bx - s*0.3 - s*0.1*CGFloat(i), y: ly))
                line.line(to: NSPoint(x: bx - s*0.35 - s*0.1*CGFloat(i), y: ly))
                line.lineWidth = 1; line.stroke()
            }
        case "thinking":
            drawHorseBody(bx: cx, by: cy - s*0.05)
            drawHorseHead(hx: cx + s*0.28, hy: cy + s*0.22)
            let tapA = abs(sin(Double(mascotPhase) * .pi * 3)) * s * 0.03
            hoofColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx + s*0.12, y: cy - s*0.45 - tapA, width: s*0.06, height: s*0.03)).fill()
            let qA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "?", attributes: [.font: NSFont.systemFont(ofSize: s*0.35, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(qA)]).draw(at: NSPoint(x: cx - s*0.15, y: cy + s*0.25))
        case "fixing":
            drawHorseBody(bx: cx, by: cy - s*0.05)
            drawHorseHead(hx: cx + s*0.28, hy: cy + s*0.22)
            let stomp = sin(Double(mascotPhase) * .pi * 6) * s * 0.06
            hoofColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx + s*0.12, y: cy - s*0.43 + stomp, width: s*0.06, height: s*0.16), xRadius: 2, yRadius: 2).fill()
            let dA = CGFloat(0.4 + 0.4 * sin(Double(mascotPhase) * .pi * 5))
            NSColor(red: 0.7, green: 0.5, blue: 0.3, alpha: dA).setFill()
            for i in 0..<3 {
                let dx = s * 0.05 * CGFloat(i) * CGFloat(cos(Double(mascotPhase) * .pi * 3 + Double(i)))
                let dy = s * 0.04 * CGFloat(i) * CGFloat(sin(Double(mascotPhase) * .pi * 3 + Double(i)))
                NSBezierPath(ovalIn: NSRect(x: cx + s*0.12 + dx, y: cy - s*0.5 - dy, width: s*0.025, height: s*0.025)).fill()
            }
        case "error":
            let tilt = CGFloat(sin(Double(mascotPhase) * .pi * 2)) * s * 0.03
            drawHorseBody(bx: cx + tilt, by: cy - s*0.08, lying: true)
            drawHorseHead(hx: cx + s*0.25 + tilt, hy: cy + s*0.05, faceUp: false)
            let sA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 4))
            NSAttributedString(string: "★ ★", attributes: [.font: NSFont.systemFont(ofSize: s*0.25, weight: .bold), .foregroundColor: NSColor.yellow.withAlphaComponent(sA)]).draw(at: NSPoint(x: cx - s*0.05, y: cy + s*0.2))
        default:
            drawHorseBody(bx: cx, by: cy - s*0.05)
            drawHorseHead(hx: cx + s*0.28, hy: cy + s*0.2)
            let zA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "z z z", attributes: [.font: NSFont.systemFont(ofSize: s*0.25, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(zA)]).draw(at: NSPoint(x: cx - s*0.15, y: cy + s*0.22))
        }
    }

    func drawChickenMascot(center: NSPoint, size: CGFloat, ballColor: NSColor?) {
        let cx = center.x, cy = center.y, s = size
        let bodyYellow = NSColor(red: 1.0, green: 0.92, blue: 0.4, alpha: 0.95)
        let bodyDark = NSColor(red: 0.9, green: 0.78, blue: 0.2, alpha: 0.85)
        let beakColor = NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.9)
        let combColor = NSColor(red: 0.95, green: 0.2, blue: 0.15, alpha: 0.9)
        let eyeColor = NSColor(white: 0.1, alpha: 0.9)
        let ballFill = ballColor ?? NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.85)
        let ballLine = NSColor(white: 0.2, alpha: 0.5)

        // 篮球占满整个灯
        let ballR = s * 0.42

        func drawBasketballFull(bx: CGFloat, by: CGFloat, bounce: CGFloat = 0) {
            let byy = by + bounce
            // 球体
            ballFill.setFill()
            NSBezierPath(ovalIn: NSRect(x: bx - ballR, y: byy - ballR, width: ballR * 2, height: ballR * 2)).fill()
            // 纹路
            ballLine.setStroke()
            let sw = ballR * 0.04
            // 十字线
            let h = NSBezierPath()
            h.move(to: NSPoint(x: bx - ballR * 0.88, y: byy))
            h.line(to: NSPoint(x: bx + ballR * 0.88, y: byy))
            h.lineWidth = sw; h.stroke()
            let v = NSBezierPath()
            v.move(to: NSPoint(x: bx, y: byy - ballR * 0.88))
            v.line(to: NSPoint(x: bx, y: byy + ballR * 0.88))
            v.lineWidth = sw; v.stroke()
            // 左弧
            let lc = NSBezierPath()
            lc.move(to: NSPoint(x: bx - ballR * 0.3, y: byy - ballR * 0.88))
            lc.curve(to: NSPoint(x: bx - ballR * 0.3, y: byy + ballR * 0.88),
                     controlPoint1: NSPoint(x: bx - ballR * 0.75, y: byy - ballR * 0.3),
                     controlPoint2: NSPoint(x: bx - ballR * 0.75, y: byy + ballR * 0.3))
            lc.lineWidth = sw; lc.stroke()
            // 右弧
            let rc = NSBezierPath()
            rc.move(to: NSPoint(x: bx + ballR * 0.3, y: byy - ballR * 0.88))
            rc.curve(to: NSPoint(x: bx + ballR * 0.3, y: byy + ballR * 0.88),
                     controlPoint1: NSPoint(x: bx + ballR * 0.75, y: byy - ballR * 0.3),
                     controlPoint2: NSPoint(x: bx + ballR * 0.75, y: byy + ballR * 0.3))
            rc.lineWidth = sw; rc.stroke()
            // 高光
            NSColor.white.withAlphaComponent(0.2).setFill()
            NSBezierPath(ovalIn: NSRect(x: bx - ballR * 0.4, y: byy + ballR * 0.15, width: ballR * 0.35, height: ballR * 0.2)).fill()
        }

        func drawChick(hx: CGFloat, hy: CGFloat, leftArm: CGFloat = 0, rightArm: CGFloat = 0, headTilt: CGFloat = 0) {
            // Body
            bodyYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: hx - s * 0.08, y: hy - s * 0.1, width: s * 0.16, height: s * 0.14)).fill()
            // Wings
            bodyDark.setFill()
            let lw = NSBezierPath()
            lw.move(to: NSPoint(x: hx - s * 0.07, y: hy - s * 0.03))
            lw.line(to: NSPoint(x: hx - s * 0.16, y: hy + s * 0.02 + leftArm))
            lw.line(to: NSPoint(x: hx - s * 0.06, y: hy + s * 0.03))
            lw.close(); lw.fill()
            let rw = NSBezierPath()
            rw.move(to: NSPoint(x: hx + s * 0.07, y: hy - s * 0.03))
            rw.line(to: NSPoint(x: hx + s * 0.16, y: hy + s * 0.02 + rightArm))
            rw.line(to: NSPoint(x: hx + s * 0.06, y: hy + s * 0.03))
            rw.close(); rw.fill()
            // Legs
            NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.8).setStroke()
            let leg = NSBezierPath(); leg.lineWidth = s * 0.018
            leg.move(to: NSPoint(x: hx - s * 0.03, y: hy - s * 0.1))
            leg.line(to: NSPoint(x: hx - s * 0.03, y: hy - s * 0.16))
            leg.move(to: NSPoint(x: hx + s * 0.03, y: hy - s * 0.1))
            leg.line(to: NSPoint(x: hx + s * 0.03, y: hy - s * 0.16))
            leg.stroke()
            // Head
            let hhx = hx + headTilt
            bodyYellow.setFill()
            let headR = s * 0.07
            NSBezierPath(ovalIn: NSRect(x: hhx - headR, y: hy + s * 0.05 - headR, width: headR * 2, height: headR * 2)).fill()
            // Comb
            combColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: hhx - s * 0.025, y: hy + s * 0.05 + headR * 0.5, width: s * 0.02, height: s * 0.04)).fill()
            NSBezierPath(ovalIn: NSRect(x: hhx + s * 0.008, y: hy + s * 0.05 + headR * 0.5, width: s * 0.02, height: s * 0.05)).fill()
            // Beak
            beakColor.setFill()
            let bk = NSBezierPath()
            bk.move(to: NSPoint(x: hhx - s * 0.015, y: hy + s * 0.05))
            bk.line(to: NSPoint(x: hhx, y: hy + s * 0.01))
            bk.line(to: NSPoint(x: hhx + s * 0.015, y: hy + s * 0.05))
            bk.close(); bk.fill()
            // Eyes
            eyeColor.setFill()
            let ey = hy + s * 0.065
            NSBezierPath(ovalIn: NSRect(x: hhx - s * 0.028, y: ey - s * 0.012, width: s * 0.02, height: s * 0.02)).fill()
            NSBezierPath(ovalIn: NSRect(x: hhx + s * 0.012, y: ey - s * 0.012, width: s * 0.02, height: s * 0.02)).fill()
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: hhx - s * 0.024, y: ey + s * 0.003, width: s * 0.008, height: s * 0.008)).fill()
            NSBezierPath(ovalIn: NSRect(x: hhx + s * 0.016, y: ey + s * 0.003, width: s * 0.008, height: s * 0.008)).fill()
            // Blush
            NSColor(red: 1.0, green: 0.5, blue: 0.4, alpha: 0.4).setFill()
            NSBezierPath(ovalIn: NSRect(x: hhx - s * 0.045, y: ey - s * 0.005, width: s * 0.02, height: s * 0.012)).fill()
            NSBezierPath(ovalIn: NSRect(x: hhx + s * 0.03, y: ey - s * 0.005, width: s * 0.02, height: s * 0.012)).fill()
        }

        let chickBaseY = cy + ballR * 0.15

        switch mascotState {
        case "working":
            let bounce = -abs(sin(Double(mascotPhase) * .pi * 4)) * s * 0.04
            let jump = -abs(sin(Double(mascotPhase) * .pi * 4)) * s * 0.06
            let arm = sin(Double(mascotPhase) * .pi * 4) * s * 0.03
            drawBasketballFull(bx: cx, by: cy, bounce: bounce)
            drawChick(hx: cx, hy: chickBaseY + jump, leftArm: 0, rightArm: CGFloat(arm))
            // 速度线
            let wA = CGFloat(0.2 + 0.3 * sin(Double(mascotPhase) * .pi * 4))
            NSColor.white.withAlphaComponent(wA).setStroke()
            for i in 0..<3 {
                let ly = cy + s * 0.06 * CGFloat(i - 1)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: cx - ballR - s * 0.04 * CGFloat(i + 1), y: ly))
                line.line(to: NSPoint(x: cx - ballR - s * 0.04 * CGFloat(i + 1) - s * 0.06, y: ly))
                line.lineWidth = 1.5; line.stroke()
            }
        case "thinking":
            let tilt = sin(Double(mascotPhase) * .pi * 2) * s * 0.01
            drawBasketballFull(bx: cx, by: cy)
            drawChick(hx: cx, hy: chickBaseY, leftArm: s * 0.04, rightArm: 0, headTilt: CGFloat(tilt))
            let qA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "?", attributes: [.font: NSFont.systemFont(ofSize: s * 0.3, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(qA)]).draw(at: NSPoint(x: cx + s * 0.06, y: chickBaseY + s * 0.18))
        case "fixing":
            let stomp = sin(Double(mascotPhase) * .pi * 6) * s * 0.03
            let bounce = -abs(sin(Double(mascotPhase) * .pi * 6)) * s * 0.02
            drawBasketballFull(bx: cx, by: cy, bounce: bounce)
            drawChick(hx: cx, hy: chickBaseY + CGFloat(stomp), leftArm: CGFloat(stomp) * 0.5, rightArm: CGFloat(stomp))
            let dA = CGFloat(0.4 + 0.4 * sin(Double(mascotPhase) * .pi * 5))
            NSColor(white: 0.7, alpha: dA).setFill()
            for i in 0..<3 {
                let dx = s * 0.05 * CGFloat(i) * CGFloat(cos(Double(mascotPhase) * .pi * 3 + Double(i)))
                let dy = s * 0.03 * CGFloat(i) * CGFloat(sin(Double(mascotPhase) * .pi * 3 + Double(i)))
                NSBezierPath(ovalIn: NSRect(x: cx + ballR * 0.4 + dx, y: cy - ballR * 0.3 - dy, width: s * 0.02, height: s * 0.02)).fill()
            }
        case "error":
            let tilt = CGFloat(sin(Double(mascotPhase) * .pi * 2)) * s * 0.015
            drawBasketballFull(bx: cx, by: cy)
            NSGraphicsContext.saveGraphicsState()
            let rot = NSAffineTransform()
            let px = cx + s * 0.04, py = cy + ballR * 0.1
            rot.translateX(by: px, yBy: py)
            rot.rotate(byDegrees: 70 + tilt * 50)
            rot.translateX(by: -px, yBy: -py)
            let t = rot.transformStruct
            let cg = CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22, tx: t.tX, ty: t.tY)
            NSGraphicsContext.current!.cgContext.concatenate(cg)
            drawChick(hx: px, hy: py)
            NSGraphicsContext.restoreGraphicsState()
            let sA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 4))
            NSAttributedString(string: "★ ★", attributes: [.font: NSFont.systemFont(ofSize: s * 0.2, weight: .bold), .foregroundColor: NSColor.yellow.withAlphaComponent(sA)]).draw(at: NSPoint(x: cx - s * 0.04, y: cy + ballR * 0.4))
        default:
            let sway = sin(Double(mascotPhase) * .pi * 2) * s * 0.01
            drawBasketballFull(bx: cx, by: cy)
            drawChick(hx: cx + CGFloat(sway), hy: chickBaseY)
            let zA = CGFloat(0.3 + 0.5 * sin(Double(mascotPhase) * .pi * 2))
            NSAttributedString(string: "z z z", attributes: [.font: NSFont.systemFont(ofSize: s * 0.15, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(zA)]).draw(at: NSPoint(x: cx + s * 0.06, y: chickBaseY + s * 0.15))
        }
    }
}

// ============================================================
// TimelineView — 今日工作状态时间线
// ============================================================

struct TimelineEntry {
    let timestamp: Double
    let state: String
    let message: String
    let sessionId: String
}

class TimelineView: NSView {
    var entries: [TimelineEntry] = [] {
        didSet { needsDisplay = true }
    }
    var scrollView: NSScrollView?
    var summaryLabel: NSTextField?

    private let stateColors: [String: NSColor] = [
        "working": NSColor(red: 0.85, green: 0.22, blue: 0.22, alpha: 1),
        "fixing": NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1),
        "thinking": NSColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1),
        "error": NSColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 1),
        "waiting": NSColor(red: 0.75, green: 0.3, blue: 0.85, alpha: 1),
        "idle": NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.4),
    ]
    private let stateLabels: [String: String] = [
        "idle": "空闲", "thinking": "思考", "working": "执行",
        "fixing": "修复", "error": "错误", "waiting": "等待",
    ]

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(white: 0.12, alpha: 1.0)
        bg.setFill()
        dirtyRect.fill()

        guard !entries.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor
            ]
            NSAttributedString(string: "暂无今日工作记录", attributes: attrs)
                .draw(at: NSPoint(x: frame.width / 2 - 60, y: frame.height / 2))
            return
        }

        let w = frame.width
        let topPad: CGFloat = 50
        let bottomPad: CGFloat = 36
        let leftPad: CGFloat = 70
        let rightPad: CGFloat = 20
        let chartH = frame.height - topPad - bottomPad
        let chartW = w - leftPad - rightPad

        // 计算24小时时间轴
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let daySeconds: Double = 86400

        // 绘制时间网格
        let gridColor = NSColor(white: 0.25, alpha: 0.6)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.5, alpha: 1)
        ]
        for h in 0...24 {
            let x = leftPad + CGFloat(h) / 24.0 * chartW
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: topPad))
            path.line(to: NSPoint(x: x, y: topPad + chartH))
            gridColor.setStroke()
            path.lineWidth = (h % 6 == 0) ? 0.8 : 0.3
            path.stroke()
            if h % 2 == 0 {
                NSAttributedString(string: String(format: "%02d:00", h), attributes: labelAttrs)
                    .draw(at: NSPoint(x: x - 16, y: 8))
            }
        }

        // 横轴线
        let axisPath = NSBezierPath()
        axisPath.move(to: NSPoint(x: leftPad, y: topPad))
        axisPath.line(to: NSPoint(x: leftPad + chartW, y: topPad))
        NSColor(white: 0.4, alpha: 1).setStroke()
        axisPath.lineWidth = 1
        axisPath.stroke()

        // 绘制状态条（每个entry画一条水平色带）
        let barH: CGFloat = max(chartH - 10, 20)
        let barY = topPad + 5

        // 聚合连续相同状态的区间
        var segments: [(start: Double, end: Double, state: String)] = []
        for (i, entry) in entries.enumerated() {
            let startOffset = max(entry.timestamp - todayStart.timeIntervalSince1970, 0)
            let endOffset: Double
            if i + 1 < entries.count {
                endOffset = entries[i + 1].timestamp - todayStart.timeIntervalSince1970
            } else {
                endOffset = min(Date().timeIntervalSince1970 - todayStart.timeIntervalSince1970, daySeconds)
            }
            if startOffset >= daySeconds { continue }
            let clampedEnd = min(endOffset, daySeconds)
            if !segments.isEmpty && segments.last!.state == entry.state && abs(segments.last!.end - startOffset) < 1 {
                segments[segments.count - 1].end = clampedEnd
            } else {
                segments.append((start: startOffset, end: clampedEnd, state: entry.state))
            }
        }

        for seg in segments {
            let x1 = leftPad + CGFloat(seg.start / daySeconds) * chartW
            let x2 = leftPad + CGFloat(seg.end / daySeconds) * chartW
            guard x2 - x1 > 0.3 else { continue }
            let color = stateColors[seg.state] ?? NSColor.gray
            let rect = NSRect(x: x1, y: barY, width: x2 - x1, height: barH)
            let bp = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            color.setFill()
            bp.fill()
        }

        // 标题和统计
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white
        ]
        let stats = computeStats()
        let titleStr = "今日 AI 工作时间线 — 工作 \(stats.workMins)分钟 / 思考 \(stats.thinkMins)分钟"
        NSAttributedString(string: titleStr, attributes: titleAttrs)
            .draw(at: NSPoint(x: leftPad, y: topPad + barH + 8))

        // 右上角图例
        let legends: [(String, NSColor)] = [("执行", stateColors["working"]!), ("思考", stateColors["thinking"]!), ("修复", stateColors["fixing"]!), ("空闲", stateColors["idle"]!)]
        var lx = w - rightPad
        let ly = topPad - 16
        let legAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.7, alpha: 1)
        ]
        for (label, color) in legends.reversed() {
            let tw = label.size(withAttributes: legAttrs).width
            lx -= tw + 14
            color.setFill()
            NSRect(x: lx, y: ly + 2, width: 8, height: 8).fill()
            NSAttributedString(string: label, attributes: legAttrs).draw(at: NSPoint(x: lx + 11, y: ly))
        }
    }

    struct Stats { var workMins: Int = 0, thinkMins: Int = 0, fixMins: Int = 0, idleMins: Int = 0 }

    func computeStats() -> Stats {
        var s = Stats()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date()).timeIntervalSince1970
        for (i, entry) in entries.enumerated() {
            let start = max(entry.timestamp - todayStart, 0)
            let end: Double
            if i + 1 < entries.count { end = entries[i + 1].timestamp - todayStart }
            else { end = Date().timeIntervalSince1970 - todayStart }
            let dur = max(end - start, 0)
            switch entry.state {
            case "working", "waiting": s.workMins += Int(dur / 60)
            case "thinking": s.thinkMins += Int(dur / 60)
            case "fixing": s.fixMins += Int(dur / 60)
            default: s.idleMins += Int(dur / 60)
            }
        }
        return s
    }
}

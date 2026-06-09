// CodeLight — 设置面板 UI 组件
// macOS System Settings 风格：分组圆角卡片 + 图标标题行

import Cocoa

// ============================================================
// SettingsRowView — 单行设置项
// ============================================================

class SettingsRowView: NSView {
    var titleLabel: NSTextField!
    var subtitleLabel: NSTextField?
    var accessoryView: NSView?
    var iconContainer: NSView?
    private var separator: NSView?
    private var textStartX: CGFloat = 12
    private var accWidth: CGFloat = 0

    init(icon: String? = nil, iconColor: NSColor? = nil,
         title: String, subtitle: String? = nil,
         accessory: NSView? = nil,
         isFirst: Bool = false, isLast: Bool = false,
         showSeparator: Bool = true) {

        let rowH: CGFloat = subtitle != nil ? 56 : 44
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: rowH))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.85).cgColor

        // 圆角处理
        if isFirst && isLast {
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
        } else if isFirst {
            layer?.cornerRadius = 10
            layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            layer?.masksToBounds = true
        } else if isLast {
            layer?.cornerRadius = 10
            layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            layer?.masksToBounds = true
        }

        let padLeft: CGFloat = 12
        let iconSize: CGFloat = 24
        var x: CGFloat = padLeft

        // 图标
        if let emoji = icon {
            let iconBg = NSView(frame: NSRect(x: x, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize))
            iconBg.wantsLayer = true
            iconBg.layer?.cornerRadius = 6
            iconBg.layer?.masksToBounds = true
            let bgColor = iconColor ?? NSColor.systemBlue
            iconBg.layer?.backgroundColor = bgColor.withAlphaComponent(0.15).cgColor

            let emojiLabel = NSTextField(labelWithString: emoji)
            emojiLabel.font = NSFont.systemFont(ofSize: 14)
            emojiLabel.alignment = .center
            emojiLabel.frame = NSRect(x: 0, y: 2, width: iconSize, height: iconSize - 2)
            iconBg.addSubview(emojiLabel)
            addSubview(iconBg)
            iconContainer = iconBg
            x += iconSize + 10
        }

        textStartX = x

        // 标题
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.usesSingleLineMode = false
        titleLabel.frame = NSRect(x: x,
                                   y: subtitle != nil ? rowH / 2 + 2 : (rowH - 20) / 2,
                                   width: 200, height: 20)
        addSubview(titleLabel)

        // 副标题
        if let sub = subtitle {
            subtitleLabel = NSTextField(labelWithString: sub)
            subtitleLabel?.font = NSFont.systemFont(ofSize: 11)
            subtitleLabel?.textColor = NSColor.tertiaryLabelColor
            subtitleLabel?.lineBreakMode = .byWordWrapping
            subtitleLabel?.usesSingleLineMode = false
            subtitleLabel?.frame = NSRect(x: x, y: rowH / 2 - 16, width: 300, height: 16)
            addSubview(subtitleLabel!)
        }

        // 右侧控件
        if let acc = accessory {
            accWidth = acc.frame.width + 28
            let accW = acc.frame.width
            let accH = acc.frame.height
            acc.frame = NSRect(x: bounds.width - accW - 14,
                               y: (rowH - accH) / 2,
                               width: accW, height: accH)
            acc.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            addSubview(acc)
            accessoryView = acc
        }

        // 分隔线
        if showSeparator && !isLast {
            separator = NSView(frame: NSRect(x: x, y: 0, width: bounds.width - x, height: 0.5))
            separator?.wantsLayer = true
            separator?.layer?.backgroundColor = NSColor.separatorColor.cgColor
            separator?.autoresizingMask = .width
            addSubview(separator!)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width

        // 重新定位 accessory 到右侧
        if let acc = accessoryView {
            let accW = acc.frame.width
            let accH = acc.frame.height
            acc.frame = NSRect(x: w - accW - 14,
                               y: (bounds.height - accH) / 2,
                               width: accW, height: accH)
        }

        // 文本区域宽度
        let textW = max(w - textStartX - accWidth - 14, 100)

        // 计算文字高度
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let titleRect = (titleLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: textW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont]
        )
        let titleH = ceil(titleRect.height)

        var subH: CGFloat = 0
        if let sub = subtitleLabel {
            let subFont = NSFont.systemFont(ofSize: 11)
            let subRect = (sub.stringValue as NSString).boundingRect(
                with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: subFont]
            )
            subH = ceil(subRect.height)
        }

        // 定位标签
        if subH > 0 {
            let totalTextH = titleH + 4 + subH
            let blockBottom = (bounds.height - totalTextH) / 2
            subtitleLabel?.frame = NSRect(x: textStartX, y: blockBottom, width: textW, height: subH)
            titleLabel.frame = NSRect(x: textStartX, y: blockBottom + subH + 4, width: textW, height: titleH)
        } else {
            titleLabel.frame = NSRect(x: textStartX, y: (bounds.height - titleH) / 2, width: textW, height: titleH)
        }

        // 重新定位分隔线
        separator?.frame = NSRect(x: textStartX, y: 0,
                                   width: w - textStartX, height: 0.5)
    }

    /// 根据宽度计算行高（支持文字换行）
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let textW = max(width - textStartX - accWidth - 14, 100)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let titleRect = (titleLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: textW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont]
        )
        let titleH = ceil(titleRect.height)

        var subH: CGFloat = 0
        if let sub = subtitleLabel {
            let subFont = NSFont.systemFont(ofSize: 11)
            let subRect = (sub.stringValue as NSString).boundingRect(
                with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: subFont]
            )
            subH = ceil(subRect.height)
        }

        let totalH: CGFloat = subH > 0 ? titleH + subH + 20 : titleH + 24
        return max(totalH, subH > 0 ? 56 : 44)
    }
}

// ============================================================
// SettingsGroupView — 分组容器
// ============================================================

class SettingsGroupView: NSView {
    var rows: [SettingsRowView] = []
    private var headerLabel: NSTextField?

    init(header: String? = nil, rows: [SettingsRowView]) {
        let rowH: CGFloat = rows.reduce(0) { $0 + $1.frame.height }
        let headerH: CGFloat = header != nil ? 28 : 0
        let totalH = headerH + rowH
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: totalH))

        wantsLayer = true

        // 分组标题
        if let h = header {
            headerLabel = NSTextField(labelWithString: h)
            headerLabel?.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            headerLabel?.textColor = NSColor.secondaryLabelColor
            headerLabel?.frame = NSRect(x: 16, y: totalH - 20, width: 200, height: 20)
            addSubview(headerLabel!)
        }

        // 堆叠 rows
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: y, width: 600, height: row.frame.height)
            row.autoresizingMask = .width
            addSubview(row)
            y += row.frame.height
        }
        self.rows = rows
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 0
        for row in rows {
            let h = row.preferredHeight(for: w)
            row.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        if let hl = headerLabel {
            hl.frame = NSRect(x: 16, y: y, width: w - 32, height: 20)
        }
        // 调整自身高度
        let headerH = headerLabel != nil ? 28 : 0
        frame.size = NSSize(width: w, height: y + CGFloat(headerH))
    }
}

// ============================================================
// Accessory 工厂方法
// ============================================================

extension SettingsRowView {

    /// 开关控件
    static func makeToggle(isOn: Bool, action: @escaping (Bool) -> Void) -> NSSwitch {
        let toggle = NSSwitch(frame: NSRect(x: 0, y: 0, width: 42, height: 24))
        toggle.state = isOn ? .on : .off
        toggle.onAction = {
            action(toggle.state == .on)
        }
        return toggle
    }

    /// 滑块 + 值标签
    static func makeSlider(value: Double, min: Double, max: Double,
                           format: String = "%.0f",
                           onChange: @escaping (Double) -> Void) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let slider = NSSlider(frame: NSRect(x: 0, y: 2, width: 140, height: 20))
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true

        let label = NSTextField(labelWithString: String(format: format, value))
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor.secondaryLabelColor
        label.frame = NSRect(x: 146, y: 4, width: 50, height: 16)
        label.alignment = .right

        slider.onAction = {
            let v = slider.doubleValue
            label.stringValue = String(format: format, v)
            onChange(v)
        }

        container.addSubview(slider)
        container.addSubview(label)
        return container
    }

    /// 下拉选择
    static func makePopup(items: [String], selectedIndex: Int,
                          onChange: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        popup.addItems(withTitles: items)
        popup.selectItem(at: selectedIndex)
        popup.onAction = {
            onChange(popup.indexOfSelectedItem)
        }
        return popup
    }

    /// 分段选择
    static func makeSegmented(labels: [String], selected: Int,
                              onChange: @escaping (Int) -> Void) -> NSSegmentedControl {
        let seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        seg.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        seg.sizeToFit()
        var frame = seg.frame
        frame.size.width = max(frame.width, CGFloat(labels.count) * 60)
        seg.frame = frame
        seg.selectedSegment = selected
        seg.onAction = {
            onChange(seg.selectedSegment)
        }
        return seg
    }
}

// ============================================================
// NSButton action closure 扩展
// ============================================================

private var onActionKey: UInt8 = 0

extension NSControl {
    var onAction: (() -> Void)? {
        get { objc_getAssociatedObject(self, &onActionKey) as? (() -> Void) }
        set {
            objc_setAssociatedObject(self, &onActionKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            if newValue != nil {
                target = self
                action = #selector(invokeOnAction)
            } else {
                target = nil
                action = nil
            }
        }
    }

    @objc private func invokeOnAction() {
        onAction?()
    }
}

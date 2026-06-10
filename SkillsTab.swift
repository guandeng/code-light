import Cocoa

// MARK: - Skills Tab (SettingsWindowController Extension)

extension SettingsWindowController {

    // MARK: - Properties (stored via associated objects workaround — use existing ivars)

    func buildSkillsTab(_ container: NSView, _ c: AppConfig) {
        var y: CGFloat = 16
        let contentW = container.frame.width

        // --- 分段控件: 已安装 / 发现 ---
        skillsSegment = NSSegmentedControl(labels: ["已安装", "发现"], trackingMode: .selectOne, target: self, action: #selector(skillsSegmentChanged(_:)))
        skillsSegment.selectedSegment = 0
        skillsSegment.frame = NSRect(x: 0, y: 0, width: 200, height: 26)
        skillsSegment.sizeToFit()

        let segGroup = SettingsGroupView(header: nil, rows: [
            SettingsRowView(title: "视图", accessory: skillsSegment, isFirst: true, isLast: true),
        ])
        segGroup.frame.origin = NSPoint(x: 16, y: y)
        segGroup.autoresizingMask = .width
        container.addSubview(segGroup)
        y += segGroup.frame.height + 4

        // --- 安装来源配置区（仅"发现"模式可见）---
        // 注意：config view 浮在列表之上，不占据 y 空间
        let configBaseY = y  // 记录当前位置，发现模式时使用
        skillsRepoConfigView = NSView(frame: NSRect(x: 16, y: configBaseY, width: contentW - 32, height: 0))
        skillsRepoConfigView.wantsLayer = true
        container.addSubview(skillsRepoConfigView)
        skillsRepoConfigView.isHidden = true  // 默认"已安装"模式

        var ry: CGFloat = 0

        // 来源选择分段控件
        installSourceSegment = NSSegmentedControl(labels: ["🌐 市场", "🔗 Git", "📂 目录", "📦 压缩包"], trackingMode: .selectOne, target: self, action: #selector(installSourceChanged(_:)))
        installSourceSegment.selectedSegment = 0
        installSourceSegment.frame = NSRect(x: 0, y: ry, width: 400, height: 26)
        installSourceSegment.sizeToFit()
        skillsRepoConfigView.addSubview(installSourceSegment)
        ry += 34

        // --- 市场模式容器 ---
        skillsMarketContainer = NSView(frame: NSRect(x: 0, y: ry, width: contentW - 32, height: 0))
        skillsRepoConfigView.addSubview(skillsMarketContainer)

        var my: CGFloat = 0
        // 预置仓库下拉
        let repoPopup = NSPopUpButton(frame: NSRect(x: 0, y: my, width: contentW - 170, height: 26))
        repoPopup.font = NSFont.systemFont(ofSize: 12)
        for preset in AppConfig.presetRepos {
            repoPopup.addItem(withTitle: "\(preset.name) (\(preset.owner)/\(preset.repo))")
        }
        repoPopup.addItem(withTitle: "自定义...")
        repoPopup.target = self
        repoPopup.action = #selector(skillsRepoPopupChanged(_:))
        skillsRepoPopup = repoPopup
        skillsMarketContainer.addSubview(repoPopup)
        my += 34

        // 自定义仓库输入框（默认隐藏）
        let repoField = NSTextField(frame: NSRect(x: 0, y: my, width: contentW - 170, height: 26))
        repoField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        repoField.placeholderString = "owner/repo，如 anthropics/skills"
        repoField.stringValue = c.skillsRepoURL
        repoField.target = self
        repoField.action = #selector(skillsRepoFieldChanged(_:))
        repoField.usesSingleLineMode = true
        repoField.isHidden = true
        skillsRepoField = repoField
        skillsMarketContainer.addSubview(repoField)

        // 路径输入框
        let pathField = NSTextField(frame: NSRect(x: 0, y: my, width: contentW - 170, height: 26))
        pathField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.placeholderString = "仓库内路径，如 skills"
        pathField.stringValue = c.skillsCatalogPath
        pathField.target = self
        pathField.action = #selector(skillsRepoFieldChanged(_:))
        pathField.usesSingleLineMode = true
        pathField.isHidden = true
        skillsPathField = pathField
        skillsMarketContainer.addSubview(pathField)
        my += 34

        // 刷新按钮
        let refreshBtn = NSButton(frame: NSRect(x: contentW - 148, y: 0, width: 116, height: 60))
        refreshBtn.title = "🔄 刷新"
        refreshBtn.bezelStyle = .rounded
        refreshBtn.font = NSFont.systemFont(ofSize: 12)
        refreshBtn.target = self
        refreshBtn.action = #selector(skillsRefreshRemote(_:))
        skillsMarketContainer.addSubview(refreshBtn)

        skillsMarketContainer.frame.size.height = my
        ry += my

        // --- Git 模式容器 ---
        skillsGitContainer = NSView(frame: NSRect(x: 0, y: ry, width: contentW - 32, height: 56))
        skillsGitContainer.isHidden = true
        skillsRepoConfigView.addSubview(skillsGitContainer)

        let gitField = NSTextField(frame: NSRect(x: 0, y: 28, width: contentW - 170, height: 26))
        gitField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        gitField.placeholderString = "Git 仓库 URL，如 https://github.com/user/skills"
        gitField.usesSingleLineMode = true
        skillsGitField = gitField
        skillsGitContainer.addSubview(gitField)

        let gitBtn = NSButton(frame: NSRect(x: contentW - 148, y: 28, width: 116, height: 26))
        gitBtn.title = "克隆安装"
        gitBtn.bezelStyle = .rounded
        gitBtn.font = NSFont.systemFont(ofSize: 12)
        gitBtn.target = self
        gitBtn.action = #selector(skillsGitInstall(_:))
        skillsGitContainer.addSubview(gitBtn)
        ry += 56

        // --- 目录模式容器 ---
        skillsDirContainer = NSView(frame: NSRect(x: 0, y: ry, width: contentW - 32, height: 34))
        skillsDirContainer.isHidden = true
        skillsRepoConfigView.addSubview(skillsDirContainer)

        let dirBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        dirBtn.title = "📂 选择目录导入..."
        dirBtn.bezelStyle = .rounded
        dirBtn.font = NSFont.systemFont(ofSize: 12)
        dirBtn.target = self
        dirBtn.action = #selector(skillsDirImport(_:))
        skillsDirContainer.addSubview(dirBtn)
        ry += 34

        // --- 压缩包模式容器 ---
        skillsZipContainer = NSView(frame: NSRect(x: 0, y: ry, width: contentW - 32, height: 34))
        skillsZipContainer.isHidden = true
        skillsRepoConfigView.addSubview(skillsZipContainer)

        let zipBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        zipBtn.title = "📦 选择压缩包导入..."
        zipBtn.bezelStyle = .rounded
        zipBtn.font = NSFont.systemFont(ofSize: 12)
        zipBtn.target = self
        zipBtn.action = #selector(skillsZipImport(_:))
        skillsZipContainer.addSubview(zipBtn)
        ry += 34

        skillsRepoConfigView.frame.size.height = ry
        // 不更新 y！config view 是浮层，不占据空间
        skillsDiscoverListY = configBaseY + ry  // 发现模式：列表在 config view 之后

        // --- 状态标签 ---
        skillsStatusLabel = NSTextField(frame: NSRect(x: 16, y: y, width: contentW - 32, height: 18))
        skillsStatusLabel.isEditable = false
        skillsStatusLabel.isBordered = false
        skillsStatusLabel.backgroundColor = .clear
        skillsStatusLabel.font = NSFont.systemFont(ofSize: 11)
        skillsStatusLabel.textColor = NSColor.tertiaryLabelColor
        skillsStatusLabel.stringValue = ""
        container.addSubview(skillsStatusLabel)
        y += 24

        // --- 动态列表区域 ---
        skillsListContainer = FlippedView(frame: NSRect(x: 16, y: y, width: contentW - 32, height: 0))
        skillsListContainer.autoresizingMask = .width
        container.addSubview(skillsListContainer)

        // 记录列表容器上方的 Y 位置，方便后续动态调整
        skillsListTopY = y
        skillsContainerHeight = contentW - 32

        // 已安装模式：y 就是当前位置（config view 没撑大 y）
        // 列表紧跟分段卡片，状态标签也不占间距
        skillsInstalledListY = segGroup.frame.origin.y + segGroup.frame.height + 4
        skillsStatusLabel.frame.origin.y = skillsInstalledListY
        skillsListContainer.frame.origin.y = skillsInstalledListY + 18
        skillsListTopY = skillsInstalledListY + 18

        // 初始加载已安装列表
        rebuildSkillsList()
    }

    // MARK: - Segment Changed

    @objc func skillsSegmentChanged(_ sender: NSSegmentedControl) {
        let isDiscover = sender.selectedSegment == 1

        if isDiscover {
            // 发现模式：config view 浮在列表之上
            skillsRepoConfigView.isHidden = false
            // 状态标签和列表移到 config view 下方
            skillsStatusLabel.frame.origin.y = skillsDiscoverListY
            skillsListContainer.frame.origin.y = skillsDiscoverListY + 16
            skillsListTopY = skillsDiscoverListY + 16

            skillsListContainer?.subviews.forEach { $0.removeFromSuperview() }
            skillsStatusLabel.stringValue = ""  // 清掉已安装模式的文字
            updateInstallSourceView()
            rebuildSkillsDiscoverList()
        } else {
            // 已安装模式：隐藏 config view，列表回到紧凑位置
            skillsRepoConfigView.isHidden = true
            skillsStatusLabel.frame.origin.y = skillsInstalledListY
            skillsListContainer.frame.origin.y = skillsInstalledListY + 16
            skillsListTopY = skillsInstalledListY + 16

            // 重置 docView 高度
            if let docView = skillsListContainer?.superview {
                docView.frame.size.height = skillsInstalledListY + 16 + 200
            }
            rebuildSkillsList()
        }
    }

    // MARK: - Install Source Changed

    @objc func installSourceChanged(_ sender: NSSegmentedControl) {
        updateInstallSourceView()
        // 切换到市场时自动加载
        // 不自动请求，避免 GitHub API 限流报错
    }

    private func updateInstallSourceView() {
        let idx = installSourceSegment?.selectedSegment ?? 0
        let sourceY: CGFloat = 34  // 紧跟在来源分段控件下方

        // 隐藏所有容器，将可见的移到紧邻分段控件下方
        skillsMarketContainer?.isHidden = (idx != 0)
        skillsGitContainer?.isHidden = (idx != 1)
        skillsDirContainer?.isHidden = (idx != 2)
        skillsZipContainer?.isHidden = (idx != 3)

        // 动态定位：选中的容器紧跟分段控件
        skillsMarketContainer?.frame.origin.y = sourceY
        skillsGitContainer?.frame.origin.y = sourceY
        skillsDirContainer?.frame.origin.y = sourceY
        skillsZipContainer?.frame.origin.y = sourceY

        // 动态调整配置区总高度
        let containerH: CGFloat
        switch idx {
        case 0: containerH = (skillsMarketContainer?.frame.height ?? 0)
        case 1: containerH = (skillsGitContainer?.frame.height ?? 0)
        case 2: containerH = (skillsDirContainer?.frame.height ?? 0)
        case 3: containerH = (skillsZipContainer?.frame.height ?? 0)
        default: containerH = 0
        }
        skillsRepoConfigView?.frame.size.height = sourceY + containerH
        // 非"发现"的市场模式时清空列表
        if idx != 0 {
            guard let lc = skillsListContainer else { return }
            lc.subviews.forEach { $0.removeFromSuperview() }
            let empty = NSTextField(frame: NSRect(x: 16, y: 8, width: lc.frame.width - 32, height: 24))
            empty.isEditable = false; empty.isBordered = false; empty.backgroundColor = .clear
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = NSColor.tertiaryLabelColor
            empty.stringValue = idx == 1 ? "输入 Git 仓库 URL 后点击「克隆安装」" : (idx == 2 ? "点击「选择目录」导入本地技能" : "点击「选择压缩包」导入 .zip 技能")
            empty.alignment = .center
            lc.addSubview(empty)
            adjustSkillsListHeight(lc, maxY: 48)
        }
    }

    // MARK: - Repo Popup Changed

    @objc func skillsRepoPopupChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        let isCustom = (idx >= AppConfig.presetRepos.count)
        skillsRepoField?.isHidden = !isCustom
        skillsPathField?.isHidden = !isCustom

        if !isCustom {
            let preset = AppConfig.presetRepos[idx]
            var c = appDelegate.config
            c.skillsRepoURL = "\(preset.owner)/\(preset.repo)"
            c.skillsCatalogPath = preset.path
            c.save()
            appDelegate.config = c
            skillsRepoField?.stringValue = c.skillsRepoURL
            skillsPathField?.stringValue = c.skillsCatalogPath
            SkillsGitHubClient.shared.invalidateCache()
            skillsRemoteItems = []
            skillsRemoteContents = [:]
            skillsRefreshRemote(sender)
        }
    }

    // MARK: - Repo Field Changed

    @objc func skillsRepoFieldChanged(_ sender: NSTextField) {
        var c = appDelegate.config
        if sender == skillsRepoField {
            c.skillsRepoURL = sender.stringValue
        } else if sender == skillsPathField {
            c.skillsCatalogPath = sender.stringValue
        }
        c.save()
        appDelegate.config = c
        SkillsGitHubClient.shared.invalidateCache()
    }

    // MARK: - Refresh Remote

    @objc func skillsRefreshRemote(_ sender: Any) {
        skillsStatusLabel.stringValue = "正在获取远程技能列表..."
        skillsStatusLabel.textColor = NSColor.tertiaryLabelColor

        let parts = appDelegate.config.skillsRepoURL.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
            skillsStatusLabel.stringValue = "仓库地址格式错误，应为 owner/repo"
            skillsStatusLabel.textColor = NSColor.systemRed
            return
        }
        let owner = String(parts[0])
        let repo = String(parts[1])
        let path = appDelegate.config.skillsCatalogPath

        SkillsGitHubClient.shared.fetchCatalog(owner: owner, repo: repo, path: path) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let items):
                // 标记已安装状态
                let localNames = SkillsManager.shared.scanAll().map { $0.name.lowercased() }
                self.skillsRemoteItems = items.map { item in
                    var m = item
                    m.isInstalled = localNames.contains(item.name.lowercased())
                    return m
                }
                self.rebuildSkillsDiscoverList()
                self.skillsStatusLabel.stringValue = "发现 \(items.count) 个远程技能"
                self.skillsStatusLabel.textColor = NSColor.tertiaryLabelColor

                // 异步获取每个技能的描述
                self.fetchRemoteDetails(items: self.skillsRemoteItems)

            case .failure(let err):
                self.skillsStatusLabel.stringValue = err.description
                self.skillsStatusLabel.textColor = NSColor.systemRed
            }
        }
    }

    // MARK: - Fetch Remote Details (async enrich)

    private func fetchRemoteDetails(items: [SkillItem]) {
        for (index, item) in items.enumerated() {
            SkillsGitHubClient.shared.fetchSkillDetail(item) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let (content, updated)):
                    if index < self.skillsRemoteItems.count {
                        self.skillsRemoteItems[index] = updated
                        // 存储内容用于后续安装
                        self.skillsRemoteContents[updated.name] = content
                    }
                    // 增量更新 UI（仅更新当前发现视图时）
                    if self.skillsSegment.selectedSegment == 1 {
                        self.rebuildSkillsDiscoverList()
                    }
                case .failure:
                    break  // 保持"加载中..."
                }
            }
        }
    }

    // MARK: - Rebuild Installed List

    @objc func installedFilterChanged(_ sender: NSSegmentedControl) {
        skillsSelectedTag = nil
        rebuildSkillsList()
    }

    @objc func skillsTagClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("tag:") else { return }
        let tag = String(id.dropFirst(4))
        skillsSelectedTag = (skillsSelectedTag == tag) ? nil : tag
        rebuildSkillsList()
    }

    // MARK: - Batch Operations

    @objc func skillsToggleSelect(_ sender: NSButton) {
        let idx = sender.tag
        if sender.state == .on {
            skillsSelectedIndices.insert(idx)
        } else {
            skillsSelectedIndices.remove(idx)
        }
        // 不完全重建，只刷新批量操作栏
        rebuildSkillsList()
    }

    @objc func skillsBatchUninstall(_ sender: NSButton) {
        let allItems = SkillsManager.shared.scanAll()
        let filterIdx = installedFilterSegment?.selectedSegment ?? 0
        let displayItems: [SkillItem]
        switch filterIdx {
        case 1: displayItems = allItems.filter { $0.type == .skill }
        case 2: displayItems = allItems.filter { $0.type == .command }
        default: displayItems = allItems
        }

        var success = 0
        var failed = 0
        for idx in skillsSelectedIndices.sorted().reversed() {
            guard idx < displayItems.count else { continue }
            if SkillsManager.shared.uninstall(displayItems[idx]) {
                success += 1
            } else {
                failed += 1
            }
        }
        skillsSelectedIndices.removeAll()
        skillsStatusLabel.stringValue = "✅ 批量卸载完成：成功 \(success) 个\(failed > 0 ? "，失败 \(failed) 个" : "")"
        skillsStatusLabel.textColor = failed > 0 ? NSColor.systemOrange : NSColor.systemGreen
        rebuildSkillsList()
    }

    @objc func skillsClearSelection(_ sender: NSButton) {
        skillsSelectedIndices.removeAll()
        rebuildSkillsList()
    }

    // MARK: - Preset Actions

    @objc func skillsCreatePreset(_ sender: NSButton) {
        // 从当前选中项创建预设
        let allItems = SkillsManager.shared.scanAll()
        let filterIdx = installedFilterSegment?.selectedSegment ?? 0
        let displayItems: [SkillItem]
        switch filterIdx {
        case 1: displayItems = allItems.filter { $0.type == .skill }
        case 2: displayItems = allItems.filter { $0.type == .command }
        default: displayItems = allItems
        }

        let selectedItems = skillsSelectedIndices.isEmpty
            ? displayItems
            : skillsSelectedIndices.sorted().compactMap { idx -> SkillItem? in
                idx < displayItems.count ? displayItems[idx] : nil
            }

        if selectedItems.isEmpty {
            skillsStatusLabel.stringValue = "没有可用的技能来创建预设"
            skillsStatusLabel.textColor = NSColor.systemRed
            return
        }

        // 弹出输入预设名称的对话框
        let alert = NSAlert()
        alert.messageText = "新建预设"
        alert.informativeText = "将 \(selectedItems.count) 个技能归入预设"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "预设名称，如「前端开发」"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            skillsStatusLabel.stringValue = "预设名称不能为空"
            skillsStatusLabel.textColor = NSColor.systemRed
            return
        }

        let preset = SkillPreset(
            name: name,
            skillNames: selectedItems.map { $0.name },
            agents: ["claude-code"]
        )
        PresetManager.shared.addPreset(preset)
        skillsSelectedIndices.removeAll()
        skillsStatusLabel.stringValue = "✅ 已创建预设「\(name)」（\(selectedItems.count) 个技能）"
        skillsStatusLabel.textColor = NSColor.systemGreen
        rebuildSkillsList()
    }

    @objc func skillsActivatePreset(_ sender: NSButton) {
        let idx = sender.tag
        let result = PresetManager.shared.activatePreset(at: idx)
        let name = PresetManager.shared.presets[idx].name
        skillsStatusLabel.stringValue = "✅ 预设「\(name)」已激活（同步 \(result.activated) 项\(result.failed > 0 ? "，失败 \(result.failed)" : "")）"
        skillsStatusLabel.textColor = result.failed > 0 ? NSColor.systemOrange : NSColor.systemGreen
        rebuildSkillsList()
    }

    @objc func skillsDeactivatePreset(_ sender: NSButton) {
        let idx = sender.tag
        let result = PresetManager.shared.deactivatePreset(at: idx)
        let name = PresetManager.shared.presets[idx].name
        skillsStatusLabel.stringValue = "预设「\(name)」已停用（移除 \(result.removed) 项）"
        skillsStatusLabel.textColor = NSColor.tertiaryLabelColor
        rebuildSkillsList()
    }

    @objc func skillsDeletePreset(_ sender: NSButton) {
        let idx = sender.tag
        let name = PresetManager.shared.presets[idx].name
        PresetManager.shared.removePreset(at: idx)
        skillsStatusLabel.stringValue = "已删除预设「\(name)」"
        skillsStatusLabel.textColor = NSColor.tertiaryLabelColor
        rebuildSkillsList()
    }

    func rebuildSkillsList() {
        guard let listContainer = skillsListContainer else { return }
        listContainer.subviews.forEach { $0.removeFromSuperview() }

        let allItems = SkillsManager.shared.scanAll()
        let skills = allItems.filter { $0.type == .skill }
        let commands = allItems.filter { $0.type == .command }
        var y: CGFloat = 0
        let listW = listContainer.frame.width

        if skills.isEmpty && commands.isEmpty {
            let empty = NSTextField(frame: NSRect(x: 16, y: 8, width: listW - 32, height: 40))
            empty.isEditable = false; empty.isBordered = false; empty.backgroundColor = .clear
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = NSColor.tertiaryLabelColor
            empty.stringValue = "暂无已安装的技能或命令\n技能目录: ~/.claude/skills/  命令目录: ~/.claude/commands/"
            empty.alignment = .center
            listContainer.addSubview(empty)
            skillsStatusLabel.stringValue = "已安装 0 个"
            adjustSkillsListHeight(listContainer, maxY: 60)
            return
        }

        // 筛选分段控件
        let filterSeg = NSSegmentedControl(labels: ["全部", "技能", "命令"], trackingMode: .selectOne, target: self, action: #selector(installedFilterChanged(_:)))
        if installedFilterSegment == nil {
            filterSeg.selectedSegment = 0
            installedFilterSegment = filterSeg
        } else {
            installedFilterSegment.target = self
            installedFilterSegment.action = #selector(installedFilterChanged(_:))
        }
        installedFilterSegment.frame = NSRect(x: 0, y: 0, width: 200, height: 26)
        installedFilterSegment.sizeToFit()
        let filterGroup = SettingsGroupView(header: nil, rows: [
            SettingsRowView(title: "筛选", accessory: installedFilterSegment, isFirst: true, isLast: true),
        ])
        filterGroup.frame.origin = NSPoint(x: 0, y: y)
        filterGroup.autoresizingMask = .width
        listContainer.addSubview(filterGroup)
        y += filterGroup.frame.height + 4

        // --- 预设区域 ---
        let presets = PresetManager.shared.presets
        if !presets.isEmpty || !allItems.isEmpty {
            let addPresetBtn = NSButton(frame: NSRect(x: 0, y: y, width: 120, height: 22))
            addPresetBtn.title = "＋ 新建预设"
            addPresetBtn.bezelStyle = .recessed
            addPresetBtn.font = NSFont.systemFont(ofSize: 11)
            addPresetBtn.target = self
            addPresetBtn.action = #selector(skillsCreatePreset(_:))
            listContainer.addSubview(addPresetBtn)
            y += 26

            // 显示已有预设
            if !presets.isEmpty {
                let presetRows = presets.enumerated().map { (idx, preset) -> SettingsRowView in
                    let accView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))

                    let activateBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 56, height: 24))
                    activateBtn.title = "激活"
                    activateBtn.bezelStyle = .rounded
                    activateBtn.font = NSFont.systemFont(ofSize: 10)
                    activateBtn.tag = idx
                    activateBtn.target = self
                    activateBtn.action = #selector(skillsActivatePreset(_:))
                    accView.addSubview(activateBtn)

                    let deactBtn = NSButton(frame: NSRect(x: 60, y: 0, width: 56, height: 24))
                    deactBtn.title = "停用"
                    deactBtn.bezelStyle = .rounded
                    deactBtn.font = NSFont.systemFont(ofSize: 10)
                    deactBtn.tag = idx
                    deactBtn.target = self
                    deactBtn.action = #selector(skillsDeactivatePreset(_:))
                    accView.addSubview(deactBtn)

                    let delBtn = NSButton(frame: NSRect(x: 120, y: 0, width: 40, height: 24))
                    delBtn.title = "删除"
                    delBtn.bezelStyle = .rounded
                    delBtn.font = NSFont.systemFont(ofSize: 10)
                    delBtn.contentTintColor = NSColor.systemRed
                    delBtn.tag = idx
                    delBtn.target = self
                    delBtn.action = #selector(skillsDeletePreset(_:))
                    accView.addSubview(delBtn)

                    let agentIcons = preset.agents.compactMap { id -> String? in
                        SkillsManager.knownAgents.first(where: { $0.id == id })?.icon
                    }.joined()
                    let subtitle = "\(preset.skillNames.count) 个技能  \(agentIcons)"

                    return SettingsRowView(
                        title: "📦 \(preset.name)",
                        subtitle: subtitle,
                        accessory: accView,
                        isFirst: idx == 0,
                        isLast: idx == presets.count - 1
                    )
                }
                let presetGroup = SettingsGroupView(header: "预设 (\(presets.count))", rows: presetRows)
                presetGroup.frame.origin = NSPoint(x: 0, y: y)
                presetGroup.autoresizingMask = .width
                listContainer.addSubview(presetGroup)
                y += presetGroup.frame.height + 8
            }
        }

        let filterIdx = installedFilterSegment.selectedSegment
        var displayItems: [SkillItem]
        switch filterIdx {
        case 1: displayItems = skills
        case 2: displayItems = commands
        default: displayItems = allItems
        }

        // 标签 chip 行：聚合所有 tags
        let allTags = Set(displayItems.flatMap { $0.tags }).sorted()
        if !allTags.isEmpty {
            var chipX: CGFloat = 0
            for tag in allTags {
                let chip = NSButton(frame: NSRect(x: chipX, y: y, width: 0, height: 22))
                chip.title = " \(tag) "
                chip.bezelStyle = .recessed
                chip.font = NSFont.systemFont(ofSize: 10)
                chip.isBordered = true
                chip.sizeToFit()
                chip.frame.size.width += 12
                chip.frame.size.height = 22
                // 高亮当��选中标签
                if skillsSelectedTag == tag {
                    chip.contentTintColor = NSColor.controlAccentColor
                }
                chip.identifier = NSUserInterfaceItemIdentifier("tag:\(tag)")
                chip.target = self
                chip.action = #selector(skillsTagClicked(_:))
                listContainer.addSubview(chip)
                chipX += chip.frame.width + 4
                if chipX > listW - 32 {
                    // 换行
                    y += 26
                    chipX = 0
                }
            }
            y += 28
        }

        // 按标签��选
        if let selectedTag = skillsSelectedTag, !selectedTag.isEmpty {
            displayItems = displayItems.filter { $0.tags.contains(selectedTag) }
        }

        // 批量操作栏（有选中项时显示）
        if !skillsSelectedIndices.isEmpty {
            let bar = NSView(frame: NSRect(x: 0, y: y, width: listW, height: 32))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
            bar.layer?.cornerRadius = 6

            let countLabel = NSTextField(frame: NSRect(x: 12, y: 4, width: 120, height: 24))
            countLabel.isEditable = false; countLabel.isBordered = false; countLabel.backgroundColor = .clear
            countLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            countLabel.textColor = NSColor.labelColor
            countLabel.stringValue = "已选 \(skillsSelectedIndices.count) 项"
            bar.addSubview(countLabel)

            let batchDeleteBtn = NSButton(frame: NSRect(x: listW - 200, y: 4, width: 80, height: 24))
            batchDeleteBtn.title = "批量卸载"
            batchDeleteBtn.bezelStyle = .rounded
            batchDeleteBtn.font = NSFont.systemFont(ofSize: 11)
            batchDeleteBtn.contentTintColor = NSColor.systemRed
            batchDeleteBtn.target = self
            batchDeleteBtn.action = #selector(skillsBatchUninstall(_:))
            bar.addSubview(batchDeleteBtn)

            let clearBtn = NSButton(frame: NSRect(x: listW - 110, y: 4, width: 80, height: 24))
            clearBtn.title = "取消选择"
            clearBtn.bezelStyle = .rounded
            clearBtn.font = NSFont.systemFont(ofSize: 11)
            clearBtn.target = self
            clearBtn.action = #selector(skillsClearSelection(_:))
            bar.addSubview(clearBtn)

            listContainer.addSubview(bar)
            y += 40
        }

        // 按 sourceGroup 分组显示
        if displayItems.isEmpty {
            let empty = NSTextField(frame: NSRect(x: 16, y: y + 4, width: listW - 32, height: 24))
            empty.isEditable = false; empty.isBordered = false; empty.backgroundColor = .clear
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = NSColor.tertiaryLabelColor
            empty.stringValue = "当前筛选下无内容"
            empty.alignment = .center
            listContainer.addSubview(empty)
            y += 32
        } else {
            // 按 sourceGroup 分组
            var grouped: [(group: String, url: String?, items: [SkillItem])] = []
            for item in displayItems {
                let g = item.sourceGroup ?? "其他"
                if let idx = grouped.firstIndex(where: { $0.group == g }) {
                    grouped[idx].items.append(item)
                } else {
                    grouped.append((group: g, url: item.sourceURL, items: [item]))
                }
            }

            // 构建每个组的 tag offset 映射
            var globalIdx = 0
            for group in grouped {
                let rows = group.items.enumerated().map { (idx, item) -> SettingsRowView in
                    let itemIdx = globalIdx + idx
                    let btn = NSButton(title: "卸载", target: self, action: #selector(skillsUninstallItem(_:)))
                    btn.bezelStyle = .rounded
                    btn.font = NSFont.systemFont(ofSize: 11)
                    btn.tag = itemIdx

                    // checkbox 选中状态
                    let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(skillsToggleSelect(_:)))
                    checkbox.setButtonType(.switch)
                    checkbox.state = skillsSelectedIndices.contains(itemIdx) ? .on : .off
                    checkbox.tag = itemIdx
                    // 将 checkbox 和卸载按钮放在 accessory 容器中
                    let accView = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
                    checkbox.frame = NSRect(x: 0, y: 0, width: 20, height: 24)
                    btn.frame = NSRect(x: 24, y: 0, width: 60, height: 24)
                    accView.addSubview(checkbox)
                    accView.addSubview(btn)

                    // Agent 徽章 + 来源
                    let agents = SkillsManager.shared.detectAgents(for: item)
                    var subtitle = item.description.isEmpty ? "" : String(item.description.prefix(50))
                    if !agents.isEmpty {
                        let badges = agents.compactMap { id -> String? in
                            SkillsManager.knownAgents.first(where: { $0.id == id })?.icon
                        }.joined()
                        if !subtitle.isEmpty { subtitle += "  " }
                        subtitle += badges
                    }

                    let displayName = item.type == .command ? "/\(item.name)" : item.name
                    let row = SettingsRowView(
                        title: displayName,
                        subtitle: subtitle.isEmpty ? nil : subtitle,
                        accessory: accView,
                        isFirst: idx == 0,
                        isLast: idx == group.items.count - 1
                    )
                    // 点击行预览 SKILL.md
                    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(skillsPreviewClicked(_:)))
                    row.addGestureRecognizer(clickGesture)
                    row.identifier = NSUserInterfaceItemIdentifier("skill-\(itemIdx)")
                    return row
                }

                // 组标题：名称 (数量) + 来源链接
                var header = "\(group.group) (\(group.items.count))"
                if let url = group.url, !url.isEmpty {
                    header += "  \(url)"
                }
                let groupView = SettingsGroupView(header: header, rows: rows)
                groupView.frame.origin = NSPoint(x: 0, y: y)
                groupView.autoresizingMask = .width
                listContainer.addSubview(groupView)
                y += groupView.frame.height + 4
                globalIdx += group.items.count
            }
        }

        skillsStatusLabel.stringValue = "已安装 \(allItems.count) 个（技能 \(skills.count)，命令 \(commands.count)）"
        adjustSkillsListHeight(listContainer, maxY: y)
    }

    // MARK: - Rebuild Discover List

    func rebuildSkillsDiscoverList() {
        guard let listContainer = skillsListContainer else { return }
        listContainer.subviews.forEach { $0.removeFromSuperview() }

        let items = skillsRemoteItems
        var y: CGFloat = 0
        let listW = listContainer.frame.width

        if items.isEmpty {
            let empty = NSTextField(frame: NSRect(x: 16, y: 8, width: listW - 32, height: 40))
            empty.isEditable = false; empty.isBordered = false; empty.backgroundColor = .clear
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = NSColor.tertiaryLabelColor
            empty.stringValue = "点击「🔄 刷新」获取远程技能列表"
            empty.alignment = .center
            listContainer.addSubview(empty)
            adjustSkillsListHeight(listContainer, maxY: 60)
            return
        }

        // 更新已安装状态
        let localNames = SkillsManager.shared.scanAll().map { $0.name.lowercased() }

        let rows = items.enumerated().map { (idx, item) -> SettingsRowView in
            let isInstalled = localNames.contains(item.name.lowercased())
            let btn: NSButton
            if isInstalled {
                btn = NSButton(title: "已安装", target: nil, action: nil)
                btn.isEnabled = false
            } else {
                btn = NSButton(title: "安装", target: self, action: #selector(skillsInstallItem(_:)))
                btn.tag = idx
            }
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 11)

            return SettingsRowView(
                title: item.name,
                subtitle: item.description.isEmpty ? nil : String(item.description.prefix(80)),
                accessory: btn,
                isFirst: idx == 0,
                isLast: idx == items.count - 1
            )
        }

        let repoName = appDelegate.config.skillsRepoURL
        let group = SettingsGroupView(header: "远程技能 — \(repoName) (\(items.count))", rows: rows)
        group.frame.origin = NSPoint(x: 0, y: y)
        group.autoresizingMask = .width
        listContainer.addSubview(group)
        y += group.frame.height + 8

        adjustSkillsListHeight(listContainer, maxY: y)
    }

    // MARK: - Install Action

    @objc func skillsInstallItem(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < skillsRemoteItems.count else { return }
        let item = skillsRemoteItems[idx]

        // 优先使用已缓存的内容
        if let content = skillsRemoteContents[item.name], !content.isEmpty {
            performInstall(item: item, content: content)
        } else {
            sender.title = "安装中..."
            sender.isEnabled = false
            SkillsGitHubClient.shared.fetchSkillDetail(item) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let (content, updated)):
                    self.performInstall(item: updated, content: content)
                case .failure(let err):
                    self.skillsStatusLabel.stringValue = "安装失败: \(err.description)"
                    self.skillsStatusLabel.textColor = NSColor.systemRed
                    sender.title = "安装"
                    sender.isEnabled = true
                }
            }
        }
    }

    private func performInstall(item: SkillItem, content: String) {
        if SkillsManager.shared.installSkill(item, content: content) {
            // 更新远程列表的安装状态
            if let idx = skillsRemoteItems.firstIndex(where: { $0.name == item.name }) {
                skillsRemoteItems[idx].isInstalled = true
            }
            skillsStatusLabel.stringValue = "✅ 已安装「\(item.name)」"
            skillsStatusLabel.textColor = NSColor.systemGreen

            // 刷新当前视图
            if skillsSegment.selectedSegment == 1 {
                rebuildSkillsDiscoverList()
            } else {
                rebuildSkillsList()
            }
        } else {
            skillsStatusLabel.stringValue = "安装失败：写入文件失败"
            skillsStatusLabel.textColor = NSColor.systemRed
        }
    }

    // MARK: - Uninstall Action

    @objc func skillsUninstallItem(_ sender: NSButton) {
        let allItems = SkillsManager.shared.scanAll()
        let filterIdx = installedFilterSegment?.selectedSegment ?? 0
        let displayItems: [SkillItem]
        switch filterIdx {
        case 1: displayItems = allItems.filter { $0.type == .skill }
        case 2: displayItems = allItems.filter { $0.type == .command }
        default: displayItems = allItems
        }
        // tag 是扁平化后的全局索引（与分组显示一致）
        let idx = sender.tag
        guard idx < displayItems.count else { return }
        let item = displayItems[idx]

        if SkillsManager.shared.uninstall(item) {
            // 更新远程列表的安装状态
            if let rIdx = skillsRemoteItems.firstIndex(where: { $0.name.lowercased() == item.name.lowercased() }) {
                skillsRemoteItems[rIdx].isInstalled = false
            }
            skillsStatusLabel.stringValue = "已卸载「\(item.name)」"
            skillsStatusLabel.textColor = NSColor.tertiaryLabelColor
            rebuildSkillsList()
        } else {
            skillsStatusLabel.stringValue = "卸载失败：删除文件失败"
            skillsStatusLabel.textColor = NSColor.systemRed
        }
    }

    // MARK: - Git Install

    @objc func skillsGitInstall(_ sender: NSButton) {
        guard let url = skillsGitField?.stringValue, !url.isEmpty else {
            skillsStatusLabel.stringValue = "请输入 Git 仓库 URL"
            skillsStatusLabel.textColor = NSColor.systemRed
            return
        }
        sender.title = "克隆中..."
        sender.isEnabled = false
        skillsStatusLabel.stringValue = "正在从 Git 仓库克隆..."
        skillsStatusLabel.textColor = NSColor.tertiaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            SkillsManager.shared.installFromGit(url: url) { result in
                DispatchQueue.main.async {
                    sender.title = "克隆安装"
                    sender.isEnabled = true
                    switch result {
                    case .success(let items):
                        self.skillsStatusLabel.stringValue = "✅ 从 Git 安装了 \(items.count) 个技能"
                        self.skillsStatusLabel.textColor = NSColor.systemGreen
                        self.rebuildSkillsList()
                    case .failure(let err):
                        self.skillsStatusLabel.stringValue = err.description
                        self.skillsStatusLabel.textColor = NSColor.systemRed
                    }
                }
            }
        }
    }

    // MARK: - Directory Import

    @objc func skillsDirImport(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择技能目录"
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        switch SkillsManager.shared.importFromDirectory(path: path) {
        case .success(let items):
            skillsStatusLabel.stringValue = "✅ 从目录导入了 \(items.count) 个技能"
            skillsStatusLabel.textColor = NSColor.systemGreen
            rebuildSkillsList()
        case .failure(let err):
            skillsStatusLabel.stringValue = err.description
            skillsStatusLabel.textColor = NSColor.systemRed
        }
    }

    // MARK: - Zip Import

    @objc func skillsZipImport(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "选择技能压缩包"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.init(filenameExtension: "zip")!]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        skillsStatusLabel.stringValue = "正在解压安装..."
        skillsStatusLabel.textColor = NSColor.tertiaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            SkillsManager.shared.installFromZip(path: url.path) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let items):
                        self.skillsStatusLabel.stringValue = "✅ 从压缩包安装了 \(items.count) 个技能"
                        self.skillsStatusLabel.textColor = NSColor.systemGreen
                        self.rebuildSkillsList()
                    case .failure(let err):
                        self.skillsStatusLabel.stringValue = err.description
                        self.skillsStatusLabel.textColor = NSColor.systemRed
                    }
                }
            }
        }
    }

    // MARK: - Layout Helper

    private func adjustSkillsListHeight(_ listContainer: NSView, maxY: CGFloat) {
        listContainer.frame.size.height = maxY
        // 更新父级 FlippedView 的 frame，使滚动正确
        if let docView = skillsListContainer?.superview {
            let totalH = skillsListTopY + maxY + 20
            docView.frame.size.height = totalH
        }
    }

    // MARK: - Skill Preview

    @objc func skillsPreviewClicked(_ sender: NSClickGestureRecognizer) {
        guard let row = sender.view as? SettingsRowView,
              let identifier = row.identifier?.rawValue,
              identifier.hasPrefix("skill-"),
              let idx = Int(identifier.replacingOccurrences(of: "skill-", with: "")) else { return }
        let allItems = SkillsManager.shared.scanAll()
        let filterIdx = installedFilterSegment?.selectedSegment ?? 0
        let displayItems: [SkillItem]
        switch filterIdx {
        case 1: displayItems = allItems.filter { $0.type == .skill }
        case 2: displayItems = allItems.filter { $0.type == .command }
        default: displayItems = allItems
        }
        guard idx < displayItems.count else { return }
        let item = displayItems[idx]
        showSkillPreview(item)
    }

    private func showSkillPreview(_ item: SkillItem) {
        guard let path = item.localPath,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            skillsStatusLabel.stringValue = "无法读取技能文件"
            skillsStatusLabel.textColor = NSColor.systemRed
            return
        }

        // 关闭已有预览窗口
        skillsPreviewWindow?.close()

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.title = "预览: \(item.name)"
        panel.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: panel.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 500))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isRichText = false
        textView.string = content
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.sizeToFit()

        scrollView.documentView = textView
        panel.contentView?.addSubview(scrollView)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        skillsPreviewWindow = panel
    }
}

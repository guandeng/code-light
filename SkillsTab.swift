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
        y += segGroup.frame.height + 8

        // --- 安装来源配置区（仅"发现"模式可见）---
        skillsRepoConfigView = NSView(frame: NSRect(x: 16, y: y, width: contentW - 32, height: 0))
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
        y += ry

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

        // 记录「已安装」和「发现」模式下列表的不同起始 Y
        // 已安装模式：列表紧跟在分段控件之后
        skillsInstalledListY = segGroup.frame.origin.y + segGroup.frame.height + 8
        skillsDiscoverListY = y

        // 初始加载已安装列表（手动定位到紧凑位置）
        skillsStatusLabel.frame.origin.y = skillsInstalledListY
        skillsListContainer.frame.origin.y = skillsInstalledListY + 24
        skillsListTopY = skillsInstalledListY + 24

        // 初始加载已安装列表
        rebuildSkillsList()
    }

    // MARK: - Segment Changed

    @objc func skillsSegmentChanged(_ sender: NSSegmentedControl) {
        let isDiscover = sender.selectedSegment == 1
        skillsRepoConfigView.isHidden = !isDiscover

        // 动态调整列表位置：已安装模式紧凑，发现模式留出配置区空间
        let listY = isDiscover ? skillsDiscoverListY : skillsInstalledListY
        skillsStatusLabel.frame.origin.y = listY
        skillsListContainer.frame.origin.y = listY + 24
        skillsListTopY = listY + 24

        if isDiscover {
            updateInstallSourceView()
            if skillsRemoteItems.isEmpty {
                skillsRefreshRemote(sender)
            } else {
                rebuildSkillsDiscoverList()
            }
        } else {
            rebuildSkillsList()
        }
    }

    // MARK: - Install Source Changed

    @objc func installSourceChanged(_ sender: NSSegmentedControl) {
        updateInstallSourceView()
        // 切换到市场时自动加载
        if sender.selectedSegment == 0 && skillsRemoteItems.isEmpty {
            skillsRefreshRemote(sender)
        }
    }

    private func updateInstallSourceView() {
        let idx = installSourceSegment?.selectedSegment ?? 0
        skillsMarketContainer?.isHidden = (idx != 0)
        skillsGitContainer?.isHidden = (idx != 1)
        skillsDirContainer?.isHidden = (idx != 2)
        skillsZipContainer?.isHidden = (idx != 3)
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
        y += filterGroup.frame.height + 8

        let filterIdx = installedFilterSegment.selectedSegment
        var displayItems: [SkillItem]
        switch filterIdx {
        case 1: displayItems = skills
        case 2: displayItems = commands
        default: displayItems = allItems
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
                    let btn = NSButton(title: "卸载", target: self, action: #selector(skillsUninstallItem(_:)))
                    btn.bezelStyle = .rounded
                    btn.font = NSFont.systemFont(ofSize: 11)
                    btn.tag = globalIdx + idx

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
                    return SettingsRowView(
                        title: displayName,
                        subtitle: subtitle.isEmpty ? nil : subtitle,
                        accessory: btn,
                        isFirst: idx == 0,
                        isLast: idx == group.items.count - 1
                    )
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
                y += groupView.frame.height + 8
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
            docView.frame.size.height = max(totalH, docView.frame.height)
        }
    }
}
